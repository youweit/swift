// RUN: %target-run-simple-swift | FileCheck %s

import StdlibUnittest

var StringTests = TestCase("StringTests")

StringTests.test("sizeof") {
  expectEqual(3 * sizeof(Int.self), sizeof(String.self))
}

func checkUnicodeScalarViewIteration(
    expectedScalars: UInt32[], str: String) -> AssertionResult {
  if true {
    var us = str.unicodeScalars
    var i = us.startIndex
    var end = us.endIndex
    var decoded: UInt32[] = []
    while i != end {
      decoded += us[i].value
      i = i.succ()
    }
    if expectedScalars != decoded {
      return assertionFailure()
          .withDescription("forward traversal:\n")
          .withDescription("expected: \(asHex(expectedScalars))\n")
          .withDescription("actual:   \(asHex(decoded))")
    }
  }
  if true {
    var us = str.unicodeScalars
    var start = us.startIndex
    var i = us.endIndex
    var decoded: UInt32[] = []
    while i != start {
      i = i.pred()
      decoded += us[i].value
    }
    if expectedScalars != decoded {
      return assertionFailure()
          .withDescription("backward traversal:\n")
          .withDescription("expected: \(asHex(expectedScalars))\n")
          .withDescription("actual:   \(asHex(decoded))")
    }
  }

  return assertionSuccess()
}

StringTests.test("unicodeScalars") {
  checkUnicodeScalarViewIteration([], "")
  checkUnicodeScalarViewIteration([ 0x0000 ], "\u0000")
  checkUnicodeScalarViewIteration([ 0x0041 ], "A")
  checkUnicodeScalarViewIteration([ 0x007f ], "\u007f")
  checkUnicodeScalarViewIteration([ 0x0080 ], "\u0080")
  checkUnicodeScalarViewIteration([ 0x07ff ], "\u07ff")
  checkUnicodeScalarViewIteration([ 0x0800 ], "\u0800")
  checkUnicodeScalarViewIteration([ 0xd7ff ], "\ud7ff")
  checkUnicodeScalarViewIteration([ 0x8000 ], "\u8000")
  checkUnicodeScalarViewIteration([ 0xe000 ], "\ue000")
  checkUnicodeScalarViewIteration([ 0xfffd ], "\ufffd")
  checkUnicodeScalarViewIteration([ 0xffff ], "\uffff")
  checkUnicodeScalarViewIteration([ 0x10000 ], "\U00010000")
  checkUnicodeScalarViewIteration([ 0x10ffff ], "\U0010ffff")
}

StringTests.run()
// CHECK: {{^}}StringTests: All tests passed

