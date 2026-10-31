import SwiftUI
import SlskCore

// The Soulseek page: Search, Transfers, Browse, Chat, Shares, Connection and the protocol Log as chips along the top, in the look of the other pages.

struct SoulseekPage: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject private var s = SoulseekModel.shared

    var body: some View {
        PageScaffold(title: "Soulseek", subtitle: statusLine, ruled: false) {   // the rail carries SoulseekMark
            VStack(alignment: .leading, spacing: 16) {
                if !s.enabled { OffNotice() }
                else {
                    HStack(spacing: 8) {
                        ForEach(SoulseekPageID.allCases) { p in PillChip(title: chipTitle(p), on: s.page == p) { withAnimation(Motion.page) { s.page = p } } }
                    }
                    switch s.page {
                    case .search: SlskSearchView()
                    case .transfers: SlskTransfersView()
                    case .browse: SlskBrowseView()
                    case .chat: SlskChatView()
                    case .shares: SlskSharesView()
                    case .connection: SlskConnectionView()
                    case .log: SlskLogView()
                    }
                }
            }
        }
        .onAppear { s.refreshLibraryIndex() }
    }

    private func chipTitle(_ p: SoulseekPageID) -> String {
        p == .transfers && s.badge > 0 ? "Transfers \(s.badge)" : p.rawValue
    }

    private var statusLine: String {
        switch s.state {
        case .offline: "Not connected"
        case .connecting: "Connecting…"
        case .loggingIn: "Signing in…"
        case .online: "Connected as \(s.username)"
        case .failed(let r): "Not connected: \(r)"
        }
    }
}

private struct OffNotice: View {
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        Card(title: "Soulseek is off", subtitle: "A peer-to-peer network for finding music. It does nothing until you turn it on, and sharing stays off even then.") {
            Toggle("Turn on Soulseek", isOn: $s.enabled).font(Typo.sans(14))
            Note(text: SoulseekNotice.text)
        }
    }
}

enum SoulseekNotice {
    static let text = "Soulseek is a network run by its users. What you download or share there is your responsibility: only share what you have the right to share, and only download what you are allowed to have. Aureon does not search, share or connect anything until you turn it on, and it never shares your music unless you choose folders."
}

// MARK: - Search

private struct SlskSearchView: View {
    @ObservedObject private var s = SoulseekModel.shared
    @EnvironmentObject var m: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !s.isConnected { ConnectHint() }
            HStack(spacing: 8) {
                TextField("Search the network", text: $s.query).textFieldStyle(.plain).font(Typo.sans(14))
                    .padding(.horizontal, 16).frame(height: 36).background(Capsule().fill(Brand.panel2)).onSubmit { s.search() }
                Button("Search") { s.search() }.buttonStyle(SlskPrimary()).disabled(!s.isConnected)
                Button("Add to wishlist") { s.wish(s.query) }.buttonStyle(SlskSoft())
            }
            HStack(spacing: 6) {
                chip("Lossless", $s.filters.losslessOnly)
                chip("Free slot", $s.filters.freeSlotsOnly)
                chip("16-bit or more", Binding(get: { s.filters.minBitDepth >= 16 }, set: { s.filters.minBitDepth = $0 ? 16 : 0 }))
                chip("MP3 at 256+", Binding(get: { s.filters.minBitrate >= 256 }, set: { s.filters.minBitrate = $0 ? 256 : 0 }))
                Spacer()
                Text(s.snapshot.searching ? "Searching… \(s.snapshot.resultCount) files" : "\(s.snapshot.resultCount) files · \(s.rows.count) folders").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
            }
            if s.rows.isEmpty {
                if s.snapshot.searching { Note(text: "Results arrive from other people's computers; they trickle in for about 45 seconds.") }
                else if s.snapshot.diag.searchesSent > 0 && s.snapshot.resultCount == 0 {
                    HStack { Note(text: "No replies yet. Check the Connection page to see how far the search got."); Button("Open Connection") { s.page = .connection }.buttonStyle(SlskSoft()) }
                } else if s.snapshot.resultCount > 0 { Note(text: "Nothing matches the filters above. Turn one off to see the \(s.snapshot.resultCount) files found.") }
                else { Note(text: "Search for an artist, album or song. Lossless files are marked with their bit depth and sample rate.") }
            }
            else {
                ScrollView { LazyVStack(spacing: 6) { ForEach(s.rows) { SlskRowView(row: $0) } } }.frame(minHeight: 320)
            }
        }
    }

    private func chip(_ t: String, _ on: Binding<Bool>) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(t).font(Typo.sans(12, on.wrappedValue ? .medium : .regular)).padding(.horizontal, 11).frame(height: 26)
                .background(Capsule().fill(on.wrappedValue ? Brand.accent.opacity(0.22) : Brand.panel2)).foregroundStyle(Brand.ink)
        }.buttonStyle(.plain)
    }
}

