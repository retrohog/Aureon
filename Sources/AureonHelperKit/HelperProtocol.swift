import Foundation

// Shared between the app and the privileged helper.
//
// SMJobBless is deprecated; the helper is registered with ServiceManagement's SMAppService.daemon, which needs
// a signed app bundle containing Contents/Library/LaunchDaemons/org.aureon.helper.plist and the helper binary,
// and the user's approval in System Settings → General → Login Items.

public enum HelperConstants {
    public static let machServiceName = "org.aureon.helper"
    public static let plistName = "org.aureon.helper.plist"
    public static let version = "1"
    /// Seconds without a heartbeat after which the helper resumes everything by itself.
    public static let heartbeatTimeout: TimeInterval = 20
    /// Hard upper bound for any suspension, even with a live client.
    public static let maxSuspension: TimeInterval = 4 * 3600
}

/// What the app may ask the helper to do. The helper never trusts these arguments blindly: names are checked against its own allowlist,
/// priorities only apply to the calling process, and a client that disappears causes an automatic resume.
@objc public protocol AureonHelperProtocol {
    func hello(reply: @escaping (String) -> Void)
    /// Suspends (SIGSTOP) allow-listed background processes. Replies with a description of each process suspended.
    func suspend(names: [String], reply: @escaping ([String]) -> Void)
    /// Resumes (SIGCONT) everything that was suspended. Replies with how many.
    func resume(reply: @escaping (Int) -> Void)
    func heartbeat(reply: @escaping (Bool) -> Void)
    /// Sets the scheduling priority (nice value, −20…0) of the *calling* process.
    func setCallerPriority(nice: Int32, reply: @escaping (Bool) -> Void)
    /// Descriptions of what is currently suspended.
    func status(reply: @escaping ([String]) -> Void)
}
