// Unit tests for UDFKit. Run with: swift run udfkit-tests
import Foundation
@testable import UDFKit

// MARK: - Minimal harness

var passed = 0
var failed: [String] = []
var current = ""

func expect(_ condition: @autoclosure () throws -> Bool, _ what: String = "", line: Int = #line) {
    do {
        if try condition() { return }
        failed.append("\(current)（第 \(line) 行）\(what)")
    } catch {
        failed.append("\(current)（第 \(line) 行）抛出错误：\(error)")
    }
}

func expectThrows(_ body: () throws -> Void, _ what: String = "", line: Int = #line) {
    do { try body(); failed.append("\(current)（第 \(line) 行）应该报错但没有：\(what)") } catch {}
}

func test(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failed.count
    do { try body() } catch { failed.append("\(name)：意外错误 \(error)") }
    if failed.count == before { passed += 1; print("  ✓ \(name)") } else { print("  ✗ \(name)") }
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("udfkit-tests-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

func blankFile(_ name: String, sectors: Int) -> URL {
    let url = work.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data(count: sectors * 2048))
    return url
}

func run(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = Pipe(); p.standardError = Pipe()
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw UDFError("\(tool) 失败（\(p.terminationStatus)）") }
}

// MARK: - Encoding

test("CRC-ITU-T 标准向量") {
    expect(CRC16.compute(Array("123456789".utf8)[...]) == 0x31C3)
    expect(CRC16.compute([][...]) == 0)
}

test("描述符标签写入后能通过校验，改一个字节就失败") {
    var b = [UInt8](repeating: 0, count: 64)
    b.putBytes(16, Array("payload".utf8))
    Tag.write(into: &b, id: .fileSet, version: 3, serial: 7, location: 42, length: 64)
    let t = Tag.parse(b)
    expect(t?.identifier == TagID.fileSet.rawValue && t?.version == 3 && t?.serial == 7 && t?.location == 42)
    var crcBroken = b; crcBroken[20] ^= 1
    expect(Tag.parse(crcBroken) == nil, "数据被改后 CRC 应失败")
    expect(Tag.parse(crcBroken, checkCRC: false) != nil, "只校验校验和时应通过")
    var sumBroken = b; sumBroken[12] ^= 1
    expect(Tag.parse(sumBroken, checkCRC: false) == nil, "标签被改后校验和应失败")
}

test("CS0 文件名：英文用 8 位、中文用 16 位，来回一致") {
    let ascii = CS0.encode("readme.txt")
    expect(ascii.first == 8 && ascii.count == 11)
    expect(CS0.decode(ascii[...]) == "readme.txt")
    let chinese = CS0.encode("说明 文档.txt")
    expect(chinese.first == 16 && chinese.count == 1 + 2 * 9)
    expect(CS0.decode(chinese[...]) == "说明 文档.txt")
    expect(CS0.decode(CS0.encode("café")[...]) == "café")
    expect(CS0.encode("café").first == 8, "Latin-1 字符仍用 8 位")
    expect(CS0.decode(CS0.encode("😀照片")[...]) == "😀照片", "BMP 以外的字符（代理对）")
}

test("dstring 定长字段") {
    var b = [UInt8](repeating: 0, count: 32)
    let enc = CS0.encode("MYDISC")
    b.putBytes(0, enc); b[31] = UInt8(enc.count)
    expect(CS0.decodeD(b, 0, 32) == "MYDISC")
    expect(CS0.decodeD([UInt8](repeating: 0, count: 32), 0, 32) == "")
}

test("时间戳来回一致（精确到微秒）") {
    let date = Date(timeIntervalSince1970: 1_760_000_000.123456)
    var b = [UInt8](repeating: 0, count: 12)
    Timestamp.encode(date, into: &b, 0)
    expect(b.u16(0) >> 12 == 1, "类型应为本地时间")
    let back = Timestamp.decode(b, 0)
    expect(back.map { abs($0.timeIntervalSince(date)) < 0.000_01 } ?? false)
    expect(Timestamp.decode([UInt8](repeating: 0, count: 12), 0) == nil, "全零应视为没有时间")
}

