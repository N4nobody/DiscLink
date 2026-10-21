import SwiftUI
import UDFKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            Detail()
        }
        .sheet(isPresented: Binding(get: { model.busy != nil }, set: { _ in })) {
            if let b = model.busy { ProgressSheet(busy: b) }
        }
        .sheet(item: Binding(get: { model.checkReport.map(ReportBox.init) }, set: { if $0 == nil { model.checkReport = nil } })) {
            CheckReportView(report: $0.report)
        }
        .alert(model.errorTitle, isPresented: Binding(get: { model.errorMessage != nil },
                                                      set: { if !$0 { model.errorMessage = nil; model.errorTitle = L("操作失败", "Something Went Wrong") } })) {
            Button(L("好", "OK")) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(L("要写入这张光盘吗？", "Write to This Disc?"), isPresented: Binding(get: { model.pendingWrite != nil }, set: { if !$0 { model.pendingWrite = nil } })) {
            Button(L("写入", "Write")) { model.confirmPendingWrite() }
            Button(L("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(model.info?.isWriteOnce == true
                 ? L("这是一次性写入盘，写进去的内容无法擦除。这个程序还没有在很多光驱上测试过，第一次使用请先用不重要的光盘试。", "This is a write-once disc: whatever you write can't be erased. This app hasn't been tested with many drives yet, so try it with an unimportant disc first.")
                 : L("这个程序还没有在很多光驱上测试过，第一次使用请先用不重要的光盘试，或先备份光盘上的文件。", "This app hasn't been tested with many drives yet. Try it with an unimportant disc first, or back up the files on this disc."))
        }
    }
}

private struct ReportBox: Identifiable {
    let id = UUID()
    let report: CheckReport
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.source }, set: { s in
            if let s { Task { await model.open(s) } }
        })) {
            Section(L("光驱", "Drives")) {
                if model.drives.isEmpty {
                    Text(L("没有连接光驱", "No drive connected")).foregroundStyle(.secondary)
                }
                ForEach(model.drives) { d in
                    let isOpen = model.source == .drive(d) && model.info != nil
                    let hasDisc = !d.bsdName.isEmpty || model.source == .drive(d)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(d.shortName, systemImage: "opticaldiscdrive")
                                .lineLimit(1)
                            Text(isOpen ? "\(model.info?.mediaType ?? L("光盘", "Disc")) · \(L("已打开", "open"))"
                                        : (hasDisc ? L("有光盘", "Disc inserted") : L("没有光盘", "No disc")))
                                .font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                        }
                        .help(d.displayName)
                        Spacer()
                        // Like the Finder's sidebar: an eject button right on the drive's row.
                        Button { Task { await model.eject(d) } } label: {
                            Image(systemName: "eject.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(hasDisc ? L("推出光盘", "Eject Disc") : L("打开托盘", "Open Tray"))
                        .disabled(model.busy != nil)
                    }
                    .tag(Source.drive(d))
                    .selectionDisabled(!hasDisc)
                    .contextMenu {
                        Button(hasDisc ? L("推出光盘", "Eject Disc") : L("打开托盘", "Open Tray")) { Task { await model.eject(d) } }
                            .disabled(model.busy != nil)
                    }
                }
            }
            Section(L("镜像文件", "Disc Images")) {
                ForEach(model.images, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "opticaldisc")
                        .help(url.path)
                        .tag(Source.image(url))
                }
                Button { model.openImagePanel() } label: {
                    Label(L("打开镜像…", "Open Disc Image…"), systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
        }
        .listStyle(.sidebar)
        // The list keeps showing a row as selected after the source is cleared in code (eject,
        // close); rebuilding it whenever the source changes keeps the highlight truthful.
        .id(model.source)
    }
}

// MARK: - Detail

