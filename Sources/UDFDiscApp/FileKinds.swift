import AppKit
import UDFKit
import UniformTypeIdentifiers

/// Finder-style icons and kind names for entries on the disc, from their file name extension.
@MainActor
enum FileKinds {
    private static var icons: [String: NSImage] = [:]

    static func type(of e: UDFEntry) -> UTType {
        if e.isDirectory { return .folder }
        let ext = (e.name as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    static func icon(for e: UDFEntry) -> NSImage {
        let key = e.isDirectory ? "/" : (e.name as NSString).pathExtension.lowercased()
        if let cached = icons[key] { return cached }
        let image = NSWorkspace.shared.icon(for: type(of: e))
        icons[key] = image
        return image
    }

    static func kind(of e: UDFEntry) -> String {
        if e.isDirectory { return L("文件夹", "Folder") }
        return type(of: e).localizedDescription ?? L("文稿", "Document")
    }
}

extension DriveInfo {
    /// The model name without the vendor prefix ("DVDRAM GP78N" rather than "HL-DT-ST DVDRAM GP78N").
    var shortName: String { product.isEmpty ? displayName : product }
}

extension VolumeInfo {
    var used: UInt64 { total > free ? total - free : 0 }

    /// "DVD-R · 一次性写入盘", "DVD+RW · 可擦写盘", "镜像 · 可擦写".
    var mediaSummary: String {
        let kind = isWriteOnce ? L("一次性写入盘", "Write-once disc") : L("可擦写盘", "Rewritable disc")
        return [mediaType ?? (isRealDrive ? nil : L("镜像文件", "Disc image")), kind].compactMap { $0 }.joined(separator: " · ")
    }

    /// What this disc allows, in one sentence for tooltips.
    var abilities: String {
        if let r = readOnlyReason { return L("这张盘只能读取：\(r)", "This disc can only be read: \(r)") }
        return isWriteOnce
            ? L("一次性写入盘：可以继续添加文件；删除或替换文件时旧内容仍留在盘上，空间不会释放。", "Write-once disc: you can keep adding files. Deleted or replaced files stay on the disc, so their space isn't freed.")
            : L("可擦写盘：可以添加、删除、替换文件，删除后空间会释放。", "Rewritable disc: you can add, delete and replace files, and deleting frees the space.")
    }
}
