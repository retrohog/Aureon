import SwiftUI
import AppKit

extension LibraryModel {
    /// Looks for songs and albums that exist twice. `prompt` shows the banner when something is found (after an import); otherwise opens the review directly.
    func scanDuplicates(prompt: Bool) {
        guard let store, !scanningDuplicates else { return }
        scanningDuplicates = true
        let ignored = ignoredDuplicates
        Task.detached(priority: .utility) {
            var all: [TrackDTO] = [], offset = 0
            while true { let page = store.allTracks(offset: offset, limit: 2000); all += page; if page.count < 2000 { break }; offset += 2000 }
            let groups = DuplicateFinder.all(all, ignoring: ignored)
            await MainActor.run {
                self.scanningDuplicates = false
                self.duplicateGroups = groups
                if prompt { self.duplicateBanner = !groups.isEmpty } else { self.showDuplicates = true }
            }
        }
    }

    func ignoreDuplicates(_ groups: [DuplicateGroup]) {
        ignoredDuplicates.formUnion(groups.map(\.id))
        UserDefaults.standard.set(Array(ignoredDuplicates), forKey: "aureon.ignoredDuplicates")
        duplicateGroups.removeAll { g in groups.contains { $0.id == g.id } }
        if duplicateGroups.isEmpty { duplicateBanner = false }
    }

    /// The files that go away when each group keeps the copy at `keep[group.id]` (the recommended one when absent).
    func removalPlan(_ groups: [DuplicateGroup], keep: [String: Int], skipped: Set<String>) -> [(path: String, group: DuplicateGroup, kept: DuplicateItem)] {
        var out: [(String, DuplicateGroup, DuplicateItem)] = []
        for g in groups where !skipped.contains(g.id) {
            let k = min(max(keep[g.id] ?? 0, 0), g.items.count - 1)
            switch g.kind {
            case .song: for (i, it) in g.items.enumerated() where i != k { out.append((it.track.path, g, g.items[k])) }
            case .album: for (i, copy) in g.albumCopies.enumerated() where i != k { for t in copy { out.append((t.path, g, g.items[k])) } }
            }
        }
        return out
    }

    /// Moves the files to the Trash and removes them from the library. Returns (removed, failed).
    @discardableResult
    func trashDuplicates(paths: [String]) -> (removed: Int, failed: Int) {
        var done: [String] = [], failed = 0
        for p in paths {
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil); done.append(p) }
            catch { if !FileManager.default.fileExists(atPath: p) { done.append(p) } else { failed += 1 } }
        }
        store?.removeTracks(paths: done)
        let gone = Set(done)
        duplicateGroups = duplicateGroups.compactMap { g in
            switch g.kind {
            case .song: return g.items.contains { gone.contains($0.track.path) } ? nil : g
            case .album: return g.albumCopies.contains { $0.contains { gone.contains($0.path) } } ? nil : g
            }
        }
        if duplicateGroups.isEmpty { duplicateBanner = false }
        refresh()
        return (done.count, failed)
    }
}

/// Shown at the top of the library after an import finds likely duplicates.
struct DuplicateBanner: View {
    @ObservedObject var lib: LibraryModel
    var body: some View {
        if lib.duplicateBanner && !lib.duplicateGroups.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square.dashed").font(.system(size: 18)).foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(lib.duplicateGroups.count) possible duplicate\(lib.duplicateGroups.count == 1 ? "" : "s") found").font(.system(size: 13, weight: .semibold))
                    Text("Same songs or albums in more than one copy. Review them and keep the best quality — nothing is removed without your say-so.").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                PillButton(title: "Review", symbol: "checklist", filled: true) { lib.showDuplicates = true }
                Button { withAnimation { lib.duplicateBanner = false } } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Not now")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.accent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.accent.opacity(0.4), lineWidth: 0.8))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The review: every group with the recommended copy marked, a choice of which to keep, and a clear list of what would be deleted and why.
struct DuplicateReviewSheet: View {
    @ObservedObject var lib: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var keep = Box([String: Int]())
    @StateObject private var skipped = Box(Set<String>())
    @StateObject private var message = Box<String?>(nil)

