import SwiftUI
import AppKit

/// The Intelligence page: the master switch, what this Mac can do, every smart feature's switch, local models and the API provider.
struct IntelligenceTab: View {
    @ObservedObject var ai: IntelligenceCenter = .shared

    var body: some View {
        VStack(spacing: 16) {
            MasterSwitchCard(ai: ai)
            FeatureTogglesCard(ai: ai)
            LocalModelsCard(ai: ai)
            APIProviderCard(ai: ai)
        }
        .sheet(isPresented: Binding(get: { ai.showIntelWarning }, set: { if !$0 { ai.declineIntelWarning() } })) {
            IntelWarningSheet(ai: ai)
        }
    }
}

// MARK: - Master switch and hardware

struct HardwareBadge: View {
    let hardware: HostHardware
    var body: some View {
        let tone: Color = hardware.isAppleSilicon && !hardware.isTranslated ? .green : .orange
        HStack(spacing: 12) {
            Image(systemName: hardware.isAppleSilicon ? "cpu.fill" : "cpu").font(Typo.serif(18, .regular)).foregroundStyle(tone)
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: Metrics.radius(9), style: .continuous).fill(tone.opacity(0.16)))
            VStack(alignment: .leading, spacing: 2) {
                Text(hardware.badgeTitle).font(Typo.sans(13.5, .semibold))
                Text(hardware.badgeDetail).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.radius(11), style: .continuous).fill(tone.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius(11), style: .continuous).strokeBorder(tone.opacity(0.28), lineWidth: 0.8))
        .accessibilityElement(children: .combine)
    }
}

struct MasterSwitchCard: View {
    @ObservedObject var ai: IntelligenceCenter

    var body: some View {
        let hw = ai.hardware
        Card(title: "Intelligence", subtitle: "One switch for every smart feature in Aureon. Off: no model runs, nothing is held in memory for them, and each feature uses its classic path") {
            HardwareBadge(hardware: hw)
            Toggle(isOn: Binding(get: { ai.isMasterOn }, set: { ai.setMaster($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable Intelligence Features").font(Typo.sans(14, .semibold))
                    Text(ai.isMasterOn ? ai.memoryNote : "All Smart features are off.").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
                }
            }
            .toggleStyle(.rule)
            if hw.isIntel {
                Note(text: ai.settings.intelRiskAccepted
                     ? "Software mode: this Intel Mac has no Neural Engine, so models run on the CPU next to the audio engine. Expect higher CPU load; if playback stutters, switch features off."
                     : "Off by default on Intel Macs. Switching it on asks you to confirm, because models running on the CPU can cause audio dropouts.",
                     color: Brand.caution)
                if ai.settings.intelRiskAccepted {
                    Button("Turn off and show the warning again") { ai.revokeIntelAcceptance() }.buttonStyle(.link).font(Typo.sans(12))
                }
            } else if hw.isTranslated {
                Note(text: "Aureon is running under Rosetta. On-device language models need the native Apple Silicon build; API models and on-device search still work.", color: Brand.caution)
            }
        }
    }
}

struct IntelWarningSheet: View {
    @ObservedObject var ai: IntelligenceCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(Typo.sans(28)).foregroundStyle(Brand.caution)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Turn on smart features on this Intel Mac?").font(Typo.serif(17, .regular))
                    Text(ai.hardware.cpuBrand).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
                }
            }
            Text("Intel Macs have no Neural Engine, so every model runs on the CPU, right next to the audio engine. Aureon keeps model work off the audio thread, but it cannot make the CPU faster.")
                .font(Typo.sans(13)).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                risk("flame", "High CPU load and heat", "Fans may spin up while a model is working, and the rest of the Mac can feel slow.")
                risk("waveform.path.badge.minus", "Audio dropouts and stutter", "If the CPU is saturated, playback can miss its deadline. The Real-Time Audio Enhancer drops back to the classic resampler when it cannot keep up, but other playback can still be affected.")
                risk("xmark.octagon", "Freezes or crashes", "Under memory pressure Aureon may become unresponsive or quit, especially with local models.")
                risk("cpu", "Local language models need Apple Silicon", "On this Mac, Smart DJ can use an API model (OpenAI, DeepSeek or your own server) instead.")
            }
            Text("You can switch everything off again at any time on this page.").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary)
            HStack {
                Spacer()
                Button("Keep Off") { ai.declineIntelWarning() }.keyboardShortcut(.cancelAction)
                Button("Turn On Anyway", role: .destructive) { ai.acceptIntelWarning() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24).frame(width: 500)
    }

    private func risk(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(Typo.sans(14, .semibold)).foregroundStyle(Brand.caution).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.sans(13, .semibold))
                Text(detail).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Features

