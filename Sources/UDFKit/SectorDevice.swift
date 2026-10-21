import Foundation

/// Something made of fixed-size sectors: a disc image file or a real optical drive.
public protocol SectorDevice: AnyObject {
    var label: String { get }
    var sectorSize: Int { get }
    /// Number of readable sectors.
    var sectorCount: UInt32 { get }
    /// nil when writable; otherwise a user-facing reason.
    var readOnlyReason: String? { get }
    /// Writes must cover whole packets of this many sectors (1 = any sector).
    var packetSectors: Int { get }
    /// Physical address where packet numbering starts (the track start on CD-RW).
    var packetBase: UInt32 { get }
    /// Write-once media (CD-R, DVD±R): data can only be appended at `nextWritableAddress()`.
    var isSequential: Bool { get }
    /// Where the next sequential write must start. Can jump between writes (CD-R link blocks).
    func nextWritableAddress() throws -> UInt32
    /// Last sector that holds data; the VAT of a write-once disc is at or just before it.
    var lastRecordedSector: UInt32 { get }
    /// Sectors still available for appending on write-once media.
    var appendableSectors: UInt32 { get }
    /// Recording unit of write-once media (16 sectors = one ECC block on DVD±R). After a
    /// flush the drive pads the unit, so the VAT must end exactly on its last sector for
    /// Windows to find it.
    var appendAlignment: Int { get }
    func readSectors(_ lba: UInt32, count: Int) throws -> [UInt8]
    /// `data.count` must be a multiple of the sector size. With `packetSectors > 1`
    /// callers must pass whole, aligned packets; `PacketCache` takes care of that.
    func writeSectors(_ lba: UInt32, _ data: [UInt8]) throws
    /// Flushes the drive's own write cache.
    func synchronize() throws
    func close()
}

public extension SectorDevice {
    var isSequential: Bool { false }
    func nextWritableAddress() throws -> UInt32 { throw UDFError(L("这不是一次性写入盘", "This is not a write-once disc")) }
    var lastRecordedSector: UInt32 { sectorCount &- 1 }
    var appendableSectors: UInt32 { 0 }
    var appendAlignment: Int { 1 }
}

// MARK: - Disc image file

/// A raw sector image (.iso/.img/.udf). Can pretend to be packet-written media so the
/// packet logic gets exercised without a drive: with `strictPackets` any write that is not
/// a whole aligned packet throws. With `sequential` it behaves like a CD-R/DVD-R: the file
/// is the recorded area, writes may only append, and `linkBlocks` unreadable-in-practice
/// sectors are skipped after every write the way a CD-R drive does between packets.
public final class ImageDevice: SectorDevice {
    public let label: String
    public let sectorSize: Int
    public private(set) var sectorCount: UInt32
    public let readOnlyReason: String?
    public let packetSectors: Int
    public let packetBase: UInt32 = 0
    public let isSequential: Bool
    public let capacitySectors: UInt32
    public let appendAlignment: Int
    let linkBlocks: Int
    let strictPackets: Bool
    private let handle: FileHandle