test("小端整数读写") {
    var b = [UInt8](repeating: 0, count: 16)
    b.put16(0, 0xBEEF); b.put32(2, 0xDEAD_BEEF); b.put64(6, 0x0123_4567_89AB_CDEF)
    expect(b.u16(0) == 0xBEEF && b.u32(2) == 0xDEAD_BEEF && b.u64(6) == 0x0123_4567_89AB_CDEF)
    expect(b[0] == 0xEF && b[1] == 0xBE)
}

// MARK: - Space bitmap

func makeBitmap(bits: Int, free: Bool = true) throws -> SpaceBitmap {
    var raw = [UInt8](repeating: free ? 0xFF : 0, count: 24 + (bits + 7) / 8)
    raw.put32(16, UInt32(bits)); raw.put32(20, UInt32((bits + 7) / 8))
    Tag.write(into: &raw, id: .spaceBitmap, version: 3, serial: 0, location: 0, length: 24)
    return try SpaceBitmap(ref: 0, firstBlock: 0, raw: raw, blockSize: 2048)
}

test("空间位图：连续分配、按包对齐") {
    let bm = try makeBitmap(bits: 1000)
    expect(bm.freeCount == 1000)
    let a = try bm.allocate(10, align: 1, near: 3)
    expect(a.count == 1 && a[0].start == 3 && a[0].count == 10)
    let b = try bm.allocate(20, align: 16)
    expect(b.count == 1 && b[0].start % 16 == 0 && b[0].start >= 13, "应从 16 的倍数开始")
    expect(bm.freeCount == 970)
}

test("空间位图：没有连续空间时拼凑碎片，空间不够时报错") {
    let bm = try makeBitmap(bits: 64)
    for i in stride(from: 0, to: 64, by: 2) { bm.set(i, free: false) }   // every other block used
    let runs = try bm.allocate(5)
    expect(runs.reduce(0) { $0 + $1.count } == 5 && runs.count == 5)
    expect(bm.freeCount == 27)
    expectThrows({ _ = try bm.allocate(28) }, "28 > 27")
}

test("空间位图：释放后可再用，只标记改动的块") {
    let bm = try makeBitmap(bits: 40000)
    bm.dirtyBlocks.removeAll()
    bm.set(5, free: false)
    bm.set(30000, free: false)                         // byte 24 + 3750 -> block 1
    expect(bm.dirtyBlocks == [0, 1])
    bm.set(5, free: true)
    expect(bm.isFree(5) && !bm.isFree(30000))
}

// MARK: - Packet cache

test("包缓存：零散写入合并成整包，未刷新前能读到新数据") {
    let url = blankFile("packets.img", sectors: 512)
    let dev = try ImageDevice(url: url, writable: true, simulatePacket: 16, strictPackets: true)
    let cache = PacketCache(dev)
    let one = [UInt8](repeating: 0xAB, count: 2048)
    try cache.write(37, one, allowDirect: false)               // inside packet 2 (32...47)
    expect(try cache.read(37, count: 1) == one, "刷新前读到新数据")
    expect(try dev.readSectors(37, count: 1) != one, "刷新前不应落盘")
    try cache.flush()                                     // strict device rejects anything unaligned
    expect(try dev.readSectors(37, count: 1) == one)
    expect(try dev.readSectors(36, count: 1) == [UInt8](repeating: 0, count: 2048), "同包其它扇区保持原样")
}

test("包缓存：整包数据直接写入，放弃时丢掉未刷新的部分") {
    let url = blankFile("direct.img", sectors: 512)
    let dev = try ImageDevice(url: url, writable: true, simulatePacket: 16, strictPackets: true)
    let cache = PacketCache(dev)
    let big = [UInt8](repeating: 0x5A, count: 32 * 2048)
    try cache.write(64, big)                                  // two whole aligned packets
    expect(try dev.readSectors(64, count: 32) == big, "整包直接落盘")
    try cache.write(200, [UInt8](repeating: 1, count: 2048), allowDirect: false)
    cache.discard()
    try cache.flush()
    expect(try dev.readSectors(200, count: 1) == [UInt8](repeating: 0, count: 2048), "放弃后不应写入")
}

