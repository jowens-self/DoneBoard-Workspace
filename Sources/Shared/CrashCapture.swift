import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(MetricKit)
import MetricKit
#endif

/// Records the ways a run can end other than freezing: an exception nothing caught, a fatal
/// signal - a force-unwrapped nil, a bad pointer - and whatever the system noticed about earlier
/// runs and hands over later through MetricKit.
///
/// The system keeps crash reports of its own, and `Tools/diagnose.sh` pulls those off the phone.
/// What this adds is having them beside the event log, from any device, with no cable.
enum CrashCapture {
    static func start() {
        #if canImport(Darwin)
        collectPreviousCrash()
        installExceptionHandler()
        installSignalHandlers()
        #endif
        #if canImport(MetricKit)
        SystemReports.shared.start()
        #endif
    }

    #if canImport(Darwin)

    /// Where a crash writes, opened while the process is still healthy. The next launch gives
    /// anything in it a dated name.
    private static let pending = Diagnostics.reportsFolder.appendingPathComponent("crash-pending.txt", isDirectory: false)

    private static func collectPreviousCrash() {
        guard let data = try? Data(contentsOf: pending), !data.isEmpty else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: pending.path)
        let when = attributes?[.modificationDate] as? Date ?? Date()
        let kept = Diagnostics.reportsFolder.appendingPathComponent("crash-\(fileStamp(when)).txt", isDirectory: false)
        try? FileManager.default.moveItem(at: pending, to: kept)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").prefix(24)
        Diagnostics.log(.crash, "previous run crashed (\(kept.lastPathComponent)):\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Exceptions

    private static var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

    private static func installExceptionHandler() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.map { "  " + $0 }.joined(separator: "\n")
            Diagnostics.log(.crash, "uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason given")\n\(stack)")
            // The process ends as soon as this returns.
            Diagnostics.flush()
            CrashCapture.previousExceptionHandler?(exception)
        }
    }

    // MARK: - Fatal signals

    private static let fatalSignals: [Int32] = [SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP]

    /// Everything the handler touches exists before the handler can run. A crashing process may be
    /// holding the lock that allocating memory needs, so the handler allocates nothing: it writes
    /// bytes prepared at launch, a number, and a backtrace, and gets out of the way.
    private static var descriptor: Int32 = -1
    private static var banner: UnsafeMutablePointer<CChar>?
    private static var bannerLength = 0
    private static let digits = UnsafeMutablePointer<CChar>.allocate(capacity: 8)
    private static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)
    private static let previousActions = UnsafeMutablePointer<sigaction>.allocate(capacity: 32)
    private static let handler: @convention(c) (Int32) -> Void = { signal in CrashCapture.handle(signal) }

    private static func installSignalHandlers() {
        descriptor = open(pending.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return }
        banner = strdup("DoneBoard crash report\nbuild \(Diagnostics.build)\ndevice \(Diagnostics.device)\nsession \(Diagnostics.sessionID)\nfatal signal ")
        bannerLength = banner.map { strlen($0) } ?? 0
        previousActions.initialize(repeating: sigaction(), count: 32)
        _ = digits
        _ = frames
        _ = handler

        // A stack overflow reaches the handler with no stack left to run it on. Give the main
        // thread a spare.
        let spareSize = 64 * 1024
        var spare = stack_t(ss_sp: UnsafeMutableRawPointer.allocate(byteCount: spareSize, alignment: 16),
                            ss_size: spareSize, ss_flags: 0)
        sigaltstack(&spare, nil)

        for signal in fatalSignals {
            var action = sigaction()
            action.__sigaction_u = __sigaction_u(__sa_handler: handler)
            action.sa_mask = 0
            action.sa_flags = SA_ONSTACK
            sigaction(signal, &action, previousActions + Int(signal))
        }
    }

    private static func handle(_ signal: Int32) {
        if descriptor >= 0 {
            if let banner { _ = write(descriptor, banner, bannerLength) }
            var length = 0
            if signal >= 10 {
                digits[length] = CChar(48 + signal / 10)
                length += 1
            }
            digits[length] = CChar(48 + signal % 10)
            digits[length + 1] = 10
            _ = write(descriptor, digits, length + 2)
            backtrace_symbols_fd(frames, backtrace(frames, 64), descriptor)
            digits[0] = 10
            _ = write(descriptor, digits, 1)
        }
        // Put back whatever handled this signal before and let it happen again, so the process
        // ends exactly as it would have and the system still writes its own report.
        sigaction(signal, previousActions + Int(signal), nil)
        raise(signal)
    }

    #endif

    fileprivate static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}

#if canImport(MetricKit)
/// MetricKit hands over what the system noticed about earlier runs - crashes, hangs, a thread
/// burning CPU, heavy disk writing, a slow launch - with call stacks, some time after the fact.
/// Each delivery is kept whole beside the log, and summed up in it.
final class SystemReports: NSObject, MXMetricManagerSubscriber {
    static let shared = SystemReports()

    func start() {
        MXMetricManager.shared.add(self)
        keep(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        keep(payloads)
    }

    private func keep(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let name = "system-\(CrashCapture.fileStamp(payload.timeStampBegin))-\(CrashCapture.fileStamp(payload.timeStampEnd)).json"
            let file = Diagnostics.reportsFolder.appendingPathComponent(name, isDirectory: false)
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            try? payload.jsonRepresentation().write(to: file)
            Diagnostics.log(.crash, "system report \(name): "
                + "\(payload.crashDiagnostics?.count ?? 0) crashes, "
                + "\(payload.hangDiagnostics?.count ?? 0) hangs, "
                + "\(payload.cpuExceptionDiagnostics?.count ?? 0) CPU exceptions, "
                + "\(payload.diskWriteExceptionDiagnostics?.count ?? 0) disk-write exceptions")
        }
    }
}
#endif