private struct SlskRowView: View {
    let row: SlskRow
    @ObservedObject private var s = SoulseekModel.shared
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(Typo.sans(11)).foregroundStyle(Brand.inkSecondary).frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.folder.split(separator: "\\").suffix(2).joined(separator: " · ").isEmpty ? row.files.first?.name ?? "" : row.folder.split(separator: "\\").suffix(2).joined(separator: " · ")).font(Typo.sans(14, .medium)).lineLimit(1)
                    Text("\(row.user) · \(row.files.count) files · \(SlskFormat.bytes(row.bytes))").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Badge(text: row.format, color: row.files.first?.isLossless == true ? Brand.accentText : Brand.inkSecondary)
                Text(row.freeSlot ? "Free slot" : "Queue \(row.queueLength)").font(Typo.sans(12)).foregroundStyle(row.freeSlot ? Brand.accentText : Brand.caution).frame(width: 74, alignment: .trailing)
                Button("Download") { s.download(row.files, from: row.user) }.buttonStyle(SlskSoft())
            }
            .contentShape(Rectangle()).onTapGesture { withAnimation(Motion.touch) { open.toggle() } }
            if open {
                VStack(spacing: 0) {
                    ForEach(row.files.prefix(60)) { f in
                        HStack {
                            Text(f.name).font(Typo.sans(13)).lineLimit(1)
                            Spacer()
                            if s.isInLibrary(f) { Text("Already in your library").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary) }
                            Text(SlskFormat.bytes(f.size)).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
                            Button { s.download([f], from: row.user) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.plain).disabled(s.isInLibrary(f))
                        }.frame(height: 28)
                    }
                    HStack(spacing: 6) {
                        Button("Browse user") { s.browse(row.user) }.buttonStyle(SlskSoft())
                        Button("Message") { s.page = .chat; s.browseUser = row.user }.buttonStyle(SlskSoft())
                        Button(s.isBlocked(row.user) ? "Unblock" : "Block") { s.block(row.user, !s.isBlocked(row.user)) }.buttonStyle(SlskSoft())
                    }.padding(.top, 6)
                }.padding(.leading, 24)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Brand.panel2))
    }
}

// MARK: - Transfers

private struct SlskTransfersView: View {
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button("Pause all") { s.pauseAll(true) }.buttonStyle(SlskPrimary())
                Button("Resume") { s.pauseAll(false) }.buttonStyle(SlskSoft())
                Button("Clear finished") { s.clearFinished() }.buttonStyle(SlskSoft())
                Spacer()
                Text("↓ \(SlskFormat.speed(s.snapshot.downSpeed))   ↑ \(SlskFormat.speed(s.snapshot.upSpeed))").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).monospacedDigit()
            }
            Card(title: "Downloads", subtitle: s.snapshot.downloads.isEmpty ? "Nothing yet. Choose files on the Search page." : nil) {
                if s.snapshot.protectionPause { Note(text: "Paused for a few seconds to keep playback smooth.", color: Brand.caution) }
                ForEach(s.snapshot.downloads) { TransferLine(t: $0) }
            }
            Card(title: "Uploads", subtitle: s.sharing ? "To others, from the folders you share" : "Sharing is off, so nothing is sent") {
                ForEach(s.snapshot.uploads) { TransferLine(t: $0) }
            }
        }
    }
}

