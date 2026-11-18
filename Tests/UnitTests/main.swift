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

// The image holds the true bytes; faults affect only the requested transfer. This
// reproduces a drive returning incomplete or invalid batched data without changing
// the recorded sector, and records whether recovery actually used a single read.
final class FaultyReadImage: SectorDevice {
    enum Fault { case none, short(Int), zero, badCRC, overlongCRC, failure }
    let image: ImageDevice
    var batchFault: Fault = .none
    var singleFault: Fault = .none
    var affectedSector: UInt32?
    var requests: [(lba: UInt32, count: Int)] = []
    init(_ image: ImageDevice) { self.image = image }
    var label: String { image.label }
    var sectorSize: Int { image.sectorSize }
    var sectorCount: UInt32 { image.sectorCount }
    var readOnlyReason: String? { image.readOnlyReason }
    var packetSectors: Int { image.packetSectors }
    var packetBase: UInt32 { image.packetBase }
    var isSequential: Bool { image.isSequential }
    var lastRecordedSector: UInt32 { image.lastRecordedSector }
    var appendAlignment: Int { image.appendAlignment }
    var appendableSectors: UInt32 { image.appendableSectors }
    func nextWritableAddress() throws -> UInt32 { try image.nextWritableAddress() }
    func readSectors(_ lba: UInt32, count: Int) throws -> [UInt8] {
        requests.append((lba, count))
        var bytes = try image.readSectors(lba, count: count)
        if let target = affectedSector, !(lba <= target && target < lba + UInt32(count)) { return bytes }
        let offset = Int((affectedSector ?? lba) - lba) * sectorSize
        switch count > 1 ? batchFault : singleFault {
        case .none: return bytes
        case .short(let n): return Array(bytes.prefix(n))
        case .zero: return [UInt8](repeating: 0, count: bytes.count)
        case .badCRC: bytes[offset + 20] ^= 1
        case .overlongCRC:
            bytes.put16(offset + 10, UInt16(sectorSize))
            bytes[offset + 4] = 0
            for i in 0 ..< 16 where i != 4 { bytes[offset + 4] &+= bytes[offset + i] }
        case .failure: throw UDFError("Simulated batch read failure")
        }
        return bytes
    }
    func writeSectors(_ lba: UInt32, _ data: [UInt8]) throws { try image.writeSectors(lba, data) }
    func synchronize() throws { try image.synchronize() }
    func close() { image.close() }
}

func patternedReadImage(_ name: String) throws -> FaultyReadImage {
    let url = blankFile(name, sectors: 512)
    var bytes = Data()
    for sector in 0 ..< 512 { bytes.append(Data(repeating: UInt8(truncatingIfNeeded: sector), count: 2048)) }
    try bytes.write(to: url)
    return FaultyReadImage(try ImageDevice(url: url, writable: true))
}

test("光驱传输：READ(10) 必须完整，变长查询仍可返回较短数据") {
    let read: [UInt8] = [0x28, 0, 0, 0, 0, 37, 0, 0, 2, 0]
    try OpticalDrive.validateReadTransfer(read, expected: 4096, transferred: 4096)
    for actual: UInt64 in [0, 2048, 4095, 4097] {
        expectThrows({ try OpticalDrive.validateReadTransfer(read, expected: 4096, transferred: actual) },
                     "不能把 \(actual) 字节的 READ(10) 当作完整的 4096 字节")
    }
    try OpticalDrive.validateReadTransfer([0x52, 1, 0, 0, 0, 4, 0, 0, 36, 0], expected: 36, transferred: 32)
    try OpticalDrive.validateReadTransfer([0x46, 0, 0, 0, 0, 0, 0, 0, 64, 0], expected: 64, transferred: 12)
}

