import SwiftUI

extension View {
    /// The system font at a size picked for the design, grown or shrunk with the text size set on
    /// the phone. `.font(.system(size:))` stays put whatever the reader has asked for, and the text
    /// styles (`.body`, `.caption`) would move every size this app was laid out at. At the default
    /// setting this is exactly `.system(size:weight:design:)`, and on the Mac, which has no text
    /// size setting for it to follow, it always is.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design))
    }
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: Self.style(near: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }

    /// The text style whose default size is nearest, so a size grows along the same curve as the
    /// system's text of about that size - big type grows proportionally less than small.
    private static func style(near size: CGFloat) -> Font.TextStyle {
        switch size {
        case 31...: return .largeTitle   // 34
        case 25..<31: return .title      // 28
        case 21..<25: return .title2     // 22
        case 18.5..<21: return .title3   // 20
        case 16.5..<18.5: return .body   // 17
        case 15.5..<16.5: return .callout // 16
        case 14..<15.5: return .subheadline // 15
        case 12.5..<14: return .footnote // 13
        case 11.5..<12.5: return .caption // 12
        default: return .caption2        // 11
        }
    }
}
