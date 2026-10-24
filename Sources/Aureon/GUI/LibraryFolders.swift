import SwiftUI
import AppKit

// The folders a library is built from, and the way to take one out: a toolbar button on the Library pages (a popover with a minus button per folder)
// and the same list on the empty Library page. Removing a folder removes its songs from the library; the files on disk are never touched.

/// Asks before a library folder is taken out. Returns whether the person confirmed.
@MainActor
func confirmRemoveLibraryFolder(_ path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    let a = NSAlert()
    a.messageText = "Remove “\(name)” from your library?"
    a.informativeText = "Its songs leave the library, along with the playlist entries that point to them. The files stay where they are, and you can add the folder again at any time."
    a.alertStyle = .warning
    a.addButton(withTitle: "Remove")
    a.addButton(withTitle: "Cancel")
    return a.runModal() == .alertFirstButtonReturn
}

/// One row per library folder with a minus button.
struct LibraryFolderList: View {
    @ObservedObject var lib: LibraryModel
    var onRemoved: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lib.folders, id: \.self) { path in
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(Typo.sans(12, .light)).foregroundStyle(Brand.inkSecondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text((path as NSString).lastPathComponent).font(Typo.sans(12.5, .medium)).lineLimit(1)
                        Text((path as NSString).abbreviatingWithTildeInPath).font(Typo.sans(10.5)).foregroundStyle(Brand.inkTertiary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button {
                        guard confirmRemoveLibraryFolder(path) else { return }
                        lib.removeFolder(path) { _ in onRemoved?() }
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(IconButtonStyle()).disabled(lib.importing)
                        .help("Remove “\((path as NSString).lastPathComponent)” from the library")
                        .accessibilityLabel("Remove \((path as NSString).lastPathComponent) from the library")
                }
                .padding(.vertical, 8)
                .help(path)
                if path != lib.folders.last { Rule() }
            }
        }
    }
}

/// The toolbar button that lists the library folders.
struct LibraryFoldersButton: View {
    @ObservedObject var lib: LibraryModel
    @StateObject private var open = Box(false)

    var body: some View {
        Button { open.v.toggle() } label: { Image(systemName: "folder.badge.minus") }
            .buttonStyle(IconButtonStyle()).help("Library folders")
            .accessibilityLabel("Library folders")
            .popover(isPresented: Binding(get: { open.v }, set: { open.v = $0 }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library folders").microLabel().foregroundStyle(Brand.inkTertiary)
                    if lib.folders.isEmpty {
                        Text("No folders yet.").font(Typo.callout).foregroundStyle(Brand.inkSecondary).padding(.vertical, 8)
                    } else {
                        LibraryFolderList(lib: lib, onRemoved: { if lib.folders.isEmpty { open.v = false } })
                    }
                }
                .padding(16).frame(width: 360).glassPopover().foregroundStyle(Brand.ink)
            }
    }
}
