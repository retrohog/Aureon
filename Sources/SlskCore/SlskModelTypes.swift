import Foundation

// Plain values the client publishes. The user interface reads snapshots of these at a few hertz; nothing here is observed per packet.

public enum SlskLinkState: Equatable, Sendable {
    case offline, connecting, loggingIn, online(String), failed(String)
    public var isOnline: Bool { if case .online = self { return true }; return false }
}

public enum SlskTransferKind: String, Sendable { case download, upload }

public enum SlskTransferState: Equatable, Sendable {
    case waiting                    // not started yet
    case connecting
    case queued(place: Int?)        // in the other side's queue
    case transferring
    case finished
    case paused
    case needsAttention(String)     // refused or failed for good; the reason is shown
    case retrying(String)           // failed, will try again
    public var isActive: Bool { switch self { case .connecting, .queued, .transferring, .retrying, .waiting: true; default: false } }
}

public struct SlskTransferInfo: Equatable, Identifiable, Sendable {
    public var id: Int
    public var kind: SlskTransferKind
    public var user: String
    public var path: String
    public var size: UInt64
    public var done: UInt64
    public var state: SlskTransferState
    public var speed: Double          // bytes per second, smoothed
    public var attempts: Int
    public init(id: Int, kind: SlskTransferKind, user: String, path: String, size: UInt64, done: UInt64, state: SlskTransferState, speed: Double, attempts: Int) {
        self.id = id; self.kind = kind; self.user = user; self.path = path; self.size = size; self.done = done; self.state = state; self.speed = speed; self.attempts = attempts
    }
    public var name: String { path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path }
    public var progress: Double { size == 0 ? 0 : min(1, Double(done) / Double(size)) }
}

public struct SlskLogLine: Equatable, Identifiable, Sendable {
    public var id: Int
    public var time: Date
    public var direction: String      // "→" sent, "←" received, "·" note
    public var text: String
}

public struct SlskRoomState: Equatable, Sendable {
    public var name: String
    public var lines: [String]
    public var users: Int
}

/// Counters that show where a search stops: listening, who reached us, who asked the server to relay, how many results were read.
public struct SlskDiagnostics: Equatable {
    public var listening = false
    public var listenPort: UInt16 = 0
    public var incomingLinks = 0          // peers that connected to us
    public var relayRequests = 0          // ConnectToPeer messages from the server (we connect out)
    public var relayConnected = 0         // of those, links that opened
    public var searchesSent = 0
    public var responsesRead = 0          // FileSearchResponse messages understood
    public var responsesUnreadable = 0    // ... and those that could not be read
    public var peerLinks = 0              // live peer links now
    public init() {}
}

public struct SlskSnapshot: Equatable {
    public var state: SlskLinkState = .offline
    public var downloads: [SlskTransferInfo] = []
    public var uploads: [SlskTransferInfo] = []
    public var downSpeed: Double = 0
    public var upSpeed: Double = 0
    public var results: [SlskSearchResponse] = []
    public var resultCount = 0
    public var searching = false
    public var rooms: [SlskRoomState] = []
    public var messages: [String: [String]] = [:]
    public var browsed: [String: [SlskFileResult]] = [:]
    public var listenPort: UInt16 = 0
    public var protectionPause = false
    public var diag = SlskDiagnostics()
    public init() {}
    public var activeCount: Int { (downloads + uploads).filter { $0.state.isActive }.count }
    public var movingCount: Int { (downloads + uploads).filter { $0.state == .transferring }.count }
}

/// The protocol log, a ring of readable lines. Passwords never reach it.
public final class SlskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [SlskLogLine] = []
    private var next = 1
    public let capacity: Int
    public init(capacity: Int = 2000) { self.capacity = capacity }
    public func add(_ dir: String, _ text: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(SlskLogLine(id: next, time: Date(), direction: dir, text: text)); next += 1
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }
    public func all() -> [SlskLogLine] { lock.lock(); defer { lock.unlock() }; return lines }
    public func clear() { lock.lock(); lines.removeAll(); lock.unlock() }
}
