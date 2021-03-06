infix operator .== : ComparisonPrecedence
infix operator .!= : ComparisonPrecedence
infix operator .< : ComparisonPrecedence
infix operator .<= : ComparisonPrecedence
infix operator .> : ComparisonPrecedence
infix operator .>= : ComparisonPrecedence
infix operator .& : LogicalConjunctionPrecedence
infix operator .^ : LogicalDisjunctionPrecedence
infix operator .| : LogicalDisjunctionPrecedence
infix operator .&= : AssignmentPrecedence
infix operator .^= : AssignmentPrecedence
infix operator .|= : AssignmentPrecedence
prefix operator .!

/// A SIMD vector type that may not have any computational operations.
///
/// This protocol only defines a storage layout and provides elementwise
/// accesses. Computational operations are defined on SIMDVector, which
/// refines this protocol, or on the concrete types that conform.
public protocol SIMDStorage {
  /// The type of scalars in the vector space.
  associatedtype Scalar : Hashable
  
  /// The number of scalars/elements in the vector.
  var scalarCount: Int { get }
  
  /// A vector with zero in all lanes.
  init()
  
  /// Element access to the vector.
  subscript(index: Int) -> Scalar { get set }
}

public protocol SIMDScalar {
  associatedtype SIMDMaskScalar : SIMDScalar & FixedWidthInteger & SignedInteger
  associatedtype SIMD2Storage : SIMDStorage where SIMD2Storage.Scalar == Self
  associatedtype SIMD4Storage : SIMDStorage where SIMD4Storage.Scalar == Self
  associatedtype SIMD8Storage : SIMDStorage where SIMD8Storage.Scalar == Self
  associatedtype SIMD16Storage : SIMDStorage where SIMD16Storage.Scalar == Self
  associatedtype SIMD32Storage : SIMDStorage where SIMD32Storage.Scalar == Self
  associatedtype SIMD64Storage : SIMDStorage where SIMD64Storage.Scalar == Self
}

public protocol SIMD : SIMDStorage,
                       Hashable,
                       CustomStringConvertible,
                       ExpressibleByArrayLiteral {
  /// The mask type resulting from pointwise comparisons of this vector type.
  associatedtype MaskStorage : SIMD
    where MaskStorage.Scalar : FixedWidthInteger & SignedInteger
}

public extension SIMD {
  /// The valid indices for subscripting the vector.
  @_transparent
  var indices: Range<Int> { return 0 ..< scalarCount }
  
  /// A vector with value in all lanes.
  @_transparent
  init(repeating value: Scalar) {
    self.init()
    for i in indices { self[i] = value }
  }
  
  /// Conformance to Equatable
  @_transparent
  static func ==(lhs: Self, rhs: Self) -> Bool {
    var result = true
    for i in lhs.indices { result = result && lhs[i] == rhs[i] }
    return result
  }
  
  /// Conformance to Hashable
  @inlinable
  func hash(into hasher: inout Hasher) {
    for i in indices { hasher.combine(self[i]) }
  }
  
  /// Conformance to CustomStringConvertible
  var description: String {
    get {
      return "\(Self.self)(" + indices.map({"\(self[$0])"}).joined(separator: ", ") + ")"
    }
  }
  
  /// Pointwise equality
  @_transparent
  static func .==(lhs: Self, rhs: Self) -> SIMDMask<MaskStorage> {
    var result = SIMDMask<MaskStorage>()
    for i in result.indices { result[i] = lhs[i] == rhs[i] }
    return result
  }
  
  /// Replaces elements of this vector with `other` in the lanes where
  /// `mask` is `true`.
  @_transparent
  mutating func replace(with other: Self, where mask: SIMDMask<MaskStorage>) {
    for i in indices { self[i] = mask[i] ? other[i] : self[i] }
  }
  
  @inlinable
  init(arrayLiteral scalars: Scalar...) {
    self.init(scalars)
  }
  
  @inlinable
  init<S: Sequence>(_ scalars: S) where S.Element == Scalar {
    self.init()
    var index = 0
    for scalar in scalars {
      if index == scalarCount {
        _preconditionFailure("Too many elements in sequence.")
      }
      self[index] = scalar
      index += 1
    }
    if index < scalarCount {
      _preconditionFailure("Not enough elements in sequence.")
    }
  }
}