struct Detail: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let info = model.info {
                // The list runs edge to edge; path and status float over it as glass.
                FileTable()
                    .edgeBar(.top) { PathBar() }
                    .edgeBar(.bottom) { InfoBar(info: info) }
            } else if let err = model.openError {
                ContentUnavailableView(L("无法读取这张光盘", "Can't Read This Disc"), systemImage: "exclamationmark.triangle", description: Text(err))
            } else {
                ContentUnavailableView {
                    Label(model.drives.isEmpty ? L("连接光驱，或打开一个光盘镜像", "Connect a Drive or Open a Disc Image") : L("把光盘放进光驱，会自动打开", "Insert a Disc to Open It"),
                          systemImage: model.drives.isEmpty ? "opticaldiscdrive" : "opticaldisc")
                } description: {
                    Text(L("支持 Windows“类似于 USB 闪存驱动器”格式的光盘", "Works with discs formatted in Windows as “Like a USB flash drive”"))
                } actions: {
                    Button(L("打开镜像…", "Open Disc Image…")) { model.openImagePanel() }.controlSize(.large)
                }
            }
        }
        .navigationTitle(model.info?.name ?? AppName.display)
        .navigationSubtitle(model.source?.title ?? "")
        .toolbar { toolbar }
        .alert(L("新建文件夹", "New Folder"), isPresented: $model.askingFolderName) {
            TextField(L("名称", "Name"), text: $model.newFolderName)
            Button(L("新建", "Create")) { model.makeFolder(named: model.newFolderName) }
            Button(L("取消", "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: $model.confirmingDelete) {
            Button(L("删除", "Delete"), role: .destructive) { model.delete(model.selectedEntries) }
        } message: {
            Text(model.info?.isWriteOnce == true ? L("一次性写入盘上的内容不会真正擦掉，只是不再显示，空间也不会释放。", "On a write-once disc nothing is really erased: deleted items are only hidden, and their space isn't freed.") : L("删除后不能恢复。", "This can't be undone."))
        }
    }

    @ToolbarContentBuilder
    private var groupSpacer: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    private var deleteTitle: String {
        let items = model.selectedEntries
        return items.count == 1 ? L("要删除“\(items[0].name)”吗？", "Delete “\(items[0].name)”?") : L("要删除这 \(items.count) 项吗？", "Delete These \(items.count) Items?")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.info != nil {
            ToolbarItemGroup(placement: .navigation) {
                Button { Task { await model.goUp() } } label: { Label(L("上一级", "Back"), systemImage: "chevron.left") }
                    .help(L("回到上一级文件夹", "Go to the enclosing folder"))
                    .disabled(model.pathComponents.isEmpty)
            }
            // Separate groups so each gets its own glass capsule: write, export, delete, more.
            discActions
        }
    }

    /// Only shown while a disc is open, so nothing looks clickable when there is nothing to act on.
    @ToolbarContentBuilder
    private var discActions: some ToolbarContent {
        // The everyday action gets words and the prominent style; the rest stay icons with tooltips.
        ToolbarItem(placement: .primaryAction) {
            Button { model.addPanel() } label: { Label(L("添加文件", "Add Files"), systemImage: "plus").labelStyle(.titleAndIcon) }
                .prominentButton()
                .help(L("把 Mac 上的文件或文件夹写入光盘（也可以直接拖进窗口）", "Write files or folders from this Mac to the disc (you can also drag them into the window)"))
                .disabled(!model.canWrite)
        }
        groupSpacer
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.newFolderName = L("新建文件夹", "New Folder"); model.askingFolderName = true } label: { Label(L("新建文件夹", "New Folder"), systemImage: "folder.badge.plus") }
                .help(L("在光盘上新建文件夹", "Create a folder on the disc"))
                .disabled(!model.canWrite)
            Button { model.exportPanel(model.selectedEntries) } label: { Label(L("导出", "Export"), systemImage: "square.and.arrow.down") }
                .help(L("把选中的项目复制到 Mac", "Copy the selected items to this Mac"))
                .disabled(model.selection.isEmpty || model.busy != nil)
        }
        groupSpacer
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.confirmingDelete = true } label: { Label(L("删除", "Delete"), systemImage: "trash") }
                .help(L("从光盘上删除选中的项目", "Delete the selected items from the disc"))
                .disabled(model.selection.isEmpty || !model.canWrite)
        }
        groupSpacer
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(L("检查光盘", "Check Disc")) { Task { await model.runCheck() } }
                Button(L("刷新", "Refresh")) { Task { await model.refresh() } }
                Divider()
                if let d = model.currentDrive {
                    Button(L("推出光盘", "Eject Disc")) { Task { await model.eject(d) } }
                }
                Button(L("关闭光盘", "Close Disc")) { Task { await model.closeSource() } }
            } label: { Label(L("更多", "More"), systemImage: "ellipsis.circle") }
                .disabled(model.info == nil || model.busy != nil)
        }
    }
}

