import Foundation
import AureonNeuralCore

// Drop-in replacements for `Synchronization.Atomic` and `Synchronization.Mutex`, which need macOS 15.
//
// `Atomic` is a lock-free cell over the C atomics in AureonNeuralCore. Its storage is allocated once, in `init`; load, store, add,
// exchange and compareExchange are single inlined atomic instructions with no allocation, lock or runtime messaging, so they are
// safe on the audio render thread. `Mutex` is an `os_unfair_lock` and is only for control-thread state, never the render path.

enum AtomicOrdering: Int32 {
    case relaxed = 0, acquiring = 1, releasing = 2, acquiringAndReleasing = 3, sequentiallyConsistent = 4
}

protocol AtomicRepresentable {
    init(atomicBits: UInt64)
    var atomicBits: UInt64 { get }
}

extension Int: AtomicRepresentable {
    @inline(__always) init(atomicBits: UInt64) { self = Int(truncatingIfNeeded: Int64(bitPattern: atomicBits)) }
    @inline(__always) var atomicBits: UInt64 { UInt64(bitPattern: Int64(self)) }
}
extension Int64: AtomicRepresentable {
    @inline(__always) init(atomicBits: UInt64) { self = Int64(bitPattern: atomicBits) }
    @inline(__always) var atomicBits: UInt64 { UInt64(bitPattern: self) }
}
extension UInt64: AtomicRepresentable {
    @inline(__always) init(atomicBits: UInt64) { self = atomicBits }
    @inline(__always) var atomicBits: UInt64 { self }
}
extension UInt32: AtomicRepresentable {
    @inline(__always) init(atomicBits: UInt64) { self = UInt32(truncatingIfNeeded: atomicBits) }
    @inline(__always) var atomicBits: UInt64 { UInt64(self) }
}
extension Bool: AtomicRepresentable {
    @inline(__always) init(atomicBits: UInt64) { self = atomicBits != 0 }
    @inline(__always) var atomicBits: UInt64 { self ? 1 : 0 }
}

final class Atomic<Value: AtomicRepresentable>: @unchecked Sendable {
    private let cell: UnsafeMutablePointer<UInt64>

    init(_ initial: Value) {
        cell = .allocate(capacity: 1)
        cell.initialize(to: initial.atomicBits)
    }
    deinit { cell.deallocate() }

    @inline(__always) func load(ordering: AtomicOrdering) -> Value {
        Value(atomicBits: au_atomic_load(cell, ordering.rawValue))
    }
    @inline(__always) func store(_ v: Value, ordering: AtomicOrdering) {
        au_atomic_store(cell, v.atomicBits, ordering.rawValue)
    }
    @inline(__always) @discardableResult func exchange(_ v: Value, ordering: AtomicOrdering) -> Value {
        Value(atomicBits: au_atomic_exchange(cell, v.atomicBits, ordering.rawValue))
    }
    @inline(__always) func compareExchange(expected: Value, desired: Value, ordering: AtomicOrdering) -> (exchanged: Bool, original: Value) {
        var e = expected.atomicBits
        let ok = au_atomic_compare_exchange(cell, &e, desired.atomicBits, ordering.rawValue)
        return (ok, Value(atomicBits: e))
    }
}

extension Atomic where Value: FixedWidthInteger {
    /// Wrapping add; returns the value before and after, like `Synchronization.Atomic.wrappingAdd`.
    @inline(__always) @discardableResult func add(_ v: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) {
        let old = Value(atomicBits: au_atomic_fetch_add(cell, v.atomicBits, ordering.rawValue))
        return (old, old &+ v)
    }
}

extension Atomic where Value: FixedWidthInteger {
    @inline(__always) @discardableResult func wrappingAdd(_ v: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) { add(v, ordering: ordering) }
}

extension Atomic where Value: FixedWidthInteger {
    @inline(__always) @discardableResult func subtract(_ v: Value, ordering: AtomicOrdering) -> (oldValue: Value, newValue: Value) { add(0 &- v, ordering: ordering) }
}

final class Mutex<Value>: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var value: Value

    init(_ initial: Value) {
        value = initial
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }
    deinit { lock.deallocate() }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return try body(&value)
    }
}
