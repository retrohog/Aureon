import SwiftUI

@MainActor
final class BridgeModel: ObservableObject {
    @Published var sharing: Bool { didSet { if sharing != oldValue { UserDefaults.standard.set(sharing, forKey: "aureon.bridge.on"); apply() } } }
    @Published private(set) var token: String?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var message: String?
    @Published private(set) var port: UInt16 = 0

    let registry = BridgeRegistry()
    weak var library: LibraryModel? { didSet { if sharing { apply() } } }
    private var server: BridgeServer?
    private var pairingTimer: Timer?

    init() { sharing = UserDefaults.standard.bool(forKey: "aureon.bridge.on"); devices = registry.devices }

    private func apply() {
        if sharing {
            guard server == nil, let store = library?.store else { return }
            let s = BridgeServer(source: StoreBridgeSource(store: store), registry: registry)
            s.onPaired = { [weak self] d in Task { @MainActor in self?.devices = self?.registry.devices ?? []; self?.token = nil; self?.message = "\(d.name) is paired." } }
            do { port = try s.start(); server = s; message = nil }
            catch { sharing = false; message = "Could not start sharing: \(error.localizedDescription)" }
        } else {
            server?.stop(); server = nil; token = nil; port = 0
        }
    }

    func startPairing() {
        guard let s = server else { return }
        do {
            let t = try s.beginPairing()
            token = t.token; message = nil
            pairingTimer?.invalidate()
            pairingTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in Task { @MainActor in self?.cancelPairing() } }
        } catch { message = error.localizedDescription }
    }

    func cancelPairing() { server?.endPairing(); token = nil; pairingTimer?.invalidate() }

    func remove(_ d: PairedDevice) { registry.revoke(d.id); devices = registry.devices }
    func resetAll() { registry.rotateKey(); devices = []; if sharing { server?.stop(); server = nil; apply() } }
}

struct BridgeCard: View {
    @EnvironmentObject var bridge: BridgeModel

    var body: some View {
        Card(title: "Phone and tablet sync", subtitle: "Send your library and files to the Aureon companion app over your own Wi-Fi") {
            Toggle("Share this library on the local network", isOn: $bridge.sharing)
            if bridge.sharing {
                if let t = bridge.token {
                    Text(t).font(.system(size: 22, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Note(text: "Enter this code in the companion app within two minutes. It works once.")
                    PillButton(title: "Cancel", symbol: "xmark") { bridge.cancelPairing() }
                } else {
                    PillButton(title: "Pair a device…", symbol: "iphone.badge.plus", filled: true) { bridge.startPairing() }
                }
                ForEach(bridge.devices) { d in
                    HStack { Image(systemName: "iphone"); Text(d.name); Spacer(); PillButton(title: "Remove", symbol: "trash") { bridge.remove(d) } }
                }
            }
            if let m = bridge.message { Note(text: m, color: .orange) }
            Note(text: "Everything stays on your network: the link is encrypted with a key only paired devices have, nothing goes through a server, and tracks that live in the cloud or on a music server are not offered. Sharing runs at low priority and never touches the audio engine.")
        }
    }
}