//  Implementations of comparison operations. These should eventually all
//  be replaced with @_semantics to lower directly to vector IR nodes.
public extension SIMD where Scalar : Comparable {
  /// Pointwise less than
  @_transparent
  static func .<(lhs: Self, rhs: Self) -> SIMDMask<MaskStorage> {
    var result = SIMDMask<MaskStorage>()
    for i in result.indices { result[i] = lhs[i] < rhs[i] }
    return result
  }
  
  /// Pointwise less than or equal to
  @_transparent
  static func .<=(lhs: Self, rhs: Self) -> SIMDMask<MaskStorage> {
    var result = SIMDMask<MaskStorage>()
    for i in result.indices { result[i] = lhs[i] <= rhs[i] }
    return result
  }
}

/*
//  Implementations of pointwise boolean operations. These should eventually
//  all be replaced with @_semantics to lower directly to vector IR nodes.
public extension SIMDMask {
}
*/

//  Implementations of integer operations. These should eventually all
//  be replaced with @_semantics to lower directly to vector IR nodes.
public extension SIMD where Scalar : FixedWidthInteger {
  @_transparent
  var leadingZeroBitCount: Self {
    var result = Self()
    for i in indices { result[i] = Scalar(self[i].leadingZeroBitCount) }
    return result
  }
  
  @_transparent
  var trailingZeroBitCount: Self {
    var result = Self()
    for i in indices { result[i] = Scalar(self[i].trailingZeroBitCount) }
    return result
  }
  
  @_transparent
  var nonzeroBitCount: Self {
    var result = Self()
    for i in indices { result[i] = Scalar(self[i].nonzeroBitCount) }
    return result
  }
  
  @_transparent
  static prefix func ~(rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = ~rhs[i] }
    return result
  }
  
  @_transparent
  static func &(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] & rhs[i] }
    return result
  }
  
  @_transparent
  static func ^(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] ^ rhs[i] }
    return result
  }
  
  @_transparent
  static func |(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] | rhs[i] }
    return result
  }
  
  @_transparent
  static func &<<(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] &<< rhs[i] }
    return result
  }
  
  @_transparent
  static func &>>(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] &>> rhs[i] }
    return result
  }
  
  @_transparent
  static func &+(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] &+ rhs[i] }
    return result
  }
  
  @_transparent
  static func &-(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] &- rhs[i] }
    return result
  }
  
  @_transparent
  static func &*(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] &* rhs[i] }
    return result
  }
  
  @_transparent
  static func /(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] / rhs[i] }
    return result
  }
  
  @_transparent
  static func %(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] % rhs[i] }
    return result
  }
}

//  Implementations of floating-point operations. These should eventually all
//  be replaced with @_semantics to lower directly to vector IR nodes.
public extension SIMD where Scalar : FloatingPoint {
  @_transparent
  static func +(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] + rhs[i] }
    return result
  }
  
  @_transparent
  static func -(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] - rhs[i] }
    return result
  }
  
  @_transparent
  static func *(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] * rhs[i] }
    return result
  }
  
  @_transparent
  static func /(lhs: Self, rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = lhs[i] / rhs[i] }
    return result
  }
  
  @_transparent
  func addingProduct(_ lhs: Self, _ rhs: Self) -> Self {
    var result = Self()
    for i in result.indices { result[i] = self[i].addingProduct(lhs[i], rhs[i]) }
    return result
  }
  
  @_transparent
  func squareRoot( ) -> Self {
    var result = Self()
    for i in result.indices { result[i] = self[i].squareRoot() }
    return result
  }
  
  @_transparent
  func rounded(_ rule: FloatingPointRoundingRule) -> Self {
    var result = Self()
    for i in result.indices { result[i] = self[i].rounded(rule) }
    return result
  }
}

