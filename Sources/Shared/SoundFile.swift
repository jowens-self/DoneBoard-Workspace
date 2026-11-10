import Foundation

/// Finds the audio the app was built with.
///
/// The app ships no sound files of its own. `Resources/Sounds` is empty in the repository
/// and anything dropped into it becomes a choice in Settings automatically - the picker is
/// built from this list rather than from a hard-coded one, so adding audio needs no code.
enum SoundFile {
    private static let formats = ["caf", "aiff", "aif", "wav", "m4a", "mp3"]

    /// Base names of the bundled audio, alphabetically. Empty in a stock build.
    static let bundledNames: [String] = {
        guard let directory = Bundle.main.url(forResource: "Sounds", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files
            .filter { formats.contains($0.pathExtension.lowercased()) }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }()

    /// Nil for the stock sound, and for a choice whose file isn't in this build - a board
    /// synced from a device that had audio this one doesn't.
    static func url(for sound: ChimeSound) -> URL? {
        guard !sound.isStock else { return nil }
        for format in formats {
            if let url = Bundle.main.url(forResource: sound.name, withExtension: format,
                                         subdirectory: "Sounds") {
                return url
            }
        }
        return nil
    }
}
