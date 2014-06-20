//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//


// Conversions between different Unicode encodings.  Note that UTF-16 and
// UTF-32 decoding are *not* currently resilient to erroneous data.

enum UTFDecodeResult {
  case Result(UnicodeScalar)
  case EmptyInput
  case Error

  func isEmptyInput() -> Bool {
    switch self {
    case .EmptyInput:
      return true
    default:
      return false
    }
  }
}

protocol UnicodeCodec {
  typealias CodeUnit

  init()

  /// Start or continue decoding a UTF sequence.
  ///
  /// In order to decode a code unit sequence completely, this function should
  /// be called repeatedly until it returns `UTFDecodeResult.EmptyInput`.
  /// Checking that the generator was exhausted is not sufficient.  The decoder
  /// can have an internal buffer that is pre-filled with data from the input
  /// generator.
  ///
  /// Because of buffering, it is impossible to find the corresponing position
  /// in the generator for a given returned `UnicodeScalar` or an error.
  mutating func decode<
    G : Generator where G.Element == CodeUnit
  >(inout next: G) -> UTFDecodeResult

  class func encode<
    S : Sink where S.Element == CodeUnit
  >(input: UnicodeScalar, inout output: S)
}

struct UTF8 : UnicodeCodec {

  typealias CodeUnit = UInt8

  init() {}

  /// Returns the number of expected trailing bytes for a given first byte: 0,
  /// 1, 2 or 3.  If the first byte can not start a valid UTF-8 code unit
  /// sequence, returns 4.
  static func _numTrailingBytes(cu0: CodeUnit) -> UInt8 {
    if _fastPath(cu0 & 0x80 == 0) {
      // 0x00 -- 0x7f: 1-byte sequences.
      return 0
    }

    // 0xc0 -- 0xc1: invalid first byte.
    // 0xc2 -- 0xdf: 2-byte sequences.
    // 0xe0 -- 0xef: 3-byte sequences.
    // 0xf0 -- 0xf4: 4-byte sequences.
    // 0xf5 -- 0xff: invalid first byte.

    // The rules above are represented as a lookup table.  The lookup table
    // consists of two words, where `high` contains the high bit of the result,
    // `low` contains the low bit.
    //
    // Bit patterns:
    // high | low | meaning
    // -----+-----+----------------
    //   0  |  0  | 2-byte sequence
    //   0  |  1  | 3-byte sequence
    //   1  |  0  | 4-byte sequence
    //   1  |  1  | invalid
    //
    // This implementation allows us to handle these cases without branches.

    //    ---------0xf?-------  ---------0xe?-------  ---------0xd?-------  ---------0xc?-------
    let low: UInt64 =
        0b1111_1111__1110_0000__1111_1111__1111_1111__0000_0000__0000_0000__0000_0000__0000_0011
    let high: UInt64 =
        0b1111_1111__1111_1111__0000_0000__0000_0000__0000_0000__0000_0000__0000_0000__0000_0011

    let index = UInt64(max(0, Int(cu0) - 0xc0))
    let highBit = ((high >> index) & 1) << 1
    let lowBit = (low >> index) & 1
    return UInt8(1 + (highBit | lowBit))
  }

  /// Lookahead buffer used for UTF-8 decoding.  New bytes are inserted at LSB,
  /// and bytes are read at MSB.
  var _decodeLookahead: UInt32 = 0

  /// Flags with layout: `0bxxxx_yyyy`.
  ///
  /// `xxxx` is the EOF flag.  It means that the input generator has signaled
  /// end of sequence.  Out of the four bits, only one bit can be set.  The bit
  /// position specifies how many bytes have been consumed from the lookahead
  /// buffer already.  A value of `1000` means that there are `yyyy` bytes in
  /// the buffer, `0100` means that there are `yyyy - 1` bytes, `0010` --
  /// `yyyy - 2`, `0001` -- `yyyy - 3`.
  ///
  /// `yyyy` specifies how many bytes are valid in the lookahead buffer.  Value
  /// is expressed in unary code.  Valid values: `1111` (4), `0111` (3),
  /// `0011` (2), `0001` (1), `0000` (0).
  ///
  /// This representation is crafted to allow one to consume a byte from a
  /// buffer with a shift, and update flags with a single-bit right shift.
  var _lookaheadFlags: UInt8 = 0