test("包缓存：短批读转单扇区重读，不能缓存不完整的读取单元") {
    let device = try patternedReadImage("short-batch.img")
    defer { device.close() }
    device.batchFault = .short(2048 + 511)
    let cache = PacketCache(device)
    expect(try cache.read(32, count: 1) == [UInt8](repeating: 32, count: 2048))
    let singleReads = device.requests.filter { $0.count == 1 }
    expect(singleReads.count == 1 && singleReads.first?.lba == 32, "短批读即使包含首个完整扇区也必须重新读取")
    // Avoid an infinite loop on the old implementation, which repeatedly cached
    // and evicted this same short unit when asked for its missing final sector.
    if singleReads.isEmpty { return }
    expect(try cache.read(47, count: 1) == [UInt8](repeating: 47, count: 2048))
    expect(device.requests.filter { $0.count > 1 }.count == 1, "同一个异常读取单元直接按扇区读取")
}

test("包缓存：短单读明确失败，恢复后重新读取而非返回截断缓存") {
    let device = try patternedReadImage("short-single.img")
    defer { device.close() }
    device.batchFault = .failure
    device.singleFault = .short(1024)
    let cache = PacketCache(device)
    var message: String?
    do { _ = try cache.read(37, count: 1) } catch { message = error.localizedDescription }
    expect(message != nil, "单扇区短读不能作为成功数据返回")
    expect(message?.contains("37") == true && message?.contains("2048") == true && message?.contains("1024") == true,
           "错误应包含扇区和预期/实际字节数：\(message ?? "没有错误")")
    let priorReads = device.requests.count
    device.singleFault = .none
    expect(try cache.read(37, count: 1) == [UInt8](repeating: 37, count: 2048))
    expect(device.requests.count > priorReads, "短单读不能进入缓存")
}

test("包缓存：批读错误后各扇区有效数据仍可完整读取") {
    let device = try patternedReadImage("failed-batch.img")
    defer { device.close() }
    device.batchFault = .failure
    let cache = PacketCache(device)
    let expected = (37 ... 39).flatMap { [UInt8](repeating: UInt8($0), count: 2048) }
    expect(try cache.read(37, count: 3) == expected)
    expect(device.requests.filter { $0.count == 1 }.map(\.lba) == [37, 38, 39])
}

test("包缓存：强制单扇区重读仍保留尚未落盘的修改") {
    let device = try patternedReadImage("dirty-reread.img")
    defer { device.close() }
    let cache = PacketCache(device)
    let pending = [UInt8](repeating: 0xBA, count: 2048)
    try cache.write(37, pending, allowDirect: false)
    device.requests.removeAll()
    expect(try cache.rereadSector(37) == pending)
    expect(try cache.read(37, count: 1) == pending)
    expect(device.requests.isEmpty, "重读不能用盘上旧数据覆盖 dirty 数据")
    expect(try device.image.readSectors(37, count: 1) == [UInt8](repeating: 37, count: 2048))
}

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

// MARK: - Write-once directory layout regressions

// These tests use only disposable image files. They intentionally reproduce the 2036-byte
// directory boundary that made a DVD-R unreadable to Windows despite passing our checker.
func writeOnceImage(_ name: String) throws -> URL {
    let url = blankFile(name, sectors: 32_768)
    let p = Process(), output = Pipe()
    p.executableURL = URL(fileURLWithPath: "/sbin/newfs_udf")
    p.arguments = ["-b", "2048", "-r", "2.01", "-m", "blk", "-t", "wo", "-v", "DIRTEST", url.path]
    p.standardOutput = output; p.standardError = output
    try p.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let line = text.split(separator: "\n").first(where: { $0.contains("last written block address:") }),
          let last = UInt64(line.split(separator: ":").last!.trimmingCharacters(in: .whitespaces)) else {
        throw UDFError("无法建立一次性写入测试镜像：\(text)")
    }
    let h = try FileHandle(forWritingTo: url)
    try h.truncate(atOffset: (last + 1) * 2048)
    try h.close()
    return url
}

func metadataReadFixture(_ name: String) throws -> (volume: UDFVolume, device: FaultyReadImage, root: UInt32, bytes: [UInt8]) {
    let url = try writeOnceImage(name)
    let device = FaultyReadImage(try ImageDevice(url: url, writable: false))
    let volume = try UDFVolume.open(device)
    let root = try volume.sector(volume.rootICB)
    let bytes = try volume.loadFileEntry(volume.rootICB).raw
    device.affectedSector = root
    volume.cache.discard()
    device.requests.removeAll()
    return (volume, device, root, bytes)
}