// MARK: - Path bar

struct PathBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                crumb(model.info?.name ?? L("光盘", "Disc"), path: "", symbol: "opticaldisc")
                ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { i, name in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    crumb(name, path: model.pathComponents.prefix(i + 1).joined(separator: "/"), symbol: "folder")
                }
            }
            .lineLimit(1)
            .glassCapsule(interactive: true)
            Spacer()
            if let info = model.info {
                Label(info.mediaSummary, systemImage: info.isWriteOnce ? "opticaldisc" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("\(info.abilities)\n\(info.layout)，UDF \(info.revision)")
                    .glassCapsule()
            }
        }
        .glassGroup()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func crumb(_ title: String, path: String, symbol: String) -> some View {
        Button { Task { await model.go(to: path) } } label: {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(path == model.pathComponents.joined(separator: "/") ? .primary : .secondary)
    }
}

// MARK: - File table

struct FileTable: View {
    @EnvironmentObject var model: AppModel

    /// Compact, like the Finder's list view: "今天 17:33", "昨天 09:13", "2026/3/23 16:56".
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        Table(model.entries, selection: $model.selection) {
            TableColumn(L("名称", "Name")) { e in
                HStack(spacing: 6) {
                    Image(nsImage: FileKinds.icon(for: e)).resizable().frame(width: 18, height: 18)
                    Text(e.name).truncationMode(.middle)
                }
                .lineLimit(1)
                .help(e.name)
                .opacity(e.isHidden ? 0.5 : 1)
            }
            .width(min: 200, ideal: 320)
            TableColumn(L("种类", "Kind")) { e in
                Text(FileKinds.kind(of: e)).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn(L("大小", "Size")) { e in
                Text(e.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn(L("修改日期", "Date Modified")) { e in
                Text(e.modified.map { Self.dateFormat.string(from: $0) } ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(e.modified.map { $0.formatted(date: .complete, time: .standard) } ?? "")
            }
            .width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: UDFEntry.ID.self) { ids in
            let items = model.entries.filter { ids.contains($0.id) }
            if items.count == 1, items[0].isDirectory {
                Button(L("打开", "Open")) { Task { await model.go(to: items[0].path) } }
            }
            if !items.isEmpty {
                Button(L("导出…", "Export…")) { model.exportPanel(items) }
                Divider()
                Button(L("删除", "Delete")) { model.selection = ids; model.delete(items) }.disabled(!model.canWrite)
            }
        } primaryAction: { ids in
            Task { await model.activate(ids) }
        }
        .overlay {
            if model.entries.isEmpty {
                ContentUnavailableView {
                    Label(L("这个文件夹是空的", "This Folder Is Empty"), systemImage: model.canWrite ? "tray.and.arrow.down" : "folder")
                } description: {
                    if model.canWrite { Text(L("把文件拖到这里，或点右上角的“添加文件”，就会写入光盘。", "Drag files here, or click “Add Files” at the top right, to write them to the disc.")) }
                }
            }
        }
        .overlay {
            if model.dropTargeted { DropHighlight() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard model.canWrite else { return false }
            model.add(urls.filter(\.isFileURL))
            return true
        } isTargeted: { t in model.dropTargeted = t && model.canWrite }
    }
}

// MARK: - Info bar

struct InfoBar: View {
    @EnvironmentObject var model: AppModel
    let info: VolumeInfo

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let r = info.readOnlyReason {
                    Label(L("只读：\(r)", "Read-only: \(r)"), systemImage: "lock.fill").foregroundStyle(.orange)
                } else {
                    Label(info.isWriteOnce ? L("可以继续添加", "Can add files") : L("可读写", "Read & write"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .help(info.abilities)
            .glassCapsule()
            if let w = info.warnings.first {
                Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .help(info.warnings.joined(separator: "\n"))
                    .glassCapsule()
            }
            Spacer(minLength: 8)
            Text(itemSummary).foregroundStyle(.secondary).monospacedDigit()
            Spacer(minLength: 8)
            StorageMeter(info: info).glassCapsule()
        }
        .font(.callout)
        .lineLimit(1)
        .glassGroup()
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var itemSummary: String {
        let selected = model.selectedEntries
        if selected.isEmpty { return L("\(model.entries.count) 项", "\(model.entries.count) items") }
        let bytes = selected.filter { !$0.isDirectory }.reduce(UInt64(0)) { $0 + $1.size }
        return bytes > 0 ? L("已选 \(selected.count) 项，共 \(fmt(bytes))", "\(selected.count) selected, \(fmt(bytes))") : L("已选 \(selected.count) 项", "\(selected.count) selected")
    }
}

/// Used/total as a small bar, like the storage view in System Settings.
struct StorageMeter: View {
    let info: VolumeInfo

    var body: some View {
        let fraction = info.total > 0 ? Double(info.used) / Double(info.total) : 0
        HStack(spacing: 8) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(fraction > 0.9 ? .orange : .accentColor)
                .frame(width: 90)
            Text(L("可用 \(fmt(info.free))", "\(fmt(info.free)) available")).monospacedDigit()
            Text(L("共 \(fmt(info.total))", "of \(fmt(info.total))")).foregroundStyle(.secondary).monospacedDigit()
        }
        .help(L("已用 \(fmt(info.used))，可用 \(fmt(info.free))，共 \(fmt(info.total))", "\(fmt(info.used)) used, \(fmt(info.free)) available, \(fmt(info.total)) total"))
    }
}

private func fmt(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

// MARK: - Sheets

struct ProgressSheet: View {
    let busy: Busy

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(busy.title).font(.headline)
            if busy.total > 0 {
                ProgressView(value: Double(min(busy.done, busy.total)), total: Double(busy.total))
                Text("\(fmt(busy.done)) / \(fmt(busy.total))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if busy.writes {
                Text(L("写入过程中请不要弹出光盘或拔掉光驱。", "Don't eject the disc or unplug the drive while writing.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }

    private func fmt(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}

struct CheckReportView: View {
    let report: CheckReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(report.isClean ? L("检查通过", "No Problems Found") : L("发现 \(report.problems.count) 个问题", "\(report.problems.count) Problems Found"),
                  systemImage: report.isClean ? "checkmark.seal.fill" : "exclamationmark.octagon.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(report.isClean ? .green : .red)
            Text(L("\(report.files) 个文件，\(report.directories) 个文件夹", "\(report.files) files, \(report.directories) folders")).foregroundStyle(.secondary)
            if !report.problems.isEmpty || !report.notes.isEmpty {
                List {
                    ForEach(report.problems, id: \.self) { Label($0, systemImage: "xmark.circle").foregroundStyle(.red) }
                    ForEach(report.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.secondary) }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
            HStack { Spacer(); Button(L("好", "OK")) { dismiss() }.keyboardShortcut(.defaultAction).prominentButton() }
        }
        .padding(20)
        .frame(width: 480)
    }
}
