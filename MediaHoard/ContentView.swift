import SwiftUI
import AVKit
import UIKit

struct ContentView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @State private var input = ""
    @State private var title = ""
    @State private var choices: [MediaChoice] = []
    @State private var selectedChoice = ""
    @State private var resolving = false
    @State private var localError: String?
    @State private var playingFile: URL?
    @State private var sharingCopyURL: URL?
    @State private var sharingCopyDirectory: URL?
    @State private var isShareSheetPresented = false

    private let resolver = MediaSourceResolver()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            TextField("Paste a media or YouTube URL", text: $input)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .accessibilityLabel("Media URL")
                                .accessibilityIdentifier("mediaURLField")
                            if !input.isEmpty {
                                Button {
                                    input = ""
                                    choices = []
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityLabel("Clear URL")
                            }
                            Button("Paste", systemImage: "doc.on.clipboard") {
                                pasteFromClipboard()
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("Paste URL from clipboard")
                        }
                        Button {
                            Task { await resolve() }
                        } label: {
                            HStack {
                                if resolving { ProgressView().tint(.white) }
                                Text(resolving ? "Checking link…" : "Check link")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(resolving || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Add media")
                } footer: {
                    Text("Only download content you have permission to save. YouTube availability depends on the video and service changes.")
                }

                if !choices.isEmpty {
                    Section(title.isEmpty ? "Available formats" : title) {
                        ForEach(choices) { choice in
                            Button {
                                selectedChoice = choice.id
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(choice.title).foregroundStyle(.primary)
                                        Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                                        Text(choice.expectedSizeBytes.map { "Size · \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))" } ?? "Size unavailable")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedChoice == choice.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                        Button("Download selected") {
                            guard let choice = choices.first(where: { $0.id == selectedChoice }) else { return }
                            downloads.start(choice, title: title)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(downloads.activeName != nil)
                    }
                }

                if let name = downloads.activeName {
                    Section("Downloading") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(name).lineLimit(1)
                            if let progress = downloads.progress {
                                ProgressView(value: progress)
                                Text("\(Int(progress * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                            }
                            if let speed = downloads.speedBytesPerSecond {
                                Text("Speed · \(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/s")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Cancel download", role: .destructive) { downloads.cancel() }
                        }
                    }
                }

                Section("Library") {
                    if downloads.files.isEmpty {
                        Label("Completed downloads will appear here.", systemImage: "square.and.arrow.down")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(downloads.files) { file in
                            HStack(spacing: 12) {
                                Button {
                                    playingFile = file.url
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(file.name).foregroundStyle(.primary).lineLimit(1)
                                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Button {
                                    prepareShare(for: file)
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .accessibilityLabel("Share \(file.name)")
                                Button(role: .destructive) { downloads.delete(file) } label: {
                                    Image(systemName: "trash")
                                }
                                .accessibilityLabel("Delete \(file.name)")
                            }
                        }
                    }
                }
            }
            .navigationTitle("MediaHoard")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { downloads.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh downloads")
                }
            }
            .alert("Something went wrong", isPresented: errorPresented) {
                Button("OK", role: .cancel) { localError = nil; downloads.errorMessage = nil }
            } message: {
                Text(localError ?? downloads.errorMessage ?? "Please try again.")
            }
            .sheet(isPresented: Binding(get: { playingFile != nil }, set: { if !$0 { playingFile = nil } })) {
                if let playingFile {
                    VideoPlayer(player: AVPlayer(url: playingFile))
                        .ignoresSafeArea()
                }
            }
            .sheet(isPresented: $isShareSheetPresented, onDismiss: cleanupShareCopy) {
                if let sharingCopyURL {
                    FileShareSheet(fileURL: sharingCopyURL)
                }
            }
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { localError != nil || downloads.errorMessage != nil }, set: { if !$0 { localError = nil; downloads.errorMessage = nil } })
    }


    private func pasteFromClipboard() {
        if let value = UIPasteboard.general.string ?? UIPasteboard.general.url?.absoluteString {
            input = value.trimmingCharacters(in: .whitespacesAndNewlines)
            choices = []
        } else {
            localError = "The clipboard does not contain text or a link."
        }
    }

    private func prepareShare(for file: LibraryFile) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaHoardShare-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copyURL = directory.appendingPathComponent(file.name)
            try FileManager.default.copyItem(at: file.url, to: copyURL)
            sharingCopyDirectory = directory
            sharingCopyURL = copyURL
            isShareSheetPresented = true
        } catch {
            localError = "Could not prepare the file for sharing: \(error.localizedDescription)"
        }
    }

    private func cleanupShareCopy() {
        if let sharingCopyDirectory { try? FileManager.default.removeItem(at: sharingCopyDirectory) }
        sharingCopyURL = nil
        sharingCopyDirectory = nil
    }

    @MainActor
    private func resolve() async {
        resolving = true
        localError = nil
        choices = []
        defer { resolving = false }
        do {
            let result = try await resolver.choices(for: input)
            title = result.0
            choices = result.1
            selectedChoice = result.1.first?.id ?? ""
        } catch {
            localError = error.localizedDescription
        }
    }
}
