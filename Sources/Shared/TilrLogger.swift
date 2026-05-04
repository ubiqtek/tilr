import Foundation

/// File-based logger. Appends to ~/.local/share/tilr/tilr.log.
/// Runs both in the app and the CLI — no OSLog dependency.
///
/// Thread-safety: all writes serialised through a dedicated DispatchQueue.
/// Rolling: file is renamed to tilr.log.1 once it exceeds 5 MB.
public final class TilrLogger {

    public static let shared = TilrLogger()

    // MARK: - Configuration

    private static let maxBytes: Int = 5 * 1024 * 1024  // 5 MB

    // MARK: - State

    private let queue = DispatchQueue(label: "io.ubiqtek.tilr.file-log", qos: .utility)
    private let logURL: URL
    private var handle: FileHandle?

    // MARK: - Init

    public init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/tilr", isDirectory: true)
        logURL = base.appendingPathComponent("tilr.log")

        queue.async { [weak self] in
            self?.openHandle()
        }
    }

    // MARK: - Public API

    /// Write a normal log line: `<timestamp> [CATEGORY] message`
    public func log(_ message: String, category: String) {
        let line = "\(timestamp()) [\(category)] \(message)\n"
        write(line)
    }

    /// Write a visually distinct marker line: `<timestamp> [MARKER] --- text ---`
    /// Markers are synchronous to ensure they're flushed immediately.
    public func marker(_ text: String) {
        let line = "\(timestamp()) [MARKER] --- \(text) ---\n"
        // Use sync to ensure markers are written immediately before returning
        queue.sync { [weak self] in
            guard let self else { return }
            guard let data = line.data(using: .utf8) else { return }
            self.rollIfNeeded()
            self.handle?.write(data)
            self.handle?.synchronizeFile()
        }
    }

    // MARK: - Private helpers

    private func write(_ line: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = line.data(using: .utf8) else { return }
            self.rollIfNeeded()
            self.handle?.write(data)
        }
    }

    private func openHandle() {
        // Ensure parent directory exists
        let dir = logURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Open with O_APPEND so the kernel atomically positions every write
        // at EOF. This is essential because both the running Tilr.app and the
        // short-lived `tilr` CLI process may hold their own log handles
        // concurrently. Without O_APPEND, FileHandle's internal write offset
        // can lag behind the actual file size, causing one process to
        // overwrite lines another process just appended (observed: CLI
        // markers vanishing because the daemon's stale offset stomped on
        // them).
        let fd = open(logURL.path,
                      O_WRONLY | O_APPEND | O_CREAT,
                      0o644)
        if fd >= 0 {
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    private func rollIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? Int,
              size >= Self.maxBytes else { return }

        handle?.closeFile()
        handle = nil

        let rolled = logURL.deletingLastPathComponent().appendingPathComponent("tilr.log.1")
        try? FileManager.default.removeItem(at: rolled)
        try? FileManager.default.moveItem(at: logURL, to: rolled)

        openHandle()
    }

    private func timestamp() -> String {
        var tv = timeval()
        gettimeofday(&tv, nil)
        var tm = tm()
        gmtime_r(&tv.tv_sec, &tm)
        let ms = tv.tv_usec / 1000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03ldZ",
                      tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                      tm.tm_hour, tm.tm_min, tm.tm_sec, ms)
    }
}
