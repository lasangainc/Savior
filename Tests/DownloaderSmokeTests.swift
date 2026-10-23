import AppKit

/// Run with Tests/run-smoke-tests.sh. Uses isolated preferences and temporary files.
@main
struct DownloaderSmokeTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SaviorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "SaviorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let fixture = root.appending(path: "yt-dlp")
        let script = """
        #!/bin/zsh
        url="${@[-1]}"
        if [[ "$url" == *slow* ]]; then
            print 'SAVIOR_TITLE:"Slow download"'
            exec /bin/sleep 20
        fi
        if [[ "$url" == *fail* ]]; then
            print -u2 'ERROR: Intentional fixture failure'
            exit 7
        fi
        print 'SAVIOR_TITLE:"A title with ünicode"'
        print 'SAVIOR_PROGRESS: 42.0%|2.0MiB/s|00:01'
        print 'SAVIOR_FILE:"/tmp/Savior test output.mp4"'
        """
        try script.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        defaults.set(fixture.path, forKey: "ytDLPPath")
        defaults.set("/usr/bin/true", forKey: "ffmpegPath")
        defaults.set(root.appending(path: "output"), forKey: "destination")
        let store = DownloadStore(defaults: defaults)

        precondition(DownloadStore.validatedURL("file:///etc/passwd") == nil)
        precondition(DownloadStore.validatedURL("not a link") == nil)
        precondition(DownloadStore.validatedURL(" https://example.org/watch?v=1 ") != nil)
        precondition(!store.enqueue(link: "bad", kind: .video))
        store.errorMessage = nil
        precondition(store.enqueue(link: "https://example.org/video", kind: .video))
        precondition(store.enqueue(link: "https://example.org/audio", kind: .audio))
        try await waitUntil { store.activeCount == 0 }
        precondition(store.items.allSatisfy { $0.status == .completed })
        precondition(store.items.allSatisfy { $0.title == "A title with ünicode" })
        precondition(store.items.allSatisfy { $0.files == ["/tmp/Savior test output.mp4"] })
        precondition(store.items.allSatisfy { $0.log.contains("42.0%") && $0.progress == 1 })
        print("PASS: URL validation, serial video/audio queue, UTF-8 output, progress, final paths")

        precondition(store.enqueue(link: "https://example.org/fail", kind: .video))
        try await waitUntil { store.activeCount == 0 }
        precondition(store.items.first?.status == .failed)
        precondition(store.items.first?.detail == "Intentional fixture failure")
        print("PASS: nonzero exit and stderr surfaced as an actionable error")

        precondition(store.enqueue(link: "https://example.org/slow", kind: .audio))
        let slow = store.items.first!.id
        precondition(store.enqueue(link: "https://example.org/queued", kind: .video))
        let queued = store.items.first!.id
        store.cancel(queued)
        try await Task.sleep(for: .milliseconds(150))
        store.cancel(slow)
        precondition(store.enqueue(link: "https://example.org/after-cancel", kind: .video))
        try await waitUntil { store.activeCount == 0 }
        precondition(store.items.first?.status == .completed)
        precondition(store.items.first(where: { $0.id == slow })?.status == .cancelled)
        precondition(store.items.first(where: { $0.id == queued })?.status == .cancelled)
        store.retry(queued)
        try await waitUntil { store.activeCount == 0 }
        precondition(store.items.first(where: { $0.id == queued })?.status == .completed)
        print("PASS: running/queued cancellation, queue continuation, retry")

        store.videoOptions.resolution = "720p"
        store.audioOptions.audioFormat = "FLAC"
        let restored = DownloadStore(defaults: defaults)
        precondition(restored.items.count == store.items.count)
        precondition(restored.videoOptions.resolution == "720p" && restored.audioOptions.audioFormat == "FLAC")
        store.clearFinished()
        precondition(store.items.isEmpty)
        print("PASS: history and per-page preferences persist; clearing finished downloads")

        let session = DownloadProcess()
        var version = ""
        for try await line in session.lines(executable: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"), arguments: ["--version"]) { version += line }
        precondition(!version.isEmpty)
        print("PASS: real installed yt-dlp launches (\(version))")

        if CommandLine.arguments.count > 1 {
            let destination = root.appending(path: "real-output")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for kind in MediaKind.allCases {
                let options = DownloadOptions()
                var args = options.arguments(for: kind, destination: destination)
                args += ["--ffmpeg-location", "/opt/homebrew/bin/ffmpeg", "--", CommandLine.arguments[1]]
                var files: [String] = []
                for try await line in DownloadProcess().lines(executable: URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"), arguments: args) {
                    FileHandle.standardError.write(Data((line + "\n").utf8))
                    if line.hasPrefix("SAVIOR_FILE:") {
                        let value = Data(line.dropFirst("SAVIOR_FILE:".count).utf8)
                        files.append(try JSONDecoder().decode(String.self, from: value))
                    }
                }
                precondition(!files.isEmpty && files.allSatisfy { FileManager.default.fileExists(atPath: $0) })
                let expectedExtension = kind == .video ? "mp4" : "m4a"
                precondition(files.allSatisfy { URL(fileURLWithPath: $0).pathExtension == expectedExtension })
                print("PASS: real yt-dlp \(kind.title.lowercased()) download and FFmpeg output (\(expectedExtension))")
            }
        }
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Timed out waiting for download state")
    }
}
