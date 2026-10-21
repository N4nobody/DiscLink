import Foundation

public final class UDFVolume {
    public let cache: PacketCache
    public var device: SectorDevice { cache.device }
    public let blockSize: Int
    public private(set) var volumeName = ""
    public private(set) var udfRevision: UInt16 = 0
    public private(set) var warnings: [String] = []
    public private(set) var layoutDescription = ""
    var maps: [PartitionMap] = []
    var sparing: [UInt32: UInt32] = [:]
    var metadataExtents: [Extent] = []
    var lvidSector: UInt32 = 0
    var lvid: [UInt8] = []
    var rootICB = LBAddr(block: 0, partition: 0)
    var fsdAddr = LBAddr(block: 0, partition: 0)
    var tagVersion: UInt16 = 2
    var tagSerial: UInt16 = 0
    var bitmap: SpaceBitmap?
    var writeBlocker: String?
    // Write-once (VAT) volumes.
    var vatRef: Int?
    var physRef: UInt16 = 0
    var vat: [UInt32] = []
    var vatHeader: [UInt8] = []
    var vatICBSector: UInt32 = 0
    /// Virtual blocks written in the current transaction, appended at commit.
    var staged: [UInt32: [UInt8]] = [:]
    var nextUnique: UInt64 = 16

    /// True for CD-R/DVD-R style volumes that map blocks through a VAT.
    public var isWriteOnce: Bool { vatRef != nil }

    public var readOnlyReason: String? { device.readOnlyReason ?? writeBlocker }

    public static func open(_ device: SectorDevice) throws -> UDFVolume {
        let v = UDFVolume(cache: PacketCache(device))
        try v.mount()
        return v
    }

    init(cache: PacketCache) {
        self.cache = cache
        blockSize = cache.device.sectorSize
    }

    // MARK: Sector / block I/O

    func readSectors(_ s: UInt32, _ n: Int) throws -> [UInt8] { try cache.read(s, count: n) }

    func sector(_ a: LBAddr) throws -> UInt32 {
        guard Int(a.partition) < maps.count else { throw UDFError(L("分区引用无效：\(a)", "Invalid partition reference: \(a)")) }
        let m = maps[Int(a.partition)]
        switch m.kind {
        case .physical:
            guard a.block < m.partition.length else { throw UDFError(L("块地址超出分区：\(a)", "Block address outside the partition: \(a)")) }
            return m.partition.start + a.block
        case .sparable(let pl):
            guard a.block < m.partition.length else { throw UDFError(L("块地址超出分区：\(a)", "Block address outside the partition: \(a)")) }
            let pkt = a.block - a.block % pl
            if let mapped = sparing[pkt] { return mapped + (a.block - pkt) }
            return m.partition.start + a.block
        case .metadata:
            var off = UInt64(a.block) * UInt64(blockSize)
            for e in metadataExtents {
                if off < UInt64(e.length) {
                    let phys = LBAddr(block: e.location.block + UInt32(off / UInt64(blockSize)), partition: e.location.partition)
                    return try sector(phys)
                }
                off -= UInt64(e.length)
            }
            throw UDFError(L("元数据分区地址无效：\(a)", "Invalid metadata partition address: \(a)"))
        case .virtual:
            guard Int(a.block) < vat.count, vat[Int(a.block)] != 0xFFFF_FFFF else { throw UDFError(L("虚拟块未映射：\(a)", "Virtual block is not mapped: \(a)")) }
            return m.partition.start + vat[Int(a.block)]
        }
    }

