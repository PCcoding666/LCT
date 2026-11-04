import SwiftUI

@MainActor
struct LocalTranslationControls: View {
    @Binding var enabled: Bool
    @ObservedObject private var service = EmbeddedTranslationService.shared
    @State private var actionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Translate Captions", isOn: $enabled)
                .disabled(!enabled && !service.isModelDownloaded)
                .onChange(of: enabled) { _, value in
                    guard value else { return }
                    prepareModel()
                }
            Text("Original captions work with translation off, downloading, or unavailable.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Model", value: EmbeddedTranslationService.modelName)
            Text("Allow at least 1.2 GB of free storage. Apple silicon uses Metal; Intel uses the CPU. Translation speed depends on this Mac and caption length.")
                .font(.caption).foregroundStyle(.secondary)
            Text("A one-time 1.12 GB download. Runs inside LCT on this Mac; no account or separate service.")
                .font(.caption).foregroundStyle(.secondary)

            switch service.state {
            case .notDownloaded:
                downloadButton("Download Translation Model")
            case .downloading:
                ProgressView(value: service.downloadProgress)
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: service.downloadedBytes, countStyle: .file))
                        .font(.caption).monospacedDigit()
                    Spacer()
                    Button("Cancel Download") { service.cancelDownload() }
                }
            case .verifying:
                HStack { ProgressView().controlSize(.small); Text("Verifying model…") }
            case .downloaded:
                Text("Model downloaded. Turn on Translate Captions when you are ready.")
                    .font(.caption).foregroundStyle(.secondary)
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Preparing translation…") }
            case .ready:
                Label("Ready for offline translation", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange)
                if service.isModelDownloaded {
                    Button("Retry Loading") { prepareModel() }
                    downloadButton("Download Model Again")
                } else {
                    downloadButton("Retry Download")
                }
            }
            if let actionError {
                Text(actionError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func downloadButton(_ title: String) -> some View {
        Button(title) {
            actionError = nil
            Task {
                do {
                    try await service.downloadModel()
                    if enabled { try await service.loadModel() }
                }
                catch is CancellationError { }
                catch { actionError = error.localizedDescription }
            }
        }
    }

    private func prepareModel() {
        actionError = nil
        Task {
            do { try await service.loadModel() }
            catch is CancellationError { }
            catch { actionError = error.localizedDescription }
        }
    }
}
