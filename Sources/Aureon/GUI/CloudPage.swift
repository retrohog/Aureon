import SwiftUI

struct CloudPage: View {
    @EnvironmentObject var cloud: CloudModel

    var body: some View {
        PageScaffold(title: "Cloud", subtitle: "Your own storage", trailing: {
            PillButton(title: "Add music server…", symbol: "server.rack") { cloud.newServer() }
            PillButton(title: "Add storage…", symbol: "plus") { cloud.newProfile() }
        }) {
            VStack(alignment: .leading, spacing: 16) {
                if let d = cloud.draft { editor(d) }
                if let s = cloud.serverDraft { serverEditor(s) }
                if cloud.profiles.isEmpty && cloud.servers.isEmpty && cloud.draft == nil && cloud.serverDraft == nil {
                    EmptyExplainer(icon: "icloud", title: "Play from your own storage",
                                   text: "Connect a Backblaze B2, Amazon S3, Cloudflare R2, Wasabi or MinIO bucket that holds your music, or a Navidrome or Subsonic server. Aureon indexes it into your library and streams files as you play them: it reads ahead of the playhead and prepares the next track, so playback stays gapless. Your keys stay in the macOS Keychain; nothing goes through any server of ours.")
                }
                ForEach(cloud.servers) { p in serverCard(p) }
                ForEach(cloud.profiles) { p in profileCard(p) }
                if let r = cloud.report { Note(text: r, color: cloud.reportIsError ? .red : .green) }
            }
        }
        .onAppear { cloud.reload() }
    }

    private func profileCard(_ p: CloudProfile) -> some View {
        Card(title: p.name, subtitle: "\(p.provider.title) · \(p.bucket)\(p.prefix.isEmpty ? "" : "/" + p.prefix)") {
            HStack(spacing: 10) {
                if cloud.importing == p.id {
                    ProgressView(value: Double(cloud.progress.done), total: Double(max(1, cloud.progress.total))).frame(width: 180)
                    Text("\(cloud.progress.done) of \(cloud.progress.total)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    PillButton(title: "Stop", symbol: "stop.fill") { cloud.cancelImport() }
                } else {
                    PillButton(title: "Add to library", symbol: "arrow.down.doc", filled: true) { cloud.importLibrary(p) }.disabled(cloud.importing != nil)
                    PillButton(title: "Edit", symbol: "pencil") { cloud.edit(p) }.disabled(cloud.importing != nil)
                    PillButton(title: "Remove", symbol: "trash") { cloud.remove(p) }.disabled(cloud.importing != nil)
                }
            }
            Note(text: "Run “Add to library” again whenever you upload music: only new or changed files are read, and files you deleted from the bucket leave the library.")
        }
    }

    private func editor(_ d: CloudProfile) -> some View {
        let bind = Binding<CloudProfile>(get: { cloud.draft ?? d }, set: { cloud.draft = $0 })
        return Card(title: "Storage", subtitle: nil) {
            HStack { Text("Name").frame(width: 110, alignment: .leading); TextField("My B2 music", text: bind.name).textFieldStyle(.roundedBorder) }
            HStack {
                Text("Service").frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(get: { bind.wrappedValue.provider }, set: { bind.wrappedValue.provider = $0; cloud.providerChanged() })) { ForEach(CloudProvider.allCases) { Text($0.title).tag($0) } }.labelsHidden()
            }
            if d.provider == .r2 { HStack { Text("Account ID").frame(width: 110, alignment: .leading); TextField("32-character account id", text: $cloud.accountID, onCommit: { cloud.providerChanged() }).textFieldStyle(.roundedBorder) } }
            HStack {
                Text("Region").frame(width: 110, alignment: .leading)
                TextField(d.provider.regionHint, text: Binding(get: { bind.wrappedValue.region }, set: { bind.wrappedValue.region = $0; if bind.wrappedValue.provider != .custom { cloud.providerChanged() } })).textFieldStyle(.roundedBorder)
            }
            HStack { Text("Endpoint").frame(width: 110, alignment: .leading); TextField("https://s3.us-west-004.backblazeb2.com", text: bind.endpoint).textFieldStyle(.roundedBorder).disabled(d.provider != .custom) }
            HStack { Text("Bucket").frame(width: 110, alignment: .leading); TextField("bucket name", text: bind.bucket).textFieldStyle(.roundedBorder) }
            HStack { Text("Folder").frame(width: 110, alignment: .leading); TextField("optional: only this folder, e.g. Music/", text: bind.prefix).textFieldStyle(.roundedBorder) }
            HStack { Text("Access key").frame(width: 110, alignment: .leading); TextField(d.provider == .backblaze ? "keyID" : "access key id", text: bind.accessKey).textFieldStyle(.roundedBorder) }
            HStack { Text("Secret key").frame(width: 110, alignment: .leading); SecureField(d.provider == .backblaze ? "applicationKey" : "secret access key", text: $cloud.draftSecret).textFieldStyle(.roundedBorder) }
            Note(text: "A read-only key is enough and safest: Aureon only lists and reads files. In Backblaze, create an Application Key limited to this bucket with “Read Only”. The secret is stored in the macOS Keychain.")
            if let p = cloud.draftProblem { Note(text: p, color: .orange) }
            HStack(spacing: 10) {
                PillButton(title: "Save", symbol: "checkmark", filled: true) { cloud.saveDraft() }.disabled(cloud.draftProblem != nil)
                PillButton(title: "Test connection", symbol: "bolt.horizontal") { cloud.test() }.disabled(cloud.draftProblem != nil || cloud.testing)
                PillButton(title: "Cancel", symbol: "xmark") { cloud.cancelEdit() }
                if cloud.testing { ProgressView().controlSize(.small) }
            }
            if let t = cloud.testResult { Note(text: t, color: cloud.testOK ? .green : .red) }
        }
    }