    /// Reads `count` logical blocks, splitting where the mapping is not contiguous.
    func readBlocks(_ a: LBAddr, _ count: Int) throws -> [UInt8] {
        if let v = vatRef, Int(a.partition) == v {
            var out = [UInt8]()
            for i in 0 ..< count {
                let blk = a.block + UInt32(i)
                if let d = staged[blk] { out += d } else { out += try readSectors(try sector(LBAddr(block: blk, partition: a.partition)), 1) }
            }
            return out
        }
        var out = [UInt8]()
        out.reserveCapacity(count * blockSize)
        var i = 0
        while i < count {
            let s = try sector(LBAddr(block: a.block + UInt32(i), partition: a.partition))
            var run = 1
            while i + run < count, run < 512,
                  try sector(LBAddr(block: a.block + UInt32(i + run), partition: a.partition)) == s + UInt32(run) { run += 1 }
            out += try readSectors(s, run)
            i += run
        }
        return out
    }

    /// Writes whole logical blocks. Metadata always goes through the packet cache so a failed
    /// transaction leaves the disc untouched; file data may bypass it.
    func writeBlocks(_ a: LBAddr, _ data: [UInt8], metadata: Bool = true) throws {
        precondition(data.count % blockSize == 0)
        let count = data.count / blockSize
        if let v = vatRef {
            // Write-once: virtual blocks are staged and get their real place at commit.
            guard Int(a.partition) == v else { throw UDFError(L("一次性写入盘不能覆盖已写入的数据", "Data already recorded on a write-once disc can't be overwritten")) }
            for i in 0 ..< count { staged[a.block + UInt32(i)] = Array(data[(i * blockSize) ..< ((i + 1) * blockSize)]) }
            return
        }
        var i = 0
        while i < count {
            let s = try sector(LBAddr(block: a.block + UInt32(i), partition: a.partition))
            var run = 1
            while i + run < count, run < 512,
                  try sector(LBAddr(block: a.block + UInt32(i + run), partition: a.partition)) == s + UInt32(run) { run += 1 }
            try cache.write(s, Array(data[(i * blockSize) ..< ((i + run) * blockSize)]), allowDirect: !metadata)
            i += run
        }
    }

    // MARK: Mount

