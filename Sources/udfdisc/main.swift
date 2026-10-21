import Foundation
import UDFKit

let usage = L("""
用法：udfdisc <命令> [选项] ...

  drives                         列出光驱
  eject drive:N                  推出光盘（没有光盘时打开托盘）
  info  <目标>                   显示光盘信息
  ls    <目标> [路径]            列出文件夹
  get   <目标> <光盘路径> <本地路径>   复制到本机
  put   <目标> <本地路径> <光盘路径>   复制到光盘（--overwrite 覆盖同名）
  mkdir <目标> <光盘路径>        新建文件夹
  rm    <目标> <光盘路径>        删除文件或文件夹
  check <目标>                   检查光盘文件系统是否一致
  fix-vat <目标>                 一次性写入盘：在末尾按对齐重新写一份 VAT（不改动文件）

<目标> 是光盘镜像文件路径，或 drive:1、drive:2 ...（见 drives）
镜像选项：--packet N 模拟 N 块一包的包写入  --strict 不对齐的写入直接报错
          --sequential 模拟 CD-R/DVD-R（只能在末尾追加）  --link N 每次写入后跳过 N 个扇区（模拟 CD-R 链接块）
          --align N 刷新时把最后一组补满 N 个扇区（模拟 DVD-R 的 16 扇区 ECC 块）
""", """
Usage: udfdisc <command> [options] ...

  drives                         List optical drives
  eject drive:N                  Eject the disc (opens the tray when empty)
  info  <target>                 Show information about the disc
  ls    <target> [path]          List a folder
  get   <target> <disc path> <local path>   Copy to this Mac
  put   <target> <local path> <disc path>   Copy to the disc (--overwrite replaces same name)
  mkdir <target> <disc path>     Create a folder
  rm    <target> <disc path>     Delete a file or folder
  check <target>                 Check that the disc's file system is consistent
  fix-vat <target>               Write-once discs: record the VAT again, aligned, at the end (files unchanged)

<target> is a disc image path, or drive:1, drive:2 ... (see drives)
Image options: --packet N  simulate packet writing with N blocks per packet   --strict  fail unaligned writes
               --sequential  simulate CD-R/DVD-R (append only)   --link N  skip N sectors after each write (CD-R link blocks)
               --align N  pad the last unit to N sectors on flush (DVD-R 16-sector ECC block)
""")

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i ... i + 1)
    return v
}

let overwrite = flag("--overwrite")
let strict = flag("--strict")
let packet = Int(option("--packet") ?? "1") ?? 1
let sequential = flag("--sequential")
let linkBlocks = Int(option("--link") ?? "0") ?? 0
let alignBlocks = Int(option("--align") ?? "1") ?? 1
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func openTarget(_ t: String, write: Bool) throws -> UDFVolume {
    if t.hasPrefix("drive:") {
        let drives = OpticalDrive.list()
        guard let n = Int(t.dropFirst(6)), n >= 1, n <= drives.count else { throw UDFError(L("没有这台光驱：\(t)", "No such drive: \(t)")) }
        return try UDFVolume.open(OpticalDrive(drives[n - 1], allowWrite: write))
    }
    let dev = try ImageDevice(url: URL(fileURLWithPath: t), writable: write, simulatePacket: packet, strictPackets: strict,
                          sequential: sequential, linkBlocks: linkBlocks, appendAlignment: alignBlocks)
    return try UDFVolume.open(dev)
}

