import Foundation
import ImageIO

// Grew out of met_art_downloader.py: searches museum open-access APIs (no keys
// needed) and saves public-domain paintings into <root>/<search term>/ with
// the same _metadata.json format.

/// The raw value is stored in metadata ("source") and in filenames ("_aic123.jpg").
enum Museum: String, CaseIterable {
    case met, rijks, aic, cma

    var label: String {
        switch self {
        case .met: "Met Museum"
        case .rijks: "Rijksmuseum"
        case .aic: "Art Institute of Chicago"
        case .cma: "Cleveland Museum of Art"
        }
    }

    var shortLabel: String {
        switch self {
        case .met: "Met"
        case .rijks: "Rijks"
        case .aic: "Chicago"
        case .cma: "Cleveland"
        }
    }

    /// Request headers beyond Accept. The Met's WAF blocks some non-browser
    /// user agents; the Art Institute's image server does the opposite (a
    /// browser UA gets a bot check) and asks apps to identify themselves.
    var headers: [String: String] {
        switch self {
        case .met, .rijks: ["User-Agent": HTTP.browserUserAgent]
        case .aic: ["User-Agent": HTTP.appUserAgent, "AIC-User-Agent": HTTP.appUserAgent]
        case .cma: ["User-Agent": HTTP.appUserAgent]
        }
    }
}

struct DownloadConfig {
    var term: String
    var museums: [Museum]
    var landscapeOnly = true
    var targetCount = 300
    var root = Paths.root
    // Met-only filters; the Rijksmuseum search API has no equivalent.
    var metDepartmentID = 11  // European Paintings
    var metDateBegin = 1400
    var metDateEnd = 1850
}

enum Filters {
    /// Subjects to leave out. Matched as whole words plus an optional plural
    /// "s", so "st" won't hit "forest" and "angel" won't hit "Michelangelo".
    static let excludeKeywords = [
        "christ", "jesus", "madonna", "virgin mary", "crucifix", "crucifixion",
        "pieta", "annunciation", "nativity", "resurrection", "ascension",
        "apostle", "evangelist", "saint", "st", "bible", "biblical",
        "gospel", "holy family", "adoration of the", "last supper", "deposition",
        "baptism of christ", "ecce homo", "trinity", "cherub", "angel",
        "archangel", "martyrdom", "altarpiece", "religious", "christianity",
        "old testament", "new testament", "pope", "bishop", "cardinal",
        "monastery", "cathedral interior", "church interior",
    ]

    private static let excludeRegex = try! NSRegularExpression(
        pattern: "\\b(?:" + excludeKeywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")s?\\b",
        options: .caseInsensitive)

    static func isExcluded(_ text: String) -> Bool {
        excludeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// True if any word of the search term starts a word in the text, so
    /// "venice" matches "Venice's" but "art" doesn't match "party". British
    /// and American spellings count as the same word.
    static func matches(term: String, text: String) -> Bool {
        term.lowercased().split(whereSeparator: \.isWhitespace).contains { word in
            spellings(of: String(word)).contains { form in
                let pattern = "\\b" + NSRegularExpression.escapedPattern(for: form)
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
            }
        }
    }

    /// "harbour" ↔ "harbor", "grey" ↔ "gray", "centre" ↔ "center".
    static func spellings(of word: String) -> [String] {
        var forms = [word]
        if word.hasSuffix("our") { forms.append(word.dropLast(3) + "or") }
        else if word.hasSuffix("or") { forms.append(word.dropLast(2) + "our") }
        if word.hasSuffix("re") { forms.append(word.dropLast(2) + "er") }
        for (a, b) in [("grey", "gray")] {
            if word.contains(a) { forms.append(word.replacingOccurrences(of: a, with: b)) }
            if word.contains(b) { forms.append(word.replacingOccurrences(of: b, with: a)) }
        }
        return forms
    }

    /// Same rules as the Python sanitize_filename, so names stay compatible.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "[^\\w\\s-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
        return String(cleaned.prefix(80))
    }
}

struct Artwork {
    enum SizeProbe {
        case smallImage(URL)  // Met's primaryImageSmall: same aspect, a fraction of the bytes
        case iiifInfo(URL)    // Rijksmuseum IIIF info.json lists the full dimensions
        case known(CGSize)    // Chicago and Cleveland include dimensions in search results
        case unknown
    }