struct FeatureTogglesCard: View {
    @ObservedObject var ai: IntelligenceCenter

    var body: some View {
        Card(title: "Features", subtitle: "Each one can be switched on or off on its own. Text features can run on this Mac or through your API provider; audio never leaves this Mac") {
            ForEach(Array(IntelligenceFeature.allCases.enumerated()), id: \.element) { i, f in
                if i > 0 { Divider() }
                FeatureRow(ai: ai, search: ai.search, feature: f)
            }
        }
        .opacity(ai.isMasterOn ? 1 : 0.55)
    }
}

struct FeatureRow: View {
    @ObservedObject var ai: IntelligenceCenter
    @ObservedObject var search: SemanticSearchService
    let feature: IntelligenceFeature

    var body: some View {
        let hw = ai.hardware
        let blocker = feature == .audioEnhancer ? hw.audioEnhancerBlocker : nil
        let localBlocked = (feature == .smartDJ || feature == .naturalPlaylists) && hw.localLanguageModelBlocker != nil
        let on = ai.settings.isSwitchedOn(feature) && blocker == nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: feature.icon).font(Typo.sans(14, .semibold)).foregroundStyle(Brand.accent).frame(width: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(feature.title).font(Typo.sans(13.5, .semibold))
                        if !feature.allowsAPI, feature == .audioEnhancer || feature == .lyricsGeneration { Badge(text: "LOCAL ONLY", color: Brand.accentText) }
                        if ai.isActive(feature) { Badge(text: "ACTIVE", color: Brand.accent) }
                    }
                    Text(feature.summary).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { on }, set: { ai.setFeature(feature, $0) })).toggleStyle(.rule).labelsHidden().disabled(!ai.isMasterOn || blocker != nil)
                    .accessibilityLabel(feature.title)
            }
            if feature.allowsAPI, on {
                HStack(spacing: 12) {
                    Text("Runs").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).frame(width: 22 + 10, alignment: .trailing)
                    SegmentedChoice(selection: Binding(get: { ai.settings.engine(for: feature) }, set: { ai.setEngine(feature, $0) }),
                                    items: IntelligenceEngine.allCases, label: { $0 == .api ? "API · \(ai.settings.api.provider.shortTitle)" : $0.title }, singleLine: true,
                                    isDisabled: { localBlocked && $0 == .onDevice })
                        .frame(maxWidth: 320).disabled(!ai.isMasterOn)
                    Spacer(minLength: 0)
                }
            }
            if let blocker { unavailableNote(blocker) }
            else if localBlocked, on, let reason = hw.localLanguageModelBlocker { unavailableNote("“On this Mac” is unavailable. \(reason)") }
            if blocker == nil, let s = status { Text(s.text).font(Typo.sans(11.5)).foregroundStyle(s.warn ? Brand.caution : Brand.inkSecondary).padding(.leading, 32).fixedSize(horizontal: false, vertical: true) }
            if feature == .audioEnhancer, ai.isActive(.audioEnhancer) { EnhancerStatusLine().padding(.leading, 32) }
            if feature == .lyricsGeneration, on {
                HStack(spacing: 12) {
                    Text("Model").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).frame(width: 22 + 10, alignment: .trailing)
                    SegmentedChoice(selection: Binding(get: { ai.settings.whisperModel }, set: { ai.setWhisperModel($0) }),
                                    items: WhisperModelSize.allCases, label: { "\($0.title) · \($0.approxMB) MB" }, singleLine: true)
                        .frame(maxWidth: 360).disabled(!ai.isMasterOn)
                    Spacer(minLength: 0)
                }
                Text(ai.settings.whisperModel.detail).font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary).padding(.leading, 32)
            }
        }
    }

    private func unavailableNote(_ reason: String) -> some View {
        Text("\(HostHardware.appleSiliconOnlyNote). \(reason)").font(Typo.sans(11.5)).foregroundStyle(Brand.caution).padding(.leading, 32).fixedSize(horizontal: false, vertical: true)
    }

    private var status: (text: String, warn: Bool)? {
        guard ai.isMasterOn, ai.settings.isSwitchedOn(feature) else { return nil }
        let hw = ai.hardware
        switch feature {
        case .smartDJ:
            if ai.settings.smartDJEngine == .api { return ai.hasKey(ai.settings.api.provider) || OpenAICompatibleClient.isLocalHost(ai.settings.api.baseURL) ? nil : ("Add an API key below to use \(ai.settings.api.provider.title).", true) }
            if !hw.canRunMLX { return ("On-device language models need native Apple Silicon. Choose API, or Smart DJ answers by ranking alone.", true) }
            return ("Model: " + (ai.settings.languageModel.map { "\($0.name), \(LocalModelInspector.formatParameters($0.parameters)) parameters" } ?? "Qwen2.5 0.5B Instruct, 4-bit (built in)"), false)
        case .semanticSearch:
            switch search.state {
            case .idle: return ("The index is built the first time you search.", false)
            case .indexing(let d, let t): return (t > 0 ? "Indexing your library: \(d) of \(t) songs" : "Preparing the index…", false)
            case .ready(let n): return ("\(n) songs indexed (\(formatBytes(search.indexBytes)) in memory).", false)
            case .failed(let m): return (m, true)
            }
        case .audioEnhancer:
            if ai.settings.enhancerModel == nil { return ("Choose a CoreML model under Local models. Until then lossy sources use the classic resampler.", true) }
            return hw.isIntel ? ("Runs on the CPU on this Mac (no Neural Engine).", true) : ("Runs on the Neural Engine and GPU.", false)
        case .naturalPlaylists:
            if ai.settings.playlistEngine == .api { return ai.hasKey(ai.settings.api.provider) || OpenAICompatibleClient.isLocalHost(ai.settings.api.baseURL) ? nil : ("Add an API key below to use \(ai.settings.api.provider.title).", true) }
            if !hw.canRunMLX { return ("On-device language models need native Apple Silicon. Choose API, or playlists are built by ranking alone.", true) }
            return ("Find it under Playlists → Describe a Playlist. The model is loaded when you ask and unloaded after a couple of idle minutes.", false)
        case .lyricsGeneration:
            if WhisperHelperLocator.find() == nil { return ("The speech-model helper is not part of this build. Lyrics from files and the internet still work.", true) }
            return ("Offered on the Now Playing page when a song has no lyrics. The \(ai.settings.whisperModel.title) model (about \(ai.settings.whisperModel.approxMB) MB) is downloaded once, then runs on this Mac only.", false)
        case .smartShuffle, .remixer:
            return nil
        }
    }
}

