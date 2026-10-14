import CharkerCore
import Combine
import Darwin
import Foundation

/// Runs the bundled `charker-matter` helper, which publishes the charger's
/// ports to Apple Home, and speaks its line protocol.
///
/// Everything Matter lives in the helper. This side launches it, keeps it
/// alive, tells it the port readings and passes Home's switch requests on to
/// ``onCommand``; every request must be answered with ``resend(index:)``,
/// whatever came of it, because that is how Home learns the real state.
@MainActor
final class MatterService: ObservableObject {
    enum Status: Equatable {
        case off
        /// This build ships without the helper (a `swift build` binary does).
        case unavailable
        case starting
        case waitingForPairing(qr: String, manualCode: String)
        case paired
        /// The helper cannot advertise itself, which in practice means Local
        /// Network access is off. It keeps running and retrying.
        case localNetworkDenied
        /// The helper exited or hit a fatal error; a relaunch is scheduled.
        case restarting
        /// The helper could not be launched at all.
        case failed
    }

    @Published private(set) var status: Status = .off
    /// A controller switched port `index` on or off.
    var onCommand: ((Int, Bool) -> Void)?

    private struct Configuration: Equatable {
        var storage: URL
        var name: String
        var labels: [String]
        var bridge: Bool
        var udpPort: UInt16
    }

    private let fileLog: FileLog
    /// Starts every log line, so the lines of two helpers can be told apart.
    private let logPrefix: String
    /// What should be running; nil once stopped.
    private var configuration: Configuration?
    private var process: Process?
    private var input: FileHandle?
    /// Writes leave the main actor, so a stalled helper cannot block the UI
    /// on a full pipe.
    private let writeQueue = DispatchQueue(label: "dev.charker.matter.stdin", qos: .userInitiated)
    /// Bumped on every launch and stop. Callbacks from an older process carry
    /// an older value and are dropped, so a stopped helper cannot restart itself.
    private var generation = 0
    private var ports = MatterPortSync()
    /// Answers a Home request the host has left open for too long.
    private var commandTimeouts: [Int: Task<Void, Never>] = [:]
    /// Stopped helpers by storage directory, until they are gone.
    private var exiting: [URL: Process] = [:]
    /// A helper's exit is handled once its stdout has closed and its
    /// termination has arrived, whichever comes last, so none of its lines
    /// can come after.
    private var outputOpen = false
    private var termination: String?
    private var onboarding: (qr: String, manualCode: String)?
    /// Nil until the helper has said, so an already paired accessory does not
    /// flash its QR code between the two startup lines.
    private var fabricCount: Int?
    private var mdnsFailing = false
    private var launchedAt: Date?
    private var failures = 0
    /// A launch waiting for a restart delay or for the previous helper.
    private var restartTask: Task<Void, Never>?
    /// Keeps App Nap from slowing the answers Home waits for.
    private var activity: NSObjectProtocol?

    private static let restartDelays: [Double] = [1, 2, 5, 10, 30]
    private static let commandTimeout: Duration = .seconds(10)

    init(fileLog: FileLog, logPrefix: String) {
        self.fileLog = fileLog
        self.logPrefix = logPrefix
    }

    /// `bridge` publishes every port as an accessory of its own.
    func start(storage: URL, name: String, labels: [String], bridge: Bool, udpPort: UInt16) {
        let next = Configuration(storage: storage, name: name, labels: labels, bridge: bridge, udpPort: udpPort)
        if configuration == next, process != nil || restartTask != nil { return }
        stop()
        configuration = next
        status = .starting
        launchOnceStorageIsFree()
    }