  /// Return `true` if the LSB bytes in `buffer` are well-formed UTF-8 code
  /// unit sequence.
  static func _isValidUTF8Impl(buffer: UInt32, length: UInt8) -> Bool {
    switch length {
    case 4:
      let cu3 = UInt8((buffer >> 24) & 0xff)
      if cu3 < 0x80 || cu3 > 0xbf {
        return false
      }
      fallthrough
    case 3:
      let cu2 = UInt8((buffer >> 16) & 0xff)
      if cu2 < 0x80 || cu2 > 0xbf {
        return false
      }
      fallthrough
    case 2:
      let cu0 = UInt8(buffer & 0xff)
      let cu1 = UInt8((buffer >> 8) & 0xff)
      switch cu0 {
      case 0xe0:
        if cu1 < 0xa0 || cu1 > 0xbf {
          return false
        }
      case 0xed:
        if cu1 < 0x80 || cu1 > 0x9f {
          return false
        }
      case 0xf0:
        if cu1 < 0x90 || cu1 > 0xbf {
          return false
        }
      case 0xf4:
        if cu1 < 0x80 || cu1 > 0x8f {
          return false
        }
      default:
        _sanityCheck(cu0 >= 0xc2 && cu0 <= 0xf4,
            "invalid first bytes should be handled in the caller")
        if cu1 < 0x80 || cu1 > 0xbf {
          return false
        }
      }
      return true

    default:
      _fatalError("one-byte sequences should be handled in the caller")
    }
  }

  /// Return `true` if the LSB bytes in `buffer` are well-formed UTF-8 code
  /// unit sequence.
  static func _isValidUTF8(buffer: UInt32, validBytes: UInt8) -> Bool {
    _sanityCheck(validBytes & 0b0000_1111 != 0,
        "input buffer should not be empty")

    let cu0 = UInt8(buffer & 0xff)
    let trailingBytes = _numTrailingBytes(cu0)
    switch trailingBytes {
    case 0:
      return true

    case 1, 2, 3:
      // We *don't* need to check the if the buffer actually contains at least
      // `trailingBytes` bytes.  Here's why.
      //
      // If the buffer is not full -- contains fewer than 4 bytes, we are at
      // EOF, and the buffer will be padded with 0x00.  Thus, an incomplete
      // code unit sequence just before EOF would be seen by code below as
      // padded with nuls.  This sequence will be rejected by the logic in
      // `_isValidUTF8Impl`, because the nul byte is not a valid continuation
      // byte for UTF-8.
      return _isValidUTF8Impl(buffer, length: trailingBytes + 1)

    default:
      return false
    }
  }

  /// Given an ill-formed sequence, find the length of its maximal subpart.
  static func _findMaximalSubpartOfIllFormedUTF8Sequence(
      var buffer: UInt32, var validBytes: UInt8) -> UInt8 {
    // FIXME: mark this function '@noinline' when we have it -- this is used
    // only in the error handling path.

    // Clear EOF flag, we don't care about it.
    validBytes &= 0b0000_1111

    _sanityCheck(validBytes != 0,
        "input buffer should not be empty")
    _sanityCheck(!UTF8._isValidUTF8(buffer, validBytes: validBytes),
        "input sequence should be ill-formed UTF-8")

    // Unicode 6.3.0, D93b:
    //
    //     Maximal subpart of an ill-formed subsequence: The longest code unit
    //     subsequence starting at an unconvertible offset that is either:
    //     a. the initial subsequence of a well-formed code unit sequence, or
    //     b. a subsequence of length one.

    // Perform case analysis.  See Unicode 6.3.0, Table 3-7. Well-Formed UTF-8
    // Byte Sequences.

    let cu0 = UInt8(buffer & 0xff)
    buffer >>= 8
    validBytes >>= 1
    if (cu0 >= 0xc2 && cu0 <= 0xdf) {
      // First byte is valid, but we know that this code unit sequence is
      // invalid, so the maximal subpart has to end after the first byte.
      return 1
    }

    if validBytes == 0 {
      return 1
    }

    let cu1 = UInt8(buffer & 0xff)
    buffer >>= 8
    validBytes >>= 1

    if (cu0 == 0xe0) {
      return (cu1 >= 0xa0 && cu1 <= 0xbf) ? 2 : 1
    }
    // FIXME: this should be cu0!
    // construct a test
    if (cu0 >= 0xe1 && cu0 <= 0xec) {
      return (cu1 >= 0x80 && cu1 <= 0xbf) ? 2 : 1
    }
    if (cu0 == 0xed) {
      return (cu1 >= 0x80 && cu1 <= 0x9f) ? 2 : 1
    }
    if (cu0 >= 0xee && cu0 <= 0xef) {
      return (cu1 >= 0x80 && cu1 <= 0xbf) ? 2 : 1
    }
    if (cu0 == 0xf0) {
      if (cu1 >= 0x90 && cu1 <= 0xbf) {
        if validBytes == 0 {
          return 2
        }

        let cu2 = UInt8(buffer & 0xff)
        return (cu2 >= 0x80 && cu2 <= 0xbf) ? 3 : 2
      }
      return 1
    }
    if (cu0 >= 0xf1 && cu0 <= 0xf3) {
      if (cu1 >= 0x80 && cu1 <= 0xbf) {
        if validBytes == 0 {
          return 2
        }

        let cu2 = UInt8(buffer & 0xff)
        return (cu2 >= 0x80 && cu2 <= 0xbf) ? 3 : 2
      }
      return 1
    }
    if (cu0 == 0xf4) {
      if (cu1 >= 0x80 && cu1 <= 0x8f) {
        if validBytes == 0 {
          return 2
        }

        let cu2 = UInt8(buffer & 0xff)
        return (cu2 >= 0x80 && cu2 <= 0xbf) ? 3 : 2
      }
      return 1
    }

    _sanityCheck((cu0 >= 0x80 && cu0 <= 0xc1) || cu0 >= 0xf5,
        "case analysis above should have handled all valid first bytes")

    // There are no well-formed sequences that start with these bytes.  Maximal
    // subpart is defined to have length 1 in these cases.
    return 1
  }

