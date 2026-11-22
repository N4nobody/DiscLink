import Foundation

public enum DiscImportChoice: Sendable { case replace, merge, keepBoth, skip, cancel }

public struct DiscImportConflict: Sendable {
    public let source: URL
    public let path: String
    public let incomingIsDirectory: Bool
    public let existingIsDirectory: Bool
    public let existingIsPlanned: Bool
    public let copyName: String
}

public struct DiscImportGroup: Sendable {
    public let source: URL
    public let target: String
    let steps: [DiscImportStep]

    public var byteCount: UInt64 { steps.reduce(0) { $0 + $1.size } }

    func validateSources() throws {
        for step in steps {
            let attrs = try FileManager.default.attributesOfItem(atPath: step.source.path)
            let type = attrs[.type] as? FileAttributeType
            guard type == (step.directory ? .typeDirectory : .typeRegular),
                  step.directory || ((attrs[.size] as? NSNumber)?.uint64Value == step.size &&
                                     attrs[.modificationDate] as? Date == step.modified) else {
                throw UDFError(L("源项目已发生变化：\(step.source.path)", "The source item has changed: \(step.source.path)"))
            }
        }
    }
}

struct DiscImportStep: Sendable {
    let source: URL
    let path: String
    let directory: Bool
    let overwrite: Bool
    let size: UInt64
    let modified: Date?
}

public enum DiscImportPlanner {
    /// Check the selected source files again after the last conflict dialog, before the first write.
    public static func validateSources(_ groups: [DiscImportGroup]) throws {
        for group in groups { try group.validateSources() }
    }

    /// Read-only planning. Cancellation discards all earlier choices, including approved replacements.
    public static func plan(_ sources: [URL], into path: String,
                            list: @escaping (String) async throws -> [UDFEntry],
                            decide: @escaping (DiscImportConflict) async -> DiscImportChoice) async throws -> [DiscImportGroup]? {
        let planner = Builder(list: list, decide: decide)
        let parent = UDFVolume.components(path).joined(separator: "/")
        do {
            for source in sources {
                var steps: [DiscImportStep] = []
                if let target = try await planner.collect(source, in: parent, into: &steps), !steps.isEmpty {
                    planner.groups.append(DiscImportGroup(source: source, target: target, steps: steps))
                }
            }
        } catch is Cancelled { return nil }
        // A later input may explicitly replace an earlier planned file. Write its final version once.
        return planner.groups.enumerated().compactMap { index, group in
            let steps = group.steps.enumerated().compactMap { stepIndex, step in
                step.directory || planner.finalFiles[step.path] == Position(group: index, step: stepIndex) ? step : nil
            }
            return steps.isEmpty ? nil : DiscImportGroup(source: group.source, target: group.target, steps: steps)
        }
    }

    private struct Cancelled: Error {}
    private struct Position: Equatable { let group: Int; let step: Int }

    private struct Item {
        let name: String
        let directory: Bool
        let onDisc: Bool
        let planned: Bool
    }

    /// Each folder is loaded once. New folders and earlier batch entries share this projected namespace.
    private final class Builder {
        let list: (String) async throws -> [UDFEntry]
        let decide: (DiscImportConflict) async -> DiscImportChoice
        var folders: [String: [String: Item]] = [:]
        var groups: [DiscImportGroup] = []
        var finalFiles: [String: Position] = [:]

        init(list: @escaping (String) async throws -> [UDFEntry], decide: @escaping (DiscImportConflict) async -> DiscImportChoice) {
            self.list = list
            self.decide = decide
        }

        /// Include canonical equivalents and the Unicode case folds used by UDFVolume lookups.
        func key(_ name: String) -> String {
            name.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
        }