struct TransferLine: View {
    let t: SlskTransferInfo
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(t.name).font(Typo.sans(13.5, .medium)).lineLimit(1)
                Spacer()
                Text(trailing).font(Typo.sans(12)).foregroundStyle(attention ? Brand.caution : Brand.inkSecondary).lineLimit(1).monospacedDigit()
            }
            ProgressRule(value: t.progress, tint: t.state == .finished ? Brand.accentText : Brand.accent)
            HStack(spacing: 6) {
                Text("\(t.user) · \(SlskFormat.bytes(t.done)) of \(SlskFormat.bytes(t.size))").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary)
                Spacer()
                if t.kind == .download {
                    if case .needsAttention = t.state { Button("Try again") { s.retry(t.id) }.buttonStyle(SlskSoft()) }
                    if t.state.isActive { Button("Cancel") { s.cancel(t.id) }.buttonStyle(SlskSoft()) }
                }
            }
        }
    }
    private var attention: Bool { if case .needsAttention = t.state { return true }; return false }
    private var trailing: String { t.state == .transferring ? "\(Int(t.progress * 100))% · \(SlskFormat.speed(t.speed))" : SlskFormat.state(t.state) }
}

struct ProgressRule: View {
    let value: Double; var tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.ink.opacity(0.12))
                Capsule().fill(tint).frame(width: max(0, g.size.width * value))
            }
        }.frame(height: 4)
    }
}

// MARK: - Browse

private struct SlskBrowseView: View {
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField("User name", text: $s.browseUser).textFieldStyle(.plain).padding(.horizontal, 16).frame(height: 36).background(Capsule().fill(Brand.panel2)).onSubmit { s.browse(s.browseUser) }
                Button("Browse") { s.browse(s.browseUser) }.buttonStyle(SlskPrimary()).disabled(!s.isConnected || s.browseUser.isEmpty)
            }
            let files = s.snapshot.browsed[s.browseUser] ?? []
            if files.isEmpty { Note(text: "Asks the user for the list of what they share. Users who share nothing, or who are offline, return an empty list.") }
            else {
                Text("\(files.count) files").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
                ScrollView { LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(files.prefix(5000)) { f in
                        HStack { Text(f.path.replacingOccurrences(of: "\\", with: " / ")).font(Typo.sans(12.5)).lineLimit(1); Spacer(); Text(SlskFormat.bytes(f.size)).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
                            Button { s.download([f], from: s.browseUser) } label: { Image(systemName: "arrow.down.circle") }.buttonStyle(.plain) }.frame(height: 26)
                    }
                } }.frame(minHeight: 300)
            }
        }
    }
}

// MARK: - Chat

private struct SlskChatView: View {
    @ObservedObject private var s = SoulseekModel.shared
    @State private var to = ""
    @State private var text = ""
    @State private var room = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Messages", subtitle: "Private messages to other users") {
                HStack(spacing: 8) {
                    TextField("To", text: $to).textFieldStyle(.plain).padding(.horizontal, 14).frame(width: 160, height: 34).background(Capsule().fill(Brand.panel))
                    TextField("Message", text: $text).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 34).background(Capsule().fill(Brand.panel)).onSubmit(send)
                    Button("Send", action: send).buttonStyle(SlskPrimary()).disabled(!s.isConnected || to.isEmpty || text.isEmpty)
                }
                ForEach(s.snapshot.messages.keys.sorted(), id: \.self) { u in
                    VStack(alignment: .leading, spacing: 2) { Text(u).font(Typo.sans(12.5, .medium)); ForEach(Array((s.snapshot.messages[u] ?? []).suffix(8).enumerated()), id: \.offset) { Text($0.element).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary) } }
                }
            }
            Card(title: "Rooms", subtitle: "Join a room to read and write in it") {
                HStack(spacing: 8) {
                    TextField("Room name", text: $room).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 34).background(Capsule().fill(Brand.panel)).onSubmit { s.client?.joinRoom(room); room = "" }
                    Button("Join") { s.client?.joinRoom(room); room = "" }.buttonStyle(SlskPrimary()).disabled(!s.isConnected || room.isEmpty)
                }
                ForEach(s.snapshot.rooms, id: \.name) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text("# \(r.name)").font(Typo.sans(13, .medium)); Text("\(r.users) people").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary); Spacer(); Button("Leave") { s.client?.leaveRoom(r.name) }.buttonStyle(SlskSoft()) }
                        ForEach(Array(r.lines.suffix(10).enumerated()), id: \.offset) { Text($0.element).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary) }
                    }
                }
            }
        }
    }
    private func send() { guard !to.isEmpty, !text.isEmpty else { return }; s.message(to, text); text = "" }
}