func testStringToInt() {
  println("test String to Int")
  // CHECK: test String to Int

  var s1 = "  \t 20ddd"
  var i1 : Optional<Int> = s1.toInt()
  if (!i1) {
    println("none")
  }
  // CHECK-NEXT: none

  if (!"".toInt()) {
    println("empty is none")
  }
  // CHECK-NEXT: empty is none

  if ("+20".toInt()! == 20) {
    println("20")
  }
  // CHECK-NEXT: 20

  if ("0".toInt()! == 0) {
    println("0")
  }
  // CHECK-NEXT: 0

  if ("-20".toInt()! == -20) {
    println("-20")
  }
  // CHECK-NEXT: -20

  if (!"-cc20".toInt()) {
    println("none")
  }
  // CHECK-NEXT: none

  if (!"  -20".toInt()) {
    println("none")
  }
  // CHECK-NEXT: none


  if (String(Int.min).toInt()! == Int.min) {
    println("round-trip Int.min")
  }
  // CHECK-NEXT: round-trip Int.min

  if (String(Int.max).toInt()! == Int.max) {
    println("round-trip Int.max")
  }
  // CHECK-NEXT: round-trip Int.max


  // Make a String from an Int, mangle the String's characters, 
  // then print if the new String is or is not still an Int.
  func testConvertabilityOfStringWithModification(
    initialValue: Int, 
    modification: (inout chars: UTF8.CodeUnit[]) -> () ) 
  {
    var chars = Array(String(initialValue).utf8)
    modification(chars: &chars)
    var str = String._fromWellFormedCodeUnitSequence(UTF8.self, input: chars)
    var is_isnot = str.toInt() ? "is" : "is not"
    println("\(str) \(is_isnot) an Int")
  }

  var minChars = String(Int.min).utf8

  testConvertabilityOfStringWithModification(Int.min) { 
    (inout chars: UTF8.CodeUnit[]) in ()
  }
  // CHECK-NEXT: {{-9223372036854775808|-2147483648}} is an Int

  testConvertabilityOfStringWithModification(Int.min) { 
    $0[$0.count-1]--; ()
  }
  // CHECK-NEXT: {{-9223372036854775807|-2147483647}} is an Int

  testConvertabilityOfStringWithModification(Int.min) { 
    $0[$0.count-1]++; ()  // underflow by one
  }
  // CHECK-NEXT: {{-9223372036854775809|-2147483649}} is not an Int

  testConvertabilityOfStringWithModification(Int.min) { 
    $0[2]++; ()  // underflow by lots
  }
  // CHECK-NEXT: {{-9323372036854775808|-2247483648}} is not an Int

  testConvertabilityOfStringWithModification(Int.min) { 
    $0.append(Array("0".utf8)[0]); ()  // underflow by adding digits
  }
  // CHECK-NEXT: {{-92233720368547758080|-21474836480}} is not an Int


  testConvertabilityOfStringWithModification(Int.max) { 
    (inout chars: UTF8.CodeUnit[]) in ()
  }
  // CHECK-NEXT: {{9223372036854775807|2147483647}} is an Int

  testConvertabilityOfStringWithModification(Int.max) { 
    $0[$0.count-1]--; ()
  }
  // CHECK-NEXT: {{9223372036854775806|2147483646}} is an Int

  testConvertabilityOfStringWithModification(Int.max) { 
    $0[$0.count-1]++; ()  // overflow by one
  }
  // CHECK-NEXT: {{9223372036854775808|2147483648}} is not an Int

  testConvertabilityOfStringWithModification(Int.max) { 
    $0[1]++; ()  // overflow by lots
  }
  // CHECK-NEXT: {{9323372036854775807|2247483647}} is not an Int

  testConvertabilityOfStringWithModification(Int.max) { 
    $0.append(Array("0".utf8)[0]); ()  // overflow by adding digits
  }
  // CHECK-NEXT: {{92233720368547758070|21474836470}} is not an Int


  // Test values lower than min.
  var ui = UInt(Int.max) + 1
  for index in 0..<20 {
    ui = ui + UInt(index)
    if ("-\(ui)".toInt()) {
      print(".")
    } else {
      print("*")
    }
  }
  println("lower than min")
  // CHECK-NEXT: .*******************lower than min

  // Test values greater than min.
  ui = UInt(Int.max)
  for index in 0..<20 {
    ui = ui - UInt(index)
    if ("-\(ui)".toInt()! == -Int(ui)) {
      print(".")
    } else {
      print("*")
    }
  }
  println("greater than min")
  // CHECK-NEXT: ....................greater than min

  // Test values greater than max.
  ui = UInt(Int.max)
  for index in 0..<20 {
    ui = ui + UInt(index)
    if (String(ui).toInt()) {
      print(".")
    } else {
      print("*")
    }
  }
  println("greater than max")
  // CHECK-NEXT: .*******************greater than max

  // Test values lower than max.
  ui = UInt(Int.max)
  for index in 0..<20 {
    ui = ui - UInt(index)
    if (String(ui).toInt()! == Int(ui)) {
      print(".")
    } else {
      print("*")
    }
  }
  println("lower than max")
  // CHECK-NEXT: ....................lower than max
}

// Make sure strings don't grow unreasonably quickly when appended-to
func testGrowth() {
  var s = ""
  var s2 = s

  for i in 0..<20 {
    s += "x"
    s2 = s
  }
  // CHECK-NEXT: true
  println(s.core.nativeBuffer!.capacity <= 34)
}

testStringToInt()
testGrowth()

func testCompare() {
  // CHECK: testCompare
  println("testCompare")
  // CHECK: 1
  println("hi".compare("bye"))
  // CHECK: -1
  println("bye".compare("hi"))
  // CHECK: 0
  println("swift".compare("swift"))
  // CHECK: 1
  println("a".compare(""))
  // CHECK: 0
  println("a".compare("a"))
  // CHECK: -1
  println("a".compare("z"))
  // CHECK: 1
  println("aa".compare("a"))
  // CHECK: -1
  println("a".compare("aa"))
  // CHECK: 0
  println("".compare(""))
  // CHECK: -1
  println("a".compare("b"))
  // CHECK: 1
  println("b".compare("a"))
  println("testCompare done")
  // CHECK: testCompare done
}
testCompare()