  mutating func decode<
    G : Generator where G.Element == CodeUnit
  >(inout next: G) -> UTFDecodeResult {
    // If the EOF flag is not set, fill the lookahead buffer from the input
    // generator.
    if _lookaheadFlags & 0b1111_0000 == 0 {
      // Add more bytes into the buffer until we have 4.
      while _lookaheadFlags != 0b0000_1111 {
        if let codeUnit = next.next() {
          _decodeLookahead = (_decodeLookahead << 8) | UInt32(codeUnit)
          _lookaheadFlags = (_lookaheadFlags << 1) | 1
        } else {
          // Set the EOF flag.
          switch _lookaheadFlags & 0b0000_1111 {
          case 0b1111:
            _fatalError("should have not entered buffer refill loop")
          case 0b0111:
            _lookaheadFlags |= 0b0100_0000
          case 0b0011:
            _lookaheadFlags |= 0b0010_0000
          case 0b0001:
            _lookaheadFlags |= 0b0001_0000
          case 0b0000:
            _lookaheadFlags |= 0b1000_0000
            return .EmptyInput
          default:
            _fatalError("bad value in _lookaheadFlags")
          }
          break
        }
      }
    }

    if _slowPath(_lookaheadFlags & 0b0000_1111 == 0) {
      return .EmptyInput
    }

    if _slowPath(_lookaheadFlags & 0b1111_0000 != 0) {
      // Reached EOF.  Restore the invariant: first unread byte is always at
      // MSB.
      switch _lookaheadFlags & 0b1111_0000 {
      case 0b1000_0000:
        break
      case 0b0100_0000:
        _decodeLookahead <<= 1 * 8
      case 0b0010_0000:
        _decodeLookahead <<= 2 * 8
      case 0b0001_0000:
        _decodeLookahead <<= 3 * 8
      default:
        _fatalError("bad value in _lookaheadFlags")
      }
      _lookaheadFlags = (_lookaheadFlags & 0b0000_1111) | 0b1000_0000
    }

    // The first byte to read is located at MSB of `_decodeLookahead`.  Get a
    // representation of the buffer where we can read bytes starting from LSB.
    var buffer = _decodeLookahead.byteSwapped
    if _slowPath(!UTF8._isValidUTF8(buffer, validBytes: _lookaheadFlags)) {
      // The code unit sequence is ill-formed.  According to Unicode
      // recommendation, replace the maximal subpart of ill-formed sequence
      // with one replacement character.
      _lookaheadFlags >>=
          UTF8._findMaximalSubpartOfIllFormedUTF8Sequence(buffer,
              validBytes: _lookaheadFlags)
      return .Error
    }

    // At this point we know that `buffer` starts with a well-formed code unit
    // sequence.  Decode it.
    //
    // When consuming bytes from the `buffer`, we just need to update
    // `_lookaheadFlags`.  The stored buffer in `_decodeLookahead` will be
    // shifted at the beginning of the next decoding cycle.
    let cu0 = UInt8(buffer & 0xff)
    buffer >>= 8
    _lookaheadFlags >>= 1

    if cu0 < 0x80 {
      // 1-byte sequences.
      return .Result(UnicodeScalar(UInt32(cu0)))
    }

    // Start with octet 1 (we'll mask off high bits later).
    var result = UInt32(cu0)

    let cu1 = UInt8(buffer & 0xff)
    buffer >>= 8
    _lookaheadFlags >>= 1
    result = (result << 6) | UInt32(cu1 & 0x3f)
    if cu0 < 0xe0 {
      // 2-byte sequences.
      return .Result(UnicodeScalar(result & 0x000007ff)) // 11 bits
    }

    let cu2 = UInt8(buffer & 0xff)
    buffer >>= 8
    _lookaheadFlags >>= 1
    result = (result << 6) | UInt32(cu2 & 0x3f)
    if cu0 < 0xf0 {
      // 3-byte sequences.
      return .Result(UnicodeScalar(result & 0x0000ffff)) // 16 bits
    }

    // 4-byte sequences.
    let cu3 = UInt8(buffer & 0xff)
    _lookaheadFlags >>= 1
    result = (result << 6) | UInt32(cu3 & 0x3f)
    return .Result(UnicodeScalar(result & 0x001fffff)) // 21 bits
  }