test("文件条目：批读全零或 CRC 错误时单扇区读取恢复真实元数据") {
    let f = try metadataReadFixture("metadata-batch-fault.img")
    defer { f.device.close() }
    for fault in [FaultyReadImage.Fault.zero, .badCRC] {
        f.volume.cache.discard()
        f.device.requests.removeAll()
        f.device.batchFault = fault
        let entry = try f.volume.loadFileEntry(f.volume.rootICB)
        expect(entry.raw == f.bytes && entry.isDirectory, "返回的必须是盘上真实 FE/EFE，而非全零或忽略 CRC")
        expect(f.device.requests.filter { $0.lba == f.root && $0.count == 1 }.count == 1,
               "元数据失败后应按真实物理地址单读一次")
        expect(f.device.requests.contains { $0.count > 1 }, "本例必须先遭遇整批读取异常")
    }
}

test("文件条目：持久坏标签及 CRC 长度越界不能被重试掩盖") {
    let f = try metadataReadFixture("metadata-permanent-fault.img")
    defer { f.device.close() }
    for fault in [FaultyReadImage.Fault.zero, .badCRC, .overlongCRC] {
        f.volume.cache.discard()
        f.device.requests.removeAll()
        f.device.batchFault = fault
        f.device.singleFault = fault
        var message: String?
        do { _ = try f.volume.loadFileEntry(f.volume.rootICB) } catch { message = error.localizedDescription }
        expect(message?.contains(f.volume.rootICB.description) == true, "重读仍无效时应报告具体文件条目损坏")
        expect(f.device.requests.filter { $0.lba == f.root && $0.count == 1 }.count == 1,
               "持久坏数据只能重试一次，不能无限重读或直接接受")
        f.device.batchFault = .none
        f.device.singleFault = .none
        expect(try f.volume.loadFileEntry(f.volume.rootICB).raw == f.bytes, "坏元数据不得成为后续读取的有效缓存")
    }
}

test("文件条目：VAT 暂存优先，不能用盘上旧的有效条目掩盖暂存损坏") {
    let f = try metadataReadFixture("metadata-staged.img")
    defer { f.device.close() }
    guard let virtual = f.volume.vatRef, Int(f.volume.rootICB.partition) == virtual,
          let tag = Tag.parse(f.bytes), let id = TagID(rawValue: tag.identifier) else {
        throw UDFError("回归样本需要有效的虚拟根目录")
    }
    let pending = FileEntry(addr: f.volume.rootICB, raw: f.bytes, extended: id == .extendedFileEntry)
    pending.uniqueID += 1000
    Tag.write(into: &pending.raw, id: id, version: tag.version, serial: tag.serial,
              location: tag.location, length: 16 + Int(tag.crcLength))
    f.volume.staged[f.volume.rootICB.block] = pending.raw
    expect(try f.volume.loadFileEntry(f.volume.rootICB).uniqueID == pending.uniqueID)
    expect(f.device.requests.isEmpty, "暂存条目不能去设备读取旧版本")
    var corrupt = pending.raw
    corrupt[20] ^= 1
    f.volume.staged[f.volume.rootICB.block] = corrupt
    expectThrows({ _ = try f.volume.loadFileEntry(f.volume.rootICB) }, "暂存损坏仍须失败，不能悄悄恢复盘上的旧条目")
    expect(f.device.requests.isEmpty, "暂存损坏也不能绕过事务去重读盘面")
    f.volume.staged.removeAll()
    expect(try f.volume.loadFileEntry(f.volume.rootICB).raw == f.bytes)
}

// Return names whose unpadded FIDs put the following descriptor tag at the chosen offset.
// The last name is 29 ASCII characters, so its FID is 68 bytes, as in the reported disc.
func boundaryNames(parentSize: Int, tail: Int) -> [String] {
    var left = 2048 - tail - parentSize
    var names: [String] = []
    while left > 0 {
        let size = left > 256 ? 128 : left
        precondition(size >= 40 && size % 4 == 0)
        let prefix = String(format: "f%03d_", names.count)
        names.append(prefix + String(repeating: "x", count: size - 39 - prefix.count))
        left -= size
    }
    names.append("last-" + String(repeating: "z", count: 24))
    return names
}