func testCompareUnicode() {
  // CHECK: testCompareUnicode
  println("testCompareUnicode")
  // CHECK: 1
  println("hi".compare("bye"))
  // CHECK: -1
  println("bye".compare("hi"))
  // CHECK: 0
  println("ראשון".compare("ראשון"))
  // CHECK: 1
  println("א".compare(""))
  // CHECK: 0
  println("א".compare("א"))
  // CHECK: -1
  println("א".compare("ת"))
  // CHECK: 1
  println("אא".compare("א"))
  // CHECK: -1
  println("א".compare("אא"))
  // CHECK: 0
  println("".compare(""))
  // CHECK: -1
  println("א".compare("ב"))
  // CHECK: 1
  println("ב".compare("א"))
  println("testCompareUnicode done")
  // CHECK: testCompareUnicode done
}
testCompareUnicode()


import Foundation

// The most simple subclass of NSString that CoreFoundation does not know
// about.
class NonContiguousNSString : NSString {
  init(_ value: String) {
    _value = value
    super.init()
  }

  @objc override func copyWithZone(zone: NSZone) -> AnyObject {
    return self
  }

  @objc override var length: Int {
    return _value.utf16count
  }

  @objc override func characterAtIndex(index: Int) -> unichar {
    return _value.utf16[index]
  }

  var _value: String
}

func testUTF8Encoding(expectedContents: String, stringUnderTest: String) {
  var utf8Bytes: UInt8[] = Array(stringUnderTest.utf8)
  dump(utf8Bytes)
  assert(Array(expectedContents.utf8) == utf8Bytes)
}

func testUTF8EncodingOfBridgedNSString() {
  for str in [ "abc", "абв", "あいうえお" ] {
    var nss = NonContiguousNSString(str)

    // Sanity checks to make sure we are testing the code path that does UTF-8
    // encoding itself, instead of dispatching to CF.  Both the original string
    // itself and its copies should be resilient to CF's fast path functions,
    // because Swift bridging may copy the string to ensure that it is not
    // mutated.
    let cfstring: CFString = reinterpretCast(nss)
    assert(!CFStringGetCStringPtr(cfstring,
        CFStringBuiltInEncodings.ASCII.toRaw()))
    assert(!CFStringGetCStringPtr(cfstring,
        CFStringBuiltInEncodings.UTF8.toRaw()))
    assert(!CFStringGetCharactersPtr(cfstring))

    let copy = CFStringCreateCopy(nil, cfstring)
    assert(!CFStringGetCStringPtr(copy,
        CFStringBuiltInEncodings.ASCII.toRaw()))
    assert(!CFStringGetCStringPtr(copy,
        CFStringBuiltInEncodings.UTF8.toRaw()))
    assert(!CFStringGetCharactersPtr(copy))

    testUTF8Encoding(str, cfstring)
  }

  if true {
    var bytes: UInt8[] = [ 97, 98, 99 ]
    var cfstring: CFString = CFStringCreateWithBytesNoCopy(kCFAllocatorDefault,
        bytes, bytes.count, CFStringBuiltInEncodings.MacRoman.toRaw(), 0, kCFAllocatorNull)

    // Sanity checks to make sure we are testing the code path that does UTF-8
    // encoding itself, instead of dispatching to CF.
    // GetCStringPtr fails because our un-copied bytes aren't zero-terminated.
    // GetCharactersPtr fails because our un-copied bytes aren't UTF-16.
    assert(!CFStringGetCStringPtr(cfstring,
        CFStringBuiltInEncodings.ASCII.toRaw()))
    assert(!CFStringGetCStringPtr(cfstring,
        CFStringBuiltInEncodings.UTF8.toRaw()))
    assert(!CFStringGetCharactersPtr(cfstring))

    testUTF8Encoding("abc", cfstring)
    _fixLifetime(bytes)
  }

  if true {
    var bytes: UInt8[] = [ 97, 98, 99 ]
    var cfstring: CFString = CFStringCreateWithBytes(kCFAllocatorDefault,
        bytes, bytes.count, CFStringBuiltInEncodings.MacRoman.toRaw(), 0)

    // Sanity checks to make sure we are testing the code path that does UTF-8
    // encoding itself, instead of dispatching to CF.
    // CFStringCreateWithBytes() usually allocates zero-terminated ASCII 
    // or UTF-16, in which case one of the fast paths will succeed. 
    // This test operates only when CF creates a tagged pointer string object.
    if (object_getClassName(cfstring) == "NSTaggedPointerString") {
      assert(!CFStringGetCStringPtr(cfstring,
          CFStringBuiltInEncodings.ASCII.toRaw()))
      assert(!CFStringGetCStringPtr(cfstring,
          CFStringBuiltInEncodings.UTF8.toRaw()))
      assert(!CFStringGetCharactersPtr(cfstring))

      testUTF8Encoding("abc", cfstring)
    }
  }

  println("testUTF8EncodingOfBridgedNSString done")
}
testUTF8EncodingOfBridgedNSString()
// CHECK: testUTF8EncodingOfBridgedNSString done