  static func encode<
    S : Sink where S.Element == CodeUnit
  >(input: UnicodeScalar, inout output: S) {
    var c = UInt32(input)
    var buf3 = UInt8(c & 0xFF)

    if c >= UInt32(1<<7) {
      c >>= 6
      buf3 = (buf3 & 0x3F) | 0x80 // 10xxxxxx
      var buf2 = UInt8(c & 0xFF)
      if c < UInt32(1<<5) {
        buf2 |= 0xC0              // 110xxxxx
      }
      else {
        c >>= 6
        buf2 = (buf2 & 0x3F) | 0x80 // 10xxxxxx
        var buf1 = UInt8(c & 0xFF)
        if c < UInt32(1<<4) {
          buf1 |= 0xE0              // 1110xxxx
        }
        else {
          c >>= 6
          buf1 = (buf1 & 0x3F) | 0x80 // 10xxxxxx
          output.put(UInt8(c | 0xF0)) // 11110xxx
        }
        output.put(buf1)
      }
      output.put(buf2)
    }
    output.put(buf3)
  }
}

struct UTF16 : UnicodeCodec {
  typealias CodeUnit = UInt16

  init() {}

  mutating func decode<
    G : Generator where G.Element == CodeUnit
  >(inout input: G) -> UTFDecodeResult {
    return UTF16.decode(&input)
  }

  static func decode<
    G : Generator where G.Element == CodeUnit
  >(inout input: G) -> UTFDecodeResult {
    let first = input.next()
    if !first {
      return .EmptyInput
    }

    let unit0 = UInt32(first!)
    if (unit0 >> 11) != 0x1B {
      return .Result(UnicodeScalar(unit0))
    }

    let unit1 = UInt32(input.next()!)

    // FIXME: Uglified due to type checker performance issues.
    var result : UInt32 = 0x10000
    result += ((unit0 - 0xD800) << 10)
    result += (unit1 - 0xDC00)
    return .Result(UnicodeScalar(result))
  }

  static func encode<
      S : Sink where S.Element == CodeUnit
  >(input: UnicodeScalar, inout output: S) {
    var scalarValue: UInt32 = UInt32(input)

    if scalarValue <= UInt32(UInt16.max) {
      output.put(UInt16(scalarValue))
    }
    else {
      var lead_offset = UInt32(0xD800) - (0x10000 >> 10)
      output.put(UInt16(lead_offset + (scalarValue >> 10)))
      output.put(UInt16(0xDC00 + (scalarValue & 0x3FF)))
    }
  }

  var _value = UInt16()
}

struct UTF32 : UnicodeCodec {
  typealias CodeUnit = UInt32

  init() {}

  mutating func decode<
    G : Generator where G.Element == CodeUnit
  >(inout input: G) -> UTFDecodeResult {
    return UTF32.decode(&input)
  }

  static func decode<
    G : Generator where G.Element == CodeUnit
  >(inout input: G) -> UTFDecodeResult {
    var x = input.next()
    if x {
      return .Result(UnicodeScalar(x!))
    }
    return .EmptyInput
  }

  static func encode<
    S : Sink where S.Element == CodeUnit
  >(input: UnicodeScalar, inout output: S) {
    output.put(UInt32(input))
  }
}

