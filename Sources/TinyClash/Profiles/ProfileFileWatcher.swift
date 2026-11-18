import Foundation

/// 监听当前配置文件的外部修改（同时监听目录与目标文件，兼容原地写入和原子替换保存），去抖后通知上层检查变更
final class ProfileFileWatcher {
    private let queue = DispatchQueue(label: "TinyClash.profileWatcher")
    private let debounceNanoseconds: UInt64
    private let onChange: @Sendable () -> Void

    private var watchedDirectory: URL?
    private var watchedFile: URL?
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?

    init(debounceMilliseconds: Int = 400, onChange: @escaping @Sendable () -> Void) {
        self.debounceNanoseconds = UInt64(max(debounceMilliseconds, 50)) * 1_000_000
        self.onChange = onChange
    }

    func watch(file: URL?) {
        queue.async { [weak self] in
            self?.configure(file: file)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.teardown()
        }
    }

    private func configure(file: URL?) {
        let dir = file?.deletingLastPathComponent()
        if watchedDirectory != dir {
            dirSource?.cancel()
            dirSource = nil
            watchedDirectory = dir
            if let dir {
                dirSource = makeSource(for: dir, events: [.write, .rename, .delete, .extend]) { [weak self] in
                    guard let self else { return }
                    self.reattachFileSourceIfNeeded()
                    self.scheduleCallback()
                }
            }
        }

        if watchedFile != file {
            watchedFile = file
            attachFileSource()
        } else if file != nil && fileSource == nil {
            attachFileSource()
        }
    }

    private func attachFileSource() {
        fileSource?.cancel()
        fileSource = nil
        guard let file = watchedFile else { return }
        fileSource = makeSource(for: file, events: [.write, .extend, .rename, .delete]) { [weak self] in
            guard let self else { return }
            self.reattachFileSourceIfNeeded()
            self.scheduleCallback()
        }
    }

    private func reattachFileSourceIfNeeded() {
        guard let file = watchedFile else { return }
        let currentFD = fileSource.map { Int32($0.handle) }
        var currentStat = stat()
        var diskStat = stat()
        let hasCurrent = currentFD.map { fstat($0, &currentStat) == 0 } ?? false
        let hasDisk = stat(file.path, &diskStat) == 0
        if hasDisk && (!hasCurrent || currentStat.st_ino != diskStat.st_ino || currentStat.st_dev != diskStat.st_dev) {
            attachFileSource()
        } else if !hasDisk && fileSource != nil {
            fileSource?.cancel()
            fileSource = nil
        }
    }

    private func makeSource(for url: URL,
                            events: DispatchSource.FileSystemEvent,
                            handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func scheduleCallback() {
        debounceWork?.cancel()
        let item = DispatchWorkItem { [onChange] in
            onChange()
        }
        debounceWork = item
        queue.asyncAfter(deadline: .now() + .nanoseconds(Int(debounceNanoseconds)), execute: item)
    }

    private func teardown() {
        debounceWork?.cancel()
        debounceWork = nil
        fileSource?.cancel()
        fileSource = nil
        dirSource?.cancel()
        dirSource = nil
        watchedFile = nil
        watchedDirectory = nil
    }

    deinit {
        debounceWork?.cancel()
        fileSource?.cancel()
        dirSource?.cancel()
    }
}