// MARK: - Local models

struct LocalModelsCard: View {
    @ObservedObject var ai: IntelligenceCenter
    @StateObject private var lastCheck = Box<CheckResult?>(nil)
    @StateObject private var busy = Box(false)

    struct CheckResult: Equatable { var role: String; var info: LocalModelInfo?; var verdict: LocalModelVerdict }

    var body: some View {
        Card(title: "Local models", subtitle: "Models that run on this Mac. Limit: \(LocalModelInspector.formatParameters(LocalModelCap.maxParameters)) parameters and \(formatBytes64(LocalModelCap.maxBytes)) of weights, so the audio engine always keeps the memory it needs") {
            modelRow(title: "Smart DJ language model", icon: "text.bubble",
                     current: ai.settings.languageModel.map { "\($0.name) · \($0.format.title) · \(LocalModelInspector.formatParameters($0.parameters)) parameters · \(formatBytes64($0.bytes))" }
                        ?? "Qwen2.5 0.5B Instruct, 4-bit MLX (built in, downloaded on first use)",
                     chooseTitle: "Load Model…", role: .languageModel, blocker: ai.hardware.localLanguageModelBlocker, reset: ai.settings.languageModel == nil ? nil : "Use Built-in")
            Divider()
            modelRow(title: "Audio enhancer model", icon: "waveform.badge.plus",
                     current: ai.settings.enhancerModel.map { "\($0.name) · \($0.format.title) · \(LocalModelInspector.formatParameters($0.parameters)) parameters\($0.parametersEstimated ? " (est.)" : "") · \(formatBytes64($0.bytes))" }
                        ?? "None chosen",
                     chooseTitle: "Choose CoreML Model…", role: .audioEnhancer, blocker: ai.hardware.audioEnhancerBlocker, reset: ai.settings.enhancerModel == nil ? nil : "Remove")
            if busy.v { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the model…").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary) } }
            if let r = lastCheck.v { checkView(r) }
            Note(text: "Language models: an MLX folder (config.json, tokenizer and .safetensors), for example from mlx-community on Hugging Face; GGUF files are checked but cannot run here. Audio enhancer: a CoreML .mlpackage or .mlmodelc. The parameter count is read from the model's own headers before anything is loaded.")
        }
        .opacity(ai.isMasterOn ? 1 : 0.55)
    }

    private func modelRow(title: String, icon: String, current: String, chooseTitle: String, role: LocalModelRole, blocker: String?, reset: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(Typo.sans(14, .semibold)).foregroundStyle(Brand.accent).frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typo.sans(13.5, .semibold))
                Text(current).font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary).fixedSize(horizontal: false, vertical: true)
                if let blocker { Text("\(HostHardware.appleSiliconOnlyNote). \(blocker)").font(Typo.sans(11.5)).foregroundStyle(Brand.caution).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            if let reset { Button(reset) { ai.useModel(nil, for: role); lastCheck.v = nil }.controlSize(.small) }
            Button(chooseTitle) { choose(role) }.controlSize(.small).disabled(busy.v || blocker != nil)
        }
    }

    private func checkView(_ r: CheckResult) -> some View {
        let ok = r.verdict.isAccepted
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill").foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                if let i = r.info {
                    Text("\(i.name): \(i.parameterText) parameters, \(formatBytes64(i.bytes))" + (i.architecture.map { ", \($0)" } ?? "") + (i.quantizationBits.map { ", \($0)-bit" } ?? ""))
                        .font(Typo.sans(12, .semibold))
                }
                Text(ok ? "Loaded as the \(r.role)." : (r.verdict.reason ?? "")).font(Typo.sans(12)).foregroundStyle(ok ? Brand.inkSecondary : Color.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Metrics.radius(9), style: .continuous).fill((ok ? Brand.accentText : Color.red).opacity(0.08)))
    }

    private func choose(_ role: LocalModelRole) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = role == .languageModel ? "Choose an MLX model folder (or a .gguf file to check it)" : "Choose a CoreML model (.mlpackage or .mlmodelc)"
        panel.prompt = "Check Model"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy.v = true; lastCheck.v = nil
        let hw = ai.hardware
        let roleName = role == .languageModel ? "Smart DJ language model" : "audio enhancer model"
        Task {
            // reading headers is quick, but a model on a network drive is not: keep it off the main thread
            let result: (LocalModelInfo?, LocalModelVerdict) = await Task.detached(priority: .userInitiated) {
                do { let i = try LocalModelInspector.inspect(url); return (i, LocalModelInspector.verdict(i, role: role, hardware: hw)) }
                catch { return (nil, .rejected(error.localizedDescription)) }
            }.value
            busy.v = false
            var verdict = result.1
            if let info = result.0, verdict.isAccepted { verdict = ai.useModel(info, for: role) }
            lastCheck.v = CheckResult(role: roleName, info: result.0, verdict: verdict)
        }
    }
}

