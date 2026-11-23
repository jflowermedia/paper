import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--download"), i + 1 < args.count {
            Headless.download(term: args[i + 1])
        } else if let i = args.firstIndex(of: "--open-at-login"), i + 1 < args.count {
            // Same as the menu toggle, for scripting: --open-at-login on|off
            LoginItem.set(args[i + 1] == "on")
            print("Open at login: \(LoginItem.isEnabled ? "on" : "off")")
        } else {
            PaperApp.main()
        }
    }
}

/// `Paper --download "Venice" [--count N] [--museums met,rijks,aic,cma]
/// [--any-orientation] [--root DIR]` runs a download in the terminal without
/// the menu bar UI.
enum Headless {
    static func download(term: String) -> Never {
        let args = CommandLine.arguments
        var config = DownloadConfig(term: term, museums: Museum.allCases)
        if let i = args.firstIndex(of: "--count"), i + 1 < args.count, let count = Int(args[i + 1]) {
            config.targetCount = count
        }
        if let i = args.firstIndex(of: "--museums"), i + 1 < args.count {
            config.museums = args[i + 1].split(separator: ",").compactMap { Museum(rawValue: String($0)) }
        }
        if args.contains("--any-orientation") { config.landscapeOnly = false }
        let downloader = Downloader(config: config, log: { print($0) }, progress: { _ in })
        Task {
            await downloader.run()
            exit(0)
        }
        dispatchMain()
    }
}

struct PaperApp: App {
    @StateObject private var library = Library()
    @StateObject private var downloads = DownloadModel()
    @AppStorage("showTitleInMenuBar") private var showTitle = true
    @AppStorage("menuBarTitleLength") private var titleLength = 10

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(library)
                .environmentObject(downloads)
        } label: {
            if showTitle, let title = library.current?.title {
                Image(nsImage: MenuBarLabel.image(title: title, characters: titleLength))
                    .accessibilityLabel(title)
            } else {
                Image(systemName: "photo.artframe")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Download Collection", id: "download") {
            DownloadView()
                .environmentObject(downloads)
        }
        .windowResizability(.contentSize)
    }
}

/// Draws the icon + title into a fixed-width image, so the menu bar item is
/// the same size whatever the title and neighbouring items never shift.
enum MenuBarLabel {
    static func image(title: String, characters: Int) -> NSImage {
        let font = NSFont.menuBarFont(ofSize: 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]

        // Room for `characters` average-width letters. Truncation measures the
        // real text, so narrow titles use the space instead of leaving a gap.
        let slotWidth = ceil((String(repeating: "e", count: characters) as NSString)
            .size(withAttributes: attributes).width)
        let text = truncateMiddle(title) { ($0 as NSString).size(withAttributes: attributes).width <= slotWidth }

        let symbol = NSImage(systemSymbolName: "photo.artframe", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let iconWidth = symbol?.size.width ?? 0
        let gap: CGFloat = 5
        let height: CGFloat = 22
        let size = NSSize(width: ceil(iconWidth + gap + slotWidth), height: height)

        // Centre icon + text together, so the room whole words leave over is
        // split between both sides instead of piling up on the right.
        let textWidth = min(slotWidth, ceil((text as NSString).size(withAttributes: attributes).width))
        let inset = floor((slotWidth - textWidth) / 2)

        let image = NSImage(size: size, flipped: false) { _ in
            if let symbol {
                symbol.draw(in: NSRect(x: inset, y: (height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
            let textHeight = ceil(font.ascender - font.descender)
            let textRect = NSRect(x: inset + iconWidth + gap, y: (height - textHeight) / 2,
                                  width: textWidth, height: textHeight)
            // Single-line draw, so wide letters still get middle-truncated to fit.
            (text as NSString).draw(in: textRect, withAttributes: attributes)
            return true
        }
        // Template images are tinted by the system for light/dark menu bars.
        image.isTemplate = true
        return image
    }

    /// Keeps whole words from each end where they fit ("View…Delft"); when
    /// the first and last words alone are too long, shares the room between
    /// them ("Peasa…cing"). A leading "The"/"A"/"An" is dropped first.
    static func truncateMiddle(_ title: String, fits: (String) -> Bool) -> String {
        if fits(title) { return title }
        var words = title.split(separator: " ").map(String.init)
        if words.count > 1, ["the", "a", "an"].contains(words[0].lowercased()) {
            words.removeFirst()
            let rest = words.joined(separator: " ")
            if fits(rest) { return rest }  // "The Farrier" → "Farrier"
        }
        guard words.count > 1 else {
            let word = words.first ?? title
            return share(word, word, overlapping: true, fits: fits)
        }

        var head = [words[0]]
        var tail = [words[words.count - 1]]
        func label(_ head: [String], _ tail: [String]) -> String {
            head.joined(separator: " ") + "…" + tail.joined(separator: " ")
        }
        guard fits(label(head, tail)) else {
            return share(head[0], tail[0], overlapping: false, fits: fits)
        }
        // Add more whole words, front first, while they still fit.
        var front = 1
        var back = words.count - 2
        while front <= back {
            if fits(label(head + [words[front]], tail)) {
                head.append(words[front])
                front += 1
            } else if fits(label(head, [words[back]] + tail)) {
                tail.insert(words[back], at: 0)
                back -= 1
            } else {
                break
            }
        }
        return label(head, tail)
    }

    /// Grows the start of `first` and the end of `last` in turn while they
    /// fit, so any room one word doesn't need goes to the other.
    private static func share(_ first: String, _ last: String, overlapping: Bool,
                              fits: (String) -> Bool) -> String {
        var headCount = 0
        var tailCount = 0
        func label(_ h: Int, _ t: Int) -> String { first.prefix(h) + "…" + last.suffix(t) }
        func available(_ h: Int, _ t: Int) -> Bool {
            h <= first.count && t <= last.count && !(overlapping && h + t >= first.count)
        }
        var grew = true
        while grew {
            grew = false
            if available(headCount + 1, tailCount), fits(label(headCount + 1, tailCount)) {
                headCount += 1
                grew = true
            }
            if available(headCount, tailCount + 1), fits(label(headCount, tailCount + 1)) {
                tailCount += 1
                grew = true
            }
        }
        return label(headCount, tailCount)
    }
}
