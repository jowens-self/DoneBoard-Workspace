import Foundation
#if canImport(Darwin)
import Darwin
import MachO

/// Notices the main thread stop answering, and writes down where it is stuck while it still is.
///
/// A background thread asks the main thread to check in every half second. When a check-in is a
/// second late, the main thread's stack is read - by stopping it for the few microseconds that
/// takes - and goes to the log and to a report file, and the freeze is marked in the session so
/// the next launch knows about it even when the system kills the app for it. The stack is taken
/// again at 3, 8 and 15 seconds and every 15 after: what the thread is stuck in can change, and
/// iOS ends a frozen app at 10 or 20 seconds, so the early ones are the ones that survive.
///
/// Background work that has been running for 10 seconds - a read of a share that isn't answering
/// - gets its stack taken as well, since a background thread waiting forever freezes nothing and
/// would otherwise leave no trace at all.
final class HangWatch {
    static let shared = HangWatch()

    private static let interval: TimeInterval = 0.5
    private static let firstCapture: TimeInterval = 1

    private let queue = DispatchQueue(label: "DoneBoard.hang-watch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    /// Filled in by `start()`, on the main thread - the only place its port can be asked for.
    private var mainThread: mach_port_t = 0

    private let answerLock = NSLock()
    private var answered = true
    private var pingSent = Date()
    private var lastTick = Date()

    private var frozenSince: Date?
    private var nextCapture = HangWatch.firstCapture
    private var report: URL?
    private var slowWork: [ObjectIdentifier: (activity: Diagnostics.Activity, next: TimeInterval)] = [:]

    /// Allocated up front, because a stack is read while its thread is stopped - and a stopped
    /// thread can be holding the lock that allocating memory needs.
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: 128)