    let museum: Museum
    let id: String
    let objectID: Any  // Int for the Met, Chicago and Cleveland; String for the Rijksmuseum
    let title: String
    let artist: String
    let date: String
    let imageURL: URL?
    let sizeProbe: SizeProbe
    let sourceURL: String
    let isPublicDomain: Bool
    let searchText: String

    var uid: String { "\(museum.rawValue):\(id)" }
}

private enum Candidate {
    case met(Int)
    case rijks(String)      // linked-data URL, e.g. https://id.rijksmuseum.nl/200107007
    case resolved(Artwork)  // search results that already carry everything (Chicago, Cleveland)

    var uid: String {
        switch self {
        case .met(let id): "met:\(id)"
        case .rijks(let url): "rijks:" + (url.split(separator: "/").last.map(String.init) ?? url)
        case .resolved(let art): art.uid
        }
    }
}

struct HTTP {
    struct Response {
        let data: Data
        let status: Int
    }

    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let appUserAgent = "Paper/1.0 (personal macOS wallpaper app)"

    /// GET with backoff (5s, 10s, 20s) on 403/429 rate limiting.
    func get(_ url: URL, accept: String, headers: [String: String] = Museum.met.headers,
             timeout: TimeInterval = 30) async throws -> Response {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.setValue(accept, forHTTPHeaderField: "Accept")
        var delay: UInt64 = 5
        var attempt = 0
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (status != 403 && status != 429) || attempt == 3 {
                return Response(data: data, status: status)
            }
            try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay *= 2
            attempt += 1
        }
    }
}

final class Downloader {
    let config: DownloadConfig
    private let log: (String) -> Void
    private let progress: (Int) -> Void
    private let http = HTTP()

    /// `log` and `progress` are called from a background thread.
    init(config: DownloadConfig, log: @escaping (String) -> Void, progress: @escaping (Int) -> Void) {
        self.config = config
        self.log = log
        self.progress = progress
    }

    func run() async {
        let folderName = Filters.sanitize(config.term)
        guard !folderName.isEmpty else {
            log("“\(config.term)” has no characters usable in a folder name.")
            return
        }
        let outDir = config.root.appendingPathComponent(folderName, isDirectory: true)
        let metadataURL = outDir.appendingPathComponent(Metadata.filename)
        var metadata = Metadata.load(metadataURL)
        let alreadyHave = alreadyDownloadedUIDs()

        log("Searching for: \(config.term)")
        log("Museums: \(config.museums.map(\.label).joined(separator: ", "))  ·  landscape only: \(config.landscapeOnly ? "yes" : "no")")
        log("Saving to: \(outDir.path)")
        if !alreadyHave.isEmpty {
            log("\(alreadyHave.count) artworks are already in your collections and will be skipped.")
        }
        log("")

        var perMuseum: [[Candidate]] = []
        for museum in config.museums {
            switch museum {
            case .met: perMuseum.append(await searchMet().map(Candidate.met))
            case .rijks: perMuseum.append(await searchRijks().map(Candidate.rijks))
            case .aic: perMuseum.append(await searchChicago().map(Candidate.resolved))
            case .cma: perMuseum.append(await searchCleveland().map(Candidate.resolved))
            }
        }
        // Interleave so every museum contributes before the target is reached.
        var candidates: [Candidate] = []
        for i in 0..<(perMuseum.map(\.count).max() ?? 0) {
            for list in perMuseum where i < list.count { candidates.append(list[i]) }
        }
        guard !candidates.isEmpty else {
            log("No results. Try a different search term.")
            return
        }
        log("\(candidates.count) candidates to check.")
        log("")

        var saved = 0
        var skips: [String: Int] = [:]
        func skip(_ art: Artwork?, _ reason: String) {
            skips[reason, default: 0] += 1
            if let art { log("  [\(art.museum.rawValue)] Skipped (\(reason)): \(art.title)") }
        }

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                log("")
                log("Stopped.")
                break
            }
            if saved >= config.targetCount { break }
            if index > 0 && index % 20 == 0 { log("  … checked \(index)/\(candidates.count)") }

            if alreadyHave.contains(candidate.uid) { skip(nil, "already in a collection"); continue }
            guard let art = await resolve(candidate) else { skip(nil, "couldn't fetch details"); continue }
            guard art.isPublicDomain else { skip(art, "not public domain"); continue }
            guard !Filters.isExcluded(art.searchText) else { skip(art, "religious subject"); continue }
            guard Filters.matches(term: config.term, text: art.searchText) else {
                skip(art, "not about “\(config.term)”")
                continue
            }
            guard let imageURL = art.imageURL else { skip(art, "no image"); continue }

