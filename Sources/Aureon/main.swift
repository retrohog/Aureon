import Foundation

// No arguments (e.g. launched from Finder) opens the GUI; any subcommand runs the CLI.
setvbuf(stdout, nil, _IOLBF, 0)
let cliArgs = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn") }
if let out = ProcessInfo.processInfo.environment["AUREON_SNAPSHOT"] { MainActor.assumeIsolated { runSnapshot(out: out, files: cliArgs) } }
else if cliArgs.isEmpty { runGUI() } else { runCLI(cliArgs) }