//  These operations should never need @_semantics; they should be trivial
//  wrappers around the core operations defined above.
public extension SIMD {
  @_transparent static func .!=(lhs: Self, rhs: Self) -> SIMDMask<MaskStorage> { return .!(lhs .== rhs) }
  @_transparent static func .==(lhs: Scalar, rhs: Self) -> SIMDMask<MaskStorage> { return Self(repeating: lhs) .== rhs }
  @_transparent static func .!=(lhs: Scalar, rhs: Self) -> SIMDMask<MaskStorage> { return Self(repeating: lhs) .!= rhs }
  @_transparent static func .==(lhs: Self, rhs: Scalar) -> SIMDMask<MaskStorage> { return lhs .== Self(repeating: rhs) }
  @_transparent static func .!=(lhs: Self, rhs: Scalar) -> SIMDMask<MaskStorage> { return lhs .!= Self(repeating: rhs) }
  
  @_transparent
  mutating func replace(with other: Scalar, where mask: SIMDMask<MaskStorage>) {
    replace(with: Self(repeating: other), where: mask)
  }
  
  @_transparent
  func replacing(with other: Self, where mask: SIMDMask<MaskStorage>) -> Self {
    var result = self
    result.replace(with: other, where: mask)
    return result
  }
  
  @_transparent
  func replacing(with other: Scalar, where mask: SIMDMask<MaskStorage>) -> Self {
    return replacing(with: Self(repeating: other), where: mask)
  }
}

public extension SIMD where Scalar : Comparable {
  @_transparent static func .>=(lhs: Self, rhs: Self) -> SIMDMask<MaskStorage> { return rhs .<= lhs }
  @_transparent static func .>(lhs: Self, rhs: Self) -> SIMDMask<MaskStorage> { return rhs .< lhs }
  @_transparent static func .<(lhs: Scalar, rhs: Self) -> SIMDMask<MaskStorage> { return Self(repeating: lhs) .< rhs }
  @_transparent static func .<=(lhs: Scalar, rhs: Self) -> SIMDMask<MaskStorage> { return Self(repeating: lhs) .<= rhs }
  @_transparent static func .>=(lhs: Scalar, rhs: Self) -> SIMDMask<MaskStorage> { return Self(repeating: lhs) .>= rhs }
  @_transparent static func .>(lhs: Scalar, rhs: Self) -> SIMDMask<MaskStorage> { return Self(repeating: lhs) .> rhs }
  @_transparent static func .<(lhs: Self, rhs: Scalar) -> SIMDMask<MaskStorage> { return lhs .< Self(repeating: rhs) }
  @_transparent static func .<=(lhs: Self, rhs: Scalar) -> SIMDMask<MaskStorage> { return lhs .<= Self(repeating: rhs) }
  @_transparent static func .>=(lhs: Self, rhs: Scalar) -> SIMDMask<MaskStorage> { return lhs .>= Self(repeating: rhs) }
  @_transparent static func .>(lhs: Self, rhs: Scalar) -> SIMDMask<MaskStorage> { return lhs .> Self(repeating: rhs) }
}

public extension SIMD where Scalar : FixedWidthInteger {
  @_transparent static var zero: Self { return Self() }
  