func checkPhysicalDirectory(_ v: UDFVolume, _ path: String) throws {
    let fe = try v.resolve(path).fe
    expect(fe.infoLength > 2048, "必须实际覆盖多块目录边界")
    expect(fe.adType == 1, "VAT 目录数据应使用 long_ad 引用物理分区")
    expect(!fe.extents.isEmpty)
    for e in fe.extents {
        expect(e.location.partition == v.physRef, "目录数据不能存放在虚拟分区")
        expect(e.kind == .recorded)
    }
    let data = try v.readAll(fe)
    expect(UInt64(data.count) == fe.infoLength)
    var offset = 0
    while offset + 38 <= data.count {
        let length = (38 + Int(data[offset + 19]) + Int(data.u16(offset + 36)) + 3) & ~3
        expect(offset % 2048 <= 2048 - 16, "FID Tag 在偏移 \(offset) 跨块")
        let tag = Tag.parse(data, at: offset)
        expect(tag?.identifier == TagID.fileIdentifier.rawValue, "FID CRC 和标签校验必须正确（包括正文跨块的项）")
        var extentStart = 0
        var physicalBlock: UInt32?
        for e in fe.extents {
            if offset < extentStart + Int(e.length) {
                physicalBlock = e.location.block + UInt32((offset - extentStart) / 2048)
                break
            }
            extentStart += Int(e.length)
        }
        expect(tag?.location == physicalBlock, "FID tagLocation 必须是其真实物理逻辑块，不能假定 CD-R 链接块不存在")
        let implLength = Int(data.u16(offset + 36))
        expect(implLength == 0 || (implLength >= 32 && implLength % 4 == 0), "目录填充必须采用合法的 ImplementationUse")
        offset += length
    }
    expect(offset == data.count, "目录不能用裸零字节填充 FID 之间的空隙")
}

func directoryBoundaryRegression(name: String, link: Int, alignment: Int) throws {
    let url = try writeOnceImage("directory-\(name).img")
    let payload = Array("directory regression payload".utf8)
    let src = work.appendingPathComponent("directory-payload-\(name).txt")
    try Data(payload).write(to: src)
    let v = try UDFVolume.open(ImageDevice(url: url, writable: true, sequential: true,
                                         linkBlocks: link, appendAlignment: alignment, capacityMB: 64))
    expect(v.isWriteOnce)
    var expected: [String: [String]] = [:]
    for tail in [12, 8, 4] {
        let path = "/edge\(tail)"
        try v.makeDirectory(path)
        let parentSize = try v.readFIDs(v.resolve(path).fe).reduce(0) { $0 + $1.size }
        let names = boundaryNames(parentSize: parentSize, tail: tail)
        expected[path] = names
        for filename in names { try v.add(from: src, to: path + "/" + filename) }
        try checkPhysicalDirectory(v, path)
        expect(try Set(v.list(path).map(\.name)) == Set(names))
        expect(try v.readFile(path + "/" + names.last!) == payload)
    }
    if alignment == 16 {
        expect(v.vatLocation.map { ($0 + 1) % 16 == 0 } ?? false, "更新目录后 VAT 仍位于 ECC 块末尾")
    } else {
        let dir = try v.resolve("/edge12").fe
        expect(dir.extents.count >= 2, "CD-R 镜像必须真正产生物理链接间隙")
        if dir.extents.count >= 2 {
            let first = dir.extents[0], second = dir.extents[1]
            expect(second.location.block > first.location.block + (first.length + 2047) / 2048,
                   "不能仅验证恰好连续的两个目录块")
        }
    }
    expect(try v.check().isClean)
    v.device.close()
    let reopened = try UDFVolume.open(ImageDevice(url: url, writable: false))
    for (path, names) in expected {
        try checkPhysicalDirectory(reopened, path)
        expect(try Set(reopened.list(path).map(\.name)) == Set(names))
        for filename in names { expect(try reopened.readFile(path + "/" + filename) == payload) }
    }
    expect(try reopened.check().isClean)
}

test("一次性目录：DVD-R 的 4/8/12 字节边界、物理地址和重开读取") {
    try directoryBoundaryRegression(name: "dvd", link: 16, alignment: 16)
}

