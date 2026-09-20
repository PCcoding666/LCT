import Foundation

/// Origin of a captured audio stream.
///
/// The capture pipeline can run two lanes concurrently (system audio via
/// ScreenCaptureKit + microphone via AVAudioEngine). Every buffer,
/// transcription result, and finalized segment is tagged with its source so
/// the two lanes stay distinguishable end-to-end.
enum AudioSource: String, Codable, Equatable, CaseIterable {
    case system      // What the Mac plays (ScreenCaptureKit .audio)
    case microphone  // Ambient / user voice (AVAudioEngine input)

    /// Short label shown next to transcript segments
    var label: String {
        switch self {
        case .system: return "SYS"
        case .microphone: return "MIC"
        }
    }

    /// SF Symbol used in the UI badge
    var icon: String {
        switch self {
        case .system: return "speaker.wave.2"
        case .microphone: return "mic"
        }
    }
}