            // Check orientation from a small preview before pulling the full-size file.
            var size: CGSize?
            if config.landscapeOnly { size = await probeSize(art.sizeProbe) }
            if let size, size.width <= size.height { skip(art, "not landscape"); continue }

            let filename = Filters.sanitize("\(art.artist)_\(art.title)") + "_\(art.museum.rawValue)\(art.id).jpg"
            let fileURL = outDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: fileURL.path) { continue }

            let data: Data
            do {
                let response = try await http.get(imageURL, accept: "image/avif,image/webp,image/*,*/*",
                                                  headers: art.museum.headers, timeout: 120)
                guard response.status == 200 else { skip(art, "download failed"); continue }
                data = response.data
            } catch {
                skip(art, "download failed")
                continue
            }

            if config.landscapeOnly && size == nil {
                guard let actual = Self.imageSize(data), actual.width > actual.height else {
                    skip(art, "not landscape")
                    continue
                }
            }

            do {
                try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
                try data.write(to: fileURL)
                metadata[filename] = [
                    "title": art.title,
                    "artist": art.artist,
                    "date": art.date,
                    "uid": art.uid,
                    "objectID": art.objectID,
                    "source": art.museum.rawValue,
                    "source_url": art.sourceURL,
                ]
                // Saved after every image so stopping early never leaves
                // images without metadata.
                try Metadata.save(metadata, to: metadataURL)
            } catch {
                log("Couldn't write to \(outDir.path): \(error.localizedDescription)")
                return
            }
            saved += 1
            progress(saved)
            let date = art.date.isEmpty ? "" : " (\(art.date))"
            log("[\(saved)/\(config.targetCount)] [\(art.museum.rawValue)] Saved: \(art.artist) — \(art.title)\(date)")
            try? await Task.sleep(nanoseconds: 300_000_000)  // be polite to the APIs
        }

        log("")
        log(saved == 0 ? "Nothing new was downloaded." : "Done. \(saved) images saved to \(outDir.path)")
        for (reason, count) in skips.sorted(by: { $0.value > $1.value }) {
            log("  Skipped \(count): \(reason)")
        }
    }

    private func alreadyDownloadedUIDs() -> Set<String> {
        var uids = Set<String>()
        for folder in Metadata.collections(in: config.root) {
            for entry in Metadata.load(folder.appendingPathComponent(Metadata.filename)).values {
                if let uid = entry["uid"] as? String {
                    uids.insert(uid)
                } else if let id = entry["objectID"] {
                    uids.insert("met:\(id)")  // entries from before Rijksmuseum support
                }
            }
        }
        return uids
    }

    private func resolve(_ candidate: Candidate) async -> Artwork? {
        switch candidate {
        case .met(let id): await fetchMet(id)
        case .rijks(let lodID): await fetchRijks(lodID)
        case .resolved(let art): art
        }
    }

    // MARK: Met Museum

    private struct MetObject: Decodable {
        struct Tag: Decodable { let term: String? }
        let title: String?
        let artistDisplayName: String?
        let objectDate: String?
        let primaryImage: String?
        let primaryImageSmall: String?
        let objectURL: String?
        let isPublicDomain: Bool?
        let classification: String?
        let objectName: String?
        let tags: [Tag]?
    }

    /// v1/search was retired on 2026-10-01; v1.1 is paginated (max 500 per page).
    private func searchMet() async -> [Int] {
        struct Results: Decodable {
            let total: Int?
            let objectIDs: [Int]?
        }
        let pageSize = 500
        var ids: [Int] = []
        var total = 0
        for page in 0..<5 where !Task.isCancelled {
            var components = URLComponents(string: "https://collectionapi.metmuseum.org/public/collection/v1.1/search")!
            components.queryItems = [
                URLQueryItem(name: "departmentId", value: String(config.metDepartmentID)),
                URLQueryItem(name: "hasImages", value: "true"),
                URLQueryItem(name: "dateBegin", value: String(config.metDateBegin)),
                URLQueryItem(name: "dateEnd", value: String(config.metDateEnd)),
                URLQueryItem(name: "q", value: config.term),
                URLQueryItem(name: "offset", value: String(page * pageSize)),
                URLQueryItem(name: "limit", value: String(pageSize)),
            ]
            do {
                let response = try await http.get(components.url!, accept: "application/json")
                guard response.status == 200 else {
                    log("  [met] Search failed (HTTP \(response.status))")
                    break
                }
                let results = try JSONDecoder().decode(Results.self, from: response.data)
                let pageIDs = results.objectIDs ?? []
                ids += pageIDs
                total = results.total ?? ids.count
                if pageIDs.count < pageSize || ids.count >= total { break }
            } catch {
                log("  [met] Search failed: \(error.localizedDescription)")
                break
            }
        }
        log("  [met] \(total) results" + (ids.count < total ? " (checking the first \(ids.count))" : ""))
        return ids
    }

    private func fetchMet(_ id: Int) async -> Artwork? {
        let url = URL(string: "https://collectionapi.metmuseum.org/public/collection/v1/objects/\(id)")!
        guard let response = try? await http.get(url, accept: "application/json"), response.status == 200,
              let object = try? JSONDecoder().decode(MetObject.self, from: response.data)
        else { return nil }

        let title = object.title.nonEmpty ?? "untitled_\(id)"
        let artist = object.artistDisplayName.nonEmpty ?? "Unknown"
        let tags = object.tags?.compactMap(\.term).joined(separator: " ") ?? ""
        let searchText = [object.title ?? "", object.classification ?? "", object.objectName ?? "",
                          object.artistDisplayName ?? "", tags].joined(separator: " ").lowercased()
        return Artwork(
            museum: .met,
            id: String(id),
            objectID: id,
            title: title,
            artist: artist,
            date: object.objectDate ?? "",
            imageURL: object.primaryImage.nonEmpty.flatMap(URL.init(string:)),
            sizeProbe: object.primaryImageSmall.nonEmpty.flatMap(URL.init(string:)).map { .smallImage($0) } ?? .unknown,
            sourceURL: object.objectURL ?? "",
            isPublicDomain: object.isPublicDomain ?? false,
            searchText: searchText)
    }

    // MARK: Rijksmuseum

    private struct RijksPage: Decodable {
        struct Link: Decodable { let id: String }
        let orderedItems: [Link]?
        let next: Link?
    }

    private func searchRijks() async -> [String] {
        var components = URLComponents(string: "https://data.rijksmuseum.nl/search/collection")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "painting"),
            URLQueryItem(name: "imageAvailable", value: "true"),
            URLQueryItem(name: "description", value: config.term),
        ]
        var next = components.url
        var ids: [String] = []
        var pages = 0
        while let url = next, pages < 5, !Task.isCancelled {
            do {
                let response = try await http.get(url, accept: "application/json")
                guard response.status == 200 else {
                    log("  [rijks] Search failed (HTTP \(response.status))")
                    break
                }
                let page = try JSONDecoder().decode(RijksPage.self, from: response.data)
                ids += page.orderedItems?.map(\.id) ?? []
                next = page.next.flatMap { URL(string: $0.id) }
            } catch {
                log("  [rijks] Search failed: \(error.localizedDescription)")
                break
            }
            pages += 1
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        log("  [rijks] \(ids.count) results")
        return ids
    }

    /// Metadata comes from the OAI-PMH API as EDM/RDF XML. XPath here matches
    /// on local-name() because NSXMLDocument has no namespace-prefix binding.
    private func fetchRijks(_ lodID: String) async -> Artwork? {
        let numericID = lodID.split(separator: "/").last.map(String.init) ?? lodID
        var components = URLComponents(string: "https://data.rijksmuseum.nl/oai")!
        components.queryItems = [
            URLQueryItem(name: "verb", value: "GetRecord"),
            URLQueryItem(name: "metadataPrefix", value: "edm"),
            URLQueryItem(name: "identifier", value: lodID),
        ]
        guard let response = try? await http.get(components.url!, accept: "application/xml, text/xml"),
              response.status == 200,
              let doc = try? XMLDocument(data: response.data)
        else { return nil }

        func text(_ xpath: String) -> String? {
            (try? doc.nodes(forXPath: xpath))?.lazy
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        func el(_ name: String) -> String { "*[local-name()='\(name)']" }
        let en = "[@*[local-name()='lang']='en']"
        let nl = "[@*[local-name()='lang']='nl']"
        let cho = "//\(el("ProvidedCHO"))"

        guard let resource = text("//\(el("object"))/@*[local-name()='resource']") else { return nil }
        // Turn the thumbnail URL into a full-size IIIF one:
        // https://iiif.micr.io/XXXXX/full/max/0/default.jpg
        let iiifBase = resource.contains("/full/") ? resource.components(separatedBy: "/full/")[0] : nil
        let imageURL = URL(string: iiifBase.map { "\($0)/full/max/0/default.jpg" } ?? resource)

        let title = text("\(cho)/\(el("title"))\(en)") ?? text("\(cho)/\(el("title"))\(nl)") ?? "untitled_\(numericID)"
        let artist = text("//\(el("Agent"))/\(el("prefLabel"))\(en)")
            ?? text("//\(el("Description"))/\(el("prefLabel"))\(en)")
            ?? "Unknown"
        let date = text("\(cho)/\(el("created"))\(en)") ?? ""
        let description = text("\(cho)/\(el("description"))\(en)") ?? text("\(cho)/\(el("description"))\(nl)") ?? ""

        return Artwork(
            museum: .rijks,
            id: numericID,
            objectID: numericID,
            title: title,
            artist: artist,
            date: date,
            imageURL: imageURL,
            sizeProbe: iiifBase.flatMap { URL(string: "\($0)/info.json") }.map { .iiifInfo($0) } ?? .unknown,
            sourceURL: lodID,  // redirects to the collection page in a browser
            isPublicDomain: true,
            searchText: "\(title) \(artist) \(description)".lowercased())
    }

    // MARK: Art Institute of Chicago

    private struct ChicagoPage: Decodable {
        struct Pagination: Decodable { let total: Int? }
        struct Thumbnail: Decodable {
            let width: Double?
            let height: Double?
        }
        struct Item: Decodable {
            let id: Int
            let title: String?
            let artist_title: String?
            let artist_display: String?
            let date_display: String?
            let image_id: String?
            let is_public_domain: Bool?
            let thumbnail: Thumbnail?
            let term_titles: [String]?
            let subject_titles: [String]?
            let classification_titles: [String]?
        }
        let pagination: Pagination?
        let data: [Item]?
    }

    /// Search results carry everything we need, including the full image size.
    private func searchChicago() async -> [Artwork] {
        // Their image server refuses "max"/"full" and widths over 3000.
        let maxWidth: CGFloat = 3000
        var artworks: [Artwork] = []
        var total = 0
        for page in 1...5 where !Task.isCancelled {
            var components = URLComponents(string: "https://api.artic.edu/api/v1/artworks/search")!
            components.queryItems = [
                URLQueryItem(name: "q", value: config.term),
                URLQueryItem(name: "query[bool][must][][term][is_public_domain]", value: "true"),
                URLQueryItem(name: "query[bool][must][][term][artwork_type_id]", value: "1"),  // Painting
                URLQueryItem(name: "fields", value: "id,title,artist_title,artist_display,date_display,image_id,"
                    + "is_public_domain,thumbnail,term_titles,subject_titles,classification_titles"),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ]
            do {
                let response = try await http.get(components.url!, accept: "application/json", headers: Museum.aic.headers)
                guard response.status == 200 else {
                    log("  [aic] Search failed (HTTP \(response.status))")
                    break
                }
                let results = try JSONDecoder().decode(ChicagoPage.self, from: response.data)
                let items = results.data ?? []
                total = results.pagination?.total ?? 0
                for item in items {
                    guard let imageID = item.image_id else { continue }
                    let size = item.thumbnail.flatMap { thumb in
                        thumb.width.flatMap { w in thumb.height.map { CGSize(width: w, height: $0) } }
                    }
                    let width = Int(min(size?.width ?? maxWidth, maxWidth))
                    let title = item.title.nonEmpty ?? "untitled_\(item.id)"
                    let artist = item.artist_title.nonEmpty ?? "Unknown"
                    let tags = (item.term_titles ?? []) + (item.subject_titles ?? []) + (item.classification_titles ?? [])
                    artworks.append(Artwork(
                        museum: .aic,
                        id: String(item.id),
                        objectID: item.id,
                        title: title,
                        artist: artist,
                        date: item.date_display ?? "",
                        imageURL: URL(string: "https://www.artic.edu/iiif/2/\(imageID)/full/\(width),/0/default.jpg"),
                        sizeProbe: size.map { .known($0) } ?? .unknown,
                        sourceURL: "https://www.artic.edu/artworks/\(item.id)",
                        isPublicDomain: item.is_public_domain ?? false,
                        searchText: ([title, item.artist_display ?? artist] + tags).joined(separator: " ").lowercased()))
                }
                if items.count < 100 || page * 100 >= total { break }
            } catch {
                log("  [aic] Search failed: \(error.localizedDescription)")
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        log("  [aic] \(total) results" + (artworks.count < total ? " (checking the first \(artworks.count))" : ""))
        return artworks
    }

    // MARK: Cleveland Museum of Art

    /// Uses JSONSerialization because some fields switch between strings and
    /// numbers (image widths come back as "3400").
    private func searchCleveland() async -> [Artwork] {
        var artworks: [Artwork] = []
        var total = 0
        for page in 0..<5 where !Task.isCancelled {
            var components = URLComponents(string: "https://openaccess-api.clevelandart.org/api/artworks/")!
            components.queryItems = [
                URLQueryItem(name: "q", value: config.term),
                URLQueryItem(name: "type", value: "Painting"),
                URLQueryItem(name: "has_image", value: "1"),
                URLQueryItem(name: "cc0", value: "1"),  // public domain only
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "skip", value: String(page * 100)),
            ]
            do {
                let response = try await http.get(components.url!, accept: "application/json", headers: Museum.cma.headers)
                guard response.status == 200,
                      let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
                else {
                    log("  [cma] Search failed (HTTP \(response.status))")
                    break
                }
                total = ((json["info"] as? [String: Any])?["total"] as? Int) ?? 0
                let items = json["data"] as? [[String: Any]] ?? []
                for item in items {
                    guard let id = item["id"] as? Int,
                          let print = (item["images"] as? [String: Any])?["print"] as? [String: Any],
                          let url = (print["url"] as? String).flatMap(URL.init(string:))
                    else { continue }
                    func number(_ value: Any?) -> Double? { (value as? Double) ?? (value as? String).flatMap(Double.init) }
                    let size = number(print["width"]).flatMap { w in number(print["height"]).map { CGSize(width: w, height: $0) } }
                    // "Richard Parkes Bonington (British, 1802–1828)" → "Richard Parkes Bonington"
                    let creator = ((item["creators"] as? [[String: Any]])?.first?["description"] as? String) ?? ""
                    let artist = creator.components(separatedBy: " (").first.nonEmpty ?? "Unknown"
                    let title = (item["title"] as? String).nonEmpty ?? "untitled_\(id)"
                    let text = [title, creator, item["description"] as? String ?? "", item["tombstone"] as? String ?? ""]
                    artworks.append(Artwork(
                        museum: .cma,
                        id: String(id),
                        objectID: id,
                        title: title,
                        artist: artist,
                        date: item["creation_date"] as? String ?? "",
                        imageURL: url,
                        sizeProbe: size.map { .known($0) } ?? .unknown,
                        sourceURL: item["url"] as? String ?? "",
                        isPublicDomain: (item["share_license_status"] as? String) == "CC0",
                        searchText: text.joined(separator: " ").lowercased()))
                }
                if items.count < 100 || (page + 1) * 100 >= total { break }
            } catch {
                log("  [cma] Search failed: \(error.localizedDescription)")
                break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        log("  [cma] \(total) results" + (artworks.count < total ? " (checking the first \(artworks.count))" : ""))
        return artworks
    }

    // MARK: Image size

    private func probeSize(_ probe: Artwork.SizeProbe) async -> CGSize? {
        switch probe {
        case .smallImage(let url):
            guard let response = try? await http.get(url, accept: "image/*"), response.status == 200 else { return nil }
            return Self.imageSize(response.data)
        case .iiifInfo(let url):
            struct Info: Decodable {
                let width: Double
                let height: Double
            }
            guard let response = try? await http.get(url, accept: "application/json"), response.status == 200,
                  let info = try? JSONDecoder().decode(Info.self, from: response.data)
            else { return nil }
            return CGSize(width: info.width, height: info.height)
        case .known(let size):
            return size
        case .unknown:
            return nil
        }
    }

    /// Reads dimensions from the image header without decoding it.
    static func imageSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? { flatMap { $0.isEmpty ? nil : $0 } }
}