test("一次性目录：CD-R 链接间隙中的 FID 位置和跨块 CRC") {
    try directoryBoundaryRegression(name: "cd", link: 7, alignment: 1)
}

// Construct the old, nonconforming layout in a disposable image, without relying on the
// production writer to still contain the bug. This fixture has a tag beginning at 2036
// and a 2104-byte short_ad pointing into the virtual partition.
func installLegacyDirectory(_ v: UDFVolume, path: String) throws {
    let fe = try v.resolve(path).fe
    var fids = try v.readFIDs(fe)
    for i in fids.indices { fids[i].implUse = [] }
    let length = fids.reduce(0) { $0 + $1.size }
    expect(length == 2104, "旧布局回归样本必须精确重现 2104 字节目录")
    guard let ref = v.vatRef else { throw UDFError("需要 VAT 测试镜像") }
    try v.transaction {
        let first = v.vat.count
        let blocks = (length + 2047) / 2048
        v.vat += [UInt32](repeating: 0xFFFF_FFFE, count: blocks)
        var data = [UInt8](repeating: 0, count: blocks * 2048)
        var offset = 0
        for f in fids {
            data.put16(offset + 16, f.version)
            data[offset + 18] = f.characteristics
            data[offset + 19] = UInt8(f.nameRaw.count)
            data.putBytes(offset + 20, f.icb)
            data.put16(offset + 36, 0)
            data.putBytes(offset + 38, f.nameRaw)
            Tag.write(into: &data, at: offset, id: .fileIdentifier, version: v.tagVersion,
                      serial: v.tagSerial, location: UInt32(first + offset / 2048), length: f.size)
            offset += f.size
        }
        for i in 0 ..< blocks {
            try v.writeBlocks(LBAddr(block: UInt32(first + i), partition: UInt16(ref)),
                              Array(data[(i * 2048) ..< ((i + 1) * 2048)]))
        }
        fe.adType = 0
        fe.infoLength = UInt64(length)
        fe.extents = [Extent(length: UInt32(length), kind: .recorded,
                             location: LBAddr(block: UInt32(first), partition: UInt16(ref)))]
        try v.writeFileEntry(fe)
    }
}

test("一次性目录：修复旧跨块布局只追加，文件和时间戳保持不变") {
    let url = try writeOnceImage("legacy-directory.img")
    let src = work.appendingPathComponent("legacy-directory.txt")
    let payload = Array("preserve this content".utf8)
    try Data(payload).write(to: src)
    let v = try UDFVolume.open(ImageDevice(url: url, writable: true, sequential: true,
                                         linkBlocks: 16, appendAlignment: 16, capacityMB: 64))
    try v.makeDirectory("/legacy")
    let parentSize = try v.readFIDs(v.resolve("/legacy").fe).reduce(0) { $0 + $1.size }
    let names = boundaryNames(parentSize: parentSize, tail: 12)
    for filename in names { try v.add(from: src, to: "/legacy/" + filename) }
    try installLegacyDirectory(v, path: "/legacy")
    let oldFE = try v.resolve("/legacy").fe
    let oldTime = oldFE.modified
    let oldCounts = (v.vatHeader.u32(136), v.vatHeader.u32(140))
    let oldData = try v.readAll(oldFE)
    expect(oldFE.adType == 0 && oldFE.extents.first?.length == 2104)
    expect(Tag.parse(oldData, at: 2036)?.identifier == TagID.fileIdentifier.rawValue,
           "坏样本的 CRC 应正确；缺陷是 Tag 位置跨块而非随机损坏")
    expect(try !v.check().isClean, "检查应识别目录兼容性缺陷，不能只因 CRC 正确就报通过")
    let prefix = try Data(contentsOf: url)
    try v.repairDirectoryLayout("/legacy")
    try checkPhysicalDirectory(v, "/legacy")
    expect(try v.resolve("/legacy").fe.modified == oldTime)
    expect(v.vatHeader.u32(136) == oldCounts.0 && v.vatHeader.u32(140) == oldCounts.1)
    expect(try Data(contentsOf: url).prefix(prefix.count) == prefix, "修复不能改写已有扇区")
    v.device.close()
    let reopened = try UDFVolume.open(ImageDevice(url: url, writable: false))
    try checkPhysicalDirectory(reopened, "/legacy")
    expect(try Set(reopened.list("/legacy").map(\.name)) == Set(names))
    for filename in names { expect(try reopened.readFile("/legacy/" + filename) == payload) }
    expect(try reopened.check().isClean)
}