        func collect(_ source: URL, in parent: String, into steps: inout [DiscImportStep]) async throws -> String? {
            guard source.isFileURL else { throw UDFError(L("请选择本地文件或文件夹", "Choose a local file or folder")) }
            let properties = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
            guard properties.isSymbolicLink != true, properties.isDirectory == true || properties.isRegularFile == true else {
                throw UDFError(L("无法拷贝链接或特殊文件：\(source.path)", "Cannot copy a link or special file: \(source.path)"))
            }
            let directory = properties.isDirectory == true
            if folders[parent] == nil {
                var items: [String: Item] = [:]
                for entry in try await list(parent) {
                    let nameKey = key(entry.name)
                    guard items[nameKey] == nil else {
                        throw UDFError(L("目标文件夹已有无法区分的重名：\(entry.name)", "The destination contains ambiguous duplicate names: \(entry.name)"))
                    }
                    items[nameKey] = Item(name: entry.name, directory: entry.isDirectory, onDisc: true, planned: false)
                }
                folders[parent] = items
            }
            func path(_ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }
            var name = source.lastPathComponent
            var onDisc = false, merging = false
            if let existing = folders[parent]?[key(name)] {
                name = existing.name
                let copy = copyName(for: name, directory: directory, in: parent)
                let conflict = DiscImportConflict(source: source, path: path(name), incomingIsDirectory: directory,
                                                  existingIsDirectory: existing.directory, existingIsPlanned: existing.planned, copyName: copy)
                switch await decide(conflict) {
                case .cancel: throw Cancelled()
                case .skip: return nil
                case .keepBoth: name = copy
                case .merge where directory && existing.directory: merging = true; onDisc = existing.onDisc
                case .replace where !directory && !existing.directory: onDisc = existing.onDisc
                default: throw UDFError(L("所选操作不适用于这个重名项目", "The selected action is unavailable for this conflict"))
                }
            }
            try UDFVolume.validateFilename(name)
            guard CS0.encode(name).count <= 255 else {
                throw UDFError(L("光盘不能使用这个名称：\(name)", "This name cannot be stored on the disc: \(name)"))
            }
            let target = path(name)
            folders[parent]?[key(name)] = Item(name: name, directory: directory, onDisc: onDisc, planned: true)
            if !merging {
                if directory { folders[target] = [:] }
                else { finalFiles[target] = Position(group: groups.count, step: steps.count) }
                steps.append(DiscImportStep(source: source, path: target, directory: directory, overwrite: onDisc,
                                            size: directory ? 0 : UInt64(properties.fileSize ?? 0), modified: properties.contentModificationDate))
            }
            if directory {
                let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where child.lastPathComponent != ".DS_Store" {
                    _ = try await collect(child, in: target, into: &steps)
                }
            }
            return target
        }

        /// Finder-style numeric suffix before the extension. A directory's dots are part of its name.
        func copyName(for name: String, directory: Bool, in parent: String) -> String {
            let ext = directory ? "" : (name as NSString).pathExtension
            let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            var number = 2
            while true {
                var base = stem, ending = ext.isEmpty ? "" : "." + ext
                let suffix = " \(number)"
                while base.count > 1 && CS0.encode(base + suffix + ending).count > 255 { base.removeLast() }
                // An unusually long extension may itself exceed the limit after adding a suffix.
                while !ending.isEmpty && CS0.encode(base + suffix + ending).count > 255 { ending.removeLast() }
                if CS0.encode(base + suffix + ending).count > 255 { base = "" }
                let proposed = base + suffix + ending
                if folders[parent]?[key(proposed)] == nil { return proposed }
                number += 1
            }
        }
    }
}

extension UDFVolume {
    /// Check exactly what this group created or replaced. Merged folders can also contain existing files.
    public func verifyImport(_ group: DiscImportGroup) throws -> Bool {
        cache.discard()
        for step in group.steps {
            if step.directory {
                guard try resolve(step.path).fe.isDirectory else { return false }
            } else if !(try verify(step.path, against: step.source)) { return false }
        }
        return true
    }
}
