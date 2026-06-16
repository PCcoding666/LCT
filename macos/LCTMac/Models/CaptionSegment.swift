import Foundation
import SwiftUI

/// State of a caption segment
enum SegmentState: String, Codable, Equatable {
    case listening = "listening"     // Currently receiving audio/interim results
    case translating = "translating" // ASR is stable, waiting for translation
    case stable = "stable"           // Translation complete
    case error = "error"             // Error during processing
}

/// Represents a single spoken sentence/segment and its translation lifecycle
struct CaptionSegment: Identifiable, Codable, Equatable {
    let id: UUID
    var timestamp: Date
    
    // ASR Source
    var interimSource: String = ""
    var stableSource: String = ""
    
    // Translation
    var draftTranslation: String = ""
    var finalTranslation: String = ""
    
    var state: SegmentState = .listening
    var latencyMs: Int = 0
    var errorMessage: String? = nil
    
    init(id: UUID = UUID(), timestamp: Date = Date()) {
        self.id = id
        self.timestamp = timestamp
    }
    
    /// Display text for the original source
    var displaySource: String {
        return stableSource.isEmpty ? interimSource : stableSource
    }
    
    /// Display text for the translation
    var displayTranslation: String {
        return finalTranslation.isEmpty ? draftTranslation : finalTranslation
    }
    
    /// True if there is no meaningful text to display
    var isEmpty: Bool {
        return displaySource.isEmpty && displayTranslation.isEmpty
    }
}