    private func serverCard(_ p: SubsonicProfile) -> some View {
        Card(title: p.name, subtitle: "Music server · \(p.url)") {
            HStack(spacing: 10) {
                if cloud.importing == p.id {
                    ProgressView(value: Double(cloud.progress.done), total: Double(max(1, cloud.progress.total))).frame(width: 180)
                    Text("\(cloud.progress.done) of \(cloud.progress.total) albums").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    PillButton(title: "Stop", symbol: "stop.fill") { cloud.cancelImport() }
                } else {
                    PillButton(title: "Add to library", symbol: "arrow.down.doc", filled: true) { cloud.importServer(p) }.disabled(cloud.importing != nil)
                    PillButton(title: "Edit", symbol: "pencil") { cloud.editServer(p) }.disabled(cloud.importing != nil)
                    PillButton(title: "Remove", symbol: "trash") { cloud.removeServer(p) }.disabled(cloud.importing != nil)
                }
            }
            Note(text: "Tracks stream from your server as you play them, the original file untouched, through the same engine as local music.")
        }
    }

    private func serverEditor(_ d: SubsonicProfile) -> some View {
        let bind = Binding<SubsonicProfile>(get: { cloud.serverDraft ?? d }, set: { cloud.serverDraft = $0 })
        return Card(title: "Music server", subtitle: "Navidrome, Gonic, Airsonic, Subsonic and anything that speaks the Subsonic API") {
            HStack { Text("Name").frame(width: 110, alignment: .leading); TextField("Home server", text: bind.name).textFieldStyle(.roundedBorder) }
            HStack { Text("Address").frame(width: 110, alignment: .leading); TextField("https://music.example.com", text: bind.url).textFieldStyle(.roundedBorder) }
            HStack { Text("User name").frame(width: 110, alignment: .leading); TextField("user", text: bind.username).textFieldStyle(.roundedBorder) }
            HStack { Text("Password").frame(width: 110, alignment: .leading); SecureField("password", text: $cloud.serverPassword).textFieldStyle(.roundedBorder) }
            Note(text: "The password is stored in the macOS Keychain and never sent: the server gets a one-time token made from it. Use https:// when the server is outside your home network.")
            if let p = cloud.serverProblem { Note(text: p, color: .orange) }
            HStack(spacing: 10) {
                PillButton(title: "Save", symbol: "checkmark", filled: true) { cloud.saveServer() }.disabled(cloud.serverProblem != nil)
                PillButton(title: "Test connection", symbol: "bolt.horizontal") { cloud.testServer() }.disabled(cloud.serverProblem != nil || cloud.testing)
                PillButton(title: "Cancel", symbol: "xmark") { cloud.cancelServerEdit() }
                if cloud.testing { ProgressView().controlSize(.small) }
            }
            if let t = cloud.testResult { Note(text: t, color: cloud.testOK ? .green : .red) }
        }
    }
}