    func mount() throws {
        let ss = blockSize
        // Volume recognition sequence: look for NSR02/NSR03.
        var sawNSR = false
        for k in 0 ..< 16 {
            let off = 32768 + k * 2048
            let sec = UInt32(off / ss)
            guard sec < device.sectorCount, let b = try? readSectors(sec, 1) else { break }
            let inner = off % ss
            let id = String(decoding: b[(inner + 1) ..< (inner + 6)], as: UTF8.self)
            if id == "NSR02" || id == "NSR03" { sawNSR = true }
            if id == "TEA01" || b[inner + 1] == 0 { break }
        }
        if !sawNSR { warnings.append(L("没有找到 UDF 识别标记（NSR），仍尝试读取", "No UDF recognition marker (NSR) found; trying to read anyway")) }

        // Anchor.
        var anchor: [UInt8]?
        for loc in [UInt32(256), device.sectorCount &- 1, device.sectorCount &- 257, UInt32(512)] where loc < device.sectorCount {
            if let b = try? readSectors(loc, 1), let t = Tag.parse(b), t.identifier == TagID.anchor.rawValue {
                anchor = b; break
            }
        }
        guard let avdp = anchor else { throw UDFError(L("这不是 UDF 光盘（找不到锚点描述符）", "This is not a UDF disc (no anchor descriptor found)")) }
        tagSerial = Tag.parse(avdp)!.serial

        var vds: (pvd: [UInt8]?, lvd: [UInt8]?, pds: [UInt16: [UInt8]]) = (nil, nil, [:])
        for (o, name) in [(16, L("主", "Main")), (24, L("备用", "Reserve"))] {
            vds = try readVDS(start: avdp.u32(o + 4), length: avdp.u32(o))
            if vds.lvd != nil && !vds.pds.isEmpty { break }
            warnings.append(L("\(name)卷描述符序列不完整", "\(name) volume descriptor sequence is incomplete"))
        }
        guard let lvd = vds.lvd else { throw UDFError(L("找不到逻辑卷描述符", "No logical volume descriptor found")) }
        if let pvd = vds.pvd { volumeName = CS0.decodeD(pvd, 24, 32) }
        let lvName = CS0.decodeD(lvd, 84, 128)
        if !lvName.isEmpty { volumeName = lvName }

        guard Int(lvd.u32(212)) == ss else {
            throw UDFError(L("逻辑块大小 \(lvd.u32(212)) 与扇区大小 \(ss) 不一致，暂不支持", "Logical block size \(lvd.u32(212)) differs from the sector size \(ss); not supported yet"))
        }
        let domain = EntityID.parse(lvd, 216)
        udfRevision = UInt16(domain.suffix[0]) | UInt16(domain.suffix[1]) << 8
        if !domain.identifier.hasPrefix("*OSTA UDF") { warnings.append(L("域标识不是 OSTA UDF：\(domain.identifier)", "Domain identifier is not OSTA UDF: \(domain.identifier)")) }

        // Partition maps.
        let mapCount = Int(lvd.u32(268))
        var o = 440
        var hasSparable = false
        for _ in 0 ..< mapCount {
            let type = lvd[o], len = Int(lvd[o + 1])
            guard len > 0, o + len <= lvd.count else { throw UDFError(L("分区映射表损坏", "The partition map table is damaged")) }
            if type == 1 {
                let num = lvd.u16(o + 4)
                guard let pd = vds.pds[num] else { throw UDFError(L("缺少分区描述符 \(num)", "Partition descriptor \(num) is missing")) }
                maps.append(PartitionMap(kind: .physical, partition: parsePD(pd)))
            } else if type == 2 {
                let ident = EntityID.parse(lvd, o + 4).identifier
                let num = lvd.u16(o + 38)
                guard let pd = vds.pds[num] else { throw UDFError(L("缺少分区描述符 \(num)", "Partition descriptor \(num) is missing")) }
                let part = parsePD(pd)
                if ident.hasPrefix("*UDF Sparable Partition") {
                    hasSparable = true
                    let pl = UInt32(lvd.u16(o + 40))
                    let nTables = Int(lvd[o + 42])
                    let tableSize = Int(lvd.u32(o + 44))
                    var locs: [UInt32] = []
                    for k in 0 ..< nTables { locs.append(lvd.u32(o + 48 + 4 * k)) }
                    try loadSparingTable(locs, size: tableSize)
                    maps.append(PartitionMap(kind: .sparable(packetLength: max(pl, 1)), partition: part))
                } else if ident.hasPrefix("*UDF Virtual Partition") {
                    vatRef = maps.count
                    maps.append(PartitionMap(kind: .virtual, partition: part))
                } else if ident.hasPrefix("*UDF Metadata Partition") {
                    maps.append(PartitionMap(kind: .metadata(fileLocation: lvd.u32(o + 40)), partition: part))
                    writeBlocker = L("UDF 2.50 及以上的元数据分区目前只能读取", "Metadata partitions (UDF 2.50 and later) can only be read for now")
                } else {
                    throw UDFError(L("不认识的分区类型：\(ident)", "Unknown partition type: \(ident)"))
                }
            } else {
                throw UDFError(L("不认识的分区映射类型 \(type)", "Unknown partition map type \(type)"))
            }
            o += len
        }
        guard !maps.isEmpty else { throw UDFError(L("没有分区", "No partitions")) }

        // Metadata partitions are files inside a physical partition with the same number.
        for m in maps {
            if case .metadata(let loc) = m.kind {
                guard let phys = maps.firstIndex(where: { if case .physical = $0.kind { return $0.partition.number == m.partition.number }; return false }) else {
                    throw UDFError(L("元数据分区缺少对应的物理分区", "The metadata partition has no matching physical partition"))
                }
                let fe = try loadFileEntry(LBAddr(block: loc, partition: UInt16(phys)))
                metadataExtents = fe.extents
            }
        }
        if let v = vatRef { try loadVAT(virtualIndex: v) }
        layoutDescription = maps.map { m -> String in
            switch m.kind {
            case .physical: return L("物理分区", "Physical partition")
            case .sparable(let pl): return L("可备用分区（包写入，每包 \(pl) 块）", "Sparable partition (packet writing, \(pl) blocks per packet)")
            case .virtual: return L("虚拟分配表 VAT（一次性写入，\(vat.count) 个虚拟块）", "Virtual allocation table (write-once, \(vat.count) virtual blocks)")
            case .metadata: return L("元数据分区", "Metadata partition")
            }
        }.joined(separator: " + ")

        // Integrity.
        try loadLVID(start: lvd.u32(436), length: lvd.u32(432))

        // File set descriptor -> root directory.
        fsdAddr = LBAddr.parse(lvd, 252)
        let fsd = try readBlocks(fsdAddr, 1)
        guard let ft = Tag.parse(fsd), ft.identifier == TagID.fileSet.rawValue else { throw UDFError(L("文件集描述符损坏", "The file set descriptor is damaged")) }
        tagVersion = ft.version
        rootICB = LBAddr.parse(fsd, 404)

        // Writability checks.
        if vatRef != nil, writeBlocker == nil {
            if !device.isSequential {
                writeBlocker = device is ImageDevice ? L("一次性写入盘的镜像要用追加模式打开（--sequential）", "Images of write-once discs must be opened in append mode (--sequential)") : L("光盘已封盘或光驱不能追加写入", "The disc is finalized, or the drive can't append to it")
            } else if vatHeader.isEmpty {
                writeBlocker = L("UDF 1.50 的一次性写入盘目前只能读取", "UDF 1.50 write-once discs can only be read for now")
            } else if udfRevision >= 0x0250 {
                writeBlocker = L("UDF \(revisionString) 目前只能读取", "UDF \(revisionString) can only be read for now")
            } else {
                nextUnique = try scanMaxUniqueID() + 1
            }
        } else if writeBlocker == nil {
            if udfRevision >= 0x0250 { writeBlocker = L("UDF \(revisionString) 目前只能读取", "UDF \(revisionString) can only be read for now") }
            let part = maps[Int(rootICB.partition)].partition
            if part.accessType == 1 { writeBlocker = L("分区标记为只读", "The partition is marked read-only") }
            else if part.accessType == 2 { writeBlocker = L("这是一次性写入的分区，暂不支持", "This is a write-once partition; not supported yet") }
            else if part.usesSpaceTable && part.bitmap == nil { writeBlocker = L("分区使用空间表而非位图，暂不支持写入", "The partition uses a space table instead of a bitmap; writing isn't supported yet") }
            else if part.bitmap == nil { writeBlocker = L("分区没有空间位图，无法安全写入", "The partition has no space bitmap, so it can't be written safely") }
            else if lvid.isEmpty { writeBlocker = L("找不到完整性描述符，无法安全写入", "No integrity descriptor found, so the disc can't be written safely") }
        }
        if writeBlocker == nil, let bm = maps[Int(rootICB.partition)].partition.bitmap {
            let nBlocks = (Int(bm.length) + blockSize - 1) / blockSize
            let raw = try readBlocks(LBAddr(block: bm.position, partition: rootICB.partition), nBlocks)
            bitmap = try SpaceBitmap(ref: rootICB.partition, firstBlock: bm.position, raw: raw, blockSize: blockSize)
        }
        if vatRef == nil && !lvid.isEmpty && lvid.u32(28) == 0 {
            warnings.append(L("光盘上次没有正常关闭（完整性标记为“打开”），建议先在 Windows 上检查", "The disc wasn't closed properly last time (integrity is marked open); check it in Windows first"))
        }
        if hasSparable && device.packetSectors == 1 && !(device is ImageDevice) {
            warnings.append(L("这是包写入格式，但光驱没有报告包大小", "This disc uses packet writing, but the drive didn't report a packet size"))
        }
    }