// MARK: - Write-once simulation

test("一次性写入镜像：只能在末尾追加，链接块会让地址跳过") {
    let url = blankFile("seq.img", sectors: 300)
    let dev = try ImageDevice(url: url, writable: true, sequential: true, linkBlocks: 7, capacityMB: 4)
    expect(try dev.nextWritableAddress() == 300)
    expectThrows({ try dev.writeSectors(10, [UInt8](repeating: 0, count: 2048)) }, "不能覆盖")
    let cache = PacketCache(dev)
    let runs = try cache.append([UInt8](repeating: 9, count: 40 * 2048))   // 32 + 8 sectors
    expect(runs.count == 2 && runs[0].start == 300 && runs[0].count == 32 && runs[1].start == 339 && runs[1].count == 8,
           "\(runs)")
    expect(try cache.read(339, count: 8) == [UInt8](repeating: 9, count: 8 * 2048))
    expect(try dev.nextWritableAddress() == 354)
}

// MARK: - Whole volume (needs macOS's newfs_udf)

test("整卷读写：新建、写入、改写、删除、重新打开后一致") {
    let url = blankFile("volume.img", sectors: 20_000)
    try run("/sbin/newfs_udf", ["-r", "2.01", "-v", "UNIT", url.path])
    let src = work.appendingPathComponent("src.bin")
    let payload = (0 ..< 300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
    try Data(payload).write(to: src)
    let small = work.appendingPathComponent("small.txt")
    try Data("你好".utf8).write(to: small)

    var v = try UDFVolume.open(ImageDevice(url: url, writable: true, simulatePacket: 16, strictPackets: true))
    expect(v.readOnlyReason == nil && v.volumeName == "UNIT")
    let free0 = v.freeBytes
    try v.makeDirectory("/资料")
    try v.add(from: src, to: "/资料/data.bin")
    try v.add(from: small, to: "/small.txt")
    expectThrows({ try v.add(from: small, to: "/small.txt") }, "重名")
    expectThrows({ try v.makeDirectory("/a/b") }, "上级不存在")
    expectThrows({ try v.makeDirectory("/") }, "根目录没有名字")
    expectThrows({ try v.makeDirectory("/a\u{0}b") }, "名字里有空字符")
    expect(try v.verify("/资料/data.bin", against: src))
    expect(v.freeBytes < free0)

    v = try UDFVolume.open(ImageDevice(url: url, writable: true))
    expect(try v.list("/").map(\.name) == ["资料", "small.txt"])
    expect(try v.readFile("/资料/data.bin") == payload)
    expect(try v.readFile("/SMALL.TXT") == Array("你好".utf8), "名字不区分大小写")
    expect(try v.check().isClean)

    try v.remove("/资料")
    expect(try v.list("/").map(\.name) == ["small.txt"])
    expect(try v.check().isClean)
    v = try UDFVolume.open(ImageDevice(url: url, writable: false))
    expect(v.freeBytes == free0 - 2048, "删除后空间回收（只剩 small.txt 的文件条目）：\(free0 - v.freeBytes)")
    expectThrows({ try v.makeDirectory("/new") }, "只读打开时不能写")
}

test("整卷：写入失败后光盘保持原样") {
    let url = blankFile("full.img", sectors: 2_000)
    try run("/sbin/newfs_udf", ["-r", "2.01", "-v", "FULL", url.path])
    let big = work.appendingPathComponent("big.bin")
    try Data(count: 8 * 1024 * 1024).write(to: big)
    let v = try UDFVolume.open(ImageDevice(url: url, writable: true))
    expectThrows({ try v.add(from: big, to: "/big.bin") }, "空间不足")
    let reopened = try UDFVolume.open(ImageDevice(url: url, writable: false))
    expect(try reopened.list("/").isEmpty && reopened.check().isClean)
    expect(reopened.freeBytes == v.freeBytes)
}

// MARK: - Report

print("\n通过 \(passed)，失败 \(failed.count)")
for f in failed { print("  ✗ \(f)") }
exit(failed.isEmpty ? 0 : 1)
