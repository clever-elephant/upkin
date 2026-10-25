import CoreServices
import Foundation
import Darwin

/// FSEvents discovers files; vnode sources catch appends from long-lived rollout writers without polling.
@MainActor
public final class CodexStateWatcher {
    nonisolated public static var rootURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? "\(NSHomeDirectory())/.codex", isDirectory: true)
    }

    private let root: URL
    private let activityURL: URL?
    private let onChange: (Set<URL>, Bool) -> Void
    nonisolated(unsafe) private var stream: FSEventStreamRef?
    nonisolated(unsafe) private var rolloutSources: [URL: DispatchSourceFileSystemObject] = [:]

    public init(rootURL: URL = CodexStateWatcher.rootURL, activityURL: URL? = nil, onChange: @escaping (Set<URL>, Bool) -> Void) throws {
        self.root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.activityURL = activityURL?.resolvingSymlinksInPath().standardizedFileURL
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        self.stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<CodexStateWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            MainActor.assumeIsolated {
                watcher.receive(paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
            }
        }, &context, ([self.root.path] + (self.activityURL.map { [$0.path] } ?? [])) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { throw CocoaError(.fileReadUnknown) }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            throw CocoaError(.fileReadUnknown)
        }
        self.refreshRollouts()
    }

    public func refreshRollouts(now: Date = Date()) {
        let files = CodexRolloutFiles.recent(in: self.root.appendingPathComponent("sessions"), now: now)
        for file in Array(self.rolloutSources.keys) where !files.contains(file) {
            self.rolloutSources.removeValue(forKey: file)?.cancel()
        }
        for file in files { self.watchRollout(file) }
    }

    deinit {
        for source in self.rolloutSources.values { source.cancel() }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func watchRollout(_ file: URL) {
        guard self.rolloutSources[file] == nil,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return }
        let descriptor = open(file.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .extend, .rename, .delete, .revoke], queue: .main)
        source.setCancelHandler { close(descriptor) }
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.rolloutSources[file] else { return }
                if !source.data.intersection([.rename, .delete, .revoke]).isEmpty {
                    self.rolloutSources.removeValue(forKey: file)?.cancel()
                    self.watchRollout(file)
                }
                self.onChange([file], false)
            }
        }
        self.rolloutSources[file] = source
        source.resume()
    }

    private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        let sessions = self.root.appendingPathComponent("sessions").path
        let files = Set(["auth.json", "session_index.jsonl"].map {
            self.root.appendingPathComponent($0).path
        })
        var changed = Set<URL>()
        var rescan = false
        for (rawPath, flag) in zip(paths, flags) {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            let path = url.path
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped) != 0 { rescan = true }
            if files.contains(path) { changed.insert(url) }
            if url.deletingLastPathComponent() == self.root,
               url.lastPathComponent.hasPrefix("state_"),
               url.lastPathComponent.hasSuffix(".sqlite") || url.lastPathComponent.hasSuffix(".sqlite-wal") {
                changed.insert(url)
            }
            if let activityURL = self.activityURL {
                if path == activityURL.path { rescan = true }
                else if url.deletingLastPathComponent().path == activityURL.path && url.pathExtension == "json" {
                    changed.insert(url)
                }
            }
            if path == sessions || path.hasPrefix(sessions + "/") {
                if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 { rescan = true }
                else if url.pathExtension == "jsonl" {
                    self.watchRollout(url)
                    changed.insert(url)
                }
            }
        }
        if rescan { self.refreshRollouts() }
        if rescan || !changed.isEmpty { self.onChange(changed, rescan) }
    }
}