// MARK: - Shares

struct SlskSharesView: View {
    @ObservedObject private var s = SoulseekModel.shared
    @EnvironmentObject var m: PlayerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Sharing", subtitle: "Off until you choose. Nothing is shared without a folder you tick.") {
                Toggle("Share my music", isOn: $s.sharing).font(Typo.sans(14))
                Note(text: "Others see names like “Jazz\\Album\\01 Track.flac”, never your folders or your user name. They can only download what is in the folders ticked below.")
                if s.sharing && s.sharedFolders.isEmpty { Note(text: "No folder is ticked yet, so nothing is shared.", color: Brand.caution) }
                ForEach(m.library.folders, id: \.self) { f in
                    Toggle(isOn: Binding(get: { s.sharedFolders.contains(f) }, set: { on in if on { s.sharedFolders.append(f) } else { s.sharedFolders.removeAll { $0 == f } } })) {
                        Text(f).font(Typo.sans(12.5)).lineLimit(1).truncationMode(.middle)
                    }.disabled(!s.sharing)
                }
                if m.library.folders.isEmpty { Note(text: "Add a music folder to the library first; its folders appear here.") }
                HStack { Text("Upload speed limit").frame(width: 150, alignment: .leading)
                    ValueSlider(value: Binding(get: { Double(s.uploadLimitKB) }, set: { s.uploadLimitKB = Int($0) }), in: 0...8192, step: 64)
                    Text(s.uploadLimitKB == 0 ? "No limit" : "\(s.uploadLimitKB) KB/s").frame(width: 90, alignment: .trailing).monospacedDigit() }
            }
            Card(title: "Download folders") {
                row("Finished", s.downloadsFolder.path)
                row("Unfinished (hidden)", s.incompleteFolder.path)
                Toggle("Add finished downloads to my library", isOn: $s.addToLibrary).font(Typo.sans(14))
                Note(text: "Files are never changed. An album is added once, after its last song has arrived. Unfinished files stay outside the library.")
            }
            Note(text: SoulseekNotice.text)
        }
    }
    private func row(_ t: String, _ v: String) -> some View { HStack { Text(t).foregroundStyle(Brand.inkSecondary); Spacer(); Text(v).font(Typo.sans(12)).lineLimit(1).truncationMode(.middle) } }
}

// MARK: - Connection