  @_transparent static func &(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) & rhs }
  @_transparent static func ^(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) ^ rhs }
  @_transparent static func |(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) | rhs }
  @_transparent static func &<<(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) &<< rhs }
  @_transparent static func &>>(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) &>> rhs }
  @_transparent static func &+(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) &+ rhs }
  @_transparent static func &-(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) &- rhs }
  @_transparent static func &*(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) &* rhs }
  @_transparent static func /(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) / rhs }
  @_transparent static func %(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) % rhs }
  
  @_transparent static func &(lhs: Self, rhs: Scalar) -> Self { return lhs & Self(repeating: rhs) }
  @_transparent static func ^(lhs: Self, rhs: Scalar) -> Self { return lhs ^ Self(repeating: rhs) }
  @_transparent static func |(lhs: Self, rhs: Scalar) -> Self { return lhs | Self(repeating: rhs) }
  @_transparent static func &<<(lhs: Self, rhs: Scalar) -> Self { return lhs &<< Self(repeating: rhs) }
  @_transparent static func &>>(lhs: Self, rhs: Scalar) -> Self { return lhs &>> Self(repeating: rhs) }
  @_transparent static func &+(lhs: Self, rhs: Scalar) -> Self { return lhs &+ Self(repeating: rhs) }
  @_transparent static func &-(lhs: Self, rhs: Scalar) -> Self { return lhs &- Self(repeating: rhs) }
  @_transparent static func &*(lhs: Self, rhs: Scalar) -> Self { return lhs &* Self(repeating: rhs) }
  @_transparent static func /(lhs: Self, rhs: Scalar) -> Self { return lhs / Self(repeating: rhs) }
  @_transparent static func %(lhs: Self, rhs: Scalar) -> Self { return lhs % Self(repeating: rhs) }
  
  @_transparent static func &=(lhs: inout Self, rhs: Self) { lhs = lhs & rhs }
  @_transparent static func ^=(lhs: inout Self, rhs: Self) { lhs = lhs ^ rhs }
  @_transparent static func |=(lhs: inout Self, rhs: Self) { lhs = lhs | rhs }
  @_transparent static func &<<=(lhs: inout Self, rhs: Self) { lhs = lhs &<< rhs }
  @_transparent static func &>>=(lhs: inout Self, rhs: Self) { lhs = lhs &>> rhs }
  @_transparent static func &+=(lhs: inout Self, rhs: Self) { lhs = lhs &+ rhs }
  @_transparent static func &-=(lhs: inout Self, rhs: Self) { lhs = lhs &- rhs }
  @_transparent static func &*=(lhs: inout Self, rhs: Self) { lhs = lhs &* rhs }
  @_transparent static func /=(lhs: inout Self, rhs: Self) { lhs = lhs / rhs }
  @_transparent static func %=(lhs: inout Self, rhs: Self) { lhs = lhs % rhs }
  
  @_transparent static func &=(lhs: inout Self, rhs: Scalar) { lhs = lhs & rhs }
  @_transparent static func ^=(lhs: inout Self, rhs: Scalar) { lhs = lhs ^ rhs }
  @_transparent static func |=(lhs: inout Self, rhs: Scalar) { lhs = lhs | rhs }
  @_transparent static func &<<=(lhs: inout Self, rhs: Scalar) { lhs = lhs &<< rhs }
  @_transparent static func &>>=(lhs: inout Self, rhs: Scalar) { lhs = lhs &>> rhs }
  @_transparent static func &+=(lhs: inout Self, rhs: Scalar) { lhs = lhs &+ rhs }
  @_transparent static func &-=(lhs: inout Self, rhs: Scalar) { lhs = lhs &- rhs }
  @_transparent static func &*=(lhs: inout Self, rhs: Scalar) { lhs = lhs &* rhs }
  @_transparent static func /=(lhs: inout Self, rhs: Scalar) { lhs = lhs / rhs }
  @_transparent static func %=(lhs: inout Self, rhs: Scalar) { lhs = lhs % rhs }
  
  @inlinable
  static func random<T: RandomNumberGenerator>(
    in range: Range<Scalar>,
    using generator: inout T
  ) -> Self {
    var result = Self()
    for i in result.indices {
      result[i] = Scalar.random(in: range, using: &generator)
    }
    return result
  }
  
  @inlinable
  static func random(in range: Range<Scalar>) -> Self {
    var g = SystemRandomNumberGenerator()
    return Self.random(in: range, using: &g)
  }
  
  @inlinable
  static func random<T: RandomNumberGenerator>(
    in range: ClosedRange<Scalar>,
    using generator: inout T
  ) -> Self {
    var result = Self()
    for i in result.indices {
      result[i] = Scalar.random(in: range, using: &generator)
    }
    return result
  }
  
  @inlinable
  static func random(in range: ClosedRange<Scalar>) -> Self {
    var g = SystemRandomNumberGenerator()
    return Self.random(in: range, using: &g)
  }
  
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&+' instead")
  static func +(lhs: Self, rhs: Self) -> Self { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&-' instead")
  static func -(lhs: Self, rhs: Self) -> Self { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&*' instead")
  static func *(lhs: Self, rhs: Self) -> Self { fatalError() }
  
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&+' instead")
  static func +(lhs: Self, rhs: Scalar) -> Self { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&-' instead")
  static func -(lhs: Self, rhs: Scalar) -> Self { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&*' instead")
  static func *(lhs: Self, rhs: Scalar) -> Self { fatalError() }
  
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&+' instead")
  static func +(lhs: Scalar, rhs: Self) -> Self { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&-' instead")
  static func -(lhs: Scalar, rhs: Self) -> Self { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&*' instead")
  static func *(lhs: Scalar, rhs: Self) -> Self { fatalError() }
  
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&+=' instead")
  static func +=(lhs: inout Self, rhs: Self) { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&-=' instead")
  static func -=(lhs: inout Self, rhs: Self) { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&*=' instead")
  static func *=(lhs: inout Self, rhs: Self) { fatalError() }
  
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&+=' instead")
  static func +=(lhs: inout Self, rhs: Scalar) { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&-=' instead")
  static func -=(lhs: inout Self, rhs: Scalar) { fatalError() }
  @available(*, unavailable, message: "integer vector types do not support checked arithmetic; use the wrapping operator '&*=' instead")
  static func *=(lhs: inout Self, rhs: Scalar) { fatalError() }
}

public extension SIMD where Scalar : FloatingPoint {
  @_transparent static var zero: Self { return Self() }
  
  @_transparent static prefix func -(rhs: Self) -> Self { return 0 - rhs }
  
  @_transparent static func +(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) + rhs }
  @_transparent static func -(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) - rhs }
  @_transparent static func *(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) * rhs }
  @_transparent static func /(lhs: Scalar, rhs: Self) -> Self { return Self(repeating: lhs) / rhs }
  
  @_transparent static func +(lhs: Self, rhs: Scalar) -> Self { return lhs + Self(repeating: rhs) }
  @_transparent static func -(lhs: Self, rhs: Scalar) -> Self { return lhs - Self(repeating: rhs) }
  @_transparent static func *(lhs: Self, rhs: Scalar) -> Self { return lhs * Self(repeating: rhs) }
  @_transparent static func /(lhs: Self, rhs: Scalar) -> Self { return lhs / Self(repeating: rhs) }
  
  @_transparent static func +=(lhs: inout Self, rhs: Self) { lhs = lhs + rhs }
  @_transparent static func -=(lhs: inout Self, rhs: Self) { lhs = lhs - rhs }
  @_transparent static func *=(lhs: inout Self, rhs: Self) { lhs = lhs * rhs }
  @_transparent static func /=(lhs: inout Self, rhs: Self) { lhs = lhs / rhs }
  
  @_transparent static func +=(lhs: inout Self, rhs: Scalar) { lhs = lhs + rhs }
  @_transparent static func -=(lhs: inout Self, rhs: Scalar) { lhs = lhs - rhs }
  @_transparent static func *=(lhs: inout Self, rhs: Scalar) { lhs = lhs * rhs }
  @_transparent static func /=(lhs: inout Self, rhs: Scalar) { lhs = lhs / rhs }
  
  @_transparent func addingProduct(_ lhs: Scalar, _ rhs: Self) -> Self {
    return self.addingProduct(Self(repeating: lhs), rhs)
  }
  @_transparent func addingProduct(_ lhs: Self, _ rhs: Scalar) -> Self {
    return self.addingProduct(lhs, Self(repeating: rhs))
  }
  @_transparent mutating func addProduct(_ lhs: Self, _ rhs: Self) {
    self = self.addingProduct(lhs, rhs)
  }
  @_transparent mutating func addProduct(_ lhs: Scalar, _ rhs: Self) {
    self = self.addingProduct(lhs, rhs)
  }
  @_transparent mutating func addProduct(_ lhs: Self, _ rhs: Scalar) {
    self = self.addingProduct(lhs, rhs)
  }
  
  @_transparent mutating func formSquareRoot( ) {
    self = self.squareRoot()
  }
  
  @_transparent mutating func round(_ rule: FloatingPointRoundingRule) {
    self = self.rounded(rule)
  }
}

public extension SIMD
where Scalar : BinaryFloatingPoint, Scalar.RawSignificand : FixedWidthInteger {
  @inlinable
  static func random<T: RandomNumberGenerator>(
    in range: Range<Scalar>,
    using generator: inout T
  ) -> Self {
    var result = Self()
    for i in result.indices {
      result[i] = Scalar.random(in: range, using: &generator)
    }
    return result
  }
  
  @inlinable
  static func random(in range: Range<Scalar>) -> Self {
    var g = SystemRandomNumberGenerator()
    return Self.random(in: range, using: &g)
  }
  
  @inlinable
  static func random<T: RandomNumberGenerator>(
    in range: ClosedRange<Scalar>,
    using generator: inout T
  ) -> Self {
    var result = Self()
    for i in result.indices {
      result[i] = Scalar.random(in: range, using: &generator)
    }
    return result
  }
  
  @inlinable
  static func random(in range: ClosedRange<Scalar>) -> Self {
    var g = SystemRandomNumberGenerator()
    return Self.random(in: range, using: &g)
  }
}

@_fixed_layout
public struct SIMDMask<Storage> : SIMD
                  where Storage : SIMD,
                 Storage.Scalar : FixedWidthInteger & SignedInteger {
  
  public var _storage : Storage
  
  public typealias MaskStorage = Storage
  
  public typealias Scalar = Bool
  
  @_transparent
  public var scalarCount: Int {
    return _storage.scalarCount
  }
  
  @_transparent
  public init() {
    _storage = Storage()
  }
  
  @_transparent
  public init(_ _storage: Storage) {
    self._storage = _storage
  }
  
  public subscript(index: Int) -> Bool {
    @_transparent
    get {
      _precondition(indices.contains(index))
      return _storage[index] < 0
    }
    @_transparent
    set {
      _precondition(indices.contains(index))
      _storage[index] = newValue ? -1 : 0
    }
  }
}

public extension SIMDMask {
  @_transparent
  static prefix func .!(rhs: SIMDMask) -> SIMDMask {
    return SIMDMask(~rhs._storage)
  }
  
  @_transparent
  static func .&(lhs: SIMDMask, rhs: SIMDMask) -> SIMDMask {
    return SIMDMask(lhs._storage & rhs._storage)
  }
  
  @_transparent
  static func .^(lhs: SIMDMask, rhs: SIMDMask) -> SIMDMask {
    return SIMDMask(lhs._storage ^ rhs._storage)
  }
  
  @_transparent
  static func .|(lhs: SIMDMask, rhs: SIMDMask) -> SIMDMask {
    return SIMDMask(lhs._storage | rhs._storage)
  }
}

public extension SIMDMask {
  
  @_transparent static func .&(lhs: Bool, rhs: SIMDMask) -> SIMDMask { return SIMDMask(repeating: lhs) .& rhs }
  @_transparent static func .^(lhs: Bool, rhs: SIMDMask) -> SIMDMask { return SIMDMask(repeating: lhs) .^ rhs }
  @_transparent static func .|(lhs: Bool, rhs: SIMDMask) -> SIMDMask { return SIMDMask(repeating: lhs) .| rhs }
  
  @_transparent static func .&(lhs: SIMDMask, rhs: Bool) -> SIMDMask { return lhs .& SIMDMask(repeating: rhs) }
  @_transparent static func .^(lhs: SIMDMask, rhs: Bool) -> SIMDMask { return lhs .^ SIMDMask(repeating: rhs) }
  @_transparent static func .|(lhs: SIMDMask, rhs: Bool) -> SIMDMask { return lhs .| SIMDMask(repeating: rhs) }
  
  @_transparent static func .&=(lhs: inout SIMDMask, rhs: SIMDMask) { lhs = lhs .& rhs }
  @_transparent static func .^=(lhs: inout SIMDMask, rhs: SIMDMask) { lhs = lhs .^ rhs }
  @_transparent static func .|=(lhs: inout SIMDMask, rhs: SIMDMask) { lhs = lhs .| rhs }
  
  @_transparent static func .&=(lhs: inout SIMDMask, rhs: Bool) { lhs = lhs .& rhs }
  @_transparent static func .^=(lhs: inout SIMDMask, rhs: Bool) { lhs = lhs .^ rhs }
  @_transparent static func .|=(lhs: inout SIMDMask, rhs: Bool) { lhs = lhs .| rhs }
  
  @inlinable
  static func random<T: RandomNumberGenerator>(using generator: inout T) -> SIMDMask {
    var result = SIMDMask()
    for i in result.indices { result[i] = Bool.random(using: &generator) }
    return result
  }
  
  @inlinable
  static func random() -> SIMDMask {
    var g = SystemRandomNumberGenerator()
    return SIMDMask.random(using: &g)
  }
}
