import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var downloads: DownloadModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showTitleInMenuBar") private var showTitle = true
    @AppStorage("menuBarTitleLength") private var titleLength = 10
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let painting = library.current {
                nowShowing(painting)
            }
            if let problem = library.problem {
                Text(problem).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Button { library.rotate() } label: {
                    HStack {
                        Label("Rotate Now", systemImage: "arrow.clockwise")
                        Spacer()
                        Text("⌃⌥⇧⌘R").opacity(0.55)
                    }
                }
                if let painting = library.current {
                    let isFavourite = library.favourites.contains(painting.key)
                    Button { library.toggleFavourite() } label: {
                        Label(isFavourite ? "Favourite" : "Add to Favourites",
                              systemImage: isFavourite ? "heart.fill" : "heart")
                    }
                    Button { library.hideCurrent() } label: {
                        Label("Don’t Show Again", systemImage: "eye.slash")
                    }
                    // Always shown (disabled without a link) so the menu keeps its height.
                    Button { painting.sourceURL.map { _ = NSWorkspace.shared.open($0) } } label: {
                        Label("View on \(painting.sourceLabel)", systemImage: "building.columns")
                    }
                    .disabled(painting.sourceURL == nil)
                }
                Divider().padding(.vertical, 4)
                Button {
                    openWindow(id: "download")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    HStack {
                        Label("Download New Collection…", systemImage: "arrow.down.circle")
                        Spacer()
                        // Progress sits in the row rather than adding a line.
                        if downloads.running { Text("\(downloads.saved) saved").opacity(0.55) }
                    }
                }
                Button { NSWorkspace.shared.open(Paths.root) } label: {
                    Label("Open Wallpapers Folder", systemImage: "folder")
                }
            }
            .buttonStyle(MenuRowStyle())

            Divider()

            // A pop-up menu rather than an expanding list: the menu window
            // doesn't resize while open.
            LabeledContent("Collections") {
                Menu(collectionsSummary) {
                    ForEach(library.collections) { collection in
                        Toggle("\(collection.name) (\(collection.count))", isOn: Binding(
                            get: { !library.disabledCollections.contains(collection.name) },
                            set: { library.setCollection(collection.name, enabled: $0) }))
                    }
                    if !library.hidden.isEmpty {
                        Divider()
                        Button("Show \(library.hidden.count) Hidden Painting\(library.hidden.count == 1 ? "" : "s") Again") {
                            library.unhideAll()
                        }
                    }
                }
                .fixedSize()
            }
            Picker("Change wallpaper", selection: $library.rotationInterval) {
                Text("Never").tag(0.0)
                Text("Every hour").tag(3_600.0)
                Text("Every 3 hours").tag(10_800.0)
                Text("Every 6 hours").tag(21_600.0)
                Text("Daily").tag(86_400.0)
            }
            Toggle("Show title in menu bar", isOn: $showTitle)
            if showTitle {
                Picker("Title length", selection: $titleLength) {
                    ForEach([8, 10, 12, 16, 20], id: \.self) { Text("\($0) characters").tag($0) }
                }
            }
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { LoginItem.set(openAtLogin) }

            Divider()

            Button("Quit Paper") { NSApp.terminate(nil) }
                .buttonStyle(MenuRowStyle())
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            library.reloadIfChanged()
            library.refreshCollections()
            openAtLogin = LoginItem.isEnabled
        }
    }

    private var collectionsSummary: String {
        let on = library.collections.filter { !library.disabledCollections.contains($0.name) }.count
        return on == library.collections.count ? "All \(on)" : "\(on) of \(library.collections.count)"
    }

    private func nowShowing(_ painting: Painting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Always the same box: the thumbnail is pre-cropped to this shape,
            // and a placeholder holds the space while it loads (the menu window
            // squashes flexible images and doesn't resize while open).
            Group {
                if let thumbnail = library.thumbnail {
                    Image(nsImage: thumbnail).resizable()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: Library.previewSize.width, height: Library.previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Fixed line counts so every painting gives the menu the same
            // height: the title always takes two lines, the rest one each.
            VStack(alignment: .leading, spacing: 2) {
                Text(painting.title)
                    .font(.headline)
                    .lineLimit(2, reservesSpace: true)
                    .help(painting.title)
                Text(painting.artist).lineLimit(1)
                Text(painting.date.isEmpty ? " " : painting.date)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Collection: \(painting.folder)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

/// Full-width rows with a hover highlight, like a regular menu.
struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.accentColor : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
