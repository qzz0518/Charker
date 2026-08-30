import Foundation

/// Bounded rolling text log inside the app's own container.
///
/// This exists so a scan session can be inspected after the fact — by the user
/// through the diagnostics export, and during development straight from the
/// shell. It is size capped and carries the same redaction rules as
/// ``DiagnosticsLog``: no serials, no key material, no raw payloads unless the
/// user has explicitly turned raw capture on.
public final class FileLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.charker.filelog", qos: .utility)
    private let url: URL?
    private let baseByteLimit: Int
    private let formatter: ISO8601DateFormatter
    /// All three only ever touched on `queue`.
    private var handle: FileHandle?
    private var writtenBytes = 0
    private var expanded = false

    /// How much bigger the file may get while raw capture is on.
    ///
    /// A real frame expands to about two dozen TLV lines, roughly 1.4 KB, and the
    /// device reports every second: 512 KB is about six minutes, and rotation
    /// keeps a single generation, so the frames from before a ten-minute trip to
    /// the phone were already gone by the time the user came back. Eight times
    /// that covers the whole round trip. It costs up to 8 MB on disk counting the
    /// rotated generation, which is why it is tied to the raw-capture switch
    /// rather than being the default.
    private static let rawCaptureMultiplier = 8

    private var byteLimit: Int { expanded ? baseByteLimit * Self.rawCaptureMultiplier : baseByteLimit }

    public private(set) var isEnabled: Bool

    /// `~/Library/Containers/dev.charker.Charker/Data/Library/Logs/` when sandboxed,
    /// `~/Library/Logs/` otherwise. No entitlement beyond app-sandbox is needed to
    /// write inside our own container.
    public static func defaultURL(named name: String = "charker-scan.log") -> URL? {
        guard let logs = try? FileManager.default.url(
            for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("Logs", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent(name)
    }

    public init(url: URL? = FileLog.defaultURL(), byteLimit: Int = 512 * 1024, enabled: Bool = true) {
        self.url = url
        self.baseByteLimit = byteLimit
        self.isEnabled = enabled
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
    }

    public var path: String { url?.path ?? "—" }

    /// Widens the rotation budget while the user has raw payload capture on.
    ///
    /// Turning it back off never destroys a capture: an over-sized file simply
    /// rotates on the next write, which moves it to the `.1.log` generation where
    /// it stays readable.
    public func setExpandedForRawCapture(_ expanded: Bool) {
        queue.async { self.expanded = expanded }
    }

    public func setEnabled(_ enabled: Bool) {
        queue.async {
            self.isEnabled = enabled
            if !enabled { self.closeLocked() }
        }
    }

    public func write(_ line: String) {
        queue.async {
            guard self.isEnabled, let url = self.url else { return }
            let stamped = "\(self.formatter.string(from: Date()))  \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            self.appendLocked(data, to: url)
        }
    }

    /// One handle for the life of the log instead of one per line.
    ///
    /// A connected session writes a line per BLE frame, and reopening the file
    /// each time — `FileHandle(forWritingTo:)`, `seekToEnd`, `close` — showed up
    /// as the largest non-UI cost in a sampled run. The handle and the size it
    /// has already written are kept here; only rotation reopens anything.
    private func appendLocked(_ data: Data, to url: URL) {
        if handle == nil { openLocked(url) }
        guard let handle else {
            try? data.write(to: url, options: .atomic)
            return
        }

        if writtenBytes + data.count > byteLimit {
            try? handle.close()
            self.handle = nil
            rotate(url)
            try? data.write(to: url, options: .atomic)
            writtenBytes = data.count
            return
        }

        do {
            try handle.write(contentsOf: data)
            writtenBytes += data.count
        } catch {
            // The file was moved or deleted underneath us; start a new one.
            try? handle.close()
            self.handle = nil
            try? data.write(to: url, options: .atomic)
            writtenBytes = data.count
        }
    }

    private func openLocked(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return }
        writtenBytes = Int((try? opened.seekToEnd()) ?? 0)
        handle = opened
    }

    private func closeLocked() {
        try? handle?.close()
        handle = nil
        writtenBytes = 0
    }

    /// One generation only: the log is a debugging aid, not an archive.
    private func rotate(_ url: URL) {
        let previous = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }

    deinit {
        try? handle?.close()
    }

    public func clear() {
        queue.async {
            guard let url = self.url else { return }
            self.closeLocked()
            try? FileManager.default.removeItem(at: url)
        }
    }
}