func size(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

do {
    switch command {
    case "drives":
        let d = OpticalDrive.list()
        if d.isEmpty { print(L("没有找到光驱", "No optical drive found")) }
        for (i, x) in d.enumerated() { print("drive:\(i + 1)  \(x.displayName)  \(x.bsdName.isEmpty ? L("（无盘）", "(no disc)") : "/dev/" + x.bsdName)  [service 0x\(String(x.registryID, radix: 16)), drive 0x\(String(x.stableID, radix: 16))]") }

    case "info":
        guard args.count == 1 else { fail(usage) }
        let v = try openTarget(args[0], write: true)
        print(L("卷名：\(v.volumeName)", "Volume: \(v.volumeName)"))
        print(L("UDF 版本：\(v.revisionString)", "UDF revision: \(v.revisionString)"))
        print(L("布局：\(v.layoutDescription)", "Layout: \(v.layoutDescription)"))
        print(L("容量：\(size(v.totalBytes))，可用：\(size(v.freeBytes))", "Capacity: \(size(v.totalBytes)), available: \(size(v.freeBytes))"))
        if let d = v.device as? OpticalDrive {
            print(L("盘型：\(d.profileName)，每包 \(d.packetSectors) 扇区", "Disc: \(d.profileName), \(d.packetSectors) sectors per packet"))
            if let t = d.trackSummary { print(t) }
        }
        if let at = v.vatLocation { print(L("VAT 位置：扇区 \(at)", "VAT location: sector \(at)")) }
        if let r = v.readOnlyReason { print(L("写入：不可用（\(r)）", "Writing: not available (\(r))")) } else { print(L("写入：可用", "Writing: available")) }
        for w in v.warnings { print(L("注意：\(w)", "Note: \(w)")) }

    case "ls":
        guard args.count >= 1 else { fail(usage) }
        let v = try openTarget(args[0], write: false)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        for e in try v.list(args.count > 1 ? args[1] : "/") {
            let when = e.modified.map { f.string(from: $0) } ?? "                "
            print("\(e.isDirectory ? "d" : "-") \(String(repeating: " ", count: max(0, 10 - String(e.size).count)))\(e.size)  \(when)  \(e.name)")
        }

    case "get":
        guard args.count == 3 else { fail(usage) }
        let v = try openTarget(args[0], write: false)
        try v.export(args[1], to: URL(fileURLWithPath: args[2]))

    case "put":
        guard args.count == 3 else { fail(usage) }
        let v = try openTarget(args[0], write: true)
        let src = URL(fileURLWithPath: args[1])
        try v.add(from: src, to: args[2], overwrite: overwrite)
        guard try v.verify(args[2], against: src) else { fail(L("校验失败：光盘上的内容和原文件不一致", "Verification failed: what's on the disc differs from the original file")) }
        print(L("已写入并校验：\(args[2])  剩余 \(size(v.freeBytes))", "Written and verified: \(args[2])  \(size(v.freeBytes)) left"))

    case "check":
        guard args.count == 1 else { fail(usage) }
        let r = try openTarget(args[0], write: false).check()
        print(L("\(r.files) 个文件，\(r.directories) 个文件夹", "\(r.files) files, \(r.directories) folders"))
        for n in r.notes { print(L("说明：\(n)", "Note: \(n)")) }
        for p in r.problems { print(L("问题：\(p)", "Problem: \(p)")) }
        print(r.isClean ? L("检查通过", "No problems found") : L("发现 \(r.problems.count) 个问题", "\(r.problems.count) problems found"))
        if !r.isClean { exit(2) }

    case "stat":
        guard args.count == 2 else { fail(usage) }
        print(try openTarget(args[0], write: false).debugDescription(of: args[1]), terminator: "")

    case "fix-vat":
        guard args.count == 1 else { fail(usage) }
        let v = try openTarget(args[0], write: true)
        try v.rewriteVAT()
        print(L("已在光盘末尾重新写入 VAT（扇区 \(v.vatLocation ?? 0)）", "VAT recorded again at the end of the disc (sector \(v.vatLocation ?? 0))"))

    case "sector":   // troubleshooting: what a physical sector holds
        guard args.count == 2, let lba = UInt32(args[1]) else { fail(usage) }
        let v = try openTarget(args[0], write: false)
        let b = try v.device.readSectors(lba, count: 1)
        print(v.describeSector(b, at: lba))

    case "eject":
        guard args.count == 1, args[0].hasPrefix("drive:"), let n = Int(args[0].dropFirst(6)) else { fail(usage) }
        let drives = OpticalDrive.list()
        guard n >= 1, n <= drives.count else { throw UDFError(L("没有这台光驱：\(args[0])", "No such drive: \(args[0])")) }
        try OpticalDrive.eject(drives[n - 1])
        print(L("已推出", "Ejected"))

    case "mkdir":
        guard args.count == 2 else { fail(usage) }
        try openTarget(args[0], write: true).makeDirectory(args[1])

    case "rm":
        guard args.count == 2 else { fail(usage) }
        try openTarget(args[0], write: true).remove(args[1])

    default:
        fail(usage)
    }
} catch {
    fail(L("错误：\(error.localizedDescription)", "Error: \(error.localizedDescription)"))
}