// MARK: - API provider

struct APIProviderCard: View {
    @ObservedObject var ai: IntelligenceCenter
    @StateObject private var baseURL = Box("")
    @StateObject private var model = Box("")
    @StateObject private var embedding = Box("")
    @StateObject private var key = Box("")
    @StateObject private var loadedFor = Box<AIProvider?>(nil)
    @FocusState private var focus: Field?

    enum Field: Hashable { case url, model, embedding, key }

    var body: some View {
        let api = ai.settings.api
        Card(title: "API provider", subtitle: "Bring your own key for Smart DJ and Semantic Search. Only text is sent: your request and short song descriptions (title, artist, genre, tempo). Audio never leaves this Mac") {
            SegmentedChoice(selection: Binding(get: { api.provider }, set: { ai.setProvider($0); loadDrafts(force: true) }), items: AIProvider.allCases, label: { $0.shortTitle }, singleLine: true)
            field("Endpoint", text: $baseURL.v, prompt: api.provider.defaultBaseURL, which: .url)
            field("Model", text: $model.v, prompt: api.provider.defaultModel.isEmpty ? "model name" : api.provider.defaultModel, which: .model)
            field("Embeddings", text: $embedding.v, prompt: api.provider == .deepSeek ? "not offered by DeepSeek" : "text-embedding-3-small", which: .embedding)
            HStack(spacing: 12) {
                Text("API key").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).frame(width: 84, alignment: .trailing)
                SecureField(ai.hasKey(api.provider) ? "•••••••• saved in the Keychain" : "Paste your \(api.provider.title) key", text: $key.v)
                    .textFieldStyle(.plain).ruleField().focused($focus, equals: .key).onSubmit(saveKey)
                Button("Save") { saveKey() }.disabled(key.v.trimmingCharacters(in: .whitespaces).isEmpty)
                if ai.hasKey(api.provider) { Button("Remove") { ai.removeKey(for: api.provider) } }
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: 84, height: 1)
                Button { commitAll(); Task { await ai.testConnection() } } label: { Label("Test Connection", systemImage: "bolt.horizontal") }
                    .disabled(ai.connection == .checking)
                connectionView
                Spacer(minLength: 0)
            }
            Note(text: "Keys are stored in the macOS Keychain, never in Aureon's settings files. Plain http:// is accepted only for a server on this Mac (LM Studio, Ollama and similar); anything else needs https://.")
        }
        .opacity(ai.isMasterOn ? 1 : 0.55)
        .onAppear { loadDrafts(force: true) }
        .onChange(of: focus) { old, _ in commit(old) }
        .onDisappear { commitAll() }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, which: Field) -> some View {
        HStack(spacing: 12) {
            Text(label).font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary).frame(width: 84, alignment: .trailing)
            TextField(prompt, text: text).textFieldStyle(.plain).ruleField().focused($focus, equals: which).onSubmit { commit(which) }
        }
    }

    @ViewBuilder private var connectionView: some View {
        switch ai.connection {
        case .idle: EmptyView()
        case .checking: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(Typo.sans(12)).foregroundStyle(Brand.inkSecondary) }
        case .ok(let m): Label(m, systemImage: "checkmark.circle.fill").font(Typo.sans(12)).foregroundStyle(Brand.accentText).lineLimit(2)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(Typo.sans(12)).foregroundStyle(Brand.caution).lineLimit(3)
        }
    }

    private func loadDrafts(force: Bool) {
        let api = ai.settings.api
        guard force || loadedFor.v != api.provider else { return }
        baseURL.v = api.baseURL; model.v = api.model; embedding.v = api.embeddingModel; key.v = ""
        loadedFor.v = api.provider
    }

    private func commit(_ f: Field?) {
        switch f {
        case .url: if baseURL.v != ai.settings.api.baseURL { ai.setAPI(baseURL: baseURL.v) }
        case .model: if model.v != ai.settings.api.model { ai.setAPI(model: model.v) }
        case .embedding: if embedding.v != ai.settings.api.embeddingModel { ai.setAPI(embeddingModel: embedding.v) }
        case .key, nil: break
        }
    }

    private func commitAll() { commit(.url); commit(.model); commit(.embedding) }

    private func saveKey() {
        let k = key.v.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        ai.saveKey(k, for: ai.settings.api.provider)
        key.v = ""
    }
}

