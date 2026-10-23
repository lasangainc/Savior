import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var store: DownloadStore
    @State private var selection: MediaKind? = .video
    @State private var videoLink = ""
    @State private var audioLink = ""
    @State private var inspectedItem: DownloadItem?
    @FocusState private var linkFocused: Bool

    private var kind: MediaKind { selection ?? .video }
    private var link: Binding<String> { kind == .video ? $videoLink : $audioLink }
    private var options: Binding<DownloadOptions> { kind == .video ? $store.videoOptions : $store.audioOptions }
    private var downloads: [DownloadItem] { store.items.filter { $0.kind == kind } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(MediaKind.allCases) { media in
                    Label(media.title, systemImage: media.symbol)
                        .badge(store.items.filter { $0.kind == media && $0.status.isActive }.count)
                        .tag(media)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            GlassEffectContainer {
                Form {
                    Section("Link") {
                        HStack {
                            TextField("URL", text: link)
                                .textFieldStyle(.roundedBorder)
                                .focused($linkFocused)
                                .onSubmit(startDownload)
                                .accessibilityLabel("\(kind.title) URL")
                            Button("Paste") {
                                if let value = NSPasteboard.general.string(forType: .string) {
                                    link.wrappedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.capsule)
                        }
                    }

                    Section("Options") {
                        if kind == .video {
                            Picker("Resolution", selection: options.resolution) {
                                ForEach(["Best available", "2160p", "1440p", "1080p", "720p", "480p"], id: \.self) { Text($0) }
                            }
                            Picker("Format", selection: options.container) {
                                ForEach(["Automatic", "MP4", "MKV"], id: \.self) { Text($0) }
                            }
                            Toggle("English subtitles", isOn: options.subtitles)
                        } else {
                            Picker("Format", selection: options.audioFormat) {
                                ForEach(["M4A", "MP3", "FLAC", "WAV", "OPUS"], id: \.self) { Text($0) }
                            }
                            Picker("Quality", selection: options.audioQuality) {
                                Text("Best available").tag("Best")
                                Text("320 kbps").tag("320K")
                                Text("256 kbps").tag("256K")
                                Text("192 kbps").tag("192K")
                            }
                            .disabled(["FLAC", "WAV"].contains(options.wrappedValue.audioFormat))
                        }
                        Toggle("Metadata", isOn: options.metadata)
                        Toggle("Entire playlist", isOn: options.playlist)
                    }

                    Section {
                        LabeledContent("Save to") {
                            Button(store.destination.lastPathComponent + "…") { store.chooseDestination() }
                                .help(store.destination.path)
                        }
                        HStack {
                            Spacer()
                            Button("Download \(kind.title)", action: startDownload)
                                .buttonStyle(.glassProminent)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                                .disabled(DownloadStore.validatedURL(link.wrappedValue) == nil || !store.isReady)
                                .keyboardShortcut(.return, modifiers: .command)
                        }
                    }

                    if !store.isReady {
                        Section {
                            HStack {
                                Text("yt-dlp or FFmpeg not found")
                                Spacer()
                                SettingsLink { Text("Settings…") }
                            }
                        }
                    }

                    Section {
                        if downloads.isEmpty {
                            Text("No downloads").foregroundStyle(.secondary)
                        } else {
                            ForEach(downloads) { item in
                                DownloadRow(item: item, cancel: { store.cancel(item.id) }, retry: { store.retry(item.id) }, reveal: { store.reveal(item) }, inspect: { inspectedItem = item })
                            }
                        }
                    } header: {
                        HStack {
                            Text("Downloads")
                            Spacer()
                            if store.items.contains(where: { !$0.status.isActive }) {
                                Button("Clear finished") { store.clearFinished() }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .navigationTitle(kind.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Open Download Folder", systemImage: "folder") { store.openDestination() }
                        .help("Open download folder (⇧⌘O)")
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .help("Settings")
                }
            }
        }
        .frame(minWidth: 740, minHeight: 600)
        .alert("Couldn’t start download", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(item: $inspectedItem) { item in
            DownloadLogView(item: store.items.first(where: { $0.id == item.id }) ?? item)
        }
        .onChange(of: selection) { _, _ in linkFocused = false }
    }

    private func startDownload() {
        if store.enqueue(link: link.wrappedValue, kind: kind) {
            link.wrappedValue = ""
            linkFocused = false
        }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let cancel: () -> Void
    let retry: () -> Void
    let reveal: () -> Void
    let inspect: () -> Void

    private var color: Color {
        switch item.status {
        case .completed: .green
        case .failed: .orange
        case .cancelled: .secondary
        default: .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.status == .completed ? "checkmark" : item.kind.symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer()
                    Text(item.status.title).font(.caption2).foregroundStyle(color)
                }
                if item.status == .downloading {
                    ProgressView(value: item.progress).tint(.accentColor)
                        .accessibilityLabel("Download progress")
                }
                Text(item.detail.isEmpty ? "Downloading…" : item.detail)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text(item.options.summary(for: item.kind))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Group {
                if item.status.isActive {
                    Button("Cancel", systemImage: "xmark.circle", action: cancel)
                } else if item.status == .completed {
                    Button("Show in Finder", systemImage: "folder", action: reveal)
                } else {
                    Button("Retry", systemImage: "arrow.clockwise", action: retry)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help(item.status.isActive ? "Cancel download" : item.status == .completed ? "Show in Finder" : "Retry download")
        }
        .contextMenu {
            Button("View Download Log", systemImage: "text.alignleft", action: inspect)
            Button("Copy Source Link", systemImage: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            if item.status == .completed { Button("Show in Finder", action: reveal) }
        }
    }
}

private struct DownloadLogView: View {
    let item: DownloadItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Log").font(.title2.bold())
                    Text(item.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(item.log.isEmpty ? "No output yet." : item.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .padding(24)
        .frame(width: 640, height: 440)
    }
}

#Preview {
    ContentView(store: DownloadStore())
}
