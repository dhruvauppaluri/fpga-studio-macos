import Foundation

/// A presentation preset. Profiles never gate project or hardware capabilities.
public enum ExperienceProfile: String, CaseIterable, Codable, Identifiable, Sendable {
    case beginner
    case hobbyist
    case professional

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .beginner: "Beginner"
        case .hobbyist: "Hobbyist"
        case .professional: "Professional"
        }
    }

    public var icon: String {
        switch self {
        case .beginner: "graduationcap"
        case .hobbyist: "wrench.and.screwdriver"
        case .professional: "waveform.path.ecg.rectangle"
        }
    }

    public var summary: String {
        switch self {
        case .beginner: "Guided steps and plain-language explanations."
        case .hobbyist: "A balanced workspace for building and experimenting."
        case .professional: "Dense technical detail with advanced controls visible."
        }
    }

    public var showsLearningGuideByDefault: Bool { self == .beginner }
    public var showsAdvancedControlsByDefault: Bool { self == .professional }

    public var recommendedTemplate: ProjectTemplate {
        self == .beginner ? .blinky : .blank
    }
}
