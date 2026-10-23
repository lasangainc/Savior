import Foundation

enum MediaKind: String, CaseIterable, Codable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var title: String { self == .video ? "Video" : "Audio" }
    var symbol: String { self == .video ? "play.rectangle" : "waveform" }
}

struct DownloadOptions: Codable, Equatable {
    var resolution = "1080p"
    var container = "MP4"
    var audioFormat = "M4A"
    var audioQuality = "Best"
    var subtitles = false
    var metadata = true
    var playlist = false

    func summary(for kind: MediaKind) -> String {
        if kind == .video { return "\(container) · \(resolution)" }
        let quality = ["FLAC", "WAV"].contains(audioFormat) ? "Source quality" : audioQuality
        return "\(audioFormat) · \(quality)"
    }

    func arguments(for kind: MediaKind, destination: URL) -> [String] {
        var args = ["--ignore-config", "--no-colors", "--newline", "--progress", "--no-simulate",
                    "--progress-template", "download:SAVIOR_PROGRESS:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
                    "--print", "before_dl:SAVIOR_TITLE:%(title)j",
                    "--print", "after_move:SAVIOR_FILE:%(filepath)j",
                    "--paths", destination.path, "--output", "%(title).180B [%(id)s].%(ext)s",
                    playlist ? "--yes-playlist" : "--no-playlist"]
        if metadata { args += ["--embed-metadata"] }
        if kind == .video {
            if let height = Int(resolution.replacingOccurrences(of: "p", with: "")) {
                args += ["--format", "bv*[height<=?\(height)]+ba/b[height<=?\(height)]"]
            } else {
                args += ["--format", "bv*+ba/b"]
            }
            if container != "Automatic" {
                args += ["--merge-output-format", container.lowercased(), "--remux-video", container.lowercased()]
                if container == "MP4" { args += ["--format-sort", "vcodec:h264,acodec:aac"] }
            }
            if subtitles { args += ["--write-subs", "--sub-langs", "en.*,en", "--embed-subs"] }
        } else {
            args += ["--format", "bestaudio/best", "--extract-audio", "--audio-format", audioFormat.lowercased(),
                     "--audio-quality", audioQuality == "Best" ? "0" : audioQuality]
        }
        return args
    }
}

enum DownloadStatus: String, Codable {
    case queued, downloading, completed, failed, cancelled
    var title: String { rawValue.capitalized }
    var isActive: Bool { self == .queued || self == .downloading }
}

struct DownloadItem: Identifiable, Codable {
    var id = UUID()
    let url: String
    let kind: MediaKind
    let options: DownloadOptions
    let destination: URL
    var title: String
    var status: DownloadStatus = .queued
    var progress = 0.0
    var detail = "Waiting to download"
    var files: [String] = []
    var log = ""
    var createdAt = Date()
}

/// A subprocess with a merged output stream. No shell interprets URLs or user input.
nonisolated final class DownloadProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func lines(executable: URL, arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached { [self] in
                let task = Process()
                let pipe = Pipe()
                task.executableURL = executable
                task.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                environment["PYTHONUNBUFFERED"] = "1"
                task.environment = environment
                task.standardOutput = pipe
                task.standardError = pipe
                task.standardInput = FileHandle.nullDevice
                do {
                    try launch(task)
                    // Close the parent's write end so EOF arrives even after a launch failure or cancellation.
                    try? pipe.fileHandleForWriting.close()
                    var pending = Data()
                    while true {
                        let chunk = pipe.fileHandleForReading.availableData
                        if chunk.isEmpty { break }
                        pending.append(chunk)
                        while let newline = pending.firstIndex(of: 10) {
                            continuation.yield(String(decoding: pending[..<newline], as: UTF8.self))
                            pending.removeSubrange(...newline)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                    task.waitUntilExit()
                    if task.terminationStatus != 0 {
                        throw NSError(domain: "Savior.Downloader", code: Int(task.terminationStatus),
                                      userInfo: [NSLocalizedDescriptionKey: "yt-dlp exited with code \(task.terminationStatus)."])
                    }
                    continuation.finish()
                } catch {
                    try? pipe.fileHandleForWriting.close()
                    continuation.finish(throwing: error)
                }
                try? pipe.fileHandleForReading.close()
            }
            continuation.onTermination = { @Sendable reason in
                if case .cancelled = reason { self.cancel(); worker.cancel() }
            }
        }
    }

    private func launch(_ task: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        process = task
        try task.run()
    }
}