// Give an image a precise remaining capacity, including the simulated drive's link
// blocks and flush padding. A real capacity limit must reject writes too, otherwise a
// missing preflight could silently succeed despite reporting no available space.
final class CapacityLimitedImage: SectorDevice {
    let image: ImageDevice
    let end: UInt32
    private(set) var writeAttempts = 0
    init(_ image: ImageDevice, remaining: UInt32) {
        self.image = image
        end = image.sectorCount + remaining
    }
    var label: String { image.label }
    var sectorSize: Int { image.sectorSize }
    var sectorCount: UInt32 { image.sectorCount }
    var readOnlyReason: String? { image.readOnlyReason }
    var packetSectors: Int { image.packetSectors }
    var packetBase: UInt32 { image.packetBase }
    var isSequential: Bool { image.isSequential }
    var lastRecordedSector: UInt32 { image.lastRecordedSector }
    var appendAlignment: Int { image.appendAlignment }
    var appendableSectors: UInt32 { min(image.appendableSectors, end - min(end, sectorCount)) }
    func nextWritableAddress() throws -> UInt32 { try image.nextWritableAddress() }
    func readSectors(_ lba: UInt32, count: Int) throws -> [UInt8] { try image.readSectors(lba, count: count) }
    func writeSectors(_ lba: UInt32, _ data: [UInt8]) throws {
        writeAttempts += 1
        let link = appendAlignment > 1 ? 0 : image.linkBlocks
        guard UInt64(lba) + UInt64(data.count / sectorSize + link) <= UInt64(end) else {
            throw UDFError("测试镜像容量已耗尽")
        }
        try image.writeSectors(lba, data)
    }
    func synchronize() throws {
        let extra = appendAlignment > 1
            ? (appendAlignment - Int(sectorCount) % appendAlignment) % appendAlignment + image.linkBlocks : 0
        guard UInt64(sectorCount) + UInt64(extra) <= UInt64(end) else {
            throw UDFError("测试镜像没有刷新所需的空间")
        }
        try image.synchronize()
    }
    func close() { image.close() }
}

test("一次性目录：近满 DVD-R/CD-R 修复须在任何追加前拒绝") {
    let original = try writeOnceImage("capacity-legacy.img")
    let src = work.appendingPathComponent("capacity-payload.txt")
    let payload = Array("keep this file even when repair cannot fit".utf8)
    try Data(payload).write(to: src)
    let setup = try UDFVolume.open(ImageDevice(url: original, writable: true, sequential: true,
                                             linkBlocks: 16, appendAlignment: 16, capacityMB: 64))
    try setup.makeDirectory("/legacy")
    let parentSize = try setup.readFIDs(setup.resolve("/legacy").fe).reduce(0) { $0 + $1.size }
    let names = boundaryNames(parentSize: parentSize, tail: 12)
    for filename in names { try setup.add(from: src, to: "/legacy/" + filename) }
    try installLegacyDirectory(setup, path: "/legacy")
    setup.device.close()
    let before = try Data(contentsOf: original)

    for (name, link, alignment, capacity) in [("dvd", 16, 16, 2), ("cd", 7, 1, 16)] {
        let url = work.appendingPathComponent("capacity-\(name).img")
        try FileManager.default.copyItem(at: original, to: url)
        let device = CapacityLimitedImage(try ImageDevice(url: url, writable: true, sequential: true,
                                                         linkBlocks: link, appendAlignment: alignment, capacityMB: 64),
                                          remaining: UInt32(capacity))
        let v = try UDFVolume.open(device)
        let oldNWA = try device.nextWritableAddress()
        let oldVAT = v.vatLocation
        // Both limits fit the complete two-sector replacement directory, including
        // CD-R link blocks, but leave no room for its ICB or the committing VAT.
        expect(device.appendableSectors == UInt32(capacity))
        var repairError: String?
        do { try v.repairDirectoryLayout("/legacy") } catch { repairError = error.localizedDescription }
        expect(repairError != nil, "空间不足时修复必须失败")
        expect(repairError?.contains("空间不足") == true || repairError?.contains("Not enough space") == true,
               "应由写前容量检查拒绝，不能等到底层写失败：\(repairError ?? "没有错误")")
        expect(device.writeAttempts == 0, "\(name)：不能尝试写入目录或回滚 VAT")
        expect(try device.nextWritableAddress() == oldNWA && v.vatLocation == oldVAT)
        expect(try Data(contentsOf: url) == before, "\(name)：拒绝修复后整个镜像必须字节不变，不能仅保持旧前缀")
        device.close()
        let reopened = try UDFVolume.open(ImageDevice(url: url, writable: false))
        expect(try Set(reopened.list("/legacy").map(\.name)) == Set(names))
        for filename in names { expect(try reopened.readFile("/legacy/" + filename) == payload) }
        reopened.device.close()
    }
}

