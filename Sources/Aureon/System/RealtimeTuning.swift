import Foundation
import Darwin
import CoreAudio

/// Scheduling tweaks that need no privileges.
///
/// macOS already runs the CoreAudio IOProc thread under a real-time (time-constraint) policy and a process cannot raise that
/// above what the system grants. What *can* be improved from user space:
///   • Aureon's own decode/engine thread: a time-constraint policy (and the top QoS class) so it is scheduled promptly
///     even when the machine is busy, which keeps the ring buffer full;
///   • the device's "IO cycle usage": how much of each IO cycle the HAL lets our callback use before it counts as an overload,
///     which matters for heavy processing such as long convolution.
enum RealtimeThread {
    struct TimeConstraint: Equatable { var periodMs: Double, computationMs: Double, constraintMs: Double, preemptible: Bool }

    private static func ticksPerMs() -> Double {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1e6 * Double(tb.denom) / Double(tb.numer)
    }

    /// Puts the *calling* thread under a time-constraint policy and the user-interactive QoS class.
    /// The defaults reserve 1 ms of every 5 ms and must be met within 4 ms: a polite request, not a monopoly.
    @discardableResult
    static func promoteCurrentThread(periodMs: Double = 5, computationMs: Double = 1, constraintMs: Double = 4, preemptible: Bool = true) -> Bool {
        let k = ticksPerMs()
        var p = thread_time_constraint_policy_data_t(period: UInt32(periodMs * k), computation: UInt32(computationMs * k), constraint: UInt32(constraintMs * k), preemptible: preemptible ? 1 : 0)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &p) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_policy_set(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count) }
        }
        if r != KERN_SUCCESS { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0) }   // fall back to the highest ordinary class
        return r == KERN_SUCCESS
    }

    /// The calling thread's current time-constraint policy, or nil if it is not under one.
    static func currentPolicy() -> TimeConstraint? {
        var p = thread_time_constraint_policy_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        var isDefault: boolean_t = 0
        let r = withUnsafeMutablePointer(to: &p) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_policy_get(mach_thread_self(), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, &count, &isDefault) }
        }
        guard r == KERN_SUCCESS, isDefault == 0, p.period != 0 else { return nil }
        let k = ticksPerMs()
        return TimeConstraint(periodMs: Double(p.period) / k, computationMs: Double(p.computation) / k, constraintMs: Double(p.constraint) / k, preemptible: p.preemptible != 0)
    }

    static var currentQoS: qos_class_t { qos_class_self() }
}

extension OutputDevice {
    /// kAudioDevicePropertyIOCycleUsage: the fraction (0.05 … 1.0) of each IO cycle our callback may use. System default is 0.5.
    var ioCycleUsage: Float? {
        get { getValue(id, addr(kAudioDevicePropertyIOCycleUsage, kAudioObjectPropertyScopeOutput), default: Float32(0)) }
    }

    @discardableResult
    func setIOCycleUsage(_ v: Float) -> Bool {
        setValue(id, addr(kAudioDevicePropertyIOCycleUsage, kAudioObjectPropertyScopeOutput), Float32(max(0.05, min(1, v)))) == noErr
    }
}
