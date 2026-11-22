import Foundation
@testable import UDFKit

func runDiscImportTests() async {
    let name = "导入计划：重名、合并和取消，在 DVD-R 镜像写入前解决整批冲突"
    current = name
    let before = failed.count
    do { try await exerciseDiscImport() } catch { failed.append("\(name)：\(error)") }
    if failed.count == before { passed += 1; print("  ✓ \(name)") } else { print("  ✗ \(name)") }
}

private func exerciseDiscImport() async throws {
    let fm = FileManager.default
    let fixtures = work.appendingPathComponent("import-input")
    func file(_ path: String, _ content: String) throws -> URL {
        let url = fixtures.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        return url
    }
    let img = try writeOnceImage("import-conflicts.img")
    let dev = try ImageDevice(url: img, writable: true, sequential: true, linkBlocks: 16, appendAlignment: 16, capacityMB: 64)
    defer { dev.close() }
    let volume = try UDFVolume.open(dev)
    let old = try file("old.txt", "original")
    try volume.makeDirectory("folder")
    for name in ["keep.txt", "preserve.txt", "skip.txt", "change.txt", "keep 2.txt"] {
        try volume.add(from: old, to: "folder/" + name)
    }
    for name in ["keep.txt", "skip.txt", "change.txt", "new.txt"] { _ = try file("folder/" + name, "new-" + name) }
    let first = try file("one/report.pdf", "should never be committed")
    let second = try file("two/REPORT.PDF", "final")
    let folder = fixtures.appendingPathComponent("folder")
    let startVAT = volume.vatLocation
    let cancelled = try await DiscImportPlanner.plan([first, folder], into: "", list: volume.list) { conflict in
        conflict.incomingIsDirectory ? .merge : .cancel
    }
    expect(cancelled == nil && volume.vatLocation == startVAT && !volume.exists("report.pdf"), "取消整批保留原 VAT")
    var duplicates: [DiscImportConflict] = []
    let plan = try await DiscImportPlanner.plan([first, folder, second], into: "/", list: volume.list) { conflict in
        duplicates.append(conflict)
        if conflict.incomingIsDirectory { return .merge }
        switch conflict.path {
        case "folder/keep.txt": return .keepBoth
        case "folder/skip.txt": return .skip
        default: return .replace
        }
    }
    let groups = plan ?? []
    expect(groups.count == 2 && groups.last?.source == second, "去掉本批被后项替代的首次写入")
    expect(duplicates.last?.existingIsPlanned == true && duplicates.last?.path == "report.pdf")
    expect(duplicates.first { $0.path == "folder/keep.txt" }?.copyName == "keep 3.txt")
    expect(volume.vatLocation == startVAT && !volume.exists("report.pdf"), "计划阶段不写入")
    try DiscImportPlanner.validateSources(groups)
    for group in groups {
        try volume.applyImport(group)
        expect(try volume.verifyImport(group), "只校验已写入项，合并保留原有子项")
    }
    expect(try volume.readFile("report.pdf") == Array("final".utf8))
    for name in ["keep.txt", "preserve.txt", "skip.txt", "keep 2.txt"] {
        expect(try volume.readFile("folder/" + name) == Array("original".utf8))
    }
    expect(try volume.readFile("folder/keep 3.txt") == Array("new-keep.txt".utf8))
    expect(try volume.readFile("folder/change.txt") == Array("new-change.txt".utf8))
    expect(try volume.readFile("folder/new.txt") == Array("new-new.txt".utf8))
    let sameNameAsDirectory = try file("different-kind/FOLDER", "file of the same name")
    do {
        _ = try await DiscImportPlanner.plan([sameNameAsDirectory], into: "", list: volume.list) { _ in .replace }
        expect(false, "拒绝用文件覆盖目录")
    } catch {}
    let copies = try await DiscImportPlanner.plan([sameNameAsDirectory], into: "", list: volume.list) { _ in .keepBoth } ?? []
    for group in copies { try volume.applyImport(group); expect(try volume.verifyImport(group)) }
    expect(try volume.readFile("folder 2") == Array("file of the same name".utf8))
    expect(try volume.list("folder").count == 7 && volume.check().isClean)

    // Files appearing after planning must never be silently pulled into a recursive copy.
    let nestedFile = try file("fresh/empty-parent/inside.txt", "approved")
    let newGroup = try await DiscImportPlanner.plan([fixtures.appendingPathComponent("fresh")], into: "", list: volume.list) { _ in .cancel } ?? []
    _ = try file("fresh/appeared-late.txt", "unapproved")
    for group in newGroup { try volume.applyImport(group); expect(try volume.verifyImport(group)) }
    expect(!volume.exists("fresh/appeared-late.txt") && volume.exists("fresh/empty-parent/inside.txt"))
    try Data("changed after the decisions".utf8).write(to: nestedFile)
    expectThrows({ try DiscImportPlanner.validateSources(newGroup) }, "整批写入前检测源文件变化")

    let longName = "a." + String(repeating: "x", count: 251)
    let longFile = try file(longName, "long extension")
    let longCopy = try await DiscImportPlanner.plan([longFile], into: "", list: { _ in [entry(longName)] }) { conflict in
        expect(CS0.encode(conflict.copyName).count <= 255 && conflict.copyName != longName)
        return .skip
    }
    expect(longCopy?.isEmpty == true, "合法长扩展名仍可选择跳过")
    let backslash = try file("left\\right.txt", "valid Mac name")
    let unsanitized = try await DiscImportPlanner.plan([backslash], into: "", list: volume.list) { _ in .cancel } ?? []
    for group in unsanitized { try volume.applyImport(group); expect(try volume.verifyImport(group)) }
    expect(try volume.readFile("left\\right.txt") == Array("valid Mac name".utf8))

    let cycle = fixtures.appendingPathComponent("fresh/cycle")
    try fm.createSymbolicLink(at: cycle, withDestinationURL: fixtures.appendingPathComponent("fresh"))
    do {
        _ = try await DiscImportPlanner.plan([fixtures.appendingPathComponent("fresh")], into: "", list: volume.list) { _ in .merge }
        expect(false, "符号链接在写盘前报错")
    } catch {}
}
