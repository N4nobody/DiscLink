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

/// Keeps a completed write distinct from a later verification or display failure.
private struct OperationFailure: LocalizedError {
    let title: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var drives: [DriveInfo] = []
    @Published var images: [URL] = []
    @Published var source: Source?
    @Published private(set) var info: VolumeInfo?
    @Published private(set) var path = ""
    @Published private(set) var entries: [UDFEntry] = [] { didSet { resort() } }
    /// `entries` in the chosen order; this is what the list shows.
    @Published private(set) var displayedEntries: [UDFEntry] = []
    @Published var sortKey: EntrySort = .name { didSet { sortChanged() } }
    @Published var sortAscending = true { didSet { sortChanged() } }
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
    @Published var confirmingDirectoryRepair = false
    @Published var dropTargeted = false
    @Published private(set) var preparingImport = false
    @Published private(set) var importConflict: DiscImportConflict?
    @Published var applyChoiceToRemainder = false
    private var conflictResponse: CheckedContinuation<DiscImportChoice, Never>?
    private var importChoices: [DiscImportConflict.Kind: DiscImportChoice] = [:]

    /// The UDFVolume is not thread-safe: it is only ever touched on this queue.
    private let queue = DispatchQueue(label: "udfdisc.io", qos: .userInitiated)
    private var volume: UDFVolume?
    private var dragExportSource: DragExportSource?
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
        if let k = UserDefaults.standard.string(forKey: "sortKey").flatMap(EntrySort.init(rawValue:)) { sortKey = k }
        if UserDefaults.standard.object(forKey: "sortAscending") != nil {
            sortAscending = UserDefaults.standard.bool(forKey: "sortAscending")
        }
        refreshDrives()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDrives() }
        }
    }

    var canWrite: Bool { info != nil && info?.readOnlyReason == nil && busy == nil && !preparingImport && pendingWrite == nil }
    var canRepairDirectory: Bool { canWrite && info?.isWriteOnce == true }
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
        guard launched, busy == nil, !preparingImport else { return }
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
        let (result, reason): (Result<T, Error>, String?) = await withCheckedContinuation { c in
            queue.async {
                let result = Result { try body(vol) }
                c.resume(returning: (result, vol?.readOnlyReason))
            }
        }
        // A failed read can revoke write access before we can refresh the list.
        if let vol, volume === vol, let reason, info?.readOnlyReason != reason {
            info?.readOnlyReason = reason
        }
        return try result.get()
    }

    /// Reports the operation and its follow-up refresh together, without replacing
    /// the original failure or showing a second alert for the same operation.
    private func perform(_ title: String, total: UInt64 = 0, writes: Bool = true,
                         refreshFailureMessage: String? = nil,
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
        var operationError: Error?
        var refreshError: Error?
        do {
            try await run { _ in try body(vol, report) }
        } catch {
            operationError = error
        }
        do { try await refreshContents() } catch { refreshError = error }
        busy = nil
        if let error = operationError {
            let failure = error as? OperationFailure
            var message = error.localizedDescription
            if let refreshError {
                message += L("\n\n目录刷新也未完成，列表可能尚未更新。", "\n\nThe folder could not be refreshed either, so the list may be out of date.")
                if refreshError.localizedDescription != error.localizedDescription {
                    message += "\n" + refreshError.localizedDescription
                }
            }
            errorTitle = failure?.title ?? L("操作未完成", "Operation Incomplete")
            errorMessage = message
        } else if let error = refreshError {
            errorTitle = L("操作已完成，目录刷新失败", "Operation Completed, Folder Refresh Failed")
            errorMessage = (refreshFailureMessage ?? L("刚才的操作已完成，但当前目录未能重新读取。请先关闭并重新打开光盘检查结果，不要重复执行刚才的操作。",
                                                       "The operation completed, but the current folder could not be read again. Close and reopen the disc to check the result before repeating the operation."))
                + "\n\n" + error.localizedDescription
        }
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
            dragExportSource = DragExportSource()
            path = ""
            do {
                try await refreshContents()
            } catch {
                openError = L("光盘已打开，但首次读取目录失败。请关闭并重新打开光盘后再试。", "The disc opened, but its initial folder listing could not be read. Close and reopen the disc to try again.")
                    + "\n\n" + error.localizedDescription
            }
        } catch {
            openError = L("打开光盘失败。", "Opening the disc failed.") + "\n\n" + error.localizedDescription
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
        pendingWrite = nil
        answerImportConflict(.cancel)
        confirmingDirectoryRepair = false
        dragExportSource?.cancel()
        dragExportSource = nil
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
        guard busy == nil, !preparingImport else { return }
        busy = Busy(title: L("正在推出光盘…", "Ejecting the disc…"))
        defer { busy = nil }
        let ours = currentDrive?.stableID == drive.stableID
        let vol = ours ? volume : nil
        if ours {
            confirmingDirectoryRepair = false
            dragExportSource?.cancel()
            dragExportSource = nil
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
        dragExportSource?.cancel()
        dragExportSource = nil
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
        do {
            try await refreshContents()
        } catch {
            errorTitle = L("读取目录失败", "Folder Read Failed")
            errorMessage = error.localizedDescription
        }
    }

    /// Reads the current folder without deciding how its caller should report failure.
    private func refreshContents() async throws {
        let p = path
        let (list, i) = try await run { v -> ([UDFEntry], VolumeInfo) in
            guard let v else { throw UDFError(L("没有打开光盘", "No disc is open")) }
            return (try v.list(p), Self.describe(v))
        }
        entries = list
        info = i
        selection = selection.filter { id in list.contains { $0.id == id } }
    }

    private nonisolated static func describe(_ v: UDFVolume) -> VolumeInfo {
        let drive = v.device as? OpticalDrive
        return VolumeInfo(name: v.volumeName.isEmpty ? L("未命名", "Untitled") : v.volumeName, layout: v.layoutDescription,
                          revision: v.revisionString, mediaType: drive?.profileName,
                          total: v.totalBytes, free: v.freeBytes, readOnlyReason: v.readOnlyReason,
                          warnings: v.warnings, isWriteOnce: v.isWriteOnce, isRealDrive: drive != nil)
    }

    func go(to newPath: String) async {
        confirmingDirectoryRepair = false
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
        guard canWrite, !urls.isEmpty, let destination = volume else { return }
        let folder = path
        guardWrite { [self] in
            guard canWrite, volume === destination, path == folder else { return }
            preparingImport = true
            Task { await performAdd(urls, into: folder, on: destination) }
        }
    }

    private func chooseImportAction(_ conflict: DiscImportConflict) async -> DiscImportChoice {
        if let remembered = importChoices[conflict.kind] { return remembered }
        return await withCheckedContinuation { response in
            conflictResponse = response
            applyChoiceToRemainder = false
            importConflict = conflict
        }
    }

    func answerImportConflict(_ choice: DiscImportChoice) {
        guard let response = conflictResponse, let conflict = importConflict else { return }
        if applyChoiceToRemainder && choice != .cancel { importChoices[conflict.kind] = choice }
        conflictResponse = nil
        importConflict = nil
        response.resume(returning: choice)
    }

    private func performAdd(_ urls: [URL], into folder: String, on destination: UDFVolume) async {
        defer {
            preparingImport = false
            importChoices.removeAll()
        }
        let groups: [DiscImportGroup]
        do {
            let plan = try await DiscImportPlanner.plan(urls, into: folder, list: { path in
                try await self.run { vol in
                    guard vol === destination else { throw UDFError(L("目标光盘已更换", "The destination disc has changed")) }
                    return try destination.list(path)
                }
            }, decide: { conflict in
                guard self.volume === destination, self.path == folder else { return .cancel }
                return await self.chooseImportAction(conflict)
            })
            guard let plan, !plan.isEmpty, volume === destination, path == folder else { return }
            groups = plan
        } catch {
            errorTitle = L("无法准备添加文件", "Could Not Prepare the Import")
            errorMessage = error.localizedDescription
            return
        }
        let total = groups.reduce(UInt64(0)) { $0 + $1.byteCount }
        let title = groups.count == 1
            ? L("正在写入“\((groups[0].target as NSString).lastPathComponent)”…", "Writing “\((groups[0].target as NSString).lastPathComponent)”…")
            : L("正在写入 \(groups.count) 项…", "Writing \(groups.count) items…")
        await perform(title, total: total,
                      refreshFailureMessage: L("所选项目已写入并通过校验，但目录列表刷新失败。不要重复添加；请关闭并重新打开光盘，检查已写入的项目。",
                                               "The selected items were written and verified, but the folder list could not be refreshed. Do not add them again; close and reopen the disc to check the written items.")) { v, progress in
            try DiscImportPlanner.validateSources(groups)
            var done: UInt64 = 0
            for (index, group) in groups.enumerated() {
                let name = (group.target as NSString).lastPathComponent
                let start = done
                let remaining = groups.count - index - 1
                var batchSummary = ""
                if index > 0 {
                    batchSummary += L("\n\n前 \(index) 个所选项目已写入并通过校验。", "\n\nThe preceding \(index) selected items were written and verified.")
                }
                if remaining > 0 {
                    batchSummary += L("\n其余 \(remaining) 个所选项目尚未开始。", "\nThe remaining \(remaining) selected items have not been started.")
                }
                do {
                    try v.applyImport(group) { n in progress(start + n) }
                } catch {
                    throw OperationFailure(title: L("写入未完成", "Write Incomplete"),
                                           message: L("“\(name)”的写入未完成，无法确认该项目的最终状态。请重新打开光盘检查后再决定是否重试。",
                                                      "Writing “\(name)” did not complete, so its final state is unconfirmed. Reopen the disc and check it before deciding whether to retry.")
                                            + batchSummary + "\n\n" + error.localizedDescription)
                }
                done = start + group.byteCount
                let matches: Bool
                do {
                    matches = try v.verifyImport(group)
                } catch {
                    throw OperationFailure(title: L("已写入，校验未完成", "Written, Verification Incomplete"),
                                           message: L("“\(name)”已写入，但写后校验未能完成。不要重复添加；请关闭并重新打开光盘，再检查或导出该项目。",
                                                      "“\(name)” was written, but verification could not finish. Do not add it again; close and reopen the disc, then check or export the item.")
                                            + batchSummary + "\n\n" + error.localizedDescription)
                }
                guard matches else {
                    throw OperationFailure(title: L("已写入，但校验不一致", "Written, Verification Mismatch"),
                                           message: L("“\(name)”已写入，但校验发现光盘内容与本地原文件不一致。请保留原文件，重新打开光盘检查；不要直接重复添加。",
                                                      "“\(name)” was written, but verification found differences from the local original. Keep the original and reopen the disc to investigate before adding it again.")
                                            + batchSummary)
                }
            }
        }
    }

    func makeFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard canWrite, !trimmed.isEmpty else { return }
        let target = path.isEmpty ? trimmed : path + "/" + trimmed
        guardWrite { [self] in
            Task { await self.perform(L("正在新建文件夹…", "Creating the folder…")) { v, _ in try v.makeDirectory(target) } }
        }
    }

    /// Called only after the dedicated repair confirmation, which explains the append
    /// and asks the user to back up the disc before continuing.
    func repairCurrentDirectory() async {
        guard canRepairDirectory else { return }
        confirmingDirectoryRepair = false
        let target = path
        await perform(L("正在修复目录兼容性…", "Repairing folder compatibility…")) { v, _ in
            try v.repairDirectoryLayout(target)
        }
    }

    var selectedEntries: [UDFEntry] { entries.filter { selection.contains($0.id) } }

    // MARK: Sorting

    private func resort() {
        displayedEntries = sortKey.sorted(entries, ascending: sortAscending, kind: FileKinds.kind(of:))
    }

    private func sortChanged() {
        UserDefaults.standard.set(sortKey.rawValue, forKey: "sortKey")
        UserDefaults.standard.set(sortAscending, forKey: "sortAscending")
        resort()
    }

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

    /// Creates a file-promise writer bound to this exact open volume. The returned
    /// closure may be called on any queue; its completion is delivered on the main
    /// actor once. Destination is the final URL allocated by Finder, not its parent.
    func makeDragExporter(for entry: UDFEntry) -> ((URL, @escaping (Error?) -> Void) -> Void)? {
        let checkedPath = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
        guard busy == nil, let capturedVolume = volume, let capturedSource = dragExportSource,
              !capturedSource.isCancelled, entries.contains(entry),
              UDFVolume.isSafeExportName(entry.name),
              checkedPath.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ UDFVolume.isSafeExportName(String($0)) }) else { return nil }
        return { [weak self] destination, completion in
            Task { @MainActor [weak self] in
                guard let self, self.volume === capturedVolume,
                      self.dragExportSource === capturedSource, !capturedSource.isCancelled else {
                    completion(UDFError(L("原光盘已关闭或更换，请重新拖动", "The original disc was closed or changed; drag the item again")))
                    return
                }
                self.queue.async {
                    let error: Error?
                    do {
                        try capturedVolume.exportSafely(entry, to: destination,
                                                        isCancelled: { capturedSource.isCancelled })
                        error = nil
                    } catch let failure {
                        error = failure
                    }
                    DispatchQueue.main.async { completion(error) }
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
        var checkError: Error?
        do { checkReport = try await run { v in try v!.check() } } catch { checkError = error }
        busy = nil
        if let error = checkError {
            errorTitle = L("光盘检查未完成", "Disc Check Incomplete")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Sizes

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
