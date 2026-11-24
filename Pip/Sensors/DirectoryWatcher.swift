import Foundation

/// Calls back when a directory's contents change: a kernel event source (no
/// polling), debounced so one file write is one callback. Design notes: Docs/history/Sensors.md.
final class DirectoryWatcher {

    private let url: URL
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: DispatchWorkItem?

    init?(url: URL, debounce: TimeInterval = 0.35, onChange: @escaping () -> Void) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.url = url
        self.onChange = onChange
        self.debounce = debounce
        guard open() else { return nil }
    }

    deinit { close() }

    @discardableResult
    private func open() -> Bool {
        // Notifications only; doesn't keep the volume from unmounting.
        descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main)

        // Captured: `self.source` isn't set until after resume().
        source.setEventHandler { [weak self, source] in
            guard let self else { return }
            let flags = source.data
            // Replaced rather than edited: reopen on the new file.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.close()
                _ = self.open()
            }
            self.schedule()
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        source.resume()
        self.source = source
        return true
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    func close() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }
}
