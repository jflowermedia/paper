import SwiftUI

/// "All", or one museum (matching Museum's raw values).
enum MuseumChoice: String, CaseIterable, Identifiable {
    case all, met, rijks, aic, cma

    var id: Self { self }
    var label: String { Museum(rawValue: rawValue)?.shortLabel ?? "All" }
    var museums: [Museum] { Museum(rawValue: rawValue).map { [$0] } ?? Museum.allCases }
}

@MainActor
final class DownloadModel: ObservableObject {
    struct LogLine: Identifiable {
        let id: Int
        let text: String
    }

    @Published var term = ""
    @Published var museums = MuseumChoice.all
    @Published var landscapeOnly = true
    @Published var maxImages = 300
    @Published private(set) var log: [LogLine] = []
    @Published private(set) var running = false
    @Published private(set) var saved = 0
    private var nextLineID = 0
    private var task: Task<Void, Never>?

    var status: String {
        if running { return "\(saved) saved so far" }
        return log.isEmpty ? "" : "Finished: \(saved) saved"
    }

    func start() {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !running else { return }
        log = []
        saved = 0
        running = true
        let config = DownloadConfig(
            term: term, museums: museums.museums, landscapeOnly: landscapeOnly, targetCount: maxImages)
        let downloader = Downloader(
            config: config,
            log: { [weak self] line in DispatchQueue.main.async { self?.append(line) } },
            progress: { [weak self] count in DispatchQueue.main.async { self?.saved = count } })
        // run() isn't main-actor isolated, so the work happens off the main thread.
        task = Task {
            await downloader.run()
            running = false
        }
    }

    func stop() {
        task?.cancel()
    }

    private func append(_ text: String) {
        log.append(LogLine(id: nextLineID, text: text))
        nextLineID += 1
        if log.count > 2_000 { log.removeFirst(log.count - 2_000) }
    }
}

struct DownloadView: View {
    @EnvironmentObject private var model: DownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                TextField("Search", text: $model.term, prompt: Text("Artist, subject or style, e.g. Venice"))
                    .onSubmit { model.start() }
                Picker("Museums", selection: $model.museums) {
                    ForEach(MuseumChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Landscape orientation only", isOn: $model.landscapeOnly)
                Stepper("Up to \(model.maxImages) images", value: $model.maxImages, in: 10...300, step: 10)
            }
            .disabled(model.running)

            HStack {
                if model.running { ProgressView().controlSize(.small) }
                Text(model.status).foregroundStyle(.secondary)
                Spacer()
                if model.running {
                    Button("Stop") { model.stop() }
                } else {
                    Button("Download") { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log) { line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .onChange(of: model.log.last?.id) {
                    if let id = model.log.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .frame(height: 280)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
        .padding(18)
        .frame(width: 560)
    }
}
