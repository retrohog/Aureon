import Foundation
import Synchronization

/// Read-copy-update cell for handing an object from a control thread to the real-time thread without locks.
///
/// * The real-time thread calls `read`: two atomic increments and one atomic load. No retain/release, no allocation.
/// * A control thread calls `publish`: it swaps the pointer, then waits (bounded) until any real-time read that may
///   still hold the old object has finished, and only then releases it. If the wait times out the old object is
///   deliberately leaked rather than risking a use-after-free.
final class RCUBox<T: AnyObject>: @unchecked Sendable {
    private let bits = Atomic<Int>(0)
    private let epoch = Atomic<Int>(0)          // odd while a reader is inside `read`
    private(set) var leaked = 0

    init(_ initial: T? = nil) { if let initial { bits.store(Int(bitPattern: Unmanaged.passRetained(initial).toOpaque()), ordering: .sequentiallyConsistent) } }

    deinit { publish(nil) }

    /// Real-time safe. Returns nil when the box is empty.
    @inline(__always)
    func read<R>(_ body: (T) -> R) -> R? {
        _ = epoch.add(1, ordering: .sequentiallyConsistent)
        defer { _ = epoch.add(1, ordering: .sequentiallyConsistent) }
        let p = bits.load(ordering: .sequentiallyConsistent)
        guard p != 0, let raw = UnsafeRawPointer(bitPattern: p) else { return nil }
        return Unmanaged<T>.fromOpaque(raw)._withUnsafeGuaranteedRef(body)
    }

    var isEmpty: Bool { bits.load(ordering: .relaxed) == 0 }

    /// Control thread only.
    func publish(_ new: T?) {
        let newBits = new.map { Int(bitPattern: Unmanaged.passRetained($0).toOpaque()) } ?? 0
        let old = bits.exchange(newBits, ordering: .sequentiallyConsistent)
        guard old != 0, let raw = UnsafeRawPointer(bitPattern: old) else { return }
        let e = epoch.load(ordering: .sequentiallyConsistent)
        if e & 1 == 1 {                                           // a reader is inside: wait for it to leave
            var waited = 0
            while epoch.load(ordering: .sequentiallyConsistent) == e && waited < 2_000 { usleep(100); waited += 1 }
            if epoch.load(ordering: .sequentiallyConsistent) == e { leaked += 1; return }
        }
        Unmanaged<T>.fromOpaque(raw).release()
    }
}
