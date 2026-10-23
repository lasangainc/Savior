import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var store: DownloadStore
    @State private var copied = false

    var body: some View {
        Form {
            Section("Download tools") {
                toolRow("yt-dlp", path: $store.ytDLPPath, resolved: store.ytDLP)
                toolRow("FFmpeg", path: $store.ffmpegPath, resolved: store.ffmpeg)
                HStack {
                    Text("brew install yt-dlp ffmpeg")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install yt-dlp ffmpeg", forType: .string)
                        copied = true
                    }
                }
                Link("Installation guide", destination: URL(string: "https://github.com/yt-dlp/yt-dlp#installation")!)
            }
            Section("Storage") {
                LabeledContent("Download folder") {
                    Button(store.destination.lastPathComponent + "…") { store.chooseDestination() }
                        .help(store.destination.path)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 390)
    }

    private func toolRow(_ name: String, path: Binding<String>, resolved: URL?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(name, systemImage: resolved == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(resolved == nil ? .orange : .green)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.title = "Choose \(name) executable"
                    panel.canChooseDirectories = false
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
                if !path.wrappedValue.isEmpty {
                    Button("Reset") { path.wrappedValue = "" }
                }
            }
            Text(resolved?.path ?? "Not found — choose an executable or install with Homebrew")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}