    public init(url: URL, writable: Bool, sectorSize: Int = 2048, simulatePacket: Int = 1, strictPackets: Bool = false,
                sequential: Bool = false, linkBlocks: Int = 0, appendAlignment: Int = 1, capacityMB: Int = 700) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= Int64(sectorSize) * 257 else { throw UDFError(L("镜像文件太小，不是有效的 UDF 光盘镜像", "The image file is too small to be a UDF disc image")) }
        if writable {
            guard let h = FileHandle(forUpdatingAtPath: url.path) else { throw UDFError(L("无法以读写方式打开 \(url.lastPathComponent)", "Can't open \(url.lastPathComponent) for writing")) }
            handle = h
        } else {
            guard let h = FileHandle(forReadingAtPath: url.path) else { throw UDFError(L("无法打开 \(url.lastPathComponent)", "Can't open \(url.lastPathComponent)")) }
            handle = h
        }
        label = url.lastPathComponent
        self.sectorSize = sectorSize
        sectorCount = UInt32(size / Int64(sectorSize))
        readOnlyReason = writable ? nil : L("以只读方式打开", "Opened read-only")
        packetSectors = sequential ? 1 : max(1, simulatePacket)
        self.strictPackets = strictPackets
        isSequential = sequential
        self.linkBlocks = linkBlocks
        self.appendAlignment = max(1, appendAlignment)
        capacitySectors = UInt32(capacityMB * 1024 * 1024 / sectorSize)
    }

    public func nextWritableAddress() throws -> UInt32 {
        guard isSequential else { throw UDFError(L("这不是一次性写入盘", "This is not a write-once disc")) }
        return sectorCount
    }

    public var appendableSectors: UInt32 { isSequential ? capacitySectors &- min(capacitySectors, sectorCount) : 0 }

    public func readSectors(_ lba: UInt32, count: Int) throws -> [UInt8] {
        guard lba < sectorCount, count > 0 else { throw UDFError(L("读取越界：扇区 \(lba)", "Read past the end: sector \(lba)")) }
        let n = min(count, Int(sectorCount - lba))
        try handle.seek(toOffset: UInt64(lba) * UInt64(sectorSize))
        var data = [UInt8](try handle.read(upToCount: n * sectorSize) ?? Data())
        if data.count < count * sectorSize { data += [UInt8](repeating: 0, count: count * sectorSize - data.count) }
        return data
    }

    public func writeSectors(_ lba: UInt32, _ data: [UInt8]) throws {
        if let r = readOnlyReason { throw UDFError(r) }
        precondition(data.count % sectorSize == 0)
        let n = data.count / sectorSize
        if isSequential {
            guard lba == sectorCount else { throw UDFError(L("模拟一次性写入：只能在末尾追加（扇区 \(lba)，末尾 \(sectorCount)）", "Simulated write-once disc: can only append at the end (sector \(lba), end \(sectorCount))")) }
            // CD-R style: link blocks after every write. DVD-R style (alignment > 1): they come
            // after the padding at a flush instead, see synchronize().
            let link = appendAlignment > 1 ? 0 : linkBlocks
            guard UInt64(lba) + UInt64(n + link) <= UInt64(capacitySectors) else { throw UDFError(L("光盘空间不足", "Not enough space on the disc")) }
            try handle.seek(toOffset: UInt64(lba) * UInt64(sectorSize))
            try handle.write(contentsOf: Data(data + [UInt8](repeating: 0, count: link * sectorSize)))
            sectorCount += UInt32(n + link)
            return
        }
        if strictPackets {
            guard (Int(lba - packetBase) % packetSectors) == 0, n % packetSectors == 0 else {
                throw UDFError(L("模拟包写入：写入未按包对齐（扇区 \(lba)，\(n) 个）", "Simulated packet writing: write not aligned to a packet (sector \(lba), \(n) sectors)"))
            }
        }
        guard UInt64(lba) + UInt64(n) <= UInt64(sectorCount) else { throw UDFError(L("写入越界：扇区 \(lba)", "Write past the end: sector \(lba)")) }
        try handle.seek(toOffset: UInt64(lba) * UInt64(sectorSize))
        try handle.write(contentsOf: Data(data))
    }

    /// Like a DVD-R drive: a flush pads the current recording unit with empty sectors.
    public func synchronize() throws {
        if isSequential && readOnlyReason == nil && appendAlignment > 1 {
            let pad = (appendAlignment - Int(sectorCount) % appendAlignment) % appendAlignment + linkBlocks
            if pad > 0 {
                try handle.seek(toOffset: UInt64(sectorCount) * UInt64(sectorSize))
                try handle.write(contentsOf: Data(count: pad * sectorSize))
                sectorCount += UInt32(pad)
            }
        }
        try handle.synchronize()
    }
    public func close() { try? handle.close() }
}

// MARK: - Packet cache

/// Sits between the file system and the device. Partial-packet writes are merged into
/// cached packets (read-modify-write) and written out as whole packets on `flush()`.
/// Whole aligned packets go straight to the device, so big file copies don't pile up in memory.
public final class PacketCache {
    public let device: SectorDevice
    let ss: Int
    let packet: Int
    let readUnit: Int
    private var dirty: [UInt32: [UInt8]] = [:]        // packet index -> packet bytes
    private var clean: [UInt32: [UInt8]] = [:]        // read cache, keyed by read-unit index
    private var cleanOrder: [UInt32] = []
    private var badUnits = Set<UInt32>()
    private let cleanLimit = 256

    public init(_ device: SectorDevice) {
        self.device = device
        ss = device.sectorSize
        packet = device.packetSectors
        readUnit = max(device.packetSectors, 16)
    }

    private func packetIndex(_ lba: UInt32) -> UInt32 { (lba - device.packetBase) / UInt32(packet) }
    private func packetStart(_ idx: UInt32) -> UInt32 { device.packetBase + idx * UInt32(packet) }