    /// Starts watching. Belongs as early in launch as possible, on the main thread.
    func start() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.start() }
            return
        }
        let main = pthread_mach_thread_np(pthread_self())
        queue.async { [self] in
            guard timer == nil else { return }
            mainThread = main
            StackTrace.warmUp()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + Self.interval, repeating: Self.interval,
                            leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.tick() }
            lastTick = Date()
            ping(Date())
            source.resume()
            timer = source
        }
        Diagnostics.log(.hang, "watching the main thread")
    }

    // MARK: - The main thread

    private func tick() {
        let now = Date()
        defer { lastTick = now }
        // A tick this late means the whole process was stopped - a phone app in the background, a
        // Mac asleep - and the main thread didn't answer because nothing ran at all.
        if now.timeIntervalSince(lastTick) > Self.interval * 4 {
            if frozenSince != nil { endFreeze(now, suspended: true) }
            ping(now)
            return
        }
        answerLock.lock()
        let ok = answered
        answerLock.unlock()
        if ok {
            if frozenSince != nil { endFreeze(now, suspended: false) }
            ping(now)
        } else {
            let waited = now.timeIntervalSince(pingSent)
            if waited >= nextCapture { captureFreeze(now, waited: waited) }
        }
        watchSlowWork(now)
    }

    private func ping(_ now: Date) {
        answerLock.lock()
        answered = false
        pingSent = now
        answerLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.answerLock.lock()
            self.answered = true
            self.answerLock.unlock()
        }
    }

    private func captureFreeze(_ now: Date, waited: TimeInterval) {
        let first = frozenSince == nil
        let stack = stack(of: mainThread)
        let activity = Diagnostics.inFlight.first { $0.onMain }
        let doing = activity.map { "\($0.name), \(Diagnostics.seconds(now.timeIntervalSince($0.started))) in" }
        if first {
            frozenSince = pingSent
            report = Diagnostics.reportsFolder.appendingPathComponent("freeze-\(Self.fileStamp(pingSent)).txt", isDirectory: false)
            append(Self.header("Freeze"))
        }
        // Every capture, not only the first: if the system kills the app for this freeze, the last
        // one written is how long the next launch will say it had lasted.
        Diagnostics.noteFreeze(since: frozenSince, in: activity?.name ?? stack.whereStuck ?? "code outside the app")
        let headline = "main thread hasn't answered for \(Diagnostics.seconds(waited))"
            + (doing.map { " - inside \($0)" } ?? stack.whereStuck.map { " - in \($0)" } ?? "")
        Diagnostics.log(.hang, "\(headline)\n\(stack.brief)")
        append("\(headline)\n\(stack.full)\n")
        nextCapture = waited < 3 ? 3 : waited < 8 ? 8 : waited < 15 ? 15 : waited + 15
    }

    private func endFreeze(_ now: Date, suspended: Bool) {
        guard let since = frozenSince else { return }
        let held = Diagnostics.seconds(now.timeIntervalSince(since))
        let line = suspended
            ? "the app was suspended while its main thread was frozen, \(held) in"
            : "main thread answered again after \(held)"
        Diagnostics.log(.hang, line)
        append("\(line)\n")
        Diagnostics.noteFreeze(since: nil, in: nil)
        frozenSince = nil
        report = nil
        nextCapture = Self.firstCapture
    }

    // MARK: - Background work

    private func watchSlowWork(_ now: Date) {
        let running = Diagnostics.inFlight.filter { !$0.onMain }
        let ids = Set(running.map { ObjectIdentifier($0) })
        slowWork = slowWork.filter { ids.contains($0.key) }

        for activity in running {
            let id = ObjectIdentifier(activity)
            let age = now.timeIntervalSince(activity.started)
            guard age >= (slowWork[id]?.next ?? 10) else { continue }
            slowWork[id] = (activity, age < 30 ? 30 : age < 60 ? 60 : age + 60)

            let stack = stack(of: activity.thread)
            let line = "\(activity.name) still running after \(Diagnostics.seconds(age)), in the background"
            Diagnostics.log(activity.category, "\(line)\n\(stack.brief)")
            let file = Diagnostics.reportsFolder.appendingPathComponent("slow-\(Self.fileStamp(activity.started)).txt", isDirectory: false)
            if !FileManager.default.fileExists(atPath: file.path) { append(Self.header("Slow work"), to: file) }
            append("\(line)\n\(stack.full)\n", to: file)
        }
    }

    // MARK: - Writing it down

    private struct Stack {
        var brief: String
        var full: String
        /// Where the thread is, in a few words - see `StackTrace.summary`.
        var whereStuck: String?
    }

    private func stack(of thread: mach_port_t) -> Stack {
        let count = StackTrace.capture(thread, into: frames, capacity: 128)
        guard count > 0 else {
            return Stack(brief: "    (the stack couldn't be read)", full: "    (the stack couldn't be read)", whereStuck: nil)
        }
        // Only now, with the thread running again, is it safe to allocate and look things up.
        let described = StackTrace.describe(Array(UnsafeBufferPointer(start: frames, count: count)))
        let lines = described.frames.map(\.line)
        return Stack(brief: lines.prefix(16).joined(separator: "\n"),
                     full: lines.joined(separator: "\n") + "\n  images:\n" + described.images.joined(separator: "\n"),
                     whereStuck: StackTrace.summary(of: described.frames))
    }

    private func append(_ text: String, to file: URL? = nil) {
        guard let url = file ?? report else { return }
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func header(_ kind: String) -> String {
        "DoneBoard \(kind.lowercased()) report\nbuild \(Diagnostics.build)\ndevice \(Diagnostics.device)\nsession \(Diagnostics.sessionID)\n\n"
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

@_silgen_name("swift_demangle")
private func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: UInt,
                           _ output: UnsafeMutablePointer<CChar>?,
                           _ outputLength: UnsafeMutablePointer<UInt>?,
                           _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

/// Reading another thread's stack, by frame pointers. Apple's arm64 and x86-64 code always keeps
/// them, so walking the chain of saved frame records gives every return address without a single
/// symbol - those are looked up afterwards, once the thread is running again.
enum StackTrace {
    #if os(macOS)
    private static let addressMask: UInt = 0x0000_7FFF_FFFF_FFFF
    #else
    // Keeps the bits of an address and drops any pointer-authentication signature above them.
    private static let addressMask: UInt = 0x0000_000F_FFFF_FFFF
    #endif

    private final class Port: @unchecked Sendable { var value: mach_port_t = 0 }

    /// Runs one whole capture now, on a thread parked for the purpose, so every one-time setup a
    /// capture needs is done while nothing that matters is stopped.
    ///
    /// That is more than it looks in a Debug build, which is what Xcode's Run puts on the phone.
    /// Unoptimised Swift looks up the type of the register state and of each frame record the first
    /// time it meets them, and that lookup allocates and takes the runtime's locks. This used to
    /// warm up only the memory read, so those lookups waited for the first real freeze - made with
    /// the main thread stopped, a second into whatever was keeping it busy. Stopped while holding
    /// one of those locks, it would never be started again - the watchdog waiting for a lock the
    /// main thread holds, the main thread waiting for the watchdog - and a stall of a second would
    /// become a freeze that lasts until the system kills the app.
    static func warmUp() {
        let port = Port()
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        Thread {
            port.value = pthread_mach_thread_np(pthread_self())
            ready.signal()
            release.wait()
        }.start()
        ready.wait()
        // Time to get from the signal into the wait, so it is stopped holding nothing at all.
        usleep(20_000)
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: 8)
        _ = capture(port.value, into: buffer, capacity: 8)
        buffer.deallocate()
        release.signal()
    }

    /// Stops `thread`, copies its return addresses into `buffer`, and starts it again. Nothing in
    /// between allocates. Returns how many addresses were read.
    static func capture(_ thread: mach_port_t, into buffer: UnsafeMutablePointer<UInt>, capacity: Int) -> Int {
        guard thread != pthread_mach_thread_np(pthread_self()),
              thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(thread) }

        let pc: UInt, lr: UInt, framePointer: UInt
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__pc) & addressMask
        lr = UInt(state.__lr) & addressMask
        framePointer = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, x86_THREAD_STATE64, $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        pc = UInt(state.__rip)
        lr = 0
        framePointer = UInt(state.__rbp)
        #else
        return 0
        #endif

        var count = 0
        buffer[count] = pc
        count += 1

        var fp = framePointer
        var first = true
        while fp != 0, fp % UInt(MemoryLayout<UInt>.size) == 0, count < capacity {
            // A frame record is two words: the caller's frame pointer, then the return address.
            var record: (UInt, UInt) = (0, 0)
            var size: vm_size_t = 0
            let read = withUnsafeMutablePointer(to: &record) { pointer in
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<UInt>.size * 2),
                                  vm_address_t(UInt(bitPattern: pointer)), &size)
            }
            guard read == KERN_SUCCESS else { break }
            let returnAddress = record.1 & addressMask
            // A thread stopped inside a function that makes no calls - a system call's stub, most
            // often - hasn't saved its link register yet, so its caller is only there.
            if first, lr != 0, lr != returnAddress, count < capacity {
                buffer[count] = lr
                count += 1
            }
            first = false
            guard returnAddress != 0, count < capacity else { break }
            buffer[count] = returnAddress
            count += 1
            // Stacks grow down, so every caller's record sits above the one before it.
            guard record.0 > fp else { break }
            fp = record.0
        }
        return count
    }

    struct Frame {
        var line: String
        var symbol: String?
        var image: String
        var isOwn: Bool
    }

    /// Where a stack is, in a few words: the first frame in the app's own code, not counting the
    /// entry point every main-thread stack ends in - a freeze inside UIKit's keyboard layout was once
    /// reported as being "in DoneBoardApp.$main()", which says nothing - or failing that, the first
    /// framework above the system's plumbing.
    static func summary(of frames: [Frame]) -> String? {
        if let own = frames.first(where: { $0.isOwn && !isEntryPoint($0.symbol) })?.symbol { return own }
        return frames.first { $0.image != "???" && !$0.image.hasPrefix("libsystem_") }
            .map { "system code in \($0.image)" }
    }

    private static func isEntryPoint(_ symbol: String?) -> Bool {
        guard let symbol else { return false }
        return symbol == "main" || symbol.hasSuffix("$main() -> ()")
            || symbol.contains("main_executable_dylib_entry_point")
    }

    /// Names each address: the image it is in, the nearest symbol, and the offset into the image -
    /// which is what `atos` wants, for the system frames whose names a device keeps to itself.
    static func describe(_ addresses: [UInt]) -> (frames: [Frame], images: [String]) {
        let loaded = images()
        let ownPrefix = Bundle.main.bundlePath
        var used: [String: Image] = [:]

        let frames = addresses.enumerated().map { index, address -> Frame in
            // A return address points after the call; the call itself is one byte back, and can
            // be in a different function when the call was the last thing in it.
            let lookup = index == 0 ? address : address - 1
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: lookup), &info) != 0, let fname = info.dli_fname else {
                return Frame(line: String(format: "%3d  ???  0x%016lx", index, address), symbol: nil, image: "???", isOwn: false)
            }
            let path = String(cString: fname)
            let image = loaded[path]
            if let image { used[path] = image }
            let name = (path as NSString).lastPathComponent
            let symbol = info.dli_sname.map { demangle(String(cString: $0)) }
            let offset = info.dli_saddr.map { address - UInt(bitPattern: $0) } ?? 0
            let imageOffset = image.map { address - $0.header } ?? 0
            let padded = name.padding(toLength: max(name.count, 26), withPad: " ", startingAt: 0)
            let line = String(format: "%3d  ", index) + padded
                + String(format: " 0x%016lx ", address)
                + (symbol.map { "\($0) + \(offset)" } ?? "???")
                + String(format: "  (+0x%lx)", imageOffset)
            return Frame(line: line, symbol: symbol, image: name, isOwn: path.hasPrefix(ownPrefix))
        }
        let images = used.values.sorted { $0.header < $1.header }.map {
            String(format: "    0x%016lx  ", $0.header) + "\($0.uuid)  \($0.path)"
        }
        return (frames, images)
    }

    private struct Image {
        let path: String
        let header: UInt
        let uuid: String
    }

    private static func images() -> [String: Image] {
        var found: [String: Image] = [:]
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index), let name = _dyld_get_image_name(index) else { continue }
            let path = String(cString: name)
            found[path] = Image(path: path, header: UInt(bitPattern: header), uuid: uuid(of: header))
        }
        return found
    }

    private static func uuid(of header: UnsafePointer<mach_header>) -> String {
        guard header.pointee.magic == MH_MAGIC_64 else { return "" }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return ""
    }

    private static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") else { return name }
        return name.withCString { mangled in
            guard let plain = swiftDemangle(mangled, UInt(strlen(mangled)), nil, nil, 0) else { return name }
            defer { free(plain) }
            return String(cString: plain)
        }
    }
}

#else

/// Reading another thread's stack needs Mach, so elsewhere there is nothing to watch with.
final class HangWatch {
    static let shared = HangWatch()
    func start() {}
}

#endif
