import AppKit
import Observation

@MainActor @Observable
final class DownloadStore {
    var items: [DownloadItem] = []
    var videoOptions = DownloadOptions() { didSet { saveOptions(videoOptions, key: "videoOptions") } }
    var audioOptions = DownloadOptions() { didSet { saveOptions(audioOptions, key: "audioOptions") } }
    var destination: URL
    var ytDLPPath: String { didSet { defaults.set(ytDLPPath, forKey: "ytDLPPath") } }
    var ffmpegPath: String { didSet { defaults.set(ffmpegPath, forKey: "ffmpegPath") } }
    var errorMessage: String?
    private let defaults: UserDefaults
    private var worker: Task<Void, Never>?
    private var runningProcess: DownloadProcess?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destination = defaults.url(forKey: "destination") ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Downloads/Savior", directoryHint: .isDirectory)
        ytDLPPath = defaults.string(forKey: "ytDLPPath") ?? ""
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        if let data = defaults.data(forKey: "videoOptions"), let value = try? JSONDecoder().decode(DownloadOptions.self, from: data) { videoOptions = value }
        if let data = defaults.data(forKey: "audioOptions"), let value = try? JSONDecoder().decode(DownloadOptions.self, from: data) { audioOptions = value }
        if let data = defaults.data(forKey: "downloadHistory"),
           let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            items = saved.map { item in
                var item = item
                if item.status.isActive {
                    item.status = .cancelled
                    item.detail = "Interrupted when Savior closed. Retry to continue."
                }
                return item
            }
        }
    }

    var ytDLP: URL? { executable(named: "yt-dlp", custom: ytDLPPath) }
    var ffmpeg: URL? { executable(named: "ffmpeg", custom: ffmpegPath) }
    var isReady: Bool { ytDLP != nil && ffmpeg != nil }
    var activeCount: Int { items.filter { $0.status.isActive }.count }

    private func executable(named name: String, custom: String) -> URL? {
        let candidates = custom.isEmpty
            ? [Bundle.main.resourceURL?.appending(path: name).path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"].compactMap { $0 }
            : [(custom as NSString).expandingTildeInPath]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    static func validatedURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func enqueue(link: String, kind: MediaKind) -> Bool {
        guard let url = Self.validatedURL(link) else {
            errorMessage = "Enter a valid http or https link to a video or playlist."
            return false
        }
        guard isReady else {
            errorMessage = "Savior needs yt-dlp and FFmpeg. Open Settings to connect your installed tools."
            return false
        }
        do { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        catch { errorMessage = "Couldn’t create the download folder: \(error.localizedDescription)"; return false }
        items.insert(DownloadItem(url: url.absoluteString, kind: kind,
                                  options: kind == .video ? videoOptions : audioOptions,
                                  destination: destination, title: url.host ?? "New download"), at: 0)
        save()
        startNext()
        return true
    }

    func cancel(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].status.isActive else { return }
        let wasRunning = items[index].status == .downloading
        items[index].status = .cancelled
        items[index].detail = "Cancelled"
        if wasRunning { runningProcess?.cancel() }
        save()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].status.isActive else { return }
        guard isReady else { errorMessage = "Connect yt-dlp and FFmpeg in Settings before retrying."; return }
        items[index].status = .queued
        items[index].progress = 0
        items[index].detail = "Waiting to download"
        items[index].files = []
        items[index].log = ""
        save()
        startNext()
    }

    func clearFinished() { items.removeAll { !$0.status.isActive }; save() }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Choose a download folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
            defaults.set(url, forKey: "destination")
        }
    }

    func reveal(_ item: DownloadItem) {
        let files = item.files.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if files.isEmpty { NSWorkspace.shared.open(item.destination) }
        else { NSWorkspace.shared.activateFileViewerSelecting(files) }
    }

    func openDestination() {
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            NSWorkspace.shared.open(destination)
        } catch { errorMessage = error.localizedDescription }
    }

    func stopAll() {
        runningProcess?.cancel()
        worker?.cancel()
    }

    private func startNext() {
        guard worker == nil, let item = items.last(where: { $0.status == .queued }), let executable = ytDLP else { return }
        let session = DownloadProcess()
        runningProcess = session
        update(item.id) { $0.status = .downloading; $0.detail = "Connecting…" }
        var arguments = item.options.arguments(for: item.kind, destination: item.destination)
        if let ffmpeg { arguments += ["--ffmpeg-location", ffmpeg.path] }
        arguments += ["--", item.url]
        worker = Task {
            do {
                for try await line in session.lines(executable: executable, arguments: arguments) {
                    consume(line, for: item.id)
                }
                update(item.id) {
                    guard $0.status == .downloading else { return }
                    $0.status = .completed; $0.progress = 1; $0.detail = "Saved to \($0.destination.lastPathComponent)"
                }
            } catch {
                update(item.id) {
                    guard $0.status == .downloading else { return }
                    $0.status = .failed
                    $0.detail = $0.log.components(separatedBy: "\n").last(where: { $0.contains("ERROR:") })
                        .map { $0.replacingOccurrences(of: "ERROR: ", with: "") } ?? error.localizedDescription
                }
            }
            save()
            worker = nil
            runningProcess = nil
            if !Task.isCancelled { startNext() }
        }
    }

    private func update(_ id: UUID, change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func consume(_ line: String, for id: UUID) {
        update(id) { item in
            guard item.status == .downloading else { return }
            item.log = String((item.log + line + "\n").suffix(24_000))
            if line.hasPrefix("SAVIOR_TITLE:"),
               let value = decodeString(String(line.dropFirst("SAVIOR_TITLE:".count))) {
                item.title = value
                item.detail = "Preparing download…"
            } else if line.hasPrefix("SAVIOR_FILE:"),
                      let value = decodeString(String(line.dropFirst("SAVIOR_FILE:".count))) {
                item.files.append(value)
            } else if line.hasPrefix("SAVIOR_PROGRESS:") {
                let parts = line.dropFirst("SAVIOR_PROGRESS:".count).components(separatedBy: "|")
                if let first = parts.first, let percent = Double(first.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
                    item.progress = min(max(percent / 100, 0), 1)
                }
                let speed = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                let eta = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                item.detail = item.progress >= 1 ? "Finishing and processing…" : [speed == "N/A" ? "" : speed, eta == "N/A" ? "" : "\(eta) remaining"].filter { !$0.isEmpty }.joined(separator: " · ")
            } else if line.hasPrefix("[Merger]") || line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[VideoRemuxer]") {
                item.detail = "Processing \(item.kind.title.lowercased())…"
            }
        }
    }

    private func decodeString(_ value: String) -> String? {
        try? JSONDecoder().decode(String.self, from: Data(value.utf8))
    }

    private func saveOptions(_ options: DownloadOptions, key: String) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: key) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: "downloadHistory") }
    }
}