// MARK: - Search page

/// "Matches by meaning" on the Search page, shown while Semantic Search is allowed.
struct SemanticMatchesSection: View {
    @EnvironmentObject var m: PlayerModel
    @ObservedObject var ai: IntelligenceCenter = .shared
    @ObservedObject var search: SemanticSearchService = IntelligenceCenter.shared.search
    /// Songs already listed by the ordinary search, left out here.
    var exclude: Set<String> = []

    var body: some View {
        let query = m.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        Group {
            if ai.isActive(.semanticSearch), query.count >= 3 {
                let tracks = search.lastQuery == query ? search.results.filter { !exclude.contains($0.path) } : []
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass").foregroundStyle(Brand.accent)
                        Text("Matches by meaning").font(Typo.serif(17, .regular))
                        stateView
                        Spacer(minLength: 0)
                    }
                    if !tracks.isEmpty { SongList(tracks: tracks) }
                    else if case .ready = search.state, search.lastQuery == query { Text("Nothing else fits that description.").font(Typo.sans(12.5)).foregroundStyle(Brand.inkSecondary) }
                }
                .task(id: query) {
                    try? await Task.sleep(nanoseconds: 350_000_000)                // wait for typing to pause
                    guard !Task.isCancelled else { return }
                    await search.search(query)
                }
            }
        }
    }

    @ViewBuilder private var stateView: some View {
        switch search.state {
        case .indexing(let d, let t): HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t > 0 ? "indexing \(d) / \(t)" : "preparing").font(Typo.sans(11.5)).foregroundStyle(Brand.inkSecondary) }
        case .failed(let msg): Text(msg).font(Typo.sans(11.5)).foregroundStyle(Brand.caution).lineLimit(2)
        default: EmptyView()
        }
    }
}
