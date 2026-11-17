import Darwin
import Foundation

/// Observe the containing directory because bridges publish snapshots by atomically replacing the file.
@MainActor
final class BridgeDirectoryWatcher {
    private let target: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var directory: URL?
    private var debounce: Task<Void, Never>?
    private var revision = 0
    private var stopped = false

    init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        target = directory
        self.onChange = onChange
        bind()
    }

    func stop() {
        stopped = true
        revision += 1
        source?.cancel()
        source = nil
        debounce?.cancel()
        debounce = nil
    }

    private func bind(force: Bool = false) {
        guard !stopped else { return }
        var nearest = target
        var isDirectory: ObjCBool = false
        while !FileManager.default.fileExists(atPath: nearest.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            let parent = nearest.deletingLastPathComponent()
            guard parent != nearest else { return }
            nearest = parent
        }
        if !force, directory == nearest { return }
        revision += 1
        source?.cancel()
        source = nil
        directory = nil
        let fd = open(nearest.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let observed = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .revoke], queue: .main
        )
        let generation = revision
        observed.setCancelHandler { close(fd) }
        observed.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.received(generation: generation) }
        }
        directory = nearest
        source = observed
        observed.resume()
    }

    private func received(generation: Int) {
        guard generation == revision, !stopped, let events = source?.data else { return }
        bind(force: !events.intersection([.delete, .rename, .revoke]).isEmpty)
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self, !stopped else { return }
            onChange()
        }
    }

    deinit {
        source?.cancel()
        debounce?.cancel()
    }
}