    private func loadVAT(virtualIndex: Int) throws {
        let vm = maps[virtualIndex]
        guard let p = maps.firstIndex(where: { if case .physical = $0.kind { return $0.partition.number == vm.partition.number }; return false }) else {
            throw UDFError(L("虚拟分区缺少对应的物理分区", "The virtual partition has no matching physical partition"))
        }
        physRef = UInt16(p)
        let start = maps[p].partition.start
        // The VAT's file entry is the last thing recorded; CD-R link blocks or an interrupted
        // write can leave a few sectors after it, so scan backwards.
        // Read one sector at a time straight from the device: a batched read fails as a whole if
        // any sector in it is unrecorded, and the drive spends a long time retrying each failure.
        var s = min(device.lastRecordedSector, device.sectorCount &- 1)
        let lowest = max(start, s > 4096 ? s - 4096 : 0)
        var unreadable = 0
        while s >= lowest {
            guard let raw = try? device.readSectors(s, count: 1) else {
                unreadable += 1
                if unreadable > 24 { break }
                if s == 0 { break }
                s -= 1
                continue
            }
            let tag = Tag.parse(raw, checkCRC: false)?.identifier
            if tag == TagID.fileEntry.rawValue || tag == TagID.extendedFileEntry.rawValue,
               let fe = try? loadFileEntry(LBAddr(block: s - start, partition: physRef)), let data = try? readAll(fe) {
                if fe.fileType == 248, data.count >= 152 {
                    let hl = Int(data.u16(0))
                    guard hl >= 152, hl <= data.count else { throw UDFError(L("VAT 头部损坏", "The VAT header is damaged")) }
                    vatHeader = Array(data[0 ..< hl])
                    vat = stride(from: hl, to: data.count - 3, by: 4).map { data.u32($0) }
                    vatICBSector = s
                    return
                }
                if fe.fileType == 0, data.count >= 36,
                   EntityID.parse(data, data.count - 36).identifier.hasPrefix("*UDF Virtual Alloc Tbl") {
                    vat = stride(from: 0, to: data.count - 36 - 3, by: 4).map { data.u32($0) }
                    vatICBSector = s
                    return
                }
            }
            if s == 0 { break }
            s -= 1
        }
        throw UDFError(L("找不到虚拟分配表（VAT），光盘可能是空白的或已损坏", "No virtual allocation table (VAT) found; the disc may be blank or damaged"))
    }