struct SlskConnectionView: View {
    @ObservedObject private var s = SoulseekModel.shared
    @State private var password = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: "Account", subtitle: "Your Soulseek name and password. The password is kept in the keychain.") {
                TextField("User name", text: $s.username).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 36).background(Capsule().fill(Brand.panel))
                SecureField("Password", text: $password).textFieldStyle(.plain).padding(.horizontal, 14).frame(height: 36).background(Capsule().fill(Brand.panel)).onSubmit { s.connect(password: password.isEmpty ? nil : password) }
                HStack(spacing: 8) {
                    if s.isConnected { Button("Disconnect") { s.disconnect() }.buttonStyle(SlskSoft()) }
                    else { Button("Connect") { s.connect(password: password.isEmpty ? nil : password); password = "" }.buttonStyle(SlskPrimary()) }
                    Text(statusText).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary)
                }
                if let e = s.lastError { Note(text: e, color: Brand.caution) }
                Toggle("Connect when Aureon starts", isOn: $s.connectAtLaunch).font(Typo.sans(14))
                Note(text: SoulseekNotice.text)
            }
            Card(title: "Network check", subtitle: "Where a search gets to. Useful when it finds nothing") {
                let d = s.snapshot.diag
                checkRow("Listening for peers", d.listening ? "Yes, port \(d.listenPort)" : "No: others can only reach you through the server", ok: d.listening)
                checkRow("Peers that connected to you", "\(d.incomingLinks)", ok: d.incomingLinks > 0)
                checkRow("Peers the server asked you to call", "\(d.relayRequests) (\(d.relayConnected) connected)", ok: d.relayRequests == 0 || d.relayConnected > 0)
                checkRow("Searches sent", "\(d.searchesSent)", ok: true)
                checkRow("Results read", "\(d.responsesRead)" + (d.responsesUnreadable > 0 ? ", \(d.responsesUnreadable) unreadable" : ""), ok: d.responsesUnreadable == 0)
                checkRow("Peer links open now", "\(d.peerLinks)", ok: true)
                Note(text: "If searches are sent but no peer connects and the server asks for no calls, a firewall or router is probably blocking the listening port.")
            }
            Card(title: "Keep playback smooth") {
                Toggle("Pause transfers while playing hi-res from the network", isOn: $s.pauseWhileHiRes).font(Typo.sans(14))
                Note(text: "Transfers wait for ten seconds at a time, and uploads drop to one at a time while music plays. Transfers never run on the audio thread.")
            }
        }
    }
    private func checkRow(_ t: String, _ v: String, ok: Bool) -> some View {
        HStack { Text(t).foregroundStyle(Brand.inkSecondary); Spacer(); Text(v).foregroundStyle(ok ? Brand.ink : Brand.caution).monospacedDigit() }.font(Typo.sans(13))
    }
    private var statusText: String {
        switch s.state { case .offline: "Not connected"; case .connecting: "Connecting…"; case .loggingIn: "Signing in…"; case .online: "Connected, listening on port \(s.snapshot.listenPort)"; case .failed(let r): "Failed: \(r)" }
    }
}

// MARK: - Log

private struct SlskLogView: View {
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Note(text: "What the client sends and receives, in words. Passwords are never written here.")
            ScrollView { LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(s.log) { l in
                    Text("\(l.time.formatted(date: .omitted, time: .standard))  \(l.direction)  \(l.text)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Brand.inkSecondary).lineLimit(2)
                }
            } }.frame(minHeight: 320)
        }
        .onAppear { s.log = Array((s.client?.log.all() ?? []).suffix(400)) }
    }
}

private struct ConnectHint: View {
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle").foregroundStyle(Brand.inkSecondary)
            Text("Not connected. Sign in on the Connection page to search.").font(Typo.sans(13)).foregroundStyle(Brand.inkSecondary)
            Spacer()
            Button("Open Connection") { s.page = .connection }.buttonStyle(SlskSoft())
        }.padding(12).background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Brand.panel2))
    }
}

// MARK: - Buttons

struct SlskPrimary: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typo.sans(13, .medium)).foregroundStyle(Brand.onAccent).padding(.horizontal, 15).frame(height: 32)
            .background(Capsule().fill(Brand.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)))
    }
}
struct SlskSoft: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Typo.sans(12, .medium)).foregroundStyle(Brand.ink).padding(.horizontal, 11).frame(height: 26)
            .background(Capsule().fill(Brand.ink.opacity(configuration.isPressed ? 0.16 : 0.08)))
    }
}

// MARK: - Settings card

/// Settings → General: the switch that turns Soulseek on. Off by default; turning it on only shows the page, it connects to nothing.
struct SoulseekSettingsCard: View {
    @ObservedObject private var s = SoulseekModel.shared
    var body: some View {
        Card(title: "Soulseek", subtitle: "Find and share music on the Soulseek network. Off until you turn it on") {
            Toggle("Turn on Soulseek", isOn: $s.enabled).font(Typo.sans(14))
            Note(text: s.enabled ? "A Soulseek page is on the rail and a Downloads button is in the top bar. You still sign in yourself, and sharing stays off until you choose folders." : "Nothing connects and nothing is added to the window while this is off.")
            Note(text: SoulseekNotice.text)
        }
    }
}
