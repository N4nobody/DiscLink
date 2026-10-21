import AppKit
import SwiftUI
import UDFKit

/// AppModel only ever uses a volume on its serial I/O queue, so handing it to that queue is safe.
extension UDFVolume: @unchecked Sendable {}

/// Where the open disc comes from.
enum Source: Hashable {
    case drive(DriveInfo)
    case image(URL)

    var title: String {
        switch self {
        case .drive(let d): return d.displayName
        case .image(let u): return u.lastPathComponent
        }
    }

    // A drive is the same drive whatever its disc: while we hold it exclusively it stops
    // reporting a BSD name, so compare drives by registry ID only.
    static func == (a: Source, b: Source) -> Bool {
        switch (a, b) {
        case (.drive(let x), .drive(let y)): return x.stableID == y.stableID
        case (.image(let x), .image(let y)): return x == y
        default: return false
        }
    }

    func hash(into h: inout Hasher) {
        switch self {
        case .drive(let d): h.combine(0); h.combine(d.stableID)
        case .image(let u): h.combine(1); h.combine(u)
        }
    }
}

/// Facts about the open disc, gathered on the I/O queue (reading them may talk to the drive).
struct VolumeInfo {
    var name: String
    var layout: String
    var revision: String
    var mediaType: String?
    var total: UInt64
    var free: UInt64
    var readOnlyReason: String?
    var warnings: [String]
    var isWriteOnce: Bool
    var isRealDrive: Bool
}

/// A long-running operation shown as a progress sheet.
struct Busy {
    var title: String
    var done: UInt64 = 0
    var total: UInt64 = 0
    /// Show the "don't eject while writing" hint (only for operations that write).
    var writes = false
}

@MainActor
final class AppModel: ObservableObject {
    @Published var drives: [DriveInfo] = []
    @Published var images: [URL] = []
    @Published var source: Source?
    @Published private(set) var info: VolumeInfo?
    @Published private(set) var path = ""
    @Published private(set) var entries: [UDFEntry] = []
    @Published var selection = Set<UDFEntry.ID>()
    @Published private(set) var busy: Busy?
    @Published var errorMessage: String?
    /// Title of the error alert; most errors are failed operations.
    @Published var errorTitle = L("操作失败", "Something Went Wrong")
    @Published var openError: String?
    @Published var checkReport: CheckReport?
    /// A write waiting for the one-time "real disc" confirmation.
    @Published var pendingWrite: (() -> Void)?
    // View state lives here: this toolchain has no SwiftUI macro plugin, so `@State` isn't available.
    @Published var newFolderName = ""
    @Published var askingFolderName = false
    @Published var confirmingDelete = false
    @Published var dropTargeted = false

    /// The UDFVolume is not thread-safe: it is only ever touched on this queue.
    private let queue = DispatchQueue(label: "udfdisc.io", qos: .userInitiated)
    private var volume: UDFVolume?
    private var confirmedRealDiscWrite = false
    private var timer: Timer?
    // Auto-loading: a disc found in a drive is opened without a click, once per insertion.
    /// Drives whose current disc was already opened, closed by the user, or passed over for an
    /// image; cleared when the disc is taken out.
    private var noAutoOpen = Set<UInt64>()
    /// When we gave a drive back to macOS. For a few seconds after that it reports no disc
    /// until macOS has mounted it again, which must not count as the disc being removed.
    private var releasedAt: [UInt64: Date] = [:]
    private var launched = false
    /// When each drive's current disc was first seen, so auto-loading waits for macOS to settle.
    private var discSeenAt: [UInt64: Date] = [:]

