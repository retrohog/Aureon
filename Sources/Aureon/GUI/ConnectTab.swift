import SwiftUI
import AppKit

struct ConnectTab: View {
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        VStack(spacing: 18) {
            DiscordCard(social: m.social)
            ScrobbleCard(social: m.social)
            IdentifyCard(social: m.social)
            RemoteCard(remote: m.remote, social: m.social)
        }
    }
}

/// A secret is never shown back: the field is write-only, and what is saved goes to the Keychain.
struct SecretRow: View {
    let title: String
    let isSet: Bool
    let save: (String) -> Void
    @StateObject private var draft = Box("")

    var body: some View {
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            SecureField(isSet ? "saved in the Keychain — type to replace" : "paste here", text: $draft.v).textFieldStyle(.roundedBorder)
            Button("Save") { save(draft.v.trimmingCharacters(in: .whitespacesAndNewlines)); draft.v = "" }.disabled(draft.v.isEmpty)
            if isSet { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
        }
    }
}

struct DiscordCard: View {
    @ObservedObject var social: SocialModel
    var body: some View {
        Card(title: "Discord Rich Presence", subtitle: "Shows what you are listening to, with the audio quality — through Discord's local IPC, no account access") {
            Toggle("Show on Discord", isOn: $social.settings.discordEnabled)
            HStack {
                Text("Application ID").frame(width: 130, alignment: .leading)
                TextField("from discord.com/developers/applications", text: $social.settings.discordClientID).textFieldStyle(.roundedBorder)
            }
            Note(text: "Create a free application there and paste its ID. Album art appears when the track was identified (Deep Dive); otherwise upload an image named “aureon” to the application's Rich Presence assets.")
            HStack { Circle().fill(social.discordStatus.hasPrefix("Showing") || social.discordStatus == "Connected" ? Color.green : Color.gray).frame(width: 8, height: 8); Text(social.discordStatus).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct ScrobbleCard: View {
    @ObservedObject var social: SocialModel
    var body: some View {
        Card(title: "Scrobbling", subtitle: "A play counts after half the track or 4 minutes. Plays are queued offline and retried") {
            Group {
                Toggle("Last.fm", isOn: $social.settings.lastfmEnabled)
                SecretRow(title: "API key", isSet: !social.lastfmAPIKey.isEmpty) { social.lastfmAPIKey = $0 }
                SecretRow(title: "Shared secret", isSet: !social.lastfmSecret.isEmpty) { social.lastfmSecret = $0 }
                HStack {
                    Button("Sign in with Last.fm…") { social.beginLastFM() }
                    if social.lastfmWaitingToken != nil { Button("Finish sign-in") { social.finishLastFM() }.buttonStyle(.borderedProminent) }
                    Button("Sign out") { social.signOutLastFM() }.disabled(!social.lastfmStatus.hasPrefix("Signed in"))
                    Text(social.lastfmStatus).font(.caption).foregroundStyle(.secondary)
                }
                Note(text: "Register an API account at last.fm/api/account/create (it is free) and paste the key and secret. Your password is never entered in Aureon.")
            }
            Divider()
            Group {
                Toggle("ListenBrainz", isOn: $social.settings.listenbrainzEnabled)
                SecretRow(title: "User token", isSet: !social.listenbrainzToken.isEmpty) { social.listenbrainzToken = $0 }
                HStack {
                    Button("Check token") { social.validateListenBrainz() }
                    Text(social.listenbrainzStatus).font(.caption).foregroundStyle(.secondary)
                }
                Note(text: "Your token is on listenbrainz.org/settings.")
            }
            Divider()
            HStack {
                Text(social.pending == 0 ? "No plays waiting to be sent" : "\(social.pending) play\(social.pending == 1 ? "" : "s") waiting to be sent").font(.caption)
                Spacer()
                Button("Send now") { social.flush() }.disabled(social.pending == 0)
            }
            if let msg = social.message { Note(text: msg, color: .orange) }
        }
    }
}

struct IdentifyCard: View {
    @ObservedObject var social: SocialModel
    var body: some View {
        let found = FpcalcFingerprinter.locate(social.settings.fpcalcPath.isEmpty ? nil : social.settings.fpcalcPath)
        Card(title: "Identifying untagged files", subtitle: "AcoustID fingerprinting finds the MusicBrainz recording, for the Deep Dive") {
            HStack {
                Text("AcoustID key").frame(width: 130, alignment: .leading)
                TextField("application key from acoustid.org/new-application", text: $social.settings.acoustIDKey).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("fpcalc").frame(width: 130, alignment: .leading)
                TextField("automatic", text: $social.settings.fpcalcPath).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 6) {
                Image(systemName: found != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(found != nil ? Color.green : Color.orange)
                Text(found.map { "Chromaprint found at \($0)" } ?? "Chromaprint (fpcalc) is not installed — run: brew install chromaprint").font(.caption).foregroundStyle(.secondary)
            }
            Note(text: "Files tagged by MusicBrainz Picard need neither: they are identified from their tags.")
        }
    }
}

struct RemoteCard: View {
    @ObservedObject var remote: RemoteModel
    @ObservedObject var social: SocialModel
    @StateObject private var reveal = Box(false)

    var body: some View {
        Card(title: "Remote control", subtitle: "Let the Aureon iPhone/iPad app, or any client of the protocol, drive this Mac's player and browse its library") {
            Toggle("Allow remote control on this network", isOn: $social.settings.remoteEnabled)
            HStack {
                Text("Name").frame(width: 130, alignment: .leading)
                TextField(remote.hostName, text: $social.settings.remoteName).textFieldStyle(.roundedBorder)
                Text("Port").font(.caption).foregroundStyle(.secondary)
                TextField("auto", value: $social.settings.remotePort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 70)
            }
            if remote.running {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text("Listening on port \(String(remote.port)) · Bonjour “\(RemoteProtocol.bonjourType)” · \(remote.clients) connected").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Pairing token").frame(width: 130, alignment: .leading)
                    Text(reveal.v ? remote.token : String(repeating: "•", count: 24)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(reveal.v ? "Hide" : "Show") { reveal.v.toggle() }.buttonStyle(.link)
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(remote.token, forType: .string) }
                }
                Note(text: "Apps prove they know the token without sending it. The connection itself is not encrypted: use it on a trusted network. Remote apps may only add files from your library folders.", color: .orange)
            } else if let e = remote.error { Note(text: e, color: .red) }
            else { Note(text: "Off. For a Mac without a screen, run “Aureon daemon” instead — the same server without the window.") }
        }
    }
}