    public func read(_ lba: UInt32, count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count * ss)
        var cur = lba
        var remaining = count
        while remaining > 0 {
            if cur >= device.packetBase, let p = dirty[packetIndex(cur)] {
                let off = Int(cur - packetStart(packetIndex(cur)))
                let n = min(remaining, packet - off)
                out += p[(off * ss) ..< ((off + n) * ss)]
                cur += UInt32(n); remaining -= n
                continue
            }
            let unit = cur / UInt32(readUnit)
            let unitStart = unit * UInt32(readUnit)
            let chunk: [UInt8]
            if let c = clean[unit] {
                chunk = c
            } else {
                let avail = Int(min(UInt32(readUnit), device.sectorCount - min(unitStart, device.sectorCount)))
                guard avail > 0 else { throw UDFError(L("读取越界：扇区 \(cur)", "Read past the end: sector \(cur)")) }
                do {
                    guard !badUnits.contains(unit) else { throw UDFError("") }
                    chunk = try device.readSectors(unitStart, count: avail)
                    remember(unit, chunk)
                } catch {
                    // Part of this unit may be unrecorded (the gaps between appends on write-once
                    // discs): fall back to reading just the sector asked for.
                    badUnits.insert(unit)
                    out += try device.readSectors(cur, count: 1)
                    cur += 1; remaining -= 1
                    continue
                }
            }
            let off = Int(cur - unitStart)
            let unitLen = chunk.count / ss
            if off >= unitLen {   // cached before the (write-once) disc grew
                clean[unit] = nil
                cleanOrder.removeAll { $0 == unit }
                guard cur < device.sectorCount else { throw UDFError(L("读取越界：扇区 \(cur)", "Read past the end: sector \(cur)")) }
                continue
            }
            // Stop at the next dirty packet so its newer contents win.
            var n = min(remaining, unitLen - off)
            if packet > 1 || !dirty.isEmpty {
                for i in 0 ..< n where cur + UInt32(i) >= device.packetBase && dirty[packetIndex(cur + UInt32(i))] != nil {
                    n = i; break
                }
            }
            if n == 0 { continue }
            out += chunk[(off * ss) ..< ((off + n) * ss)]
            cur += UInt32(n); remaining -= n
        }
        return out
    }

    private func remember(_ unit: UInt32, _ data: [UInt8]) {
        if clean[unit] == nil { cleanOrder.append(unit) }
        clean[unit] = data
        if cleanOrder.count > cleanLimit {
            let drop = cleanOrder.removeFirst()
            clean[drop] = nil
        }
    }

    private func invalidateClean(_ lba: UInt32, count: Int) {
        let first = lba / UInt32(readUnit)
        let last = (lba + UInt32(count) - 1) / UInt32(readUnit)
        for u in first ... last where clean[u] != nil {
            clean[u] = nil
            cleanOrder.removeAll { $0 == u }
        }
    }

    public func write(_ lba: UInt32, _ data: [UInt8], allowDirect: Bool = true) throws {
        if let r = device.readOnlyReason { throw UDFError(r) }
        precondition(data.count % ss == 0 && !data.isEmpty)
        let count = data.count / ss
        guard lba >= device.packetBase else { throw UDFError(L("写入位置在轨道起点之前：扇区 \(lba)", "Write position is before the start of the track: sector \(lba)")) }
        invalidateClean(lba, count: count)
        var cur = lba
        var src = 0
        var remaining = count
        while remaining > 0 {
            let idx = packetIndex(cur)
            let start = packetStart(idx)
            let off = Int(cur - start)
            let n = min(remaining, packet - off)
            if allowDirect && off == 0 && n == packet && dirty[idx] == nil {
                // Gather as many whole packets as possible into one device write.
                var whole = 1
                while (whole + 1) * packet <= remaining && dirty[idx + UInt32(whole)] == nil && (whole + 1) * packet <= 512 { whole += 1 }
                let len = whole * packet * ss
                try device.writeSectors(cur, Array(data[(src * ss) ..< (src * ss + len)]))
                cur += UInt32(whole * packet); src += whole * packet; remaining -= whole * packet
                continue
            }
            var p: [UInt8]
            if let d = dirty[idx] {
                p = d
            } else {
                let avail = Int(min(UInt32(packet), device.sectorCount - min(start, device.sectorCount)))
                p = avail > 0 ? try device.readSectors(start, count: avail) : []
                if p.count < packet * ss { p += [UInt8](repeating: 0, count: packet * ss - p.count) }
            }
            p.replaceSubrange((off * ss) ..< ((off + n) * ss), with: data[(src * ss) ..< ((src + n) * ss)])
            dirty[idx] = p
            cur += UInt32(n); src += n; remaining -= n
        }
    }

    /// Appends sectors on write-once media and returns the runs where they landed. Writes go
    /// out in small pieces and the drive is asked for the next writable address before each one,
    /// because a CD-R drive may leave link blocks between packets.
    public func append(_ data: [UInt8]) throws -> [(start: UInt32, count: Int)] {
        if let r = device.readOnlyReason { throw UDFError(r) }
        var runs: [(start: UInt32, count: Int)] = []
        let total = data.count / ss
        var done = 0
        while done < total {
            let n = min(32, total - done)
            let at = try device.nextWritableAddress()
            try device.writeSectors(at, Array(data[(done * ss) ..< ((done + n) * ss)]))
            invalidateClean(at, count: n + 16)
            badUnits.removeAll()
            if let last = runs.last, last.start + UInt32(last.count) == at {
                runs[runs.count - 1].count += n
            } else {
                runs.append((at, n))
            }
            done += n
        }
        return runs
    }

    /// Writes all merged packets in address order, then flushes the drive cache.
    public func flush() throws {
        for idx in dirty.keys.sorted() {
            try device.writeSectors(packetStart(idx), dirty[idx]!)
        }
        dirty.removeAll()
        try device.synchronize()
    }

    /// Drops unwritten changes (used after a failed transaction) and the read cache.
    public func discard() {
        dirty.removeAll()
        badUnits.removeAll()
        clean.removeAll()
        cleanOrder.removeAll()
    }
}
