import AppKit

// The one genuinely Mac-only corner of the app. Sources/iOS/Platform.swift mirrors it
// exactly - same names, same shapes - so nothing in Shared/ knows which one it got.

enum Chime {
    /// What plays when the app ships with no audio of its own. `NSSound(named:)` reaches
    /// for the system's copy - nothing is redistributed by referring to it.
    private static let stockName = "Hero"

    /// Every sound is made, played and stopped here, never on the main thread: the first play
    /// of a run can wait while macOS loads its audio components, and on 2026-11-03 that froze
    /// the window for two seconds just as the fireworks began.
    private static let queue = DispatchQueue(label: "DoneBoard.Chime", qos: .userInitiated)

    /// Touched only on `queue`.
    private static var loaded: [String: NSSound] = [:]

    static func play(_ sound: ChimeSound) {
        queue.async {
            guard let audio = audio(for: sound) else { return }
            // Stop first, so checking off two things quickly retriggers instead of being
            // swallowed by the sound already playing.
            audio.stop()
            audio.play()
        }
    }

    private static func audio(for choice: ChimeSound) -> NSSound? {
        if let cached = loaded[choice.name] { return cached }
        let audio = SoundFile.url(for: choice).flatMap { NSSound(contentsOf: $0, byReference: false) }
            ?? NSSound(named: stockName)
        loaded[choice.name] = audio
        return audio
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum BackgroundTime {
    /// A Mac app keeps running behind other windows, but App Nap can slow it to a crawl there. This
    /// keeps it awake until the work is done - the Mac's half of what iOS does with background time.
    static func begin(_ name: String) -> () -> Void {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: name)
        return { ProcessInfo.processInfo.endActivity(activity) }
    }
}

extension Notification.Name {
    /// The app came to the front - a hint that another device may have written while it
    /// was away. An iOS build points this at `UIApplication.didBecomeActiveNotification`.
    static let appBecameActive = NSApplication.didBecomeActiveNotification
    static let appResignedActive = NSApplication.didResignActiveNotification
    /// The nearest a Mac app has to the background. It is still running, so the diagnostics log
    /// never counts this as a normal way for a Mac run to end.
    static let appWentToBackground = NSApplication.didHideNotification
    static let appWillQuit = NSApplication.willTerminateNotification
}
