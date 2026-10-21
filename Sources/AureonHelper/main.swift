import Foundation
import AureonHelperKit

// aureon-helper: runs as a launchd daemon (root) registered through SMAppService. It only ever pauses an allow-list of
// background daemons while Aureon plays, and resumes them on every exit path. See Docs/SYSTEM-OPTIMIZATION.md.

let service = HelperService()
// The app must be signed with the same team to talk to us. (Set at build/packaging time; unsigned developer builds cannot connect.)
service.codeSigningRequirement = ProcessInfo.processInfo.environment["AUREON_HELPER_REQUIREMENT"] ?? "identifier \"org.aureon.player\" and anchor apple generic"

for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_IGN) }
let sources = [SIGTERM, SIGINT, SIGHUP].map { s -> DispatchSourceSignal in
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler { service.restoreEverything(); exit(0) }
    src.resume(); return src
}
atexit { service.restoreEverything() }

let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = service
listener.resume()
withExtendedLifetime(sources) { RunLoop.main.run() }
