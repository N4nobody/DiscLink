import AppKit
import SwiftUI
import UDFKit
import UniformTypeIdentifiers

/// The native table vends one file promise per row, including all selected rows
/// in a multi-item drag. Finder chooses the destination when the user drops them.
struct DiscFileTable: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileList()
        let coordinator = context.coordinator
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 23
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (key, width, minimum): (EntrySort, CGFloat, CGFloat) in
            [(.name, 320, 200), (.kind, 110, 70), (.size, 90, 70), (.date, 140, 110)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            col.title = key.title
            col.width = width
            col.minWidth = minimum
            col.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true)
            table.addTableColumn(col)
        }
        table.delegate = coordinator
        table.dataSource = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.openClickedRow(_:))
        table.buildMenu = { [weak coordinator] in coordinator?.contextMenu() }
        table.registerForDraggedTypes([.fileURL])
        table.didLeaveDropTarget = { [weak model] in model?.dropTargeted = false }
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask([], forLocal: true)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.update(table)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let model: AppModel
        private var rows: [UDFEntry] = []
        private var updating = false
        private let dates: DateFormatter = {
            let f = DateFormatter()
            f.dateStyle = .short
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            return f
        }()

        init(_ model: AppModel) { self.model = model }

        func update(_ table: NSTableView) {
            updating = true
            defer { updating = false }
            if rows != model.displayedEntries {
                rows = model.displayedEntries
                table.reloadData()
            }
            let descriptor = table.sortDescriptors.first
            if descriptor?.key != model.sortKey.rawValue || descriptor?.ascending != model.sortAscending {
                table.sortDescriptors = [NSSortDescriptor(key: model.sortKey.rawValue, ascending: model.sortAscending)]
            }
            let selection = IndexSet(rows.indices.filter { model.selection.contains(rows[$0].id) })
            if table.selectedRowIndexes != selection { table.selectRowIndexes(selection, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            model.selection = Set(table.selectedRowIndexes.filter { rows.indices.contains($0) }.map { rows[$0].id })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let sort = tableView.sortDescriptors.first, let key = sort.key.flatMap(EntrySort.init) else { return }
            if model.sortKey != key { model.sortKey = key }
            if model.sortAscending != sort.ascending { model.sortAscending = sort.ascending }
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn, let key = EntrySort(rawValue: column.identifier.rawValue),
                  rows.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: self) as? FileCell
                ?? FileCell(key: key)
            let entry = rows[row]
            switch key {
            case .name:
                cell.textField?.stringValue = entry.name
                cell.imageView?.image = FileKinds.icon(for: entry)
                cell.toolTip = entry.name
                cell.alphaValue = entry.isHidden ? 0.5 : 1
            case .kind: cell.textField?.stringValue = FileKinds.kind(of: entry)
            case .size: cell.textField?.stringValue = entry.isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
            case .date:
                cell.textField?.stringValue = entry.modified.map(dates.string) ?? ""
                cell.toolTip = entry.modified?.formatted(date: .complete, time: .standard)
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard rows.indices.contains(row) else { return nil }
            let entry = rows[row]
            guard let export = model.makeDragExporter(for: entry) else { return nil }
            let kind = FileKinds.type(of: entry)
            let type: UTType = entry.isDirectory ? .folder : (kind.conforms(to: .data) ? kind : .data)
            return DiscFilePromise(name: entry.name, fileType: type.identifier, export: export)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            let external = (info.draggingSource as? NSTableView) !== tableView
            let allowed = model.canWrite && external && info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            if model.dropTargeted != allowed { model.dropTargeted = allowed }
            if allowed { tableView.setDropRow(-1, dropOperation: .on) }
            return allowed ? .copy : []
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                       dropOperation: NSTableView.DropOperation) -> Bool {
            model.dropTargeted = false
            guard model.canWrite, (info.draggingSource as? NSTableView) !== tableView,
                  let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                       options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            model.add(urls)
            return true
        }

        @objc func openClickedRow(_ table: NSTableView) {
            guard rows.indices.contains(table.clickedRow) else { return }
            openSelection()
        }

        @objc private func openSelection() {
            let selection = model.selection
            Task { await model.activate(selection) }
        }

        func contextMenu() -> NSMenu? {
            let items = model.selectedEntries
            guard !items.isEmpty else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            if items.count == 1 && items[0].isDirectory {
                menu.addItem(withTitle: L("打开", "Open"), action: #selector(openSelection), keyEquivalent: "").target = self
            }
            let export = menu.addItem(withTitle: L("导出…", "Export…"), action: #selector(exportSelection), keyEquivalent: "")
            export.target = self
            export.isEnabled = model.busy == nil
            menu.addItem(.separator())
            let delete = menu.addItem(withTitle: L("删除", "Delete"), action: #selector(deleteSelection), keyEquivalent: "")
            delete.target = self
            delete.isEnabled = model.canWrite
            return menu
        }

        @objc private func exportSelection() { model.exportPanel(model.selectedEntries) }
        @objc private func deleteSelection() { model.confirmingDelete = true }
    }
}

private final class FileList: NSTableView {
    var buildMenu: (() -> NSMenu?)?
    var didLeaveDropTarget: (() -> Void)?

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        didLeaveDropTarget?()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender)
        didLeaveDropTarget?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return buildMenu?()
    }
}

private final class FileCell: NSTableCellView {
    init(key: EntrySort) {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        let text = NSTextField(labelWithString: "")
        text.font = key == .size ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        text.textColor = key == .name ? .labelColor : .secondaryLabelColor
        text.lineBreakMode = key == .name ? .byTruncatingMiddle : .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        textField = text
        var textLeading = leadingAnchor
        if key == .name {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            addSubview(icon)
            imageView = icon
            NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                                         icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                                         icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18)])
            textLeading = icon.trailingAnchor
        }
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: textLeading, constant: key == .name ? 6 : 2),
                                     text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
                                     text.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("FileCell is constructed in code") }
}
