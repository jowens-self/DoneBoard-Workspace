import Foundation
import Observation

/// Remembers a folder the user picked, so the archive can live somewhere both devices
/// can see it - a folder shared from a Mac, or one in Dropbox.
///
/// A path alone isn't enough. A sandboxed app's permission to reach a folder the user
/// chose is granted to the running process, and only a *security-scoped bookmark*
/// carries it across a relaunch. The two platforms spell that differently, which is the
/// only reason this file has a `#if` in it.
///
/// Nothing here that touches the folder runs on the main thread. Resolving a bookmark to a
/// share reaches the network, and a share on a Mac with its lid shut takes as long to answer
/// as the network takes to give up - which, done at launch on the main thread, froze the phone
/// until the system killed the app.
@Observable
final class SyncLocation {
    static let shared = SyncLocation()

    private static let defaultsKey = "syncFolderBookmark"
    private static let fileName = "doneboard.json"

    enum State: Equatable {
        /// No folder picked: the board lives in this device's own file.
        case local
        /// A saved or just-picked folder is being looked for.
        case connecting(String)
        case connected(URL)
        /// A folder was picked but can't be reached right now - a share on a Mac that is
        /// asleep, or on a network the device isn't on. The board runs on this device's copy.
        case unreachable(String)
    }

    private(set) var state: State = .local

    /// Told the file to use whenever that changes: a saved folder found, one picked, syncing
    /// stopped. The app points the store at it. Always called on the main thread.
    @ObservationIgnored var fileChanged: ((URL) -> Void)?

    /// The URL whose security scope is currently held open, so the start/stop calls
    /// balance exactly once no matter how often the folder changes.
    @ObservationIgnored private var scoped: URL?

    /// Bumped by every lookup, pick and stop, so work that comes back after being overtaken -
    /// a lookup still waiting on the network when Stop syncing was tapped - is recognised and
    /// dropped instead of undoing what the user did since.
    @ObservationIgnored private var attempt = 0

    /// A lookup that failed is tried again on its own, waiting 15 seconds and doubling to a minute.
    /// The first look after a phone has sat idle can fail at once - "doesn't exist" - and work a few
    /// seconds later, and without this an app left open stayed off the folder until it was reopened.
    @ObservationIgnored private var retry: DispatchWorkItem?
    @ObservationIgnored private var retryDelay: TimeInterval = 0
    /// The first wait. Tests shorten it.
    static var firstRetry: TimeInterval = 15

    /// The shared folder in use, or nil when the app is keeping its own local copy.
    var folder: URL? {
        if case .connected(let url) = state { return url }
        return nil
    }

    /// The file the store should read and write.
    ///
    /// `isDirectory` is not decoration. Left out, appending a path component asks the file system
    /// whether the result is a folder - a network round trip on a share, made on the main thread,
    /// and on a share that had gone bad it froze the phone for 16 seconds until iOS killed the app.
    var fileURL: URL {
        folder.map { $0.appendingPathComponent(Self.fileName, isDirectory: false) } ?? Store.localFileURL()
    }

    var isSyncing: Bool { folder != nil }

