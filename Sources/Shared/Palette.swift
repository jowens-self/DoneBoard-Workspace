import SwiftUI

/// The handful of colours that are named differently on each platform, gathered here
/// so the shared views don't need to carry `#if` blocks around for them.
enum Palette {
    /// The board's own page background.
    static var board: Color {
        #if os(macOS)
        Color(nsColor: .textBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// A card that has to stand off the page in both appearances - white on a pale page,
    /// a lifted grey where the phone's page is black.
    static var raised: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .tertiarySystemBackground)
        #endif
    }

    /// Behind the calendar - a sidebar on the Mac, a full screen on a phone.
    static var calendar: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
}
