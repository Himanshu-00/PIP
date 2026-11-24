import Foundation

/// The `media-control` CLI's live now-playing stream — the one route that sees
/// every player, browsers included (`brew install ungive/media-control/media-control`).
/// Design notes: Docs/history/Media.md.
final class MediaControlStream {

    static let searchPaths = [
        "/opt/homebrew/bin/media-control",
        "/usr/local/bin/media-control",
        "\(NSHomeDirectory())/.local/bin/media-control",
        "/opt/homebrew/opt/media-control/bin/media-control"
    ]

    static func locateBinary() -> String? {
        let fm = FileManager.default
        for path in searchPaths where fm.isExecutableFile(atPath: path) { return path }

        // The login shell knows custom Homebrew prefixes.
        let found = ScriptBridge.run("/bin/zsh", ["-lc", "command -v media-control"], timeout: 5)
        let path = found.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }

    private let binary: String
    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.himanshu.dynamicnotch.mediacontrol")

    /// Called on the main queue with the merged, complete payload.
    var onPayload: (([String: Any]?) -> Void)?
    /// Called on the main queue if the stream dies unexpectedly.
    var onFailure: (() -> Void)?

    private var merged: [String: Any] = [:]

    init(binary: String) { self.binary = binary }

    func start() {
        stop()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["stream"]

        let out = Pipe()
        task.standardOutput = out
        // Not a pipe: one nobody reads fills at 64 KB and blocks the process.
        task.standardError = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            self?.queue.async { self?.consume(chunk) }
        }

        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.onFailure?() }
        }

        do {
            try task.run()
            process = task
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
        }
    }

    func stop() {
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        buffer.removeAll()
        merged.removeAll()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
        // A runaway line is dropped.
        if buffer.count > 8_000_000 { buffer.removeAll() }
    }

    private func handle(line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line),
              let root = object as? [String: Any] else { return }

        guard let payload = root["payload"] as? [String: Any] else { return }
        let isDiff = (root["diff"] as? Bool) ?? false

        if isDiff {
            for (key, value) in payload {
                if value is NSNull { merged.removeValue(forKey: key) }
                else { merged[key] = value }
            }
        } else {
            merged = payload.filter { !($0.value is NSNull) }
        }

        let snapshot = merged
        DispatchQueue.main.async { [weak self] in
            self?.onPayload?(snapshot.isEmpty ? nil : snapshot)
        }
    }
}