    /// Unique IDs on write-once discs aren't tracked in the integrity descriptor, so find the largest in use.
    private func scanMaxUniqueID() throws -> UInt64 {
        var maxID: UInt64 = 15
        var seen = Set<LBAddr>()
        func walk(_ addr: LBAddr) throws {
            guard seen.insert(addr).inserted else { return }
            let fe = try loadFileEntry(addr)
            maxID = max(maxID, fe.uniqueID)
            if fe.isDirectory {
                for f in try readFIDs(fe) where !f.isDeleted && !f.isParent { try walk(f.icbAddr) }
            }
        }
        try walk(rootICB)
        return maxID
    }

    /// Sectors that can still be appended on a write-once disc (limited by drive and partition).
    var appendableSectors: UInt32 {
        guard vatRef != nil, let nwa = try? device.nextWritableAddress() else { return 0 }
        let p = maps[Int(physRef)].partition
        let partEnd = p.start + p.length
        return min(device.appendableSectors, partEnd > nwa ? partEnd - nwa : 0)
    }

    public var revisionString: String { String(format: "%x.%02x", udfRevision >> 8, udfRevision & 0xFF) }

    private func readVDS(start: UInt32, length: UInt32) throws -> (pvd: [UInt8]?, lvd: [UInt8]?, pds: [UInt16: [UInt8]]) {
        var pvd: ([UInt8], UInt32)?, lvd: ([UInt8], UInt32)?
        var pds: [UInt16: ([UInt8], UInt32)] = [:]
        var loc = start
        var end = start + max(1, length / UInt32(blockSize))
        var hops = 0
        while loc < end, loc < device.sectorCount, hops < 256 {
            guard let b = try? readSectors(loc, 1), let t = Tag.parse(b) else { break }
            let seq = b.u32(16)
            switch TagID(rawValue: t.identifier) {
            case .primaryVolume: if pvd == nil || seq >= pvd!.1 { pvd = (b, seq) }
            case .logicalVolume:
                // An LVD can be longer than one sector when it has many partition maps.
                let full = 440 + Int(b.u32(264))
                let data = full > blockSize ? (try readSectors(loc, (full + blockSize - 1) / blockSize)) : b
                if lvd == nil || seq >= lvd!.1 { lvd = (data, seq) }
            case .partition:
                let num = b.u16(22)
                if pds[num] == nil || seq >= pds[num]!.1 { pds[num] = (b, seq) }
            case .pointer:
                loc = b.u32(24); end = loc + max(1, b.u32(20) / UInt32(blockSize)); hops += 1; continue
            case .terminating: loc = end; continue
            default: break
            }
            loc += 1
        }
        return (pvd?.0, lvd?.0, pds.mapValues { $0.0 })
    }

