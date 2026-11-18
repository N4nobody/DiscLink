import Darwin
import Foundation

extension UDFVolume {
    /// Names supplied by disc metadata must remain a single local path component.
    public static func isSafeExportName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    /// Exports one captured entry without overwriting an existing destination. All
    /// work is staged beside the destination and published only after a complete copy.
    /// The caller must serialize access to this volume, as with the other read APIs.
    public func exportSafely(_ entry: UDFEntry, to destination: URL,
                             isCancelled: () -> Bool = { false }) throws {
        func checkCancellation() throws {
            if isCancelled() { throw UDFError(L("导出已取消，原光盘可能已关闭或更换", "Export cancelled; the original disc may have been closed or changed")) }
        }
        func invalidName(_ name: String) -> UDFError {
            UDFError(L("无法安全导出这个文件名：\(name)", "This file name cannot be exported safely: \(name)"))
        }
        func systemError() -> Error {
            POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        func collision() -> UDFError {
            UDFError(L("目标已存在，未覆盖：\(destination.lastPathComponent)", "The destination already exists and was not overwritten: \(destination.lastPathComponent)"))
        }

        try checkCancellation()
        let checkedPath = entry.path.hasPrefix("/") ? String(entry.path.dropFirst()) : entry.path
        let components = checkedPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard Self.isSafeExportName(entry.name), components.allSatisfy(Self.isSafeExportName),
              components.last == entry.name else { throw invalidName(entry.name) }
        guard destination.isFileURL, destination.path.hasPrefix("/") else {
            throw UDFError(L("导出位置不是本地文件夹", "The export destination is not a local folder"))
        }
        let final = destination.standardizedFileURL
        guard Self.isSafeExportName(final.lastPathComponent) else { throw invalidName(final.lastPathComponent) }
        var existing = stat()
        if lstat(final.path, &existing) == 0 { throw collision() }
        guard errno == ENOENT else { throw systemError() }

        let original = try resolve(entry.path).fe
        guard original.addr == entry.icb, original.isDirectory == entry.isDirectory else {
            throw UDFError(L("光盘上的项目已变化，请刷新后重新拖动", "The item on the disc has changed; refresh and drag it again"))
        }
        let staging = final.deletingLastPathComponent()
            .appendingPathComponent(".DiscLink-export-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw systemError() }
        defer { try? FileManager.default.removeItem(at: staging) }
        let item = staging.appendingPathComponent("item", isDirectory: original.isDirectory)
        var activeDirectories = Set<LBAddr>()

        func copy(_ fe: FileEntry, to target: URL, depth: Int) throws {
            try checkCancellation()
            if fe.isDirectory {
                guard depth < 256, activeDirectories.insert(fe.addr).inserted else {
                    throw UDFError(L("目录结构循环或层级过深，无法导出", "The folder structure contains a cycle or is too deep to export"))
                }
                defer { activeDirectories.remove(fe.addr) }
                guard mkdir(target.path, 0o755) == 0 else { throw systemError() }
                for fid in try readFIDs(fe) where !fid.isDeleted && !fid.isParent {
                    try checkCancellation()
                    let name = fid.name
                    guard Self.isSafeExportName(name) else { throw invalidName(name) }
                    let child = try loadFileEntry(fid.icbAddr)
                    guard child.isDirectory == fid.isDirectory else {
                        throw UDFError(L("目录中的项目类型不一致：\(name)", "An item in the folder has an inconsistent type: \(name)"))
                    }
                    try copy(child, to: target.appendingPathComponent(name, isDirectory: child.isDirectory), depth: depth + 1)
                }
            } else {
                let descriptor = Darwin.open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard descriptor >= 0 else { throw systemError() }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                try readData(fe) { bytes in
                    try checkCancellation()
                    try handle.write(contentsOf: Data(bytes))
                }
                try handle.synchronize()
                try handle.close()
            }
            if let modified = fe.modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
            }
        }

        try copy(original, to: item, depth: 0)
        try checkCancellation()
        // RENAME_EXCL makes the no-overwrite guarantee atomic, including a destination
        // created by another application after the initial lstat check.
        guard renamex_np(item.path, final.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw collision() }
            throw systemError()
        }
    }
}
