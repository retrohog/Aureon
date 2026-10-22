import Foundation
import CoreMIDI

// MIDI control surfaces, part 2: CoreMIDI. This is the only file that talks to the system's MIDI service.

struct MIDISourceInfo: Identifiable, Hashable, Sendable {
    /// CoreMIDI's persistent unique ID: it survives unplugging and replugging.
    let id: Int32
    let name: String
    let online: Bool
}

/// Listens to every enabled MIDI source and drops what it hears into a lock-free ring.
///
/// CoreMIDI calls the receive block on its own real-time-priority thread. That block does exactly this and nothing else: it
/// decodes the packets (no allocation, no locks, no Swift/Objective-C messaging), pushes packed messages into the ring and
/// pokes a dispatch source that wakes the main thread. Interpreting the messages happens there, never on that thread.
final class MIDIInput: @unchecked Sendable {
    let ring: MIDIEventRing
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []
    private let wake: DispatchSourceUserDataOr
    private let stateLock = NSLock()                  // guards the control-side lists only; never taken by the receive block
    private var disabledSources: Set<Int32> = []
    private(set) var started = false
    /// Called on the main queue when sources appear or disappear.
    var onTopologyChange: (() -> Void)?

    /// - Parameter onPending: runs on the main queue after messages have arrived (coalesced: many messages, one call).
    init(ring: MIDIEventRing = MIDIEventRing(), onPending: @escaping () -> Void) {
        self.ring = ring
        wake = DispatchSource.makeUserDataOrSource(queue: .main)
        wake.setEventHandler(handler: onPending)
        wake.resume()
    }

    deinit { stop(); wake.cancel() }

    /// Throws the CoreMIDI error code when the MIDI service is not available.
    func start() throws {
        guard !started else { return }
        var c = MIDIClientRef()
        var status = MIDIClientCreateWithBlock("Aureon" as CFString, &c) { [weak self] note in
            // setup changes can arrive on any thread: hop to main, where the person-facing lists live
            guard note.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.rescan(); self?.onTopologyChange?() }
        }
        guard status == noErr else { throw MIDIInputError.coreMIDI(status) }
        var p = MIDIPortRef()
        let ring = self.ring, wake = self.wake
        status = MIDIInputPortCreateWithProtocol(c, "Aureon Input" as CFString, ._1_0, &p) { list, _ in
            // CoreMIDI thread. MIDIEventList: protocol (4) numPackets (4), then packets of timestamp (8) wordCount (4) words.
            let raw = UnsafeRawPointer(list)
            let packets = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            var offset = 8, pushed = false
            for _ in 0..<min(packets, 64) {
                let words = min(64, Int(raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
                for w in 0..<words {
                    let word = raw.loadUnaligned(fromByteOffset: offset + 12 + 4 * w, as: UInt32.self)
                    if let m = MIDIMessage.parse(word: word) { ring.push(m.packed); pushed = true }
                }
                offset += 12 + 4 * words
            }
            if pushed { wake.or(data: 1) }
        }
        guard status == noErr else { MIDIClientDispose(c); throw MIDIInputError.coreMIDI(status) }
        client = c; port = p; started = true
        rescan()
    }

    func stop() {
        guard started else { return }
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected = []
        MIDIPortDispose(port); MIDIClientDispose(client)
        port = MIDIPortRef(); client = MIDIClientRef(); started = false
    }

    /// The sources the person has switched off (by unique ID). Takes effect at once.
    func setDisabled(_ ids: Set<Int32>) {
        stateLock.lock(); disabledSources = ids; stateLock.unlock()
        rescan()
    }

    /// Every source CoreMIDI knows, including ones that are currently offline.
    static func sources() -> [MIDISourceInfo] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let s = MIDIGetSource(i)
            guard s != 0 else { return nil }
            var uid: Int32 = 0, offline: Int32 = 0
            MIDIObjectGetIntegerProperty(s, kMIDIPropertyUniqueID, &uid)
            MIDIObjectGetIntegerProperty(s, kMIDIPropertyOffline, &offline)
            return MIDISourceInfo(id: uid, name: name(of: s), online: offline == 0)
        }
    }

    private static func name(of o: MIDIObjectRef) -> String {
        var cf: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(o, kMIDIPropertyDisplayName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        if MIDIObjectGetStringProperty(o, kMIDIPropertyName, &cf) == noErr, let s = cf?.takeRetainedValue() { return s as String }
        return "MIDI source"
    }

    /// Connects the port to every enabled, online source and disconnects the rest.
    func rescan() {
        guard started else { return }
        stateLock.lock(); let off = disabledSources; stateLock.unlock()
        for s in connected { MIDIPortDisconnectSource(port, s) }
        connected = []
        for i in 0..<MIDIGetNumberOfSources() {
            let s = MIDIGetSource(i)
            guard s != 0 else { continue }
            var uid: Int32 = 0, offline: Int32 = 0
            MIDIObjectGetIntegerProperty(s, kMIDIPropertyUniqueID, &uid)
            MIDIObjectGetIntegerProperty(s, kMIDIPropertyOffline, &offline)
            if offline != 0 || off.contains(uid) { continue }
            if MIDIPortConnectSource(port, s, nil) == noErr { connected.append(s) }
        }
    }

    var connectedCount: Int { connected.count }
}

enum MIDIInputError: Error, CustomStringConvertible {
    case coreMIDI(OSStatus)
    var description: String {
        switch self { case .coreMIDI(let s): "The system MIDI service refused (error \(s))" }
    }
}