func transcode<
  Input : Generator,
  Output : Sink,
  InputEncoding : UnicodeCodec,
  OutputEncoding : UnicodeCodec
  where InputEncoding.CodeUnit == Input.Element,
      OutputEncoding.CodeUnit == Output.Element>(
  inputEncoding: InputEncoding.Type, outputEncoding: OutputEncoding.Type,
  var input: Input, var output: Output, #stopOnError: Bool
) -> (hadError: Bool) {

  // NB.  It is not possible to optimize this routine to a memcpy if
  // InputEncoding == OutputEncoding.  The reason is that memcpy will not
  // substitute U+FFFD replacement characters for ill-formed sequences.

  var inputDecoder = inputEncoding()
  var hadError = false
  for var scalar = inputDecoder.decode(&input);
          !scalar.isEmptyInput();
          scalar = inputDecoder.decode(&input) {
    switch scalar {
    case .Result(let us):
      OutputEncoding.encode(us, output: &output)
    case .EmptyInput:
      _fatalError("should not enter the loop when input becomes empty")
    case .Error:
      if stopOnError {
        return (hadError: true)
      }
      OutputEncoding.encode("\ufffd", output: &output)
      hadError = true
    }
  }
  return (hadError: hadError)
}

protocol StringElement {
  class func toUTF16CodeUnit(_: Self) -> UTF16.CodeUnit
  class func fromUTF16CodeUnit(utf16: UTF16.CodeUnit) -> Self
}

extension UTF16.CodeUnit : StringElement {
  static func toUTF16CodeUnit(x: UTF16.CodeUnit) -> UTF16.CodeUnit {
    return x
  }
  static func fromUTF16CodeUnit(utf16: UTF16.CodeUnit) -> UTF16.CodeUnit {
    return utf16
  }
}

extension UTF8.CodeUnit : StringElement {
  static func toUTF16CodeUnit(x: UTF8.CodeUnit) -> UTF16.CodeUnit {
    return UTF16.CodeUnit(x)
  }
  static func fromUTF16CodeUnit(utf16: UTF16.CodeUnit) -> UTF8.CodeUnit {
    return UTF8.CodeUnit(utf16)
  }
}

extension UTF16 {
  static func width(x: UnicodeScalar) -> Int {
    return x.value <= 0xFFFF ? 1 : 2
  }

  static func leadSurrogate(x: UnicodeScalar) -> UTF16.CodeUnit {
    _precondition(width(x) == 2)
    return (UTF16.CodeUnit(x.value - 0x1_0000) >> 10) + 0xD800
  }

  static func trailSurrogate(x: UnicodeScalar) -> UTF16.CodeUnit {
    _precondition(width(x) == 2)
    return (UTF16.CodeUnit(x.value - 0x1_0000) & ((1 << 10) - 1)) + 0xDC00
  }

  static func copy<T: StringElement, U: StringElement>(
    source: UnsafePointer<T>, destination: UnsafePointer<U>, count: Int
  ) {
    if UWord(Builtin.strideof(T.self)) == UWord(Builtin.strideof(U.self)) {
      c_memcpy(
        dest: UnsafePointer(destination),
        src: UnsafePointer(source),
        size: UInt(count) * UInt(Builtin.strideof(U.self)))
    }
    else {
      for i in 0..<count {
        let u16 = T.toUTF16CodeUnit((source + i).memory)
        (destination + i).memory = U.fromUTF16CodeUnit(u16)
      }
    }
  }

  /// Returns the number of UTF-16 code units required for the given code unit
  /// sequence when transcoded to UTF-16, and a bit describing if the sequence
  /// was found to contain only ASCII characters.
  ///
  /// If `repairIllFormedSequences` is `true`, the function always succeeds.
  /// If it is `false`, `nil` is returned if an ill-formed code unit sequence is
  /// found in `input`.
  static func measure<
      Encoding : UnicodeCodec, Input : Generator
      where Encoding.CodeUnit == Input.Element
  >(
    _: Encoding.Type, var input: Input, repairIllFormedSequences: Bool
  ) -> (Int, Bool)? {
    var count = 0
    var isAscii = true

    var inputDecoder = Encoding()
    loop:
    while true {
      switch inputDecoder.decode(&input) {
      case .Result(let us):
        if us.value > 0x7f {
          isAscii = false
        }
        count += width(us)
      case .EmptyInput:
        break loop
      case .Error:
        if !repairIllFormedSequences {
          return .None
        }
        isAscii = false
        count += width(UnicodeScalar(0xfffd))
      }
    }
    return (count, isAscii)
  }
}