// MARK: - Sorting

func entry(_ name: String, dir: Bool = false, size: UInt64 = 0, day: Int? = nil) -> UDFEntry {
    UDFEntry(name: name, path: name, isDirectory: dir, size: size,
             modified: day.map { Date(timeIntervalSince1970: TimeInterval($0) * 86_400) }, isHidden: false,
             icb: LBAddr(block: 0, partition: 0))
}

test("排序：文件夹在前，名称按自然顺序") {
    // Latin names only: how Chinese sorts against Latin depends on the system language
    // (on a Chinese system Han characters come first, the same as in the Finder).
    let list = [entry("file10.txt"), entry("Photos", dir: true), entry("file2.txt"), entry("B.pdf"), entry("a.pdf"), entry("Archive", dir: true)]
    expect(EntrySort.name.sorted(list, ascending: true).map(\.name) == ["Archive", "Photos", "a.pdf", "B.pdf", "file2.txt", "file10.txt"])
    expect(EntrySort.name.sorted(list, ascending: false).map(\.name) == ["Photos", "Archive", "file10.txt", "file2.txt", "B.pdf", "a.pdf"],
           "降序时文件夹仍在前")
}

test("排序：按大小、日期，相同值按名称") {
    let list = [entry("c", size: 300, day: 3), entry("a", size: 100, day: 9), entry("b", size: 300, day: 1), entry("d", dir: true)]
    expect(EntrySort.size.sorted(list, ascending: true).map(\.name) == ["d", "a", "b", "c"])
    expect(EntrySort.size.sorted(list, ascending: false).map(\.name) == ["d", "b", "c", "a"], "同样大小时按名称 A→Z")
    expect(EntrySort.date.sorted(list, ascending: false).map(\.name) == ["d", "a", "c", "b"])
    let noDate = [entry("x"), entry("y", day: 1)]
    expect(EntrySort.date.sorted(noDate, ascending: true).map(\.name) == ["x", "y"], "没有日期的排在最早")
}

test("排序：按种类") {
    let list = [entry("photo.jpg"), entry("notes.txt"), entry("report.pdf"), entry("scan.pdf")]
    let kinds = ["jpg": "JPEG image", "txt": "Plain Text", "pdf": "PDF document"]
    let sorted = EntrySort.kind.sorted(list, ascending: true, kind: { kinds[($0.name as NSString).pathExtension] ?? "" })
    expect(sorted.map(\.name) == ["photo.jpg", "report.pdf", "scan.pdf", "notes.txt"], "\(sorted.map(\.name))")
    expect(EntrySort.kind.sorted(list, ascending: false, kind: { kinds[($0.name as NSString).pathExtension] ?? "" }).map(\.name)
           == ["notes.txt", "report.pdf", "scan.pdf", "photo.jpg"], "降序时同种类仍按名称 A→Z")
}

// MARK: - Report

print("\n通过 \(passed)，失败 \(failed.count)")
for f in failed { print("  ✗ \(f)") }
exit(failed.isEmpty ? 0 : 1)
