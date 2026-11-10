import SwiftUI

extension View {
    /// Puts the phone's keyboard away when this view is tapped.
    ///
    /// The entry field is meant to be typed in over and over, so Return commits what you
    /// wrote and keeps the keyboard up for the next line. That leaves no way out of it:
    /// a keyboard covers most of a phone screen, and a board of finished work has nothing
    /// in it to press Return on, so opening the field to add one thing left you reading
    /// the rest of the app through the top third of the screen.
    ///
    /// Applied to everything except the field itself - a tap landing there is how the
    /// keyboard arrived. The gesture is simultaneous rather than exclusive so the buttons,
    /// menus and cards underneath still get the same tap, and it only clears the focus it
    /// is handed: a row being edited holds a different one and is left alone.
    ///
    /// Nothing on the Mac, where the keyboard is a physical object and focus is the only
    /// thing this could take away.
    func putsKeyboardAway(_ focus: FocusState<Bool>.Binding) -> some View {
        #if os(macOS)
        self
        #else
        simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = false })
        #endif
    }
}