    /// Closes the helper's stdin after a shutdown line; it exits on either.
    /// One that is still around 1.5 s later is terminated. The port states go
    /// too, so the next start begins with every port off.
    func stop() {
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        if let process, let configuration {
            // releaseProcess() below closes stdin after this line.
            send(MatterHelperLine.shutdown)
            exiting[configuration.storage] = process
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if process.isRunning { process.terminate() }
            }
        }
        configuration = nil
        releaseProcess()
        ports = MatterPortSync()
        failures = 0
        status = .off
    }

    /// ``stop()``, then waits until the helper is really gone.
    func shutdown() async {
        let process = self.process
        stop()
        await Self.waitForExit(process)
    }

    /// The latest state of every port. Only ports that changed are written;
    /// a (re)launch sends them all.
    func update(_ states: [MatterPortState]) {
        ports.update(states).forEach { send($0) }
    }

    /// Answers a Home request with the port's real state.
    func resend(index: Int) {
        commandTimeouts.removeValue(forKey: index)?.cancel()
        if let line = ports.answer(index: index) { send(line) }
    }

    /// Forgets every Home pairing: the storage is deleted once the helper has
    /// exited, so it cannot write the old identity back on its way out.
    func resetPairing() {
        guard let configuration else { return }
        let states = ports.desired
        stop()
        self.configuration = configuration
        ports.update(states)
        status = .starting
        launchOnceStorageIsFree(resettingPairing: true)
    }

    // MARK: - Process

    /// Two helpers on one storage directory would write the same files, and
    /// the second would advertise as "(2)", so a stopped one is waited out.
    private func launchOnceStorageIsFree(resettingPairing: Bool = false) {
        guard let storage = configuration?.storage else { return }
        exiting = exiting.filter { $0.value.isRunning }
        let outgoing = exiting[storage]
        let generation = generation
        restartTask = Task { [weak self] in
            await Self.waitForExit(outgoing)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            if resettingPairing { self.deleteStorage(storage) }
            self.launch()
        }
    }

    private func launch() {
        restartTask = nil
        guard let configuration else { return }
        guard let executable = Bundle.main.url(forAuxiliaryExecutable: "charker-matter") else {
            status = .unavailable
            return
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "--storage", configuration.storage.path,
            "--name", configuration.name,
            "--ports", configuration.labels.joined(separator: ","),
            "--udp-port", String(configuration.udpPort),
        ] + (configuration.bridge ? ["--bridge"] : [])
        // The helper creates the directory too, but maybe not its parents.
        try? FileManager.default.createDirectory(at: configuration.storage, withIntermediateDirectories: true)
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        // A helper that died between two writes must cost an EPIPE, not the
        // app: SIGPIPE's default action is to terminate the writer.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        generation += 1
        let generation = generation
        stdout.fileHandleForReading.readabilityHandler = Self.lineReader { [weak self] line in
            // FIFO onto the main actor, so events keep their order and the
            // end of output comes after the last line.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let line {
                        self?.handle(line, generation: generation)
                    } else {
                        self?.outputEnded(generation: generation)
                    }
                }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = Self.lineReader { [fileLog, logPrefix] line in
            if let line { fileLog.write("\(logPrefix): \(line)") }
        }
        process.terminationHandler = { [weak self] process in
            let ending = process.terminationReason == .uncaughtSignal
                ? "killed by signal \(process.terminationStatus)"
                : "exited with status \(process.terminationStatus)"
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.terminated(ending, generation: generation) }
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            log("helper did not launch: \(error)")
            status = .failed
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        outputOpen = true
        termination = nil
        launchedAt = Date()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Apple Home accessory"
            )
        }
        log("helper started for \(configuration.name)")
        ports.connect(ports: configuration.labels.count).forEach { send($0) }
    }

    private func outputEnded(generation: Int) {
        guard generation == self.generation, process != nil else { return }
        outputOpen = false
        if let termination { exited(termination) }
    }

    private func terminated(_ ending: String, generation: Int) {
        guard generation == self.generation, process != nil else { return }
        termination = ending
        if !outputOpen { exited(ending) }
    }

    private func exited(_ ending: String) {
        log("helper \(ending)")
        let ranFor = launchedAt.map { Date().timeIntervalSince($0) } ?? 0
        releaseProcess()
        guard configuration != nil else { return }
        if ranFor >= 60 { failures = 0 }
        status = .restarting
        let delay = Self.restartDelays[min(failures, Self.restartDelays.count - 1)]
        failures += 1
        let generation = generation
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.launch()
        }
    }

    private func releaseProcess() {
        if let input {
            writeQueue.async { try? input.close() }
        }
        process = nil
        input = nil
        launchedAt = nil
        ports.disconnect()
        commandTimeouts.values.forEach { $0.cancel() }
        commandTimeouts = [:]
        onboarding = nil
        fabricCount = nil
        mdnsFailing = false
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func deleteStorage(_ storage: URL) {
        guard FileManager.default.fileExists(atPath: storage.path) else { return }
        do {
            try FileManager.default.removeItem(at: storage)
        } catch {
            log("pairing reset could not delete storage: \(error)")
        }
    }

    private static func waitForExit(_ process: Process?) async {
        guard let process else { return }
        for _ in 0..<30 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // A cancelled wait leaves the process to stop()'s own deadline.
        guard process.isRunning, !Task.isCancelled else { return }
        process.terminate()
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Lines

    private func handle(_ line: String, generation: Int) {
        guard generation == self.generation, process != nil else { return }
        // Never logged verbatim: the onboarding line carries the setup code.
        guard let event = MatterHelperEvent(line: line) else {
            log("ignored an unrecognised stdout line")
            return
        }
        switch event {
        case .onboarding(let qr, let manualCode):
            onboarding = (qr, manualCode)
            refreshStatus()
        case .fabrics(let count):
            log("\(count) fabric(s)")
            fabricCount = count
            refreshStatus()
        case .mdns(let ok):
            log(ok ? "mDNS registered" : "mDNS registration failed")
            mdnsFailing = !ok
            refreshStatus()
        case .command(let index, let on):
            guard ports.request(index: index, on: on) else { return }
            log("command port \(index) \(on ? "on" : "off")")
            // Armed before the host sees it: a refusal answers at once.
            commandTimeouts[index]?.cancel()
            commandTimeouts[index] = Task { [weak self] in
                try? await Task.sleep(for: Self.commandTimeout)
                guard !Task.isCancelled, let self else { return }
                self.log("command port \(index) unanswered")
                self.resend(index: index)
            }
            onCommand?(index, on)
        case .error(let code, let message):
            log("helper error \(code): \(message)")
            status = .restarting
        }
    }

    private func refreshStatus() {
        if mdnsFailing {
            status = .localNetworkDenied
        } else if let fabricCount, fabricCount > 0 {
            status = .paired
        } else if fabricCount != nil, let onboarding {
            status = .waitingForPairing(qr: onboarding.qr, manualCode: onboarding.manualCode)
        } else {
            status = .starting
        }
    }

    private func log(_ message: String) {
        fileLog.write("\(logPrefix): \(message)")
    }

    private func send(_ line: String) {
        guard let input else { return }
        let data = Data((line + "\n").utf8)
        writeQueue.async { try? input.write(contentsOf: data) }
    }

    /// Splits a pipe into lines on the pipe's own queue, then delivers nil at
    /// EOF. An empty read is EOF and unhooks the handler, which would
    /// otherwise be called forever.
    private nonisolated static func lineReader(
        _ deliver: @escaping @Sendable (String?) -> Void
    ) -> @Sendable (FileHandle) -> Void {
        let buffer = LineBuffer()
        return { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if let last = buffer.finish() { deliver(last) }
                deliver(nil)
                return
            }
            buffer.append(data).forEach { deliver($0) }
        }
    }
}

/// Bytes not yet ending in a newline. Only touched from one pipe's
/// readability handler, which the system never runs concurrently.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = Self.text(line) { lines.append(text) }
        }
        return lines
    }

    func finish() -> String? {
        defer { pending.removeAll() }
        return Self.text(pending)
    }

    private static func text(_ bytes: Data) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
