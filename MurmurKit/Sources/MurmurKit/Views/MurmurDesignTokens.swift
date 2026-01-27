import SwiftUI

public enum MurmurTokens {

    // MARK: - Brand Colors (extracted from logo)
    //
    // The logo is a glassy, flowing "M" in soft cornflower blue with teal
    // highlights and lavender accents.  No red anywhere in the palette.

    /// Primary brand — soft cornflower blue, the logo's dominant tone.
    public static let accent = Color(red: 0.42, green: 0.61, blue: 0.94)

    /// Teal highlight — the lighter edges of the logo.
    public static let teal = Color(red: 0.49, green: 0.82, blue: 0.78)

    /// Lavender accent — inner curves of the logo.
    public static let lavender = Color(red: 0.55, green: 0.48, blue: 0.77)

    /// Recording state uses the same brand blue — no red.
    public static let recordingColor = Color(red: 0.42, green: 0.61, blue: 0.94)

    /// Waveform bars use the brand blue.
    public static let waveformTint = Color(red: 0.42, green: 0.61, blue: 0.94)

    /// Button fill — same brand blue in every state. Icon communicates state.
    public static let recordButtonIdleFill = Color(red: 0.42, green: 0.61, blue: 0.94)
    public static let recordButtonActiveFill = Color(red: 0.42, green: 0.61, blue: 0.94)

    // MARK: - Typography (Dynamic Type)

    public enum Typography {
        public static let rowTitle: Font = .body
        public static let rowMeta: Font = .caption2
        public static let emptyTitle: Font = .subheadline
        public static let emptySubtitle: Font = .caption
        public static let statusLabel: Font = .subheadline.weight(.medium)
        public static let sectionHeader: Font = .headline
    }

    // MARK: - Sizing (platform-adaptive)

    public enum Sizing {

        // Waveform
        #if os(watchOS)
        public static let waveformBarCount: Int = 15
        public static let waveformBarWidth: CGFloat = 2.5
        public static let waveformBarSpacing: CGFloat = 1.5
        public static let waveformMaxHeight: CGFloat = 28
        public static let waveformMinBarHeight: CGFloat = 2
        #elseif os(iOS)
        public static let waveformBarCount: Int = 30
        public static let waveformBarWidth: CGFloat = 3
        public static let waveformBarSpacing: CGFloat = 2
        public static let waveformMaxHeight: CGFloat = 44
        public static let waveformMinBarHeight: CGFloat = 3
        #else
        public static let waveformBarCount: Int = 40
        public static let waveformBarWidth: CGFloat = 2.5
        public static let waveformBarSpacing: CGFloat = 1.5
        public static let waveformMaxHeight: CGFloat = 48
        public static let waveformMinBarHeight: CGFloat = 2
        #endif

        // Record Button
        #if os(watchOS)
        public static let recordButtonOuter: CGFloat = 50
        public static let recordButtonInner: CGFloat = 40
        public static let recordButtonIconFont: Font = .title3
        #elseif os(iOS)
        public static let recordButtonOuter: CGFloat = 66
        public static let recordButtonInner: CGFloat = 52
        public static let recordButtonIconFont: Font = .title2
        #else
        public static let recordButtonOuter: CGFloat = 64
        public static let recordButtonInner: CGFloat = 48
        public static let recordButtonIconFont: Font = .title3
        #endif

        // Empty State Icon
        #if os(watchOS)
        public static let emptyIconSize: CGFloat = 32
        #elseif os(iOS)
        public static let emptyIconSize: CGFloat = 52
        #else
        public static let emptyIconSize: CGFloat = 44
        #endif
    }

    // MARK: - Animation

    public enum Anim {
        public static let waveformLevel: SwiftUI.Animation = .spring(response: 0.1, dampingFraction: 0.7)
        public static let recordingPulse: SwiftUI.Animation = .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
        public static let stateTransition: SwiftUI.Animation = .spring(response: 0.35, dampingFraction: 0.8)
    }

    // MARK: - SF Symbols

    public enum Symbol {
        public static let micIdle = "mic.fill"
        public static let stop = "stop.fill"
        public static let waveform = "waveform"
        public static let emptyState = "waveform.badge.plus"
        public static let history = "list.bullet"
        public static let copy = "doc.on.doc"
        public static let settings = "gear"
        public static let appIcon = "waveform"
        public static let delete = "trash"
        public static let share = "square.and.arrow.up"
    }
}