    private func parsePD(_ b: [UInt8]) -> PartitionDesc {
        let contents = EntityID.parse(b, 24).identifier
        var bitmap: (UInt32, UInt32)?
        var table = false
        if contents.hasPrefix("+NSR0") {
            let phd = 56
            if b.u32(phd + 8) & 0x3FFF_FFFF > 0 { bitmap = (b.u32(phd + 12), b.u32(phd + 8) & 0x3FFF_FFFF) }
            if b.u32(phd) & 0x3FFF_FFFF > 0 { table = true }
        }
        return PartitionDesc(number: b.u16(22), start: b.u32(188), length: b.u32(192),
                             accessType: b.u32(184), bitmap: bitmap, usesSpaceTable: table)
    }

    private func loadSparingTable(_ locations: [UInt32], size: Int) throws {
        let n = max(1, (size + blockSize - 1) / blockSize)
        for loc in locations where loc < device.sectorCount {
            guard let b = try? readSectors(loc, n), let t = Tag.parse(b, checkCRC: true),
                  EntityID.parse(b, 16).identifier.hasPrefix("*UDF Sparing Table") || t.identifier == 0 else { continue }
            let entries = Int(b.u16(48))
            for k in 0 ..< entries {
                let o = 56 + 8 * k
                guard o + 8 <= b.count else { break }
                let orig = b.u32(o), mapped = b.u32(o + 4)
                if orig < 0xFFFF_FFF0 { sparing[orig] = mapped }
            }
            return
        }
        warnings.append(L("找不到有效的备用表，按未替换处理", "No valid sparing table found; assuming nothing was remapped"))
    }

    private func loadLVID(start: UInt32, length: UInt32) throws {
        var loc = start
        var end = start + length / UInt32(blockSize)
        var hops = 0
        while loc < end, loc < device.sectorCount, hops < 64 {
            guard let b = try? readSectors(loc, 1), let t = Tag.parse(b, checkCRC: false) else { break }
            if t.identifier == TagID.integrity.rawValue {
                let n = Int(b.u32(72)), iu = Int(b.u32(76))
                let total = 80 + 8 * n + iu
                let full = total > blockSize ? try readSectors(loc, (total + blockSize - 1) / blockSize) : b
                guard Tag.parse(full) != nil else { break }
                lvid = full; lvidSector = loc
                let nextLen = b.u32(32)
                if nextLen > 0 { loc = b.u32(36); end = loc + nextLen / UInt32(blockSize); hops += 1; continue }
            } else if t.identifier == TagID.terminating.rawValue {
                break
            } else { break }
            loc += 1
        }
    }
}