    init() {
        refreshDrives()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDrives() }
        }
    }

    var canWrite: Bool { info != nil && info?.readOnlyReason == nil && busy == nil }
    var pathComponents: [String] { path.split(separator: "/").map(String.init) }

    func refreshDrives() {
        let list = OpticalDrive.list()
        if list != drives { drives = list }
        // The drive we are using is gone from the system: unplugged, or reset by USB (which
        // also gives it new registry entries). Its connection is dead, so close the disc.
        if case .drive(let open) = source, volume != nil, busy == nil,
           !list.contains(where: { $0.stableID == open.stableID }) {
            Task { await driveLost(open) }
            return
        }
        for d in list {
            if d.bsdName.isEmpty { discSeenAt[d.stableID] = nil }
            else if discSeenAt[d.stableID] == nil { discSeenAt[d.stableID] = Date() }
        }
        let held = volume != nil ? currentDrive?.stableID : nil
        for d in list where d.bsdName.isEmpty && d.stableID != held {
            let justReleased = releasedAt[d.stableID].map { Date().timeIntervalSince($0) < 15 } ?? false
            if !justReleased { noAutoOpen.remove(d.stableID) }   // the disc really is gone
        }
        autoOpenIfNeeded()
    }

    /// Called once the window is up. An image named on the command line wins over discs
    /// already in a drive.
    func didLaunch(openingImage: Bool) {
        launched = true
        if openingImage {
            for d in drives where !d.bsdName.isEmpty { noAutoOpen.insert(d.stableID) }
        }
        refreshDrives()
    }

    /// Opens a newly inserted disc (or the one present at launch) without a click.
    private func autoOpenIfNeeded() {
        guard launched, busy == nil else { return }
        if volume != nil, currentDrive != nil { return }          // already showing a disc
        guard let d = drives.first(where: { !$0.bsdName.isEmpty && !noAutoOpen.contains($0.stableID) }) else { return }
        // A disc that just went in is still being mounted by macOS; give it a moment.
        if let seen = discSeenAt[d.stableID], Date().timeIntervalSince(seen) < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in self?.autoOpenIfNeeded() }
            return
        }
        Task { await open(.drive(d)) }
    }

    // MARK: Background work

    private func run<T>(_ body: @escaping (UDFVolume?) throws -> T) async throws -> T {
        let vol = volume
        return try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try body(vol) }) }
        }
    }

    /// Runs a step with a progress sheet; errors become an alert.
    private func perform(_ title: String, total: UInt64 = 0, writes: Bool = true,
                         _ body: @escaping (UDFVolume, @escaping (UInt64) -> Void) throws -> Void) async {
        guard let vol = volume else { return }
        busy = Busy(title: title, total: total, writes: writes)
        var last = Date.distantPast
        let report: (UInt64) -> Void = { [weak self] done in
            // Called on the I/O queue; update the UI at most ten times a second.
            let now = Date()
            guard now.timeIntervalSince(last) > 0.1 else { return }
            last = now
            DispatchQueue.main.async { self?.busy?.done = done }
        }
        do {
            try await run { _ in try body(vol, report) }
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh()
        busy = nil
    }

    // MARK: Opening and closing

    func open(_ s: Source) async {
        if source == s, volume != nil { return }
        switch s {
        case .drive(let d): noAutoOpen.insert(d.stableID)
        case .image:
            // Choosing an image means not jumping back to a disc that is already in a drive.
            for d in drives where !d.bsdName.isEmpty { noAutoOpen.insert(d.stableID) }
        }
        await close()
        source = s
        openError = nil
        busy = Busy(title: L("正在读取光盘…", "Reading the disc…"))
        defer { busy = nil }
        do {
            let vol = try await run { _ in try Self.makeVolume(s) }
            volume = vol
            path = ""
            await refresh()
        } catch {
            openError = error.localizedDescription
        }
    }

    private nonisolated static func makeVolume(_ s: Source) throws -> UDFVolume {
        switch s {
        case .drive(let d):
            return try UDFVolume.open(OpticalDrive(d, allowWrite: true))
        case .image(let url):
            let writable = FileManager.default.isWritableFile(atPath: url.path)
            let v = try UDFVolume.open(ImageDevice(url: url, writable: writable))
            // An image of a CD-R/DVD-R can only be appended to, like the real disc.
            if v.isWriteOnce && writable {
                v.device.close()
                return try UDFVolume.open(ImageDevice(url: url, writable: true, sequential: true))
            }
            return v
        }
    }

    /// Releases the disc. For a drive this gives it back to macOS, which mounts it again.
    func close() async {
        guard let vol = volume else { return }
        if let d = currentDrive { releasedAt[d.stableID] = Date() }
        volume = nil
        info = nil
        entries = []
        selection = []
        confirmedRealDiscWrite = false
        _ = try? await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async { vol.device.close(); c.resume() }
        }
    }

    /// The drive whose disc is open (or failed to open), if the current source is a drive.
    var currentDrive: DriveInfo? {
        if case .drive(let d) = source { return d }
        return nil
    }

    /// Ejects the disc (or opens an empty tray). A drive we hold is ejected through our own
    /// connection and then released; any other drive is ejected the way the Finder does it.
    func eject(_ drive: DriveInfo) async {
        guard busy == nil else { return }
        busy = Busy(title: L("正在推出光盘…", "Ejecting the disc…"))
        defer { busy = nil }
        let ours = currentDrive?.stableID == drive.stableID
        let vol = ours ? volume : nil
        if ours {
            volume = nil
            info = nil
            entries = []
            selection = []
            openError = nil
            source = nil
            confirmedRealDiscWrite = false
        }
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.async {
                    c.resume(with: Result {
                        if let d = vol?.device as? OpticalDrive { try d.eject() } else { try OpticalDrive.eject(drive) }
                    })
                }
            }
            noAutoOpen.remove(drive.stableID)   // the next disc put in gets opened again
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshDrives()
    }

    private func driveLost(_ drive: DriveInfo) async {
        await close()
        source = nil
        openError = nil
        errorTitle = L("光驱已断开", "Drive Disconnected")
        errorMessage = L("“\(drive.displayName)”断开了连接。重新接好后，光盘会自动载入。", "“\(drive.displayName)” was disconnected. Once it's connected again, the disc opens automatically.")
    }

    /// Closes whatever is open and clears the sidebar selection.
    func closeSource() async {
        if let d = currentDrive { noAutoOpen.insert(d.stableID) }   // stay closed until the disc changes
        await close()
        source = nil
        openError = nil
    }

    func closeSynchronously() {
        guard let vol = volume else { return }
        volume = nil
        queue.sync { vol.device.close() }
    }

    func openImagePanel() {
        let panel = NSOpenPanel()
        panel.title = L("打开光盘镜像", "Open Disc Image")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addImage(url)
    }

    func addImage(_ url: URL) {
        if !images.contains(url) { images.append(url) }
        Task { await open(.image(url)) }
    }

    // MARK: Browsing

    func refresh() async {
        guard volume != nil else { return }
        let p = path
        do {
            let (list, i) = try await run { v -> ([UDFEntry], VolumeInfo) in
                guard let v else { throw UDFError(L("没有打开光盘", "No disc is open")) }
                return (try v.list(p), Self.describe(v))
            }
            entries = list
            info = i
            selection = selection.filter { id in list.contains { $0.id == id } }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func describe(_ v: UDFVolume) -> VolumeInfo {
        let drive = v.device as? OpticalDrive
        return VolumeInfo(name: v.volumeName.isEmpty ? L("未命名", "Untitled") : v.volumeName, layout: v.layoutDescription,
                          revision: v.revisionString, mediaType: drive?.profileName,
                          total: v.totalBytes, free: v.freeBytes, readOnlyReason: v.readOnlyReason,
                          warnings: v.warnings, isWriteOnce: v.isWriteOnce, isRealDrive: drive != nil)
    }

    func go(to newPath: String) async {
        path = newPath
        selection = []
        await refresh()
    }

    func goUp() async {
        await go(to: pathComponents.dropLast().joined(separator: "/"))
    }

    func activate(_ ids: Set<UDFEntry.ID>) async {
        guard ids.count == 1, let e = entries.first(where: { ids.contains($0.id) }), e.isDirectory else { return }
        await go(to: e.path)
    }

    // MARK: Writing

    /// Runs `action` after the one-time warning for real discs.
    func guardWrite(_ action: @escaping () -> Void) {
        if info?.isRealDrive == true && !confirmedRealDiscWrite {
            pendingWrite = action
        } else {
            action()
        }
    }

    func confirmPendingWrite() {
        confirmedRealDiscWrite = true
        let a = pendingWrite
        pendingWrite = nil
        a?()
    }

    func addPanel() {
        let panel = NSOpenPanel()
        panel.title = L("添加到光盘", "Add to Disc")
        panel.prompt = L("添加", "Add")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func add(_ urls: [URL]) {
        guard canWrite, !urls.isEmpty else { return }
        guardWrite { [self] in
            Task { await self.performAdd(urls) }
        }
    }

    private func performAdd(_ urls: [URL]) async {
        let base = path
        let total = urls.reduce(UInt64(0)) { $0 + Self.localSize($1) }
        let existing = Set(entries.map { $0.name.lowercased() })
        let clashes = urls.filter { existing.contains($0.lastPathComponent.lowercased()) }
        if !clashes.isEmpty, !confirmReplace(clashes.map(\.lastPathComponent)) { return }
        let title = urls.count == 1 ? L("正在写入“\(urls[0].lastPathComponent)”…", "Writing “\(urls[0].lastPathComponent)”…") : L("正在写入 \(urls.count) 项…", "Writing \(urls.count) items…")
        await perform(title, total: total) { v, progress in
            var done: UInt64 = 0
            for url in urls {
                let target = base.isEmpty ? url.lastPathComponent : base + "/" + url.lastPathComponent
                let start = done
                try v.add(from: url, to: target, overwrite: true) { n in progress(start + n) }
                done = start + Self.localSize(url)
                guard try v.verify(target, against: url) else {
                    throw UDFError(L("校验失败：光盘上的“\(url.lastPathComponent)”和原文件不一致", "Verification failed: “\(url.lastPathComponent)” on the disc differs from the original"))
                }
            }
        }
    }

    private func confirmReplace(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? L("“\(names[0])”已经存在，要替换吗？", "“\(names[0])” already exists. Replace it?") : L("有 \(names.count) 项已经存在，要替换吗？", "\(names.count) items already exist. Replace them?")
        alert.informativeText = info?.isWriteOnce == true
            ? L("一次性写入盘上的旧版本不会被擦掉，只是不再显示，占用的空间也不会释放。", "On a write-once disc the old version isn't erased, only hidden, and its space isn't freed.")
            : L("光盘上的旧版本会被删除。", "The old version on the disc will be deleted.")
        alert.addButton(withTitle: L("替换", "Replace"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func makeFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard canWrite, !trimmed.isEmpty else { return }
        let target = path.isEmpty ? trimmed : path + "/" + trimmed
        guardWrite { [self] in
            Task { await self.perform(L("正在新建文件夹…", "Creating the folder…")) { v, _ in try v.makeDirectory(target) } }
        }
    }

    var selectedEntries: [UDFEntry] { entries.filter { selection.contains($0.id) } }

    func delete(_ items: [UDFEntry]) {
        guard canWrite, !items.isEmpty else { return }
        guardWrite { [self] in
            Task {
                await self.perform(L("正在删除…", "Deleting…")) { v, _ in
                    for e in items { try v.remove(e.path) }
                }
            }
        }
    }

    func exportPanel(_ items: [UDFEntry]) {
        guard !items.isEmpty, volume != nil else { return }
        let panel = NSOpenPanel()
        panel.title = L("导出到", "Export To")
        panel.prompt = L("导出", "Export")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let total = (try? await run { v in try items.reduce(UInt64(0)) { $0 + (try Self.discSize($1, in: v!)) } }) ?? 0
            await perform(L("正在导出…", "Exporting…"), total: total, writes: false) { v, progress in
                var done: UInt64 = 0
                for e in items {
                    let start = done
                    let dest = Self.uniqueURL(folder.appendingPathComponent(e.name))
                    try v.export(e.path, to: dest) { n in progress(start + n) }
                    done = start + (try Self.discSize(e, in: v))
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    func runCheck() async {
        guard volume != nil else { return }
        busy = Busy(title: L("正在检查光盘…", "Checking the disc…"))
        do { checkReport = try await run { v in try v!.check() } } catch { errorMessage = error.localizedDescription }
        busy = nil
    }

    // MARK: Sizes

    private nonisolated static func localSize(_ url: URL) -> UInt64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(UInt64.init) ?? 0
        }
        var total: UInt64 = 0
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += UInt64(v.fileSize ?? 0)
            }
        }
        return total
    }

    private nonisolated static func discSize(_ e: UDFEntry, in v: UDFVolume) throws -> UInt64 {
        guard e.isDirectory else { return e.size }
        return try v.list(e.path).reduce(UInt64(0)) { $0 + (try discSize($1, in: v)) }
    }

    private nonisolated static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for i in 2... {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