    var body: some View {
        let groups = lib.duplicateGroups
        let plan = lib.removalPlan(groups, keep: keep.v, skipped: skipped.v)
        let bytes = plan.reduce(Int64(0)) { sum, e in sum + (fileSize(e.path)) }
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duplicates").font(.system(size: 20, weight: .semibold))
                    Text(groups.isEmpty ? "Nothing to review" : "\(groups.count) group\(groups.count == 1 ? "" : "s") · \(plan.count) file\(plan.count == 1 ? "" : "s") to remove · frees \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            if groups.isEmpty {
                EmptyExplainer(icon: "checkmark.seal", title: "No duplicates", text: message.v ?? "Every song and album in your library exists once. Aureon checks again whenever you add music.")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(groups) { g in groupCard(g) }
                    }.padding(20)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let m = message.v, !groups.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Ignore these") { lib.ignoreDuplicates(groups); dismiss() }.disabled(groups.isEmpty).help("Never suggest these again")
                Button("Close") { dismiss() }
                Button { confirm(plan, bytes) } label: { Text("Move \(plan.count) file\(plan.count == 1 ? "" : "s") to Trash…") }
                    .buttonStyle(.borderedProminent).tint(Brand.accent).disabled(plan.isEmpty)
            }.padding(14)
        }
        .frame(width: 760, height: 580)
    }

    private func fileSize(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0 }

    private func groupCard(_ g: DuplicateGroup) -> some View {
        let k = min(keep.v[g.id] ?? 0, g.items.count - 1)
        let off = skipped.v.contains(g.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: g.kind == .album ? "square.stack" : "music.note").foregroundStyle(Brand.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(g.artist + " · " + g.reason).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Resolve", isOn: Binding(get: { !off }, set: { on in if on { skipped.v.remove(g.id) } else { skipped.v.insert(g.id) } })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .help(off ? "This group is left alone" : "This group will be resolved")
            }
            ForEach(Array(g.items.enumerated()), id: \.element.id) { i, it in
                let isKeep = i == k
                HStack(spacing: 10) {
                    Text(isKeep ? "KEEP" : "REMOVE").font(.system(size: 9.5, weight: .heavy, design: .monospaced)).tracking(0.8)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill((isKeep ? Color.green : Color.red).opacity(off ? 0.08 : 0.2))).foregroundStyle(isKeep ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.summary).font(.system(size: 12, weight: .medium))
                        Text(shorten(it.track.path)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if isKeep && i == 0 { Text(g.keepReason).font(.system(size: 11)).foregroundStyle(.green.opacity(0.9)).lineLimit(1) }
                    if !isKeep { Button("Keep this one instead") { keep.v[g.id] = i }.buttonStyle(.link).font(.system(size: 11)) }
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.track.path)]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).help("Show in Finder")
                }
                .opacity(off ? 0.45 : 1)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Brand.ink.opacity(0.05)))
    }

    private func shorten(_ p: String) -> String { p.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func confirm(_ plan: [(path: String, group: DuplicateGroup, kept: DuplicateItem)], _ bytes: Int64) {
        let a = NSAlert()
        a.messageText = "Move \(plan.count) file\(plan.count == 1 ? "" : "s") to the Trash?"
        var lines = plan.prefix(8).map { "• " + ($0.path as NSString).lastPathComponent + " — kept: " + $0.kept.summary.components(separatedBy: " · ")[0] + " (" + $0.group.keepReason.lowercased() + ")" }
        if plan.count > 8 { lines.append("… and \(plan.count - 8) more") }
        a.informativeText = lines.joined(separator: "\n") + "\n\nThis frees about \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)). The files go to the Trash, so you can still put them back."
        a.addButton(withTitle: "Move to Trash"); a.addButton(withTitle: "Cancel")
        a.buttons[0].hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = lib.trashDuplicates(paths: plan.map(\.path))
        message.v = r.failed == 0 ? "Moved \(r.removed) file\(r.removed == 1 ? "" : "s") to the Trash." : "Moved \(r.removed); \(r.failed) could not be moved."
        keep.v = [:]; skipped.v = []
    }
}
