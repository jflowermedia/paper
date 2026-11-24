import AppKit
import Carbon.HIToolbox
import ImageIO
import ServiceManagement

/// Same folder layout the Python scripts used, so existing collections,
/// _metadata.json files and current_wallpaper.json keep working (and the
/// scripts can still run alongside the app).
enum Paths {
    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Wallpapers")

    private static let commandLineRoot: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--root"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
    }()

    /// The folder chosen in the menu; nil means the default.
    static var chosenRoot: URL? {
        get { UserDefaults.standard.string(forKey: "wallpapersFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "wallpapersFolder") }
    }

    static var root: URL { commandLineRoot ?? chosenRoot ?? defaultRoot }

    static var rootExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Creates the root, unless it's a chosen folder: if that's missing its
    /// drive is probably unplugged, and a new empty folder would hide that.
    static func createRootIfNeeded() {
        guard commandLineRoot != nil || chosenRoot == nil else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static var missingRootMessage: String {
        "Can’t find the wallpapers folder “\(root.lastPathComponent)”. Is its drive connected?"
    }

    static var stateFile: URL { root.appendingPathComponent("current_wallpaper.json") }
}

typealias MetadataFile = [String: [String: Any]]

enum Metadata {
    static let filename = "_metadata.json"
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    static func load(_ url: URL) -> MetadataFile {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? MetadataFile
        else { return [:] }
        return json
    }

    /// Atomic write, so a reader never sees a half-written file.
    static func save(_ metadata: MetadataFile, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// Subfolders of the root that contain a _metadata.json.
    static func collections(in root: URL) -> [URL] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(filename).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func images(in folder: URL) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files
            .filter { imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }
}

struct Painting: Equatable {
    let folder: String
    let filename: String
    let title: String
    let artist: String
    let date: String
    let sourceURL: URL?
    let sourceLabel: String

    var fileURL: URL { Paths.root.appendingPathComponent(folder).appendingPathComponent(filename) }
    /// Identifies the painting in the favourites/hidden lists.
    var key: String { "\(folder)/\(filename)" }

    init(folder: String, filename: String, info: [String: Any]) {
        self.folder = folder
        self.filename = filename
        title = info["title"] as? String ?? (filename as NSString).deletingPathExtension
        artist = info["artist"] as? String ?? "Unknown artist"
        date = info["date"] as? String ?? ""
        // Newer entries use "source_url"; older Met-only ones put the URL in "source".
        let source = info["source"] as? String ?? "met"
        let urlString = info["source_url"] as? String ?? (source.hasPrefix("http") ? source : nil)
        sourceURL = urlString.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        sourceLabel = Museum(rawValue: source)?.label ?? Museum.met.label
    }
}

struct Collection: Identifiable {
    let name: String
    let count: Int
    var id: String { name }
}

/// A set of strings kept in UserDefaults.
private struct StoredSet {
    let key: String

    func load() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    func save(_ value: Set<String>) { UserDefaults.standard.set(value.sorted(), forKey: key) }
}

@MainActor
final class Library: ObservableObject {
    /// How much likelier a favourite is to be picked than other paintings.
    static let favouriteWeight = 4.0

    @Published private(set) var current: Painting?
    @Published private(set) var thumbnail: NSImage?
    @Published private(set) var problem: String?
    @Published private(set) var collections: [Collection] = []
    @Published private(set) var folder = Paths.root
    @Published private(set) var disabledCollections: Set<String> {
        didSet { StoredSet(key: "disabledCollections").save(disabledCollections) }
    }
    @Published private(set) var favourites: Set<String> {
        didSet { StoredSet(key: "favourites").save(favourites) }
    }
    @Published private(set) var hidden: Set<String> {
        didSet { StoredSet(key: "hidden").save(hidden) }
    }
    /// Seconds between automatic rotations; 0 turns rotation off.
    @Published var rotationInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(rotationInterval, forKey: "rotationInterval")
            checkSchedule()
        }
    }

    private var lastRotated: Date?
    private var stateModified: Date?
    private var timer: Timer?
    private var rotateHotKey: HotKey?

    init() {
        rotationInterval = UserDefaults.standard.object(forKey: "rotationInterval") as? Double ?? 86_400
        disabledCollections = StoredSet(key: "disabledCollections").load()
        favourites = StoredSet(key: "favourites").load()
        hidden = StoredSet(key: "hidden").load()
        // So Open Wallpapers Folder works before the first download.
        Paths.createRootIfNeeded()
        reload()
        refreshCollections()
        rotateHotKey = HotKey(keyCode: kVK_ANSI_R, modifiers: HotKey.hyper) { [weak self] in
            Task { @MainActor in self?.rotate() }
        }
        if rotateHotKey == nil { NSLog("Paper: couldn't register ⌃⌥⇧⌘R; another app may be using it") }
        // A coarse 60s tick is plenty for hourly/daily schedules and copes
        // with sleep, unlike one long timer.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkSchedule() }
        }
        // macOS only sets the wallpaper on the Space that's showing, so catch
        // up other Spaces as you switch to them, and newly attached displays.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyCurrent() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyCurrent() }
        }
        checkSchedule()
    }

    func checkSchedule() {
        reloadIfChanged()
        guard rotationInterval > 0 else { return }
        if let last = lastRotated, Date().timeIntervalSince(last) < rotationInterval { return }
        rotate()
    }

    /// Picks up rotations made elsewhere (e.g. the old rotate_wallpaper.py).
    func reloadIfChanged() {
        if Self.modificationDate(Paths.stateFile) != stateModified { reload() }
    }

    func reload() {
        stateModified = Self.modificationDate(Paths.stateFile)
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = state["folder"] as? String,
              let filename = state["filename"] as? String
        else {
            current = nil
            thumbnail = nil
            lastRotated = nil
            problem = Paths.rootExists ? "No wallpaper chosen yet. Click Rotate Now." : Paths.missingRootMessage
            return
        }
        lastRotated = (state["rotated_at"] as? String).flatMap(Self.parseTimestamp)
        let metadataURL = Paths.root.appendingPathComponent(folder).appendingPathComponent(Metadata.filename)
        let painting = Painting(folder: folder, filename: filename, info: Metadata.load(metadataURL)[filename] ?? [:])
        problem = nil
        guard painting != current else { return }
        // The old thumbnail stays up until the new one is ready, so the menu
        // doesn't collapse and re-grow.
        current = painting
        let url = painting.fileURL
        Task.detached(priority: .utility) {
            guard let image = Self.makeThumbnail(url) else { return }
            await MainActor.run { [weak self] in
                guard self?.current == painting else { return }
                self?.thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    /// Switches to another wallpapers folder (nil for the default). Paintings
    /// in the old one stay where they are.
    func setFolder(_ url: URL?) {
        Paths.chosenRoot = url?.standardizedFileURL == Paths.defaultRoot.standardizedFileURL ? nil : url
        Paths.createRootIfNeeded()
        folder = Paths.root
        reload()
        refreshCollections()
        applyCurrent()
        checkSchedule()
    }

    func refreshCollections() {
        collections = Metadata.collections(in: Paths.root).map {
            Collection(name: $0.lastPathComponent, count: Metadata.images(in: $0).count)
        }
    }

    func setCollection(_ name: String, enabled: Bool) {
        if enabled { disabledCollections.remove(name) } else { disabledCollections.insert(name) }
    }

    func toggleFavourite() {
        guard let key = current?.key else { return }
        if favourites.contains(key) { favourites.remove(key) } else { favourites.insert(key) }
    }

    /// Hides the current painting from rotation and moves on.
    func hideCurrent() {
        guard let key = current?.key else { return }
        hidden.insert(key)
        favourites.remove(key)
        rotate()
    }

    func unhideAll() {
        hidden.removeAll()
    }

    func rotate() {
        refreshCollections()
        guard Paths.rootExists else {
            problem = Paths.missingRootMessage
            return
        }
        // Enabled collections, minus hidden paintings and the current one;
        // favourites weigh more.
        var pool: [(folder: String, file: String, weight: Double)] = []
        for collection in collections where !disabledCollections.contains(collection.name) {
            let folder = Paths.root.appendingPathComponent(collection.name)
            for file in Metadata.images(in: folder) {
                let key = "\(collection.name)/\(file)"
                guard !hidden.contains(key), key != current?.key else { continue }
                pool.append((collection.name, file, favourites.contains(key) ? Self.favouriteWeight : 1))
            }
        }
        var roll = Double.random(in: 0..<max(pool.reduce(0) { $0 + $1.weight }, .leastNonzeroMagnitude))
        guard let pick = pool.first(where: { roll -= $0.weight; return roll < 0 }) ?? pool.last else {
            problem = collections.isEmpty
                ? "No images in \(Paths.root.path) yet. Download a collection first."
                : "Nothing to show: every collection is turned off or hidden."
            return
        }
        let state: [String: Any] = [
            "folder": pick.folder,
            "filename": pick.file,
            "rotated_at": Self.formatTimestamp(Date()),
        ]
        // Saved before the wallpaper changes: if it can't be, the schedule
        // would think a rotation was still due and change it every minute.
        do {
            try JSONSerialization.data(withJSONObject: state).write(to: Paths.stateFile, options: .atomic)
        } catch {
            problem = "Can’t save to the wallpapers folder “\(Paths.root.lastPathComponent)”."
            return
        }
        Self.applyWallpaper(Paths.root.appendingPathComponent(pick.folder).appendingPathComponent(pick.file))
        reload()
    }

    private func applyCurrent() {
        guard let url = current?.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        Self.applyWallpaper(url)
    }

    /// Applies to every display's current Space; skips displays already showing it.
    static func applyWallpaper(_ url: URL) {
        // Fill the screen, cropping the edges rather than letterboxing.
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens
        where NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL != url.standardizedFileURL {
            try? NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }

    /// Size of the menu's preview, in points.
    nonisolated static let previewSize = CGSize(width: 296, height: 180)

    /// A thumbnail centre-cropped to exactly the preview's shape, so every
    /// painting fills the same box, landscape or portrait.
    nonisolated static func makeThumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Large enough that even a portrait painting's crop is sharp at 2x.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1400,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let aspect = previewSize.width / previewSize.height
        let crop = width / height > aspect
            ? CGRect(x: (width - height * aspect) / 2, y: 0, width: height * aspect, height: height)
            : CGRect(x: 0, y: (height - width / aspect) / 2, width: width, height: width / aspect)
        return image.cropping(to: crop.integral) ?? image
    }

    // rotated_at uses Python's datetime.isoformat(): local time, no zone,
    // microseconds omitted when zero.
    nonisolated static func parseTimestamp(_ string: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            if let date = timestampFormatter(format).date(from: string) { return date }
        }
        return nil
    }

    nonisolated static func formatTimestamp(_ date: Date) -> String {
        timestampFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSSSS").string(from: date)
    }

    nonisolated private static func timestampFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    nonisolated private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Paper: couldn't change login item: \(error)")
        }
    }
}