    private init() {
        // Only the name is read here - it is inside the bookmark and needs no network. Finding
        // the folder itself waits for `connect()`.
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey) {
            state = .unreachable(Self.name(of: data))
        }
    }

    deinit {
        retry?.cancel()
        releaseScope()
    }

    /// Looks for the saved folder in the background. The app calls this at launch and whenever it
    /// comes to the front; it does nothing while connected, with no folder saved, or while a
    /// lookup is already out - a stalled one is still waiting on the network, and a second would
    /// only wait behind it.
    func connect() {
        guard case .unreachable(let name) = state,
              let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        attempt += 1
        let token = attempt
        state = .connecting(name)
        Diagnostics.log(.sync, "looking for sync folder \u{201C}\(name)\u{201D}")

        DispatchQueue.global(qos: .userInitiated).async {
            let lookup = Diagnostics.timed(.sync, "finding \u{201C}\(name)\u{201D}", reportOver: 0) {
                Self.resolve(data)
            }
            DispatchQueue.main.async { self.finish(lookup, token: token, name: name) }
        }
    }

    /// Adopts a folder the user just picked. The bookmark is made in the background, since making
    /// one reaches into the folder; `failed` hears why, on the main thread, if access can't be kept.
    func use(_ url: URL, failed: @escaping (Error) -> Void) {
        attempt += 1
        let token = attempt
        let before = state
        cancelRetry()
        state = .connecting(url.lastPathComponent)
        Diagnostics.log(.sync, "picked folder \(url.path)")

        DispatchQueue.global(qos: .userInitiated).async {
            // Open the folder before bookmarking it. iOS won't bookmark a folder outside the
            // app's own container while its security scope is closed, and every folder worth
            // syncing to is outside it.
            let opened = url.startAccessingSecurityScopedResource()
            let made = Result {
                try Diagnostics.timed(.sync, "bookmarking \u{201C}\(url.lastPathComponent)\u{201D}", reportOver: 0) {
                    try Self.bookmark(for: url)
                }
            }
            DispatchQueue.main.async {
                self.finishPick(url, made, opened: opened, token: token, before: before, failed: failed)
            }
        }
    }

    /// Goes back to this device's own copy. The store carries the contents back across when
    /// `fileChanged` points it home; this only forgets the folder.
    func stop() {
        attempt += 1
        cancelRetry()
        releaseScope()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        state = .local
        Diagnostics.log(.sync, "stopped syncing")
        fileChanged?(fileURL)
    }

    // MARK: - Coming back from the background

    private struct Lookup {
        var url: URL?
        /// Set when the bookmark resolved stale and a new one was made.
        var fresh: Data?
        var failure: String?
    }

    /// Runs in the background, and may take as long as the network does.
    private static func resolve(_ data: Data) -> Lookup {
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: resolveOptions,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            do {
                url = try URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                return Lookup(failure: describe(error))
            }
        }
        guard claimScope(url) else {
            return Lookup(failure: "the system refused access to \(url.path)")
        }
        // A stale bookmark still resolved, but won't next time. Remake it now, while the folder
        // is in reach.
        return Lookup(url: url, fresh: stale ? try? bookmark(for: url) : nil)
    }

    private func finish(_ lookup: Lookup, token: Int, name: String) {
        guard token == attempt else {
            // Overtaken by a pick or a stop. Give back the scope this lookup opened.
            lookup.url?.stopAccessingSecurityScopedResource()
            Diagnostics.log(.sync, "lookup of \u{201C}\(name)\u{201D} came back after being overtaken; dropped")
            return
        }
        guard let url = lookup.url else {
            // Out of reach. Keep the bookmark and run on this device's copy until the next
            // `connect` finds it - forgetting it here would turn one launch away from home into
            // sync quietly ending for good.
            state = .unreachable(name)
            retryDelay = min(max(retryDelay * 2, Self.firstRetry), 60)
            Diagnostics.log(.sync, "can't reach \u{201C}\(name)\u{201D}: \(lookup.failure ?? "no reason given"); "
                + "looking again in \(Diagnostics.seconds(retryDelay))")
            let work = DispatchWorkItem { [weak self] in self?.connect() }
            retry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
            return
        }
        if let fresh = lookup.fresh {
            UserDefaults.standard.set(fresh, forKey: Self.defaultsKey)
        }
        cancelRetry()
        releaseScope()
        scoped = url
        state = .connected(url)
        Diagnostics.log(.sync, "syncing through \(url.path)")
        fileChanged?(fileURL)
    }

    private func finishPick(_ url: URL, _ made: Result<Data, Error>, opened: Bool, token: Int,
                            before: State, failed: (Error) -> Void) {
        guard token == attempt else {
            if opened { url.stopAccessingSecurityScopedResource() }
            Diagnostics.log(.sync, "pick of \(url.path) came back after being overtaken; dropped")
            return
        }
        switch made {
        case .success(let data):
            releaseScope()
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            scoped = url
            state = .connected(url)
            Diagnostics.log(.sync, "syncing through \(url.path)")
            fileChanged?(fileURL)
        case .failure(let error):
            if opened { url.stopAccessingSecurityScopedResource() }
            // A lookup this pick overtook will never report back, so don't put its state back.
            if case .connecting = before { state = savedState() } else { state = before }
            Diagnostics.log(.sync, "couldn't keep access to \(url.path): \(Self.describe(error))")
            failed(error)
        }
    }

    /// What a saved bookmark alone says: a folder to look for, or none.
    private func savedState() -> State {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return .local }
        return .unreachable(Self.name(of: data))
    }

    private static func name(of bookmark: Data) -> String {
        URL.resourceValues(forKeys: [.nameKey], fromBookmarkData: bookmark)?.name ?? "the sync folder"
    }

    private static func bookmark(for url: URL) throws -> Data {
        // An unsandboxed Mac build can't make a security-scoped bookmark and doesn't
        // need one, so fall back to a plain bookmark rather than refusing the folder.
        do {
            return try url.bookmarkData(options: createOptions,
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            return try url.bookmarkData()
        }
    }

    private static func claimScope(_ url: URL) -> Bool {
        let granted = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        // Outside a sandbox this is a no-op that reports false, and access is fine.
        return true
        #else
        return granted
        #endif
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
        retryDelay = 0
    }

    private func releaseScope() {
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }

    #if os(macOS)
    private static let createOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    private static let resolveOptions: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
    // iOS makes document-picker bookmarks scoped already and rejects the option.
    private static let createOptions: URL.BookmarkCreationOptions = []
    private static let resolveOptions: URL.BookmarkResolutionOptions = []
    #endif
}
