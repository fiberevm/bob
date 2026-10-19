import Foundation
import CoreServices
import BobCore

/// One event stream per project, with no polling or filesystem work on the UI thread.
@MainActor final class ProjectFileWatcher {
    private final class Handler: @unchecked Sendable {
        let root: String
        let receive: @MainActor ([String]) -> Void
        @MainActor var active = true
        init(root: String, receive: @escaping @MainActor ([String]) -> Void) { self.root = root; self.receive = receive }
        @MainActor func deliver(_ paths: [String]) {
            if active { receive(paths) }
        }
    }
    private let handler: Handler
    private var stream: FSEventStreamRef?

    init(root: String, onChange: @escaping @MainActor ([String]) -> Void) throws {
        // Foundation can spell /private/var as /var; FSEvents uses the filesystem spelling.
        let root = root.withCString { pointer -> String in
            guard let resolved = realpath(pointer, nil) else { return root }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        handler = Handler(root: root, receive: onChange)
        // The stream owns its callback context until outstanding callbacks have drained.
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(handler).toOpaque(), retain: { info in
            guard let info else { return nil }
            return UnsafeRawPointer(Unmanaged<Handler>.fromOpaque(info).retain().toOpaque())
        }, release: { info in
            if let info { Unmanaged<Handler>.fromOpaque(info).release() }
        }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let handler = Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            let flags = Array(UnsafeBufferPointer(start: flags, count: count))
            let changed = ProjectFileWatcher.changedPaths(root: handler.root, paths: paths, flags: flags)
            if !changed.isEmpty { Task { @MainActor in handler.deliver(changed) } }
        }, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            throw BobError.message("Could not watch project files for search updates.")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "Bob.project-file-events", qos: .utility))
        guard FSEventStreamStart(stream) else {
            stop()
            throw BobError.message("Could not start watching project files for search updates.")
        }
    }

    nonisolated static func changedPaths(root: String, paths: [String], flags: [FSEventStreamEventFlags]) -> [String] {
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped |
            kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
        if flags.contains(where: { $0 & rescan != 0 }) { return [""] }
        let membership = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved |
            kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsSymlink)
        let prefix = root == "/" ? "/" : root + "/"
        let changed = zip(paths, flags).compactMap { path, flag -> String? in
            guard flag & membership != 0 else { return nil }
            if path == root { return "" }
            guard path.hasPrefix(prefix) else { return nil }
            return String(path.dropFirst(prefix.count))
        }
        let filtered = ProjectFileSearch.changedPaths(changed)
        // A checkout or event backlog is cheaper to handle with one scan.
        return filtered.count > 256 ? [""] : filtered
    }

    func stop() {
        handler.active = false
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
