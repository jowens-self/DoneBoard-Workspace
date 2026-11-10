import UIKit
import AudioToolbox

// The iOS half of the platform shim. Mirrors Sources/Mac/Platform.swift exactly.

enum Chime {
    /// The system's own fanfare, played by id. Like `NSSound(named:)` on the Mac this
    /// reaches for the OS's copy rather than carrying one.
    private static let stockID: SystemSoundID = 1026

    private static var registered: [String: SystemSoundID] = [:]

    /// Sound and haptics travel together here: on a phone the tap in your hand is most
    /// of the payoff, and a celebration that buzzed while silent would feel odd.
    static func play(_ sound: ChimeSound) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        AudioServicesPlaySystemSound(identifier(for: sound))
    }

    private static func identifier(for choice: ChimeSound) -> SystemSoundID {
        if let cached = registered[choice.name] { return cached }
        var id = stockID
        if let url = SoundFile.url(for: choice) {
            var made: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &made) == kAudioServicesNoError {
                id = made
            }
        }
        registered[choice.name] = id
        return id
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

enum BackgroundTime {
    /// Asks iOS to let the app keep running for a while if it is left now, and returns how to say
    /// the work is done. Without it, an app left partway through writing the shared file is
    /// suspended within seconds, and the change waits on the phone until the app is next opened.
    static func begin(_ name: String) -> () -> Void {
        var task = UIBackgroundTaskIdentifier.invalid
        let end = {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        task = UIApplication.shared.beginBackgroundTask(withName: name) {
            Diagnostics.log(.sync, "iOS ran out of background time for \u{201C}\(name)\u{201D}")
            end()
        }
        return end
    }
}

extension Notification.Name {
    static let appBecameActive = UIApplication.didBecomeActiveNotification
    static let appResignedActive = UIApplication.willResignActiveNotification
    static let appWentToBackground = UIApplication.didEnterBackgroundNotification
    static let appWillQuit = UIApplication.willTerminateNotification
}
