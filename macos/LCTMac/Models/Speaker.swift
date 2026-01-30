import Foundation
import SwiftUI

/// Represents a speaker identified during diarization
struct Speaker: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let label: String
    var color: SpeakerColor
    
    init(id: String = UUID().uuidString, label: String, color: SpeakerColor = .blue) {
        self.id = id
        self.label = label
        self.color = color
    }
    
    /// Create speaker from pyannote label (e.g., "SPEAKER_00")
    static func from(pyannoteLabel: String) -> Speaker {
        let speakerNumber = pyannoteLabel.replacingOccurrences(of: "SPEAKER_", with: "")
        let displayLabel = "Speaker \(Int(speakerNumber) ?? 0 + 1)"
        let colorIndex = (Int(speakerNumber) ?? 0) % SpeakerColor.allCases.count
        return Speaker(
            id: pyannoteLabel,
            label: displayLabel,
            color: SpeakerColor.allCases[colorIndex]
        )
    }
}

/// Color options for speaker identification
enum SpeakerColor: String, Codable, CaseIterable, Identifiable {
    case blue, green, orange, purple, red, teal, pink, yellow
    
    var id: String { rawValue }
    
    var color: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        case .red: return .red
        case .teal: return .teal
        case .pink: return .pink
        case .yellow: return .yellow
        }
    }
}

/// Manages speakers in a transcription session
class SpeakerManager: ObservableObject {
    @Published private(set) var speakers: [String: Speaker] = [:]
    
    /// Get or create a speaker for the given label
    func speaker(for label: String) -> Speaker {
        if let existing = speakers[label] {
            return existing
        }
        let newSpeaker = Speaker.from(pyannoteLabel: label)
        speakers[label] = newSpeaker
        return newSpeaker
    }
    
    /// Update speaker label
    func updateLabel(for id: String, newLabel: String) {
        if var speaker = speakers[id] {
            speakers[id] = Speaker(id: id, label: newLabel, color: speaker.color)
        }
    }
    
    /// Update speaker color
    func updateColor(for id: String, newColor: SpeakerColor) {
        if let speaker = speakers[id] {
            speakers[id] = Speaker(id: id, label: speaker.label, color: newColor)
        }
    }
    
    /// Clear all speakers
    func clear() {
        speakers.removeAll()
    }
    
    /// Get all speakers sorted by label
    var sortedSpeakers: [Speaker] {
        speakers.values.sorted { $0.label < $1.label }
    }
}
