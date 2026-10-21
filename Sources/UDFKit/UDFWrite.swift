import Foundation

/// Write support: add files, create folders, delete. Every public mutation runs as one
/// transaction: the integrity descriptor is marked "open" on the disc first, all metadata is
/// staged in the packet cache, flushed, and only then the integrity descriptor is closed again.
extension UDFVolume {

    // MARK: Transactions

    func transaction(_ body: () throws -> Void) throws {
        if let r = readOnlyReason { throw UDFError(L("无法写入：\(r)", "Can't write: \(r)")) }
        if vatRef != nil { try vatTransaction(body); return }
        guard let bm = bitmap else { throw UDFError(L("无法写入：没有空间位图", "Can't write: there is no space bitmap")) }
        let savedBitmap = bm.raw
        let savedLVID = lvid
        // 1. Mark the volume open so an interrupted write is detectable.
        setLVID(open: true)
        try writeLVID()
        try cache.flush()
        do {
            try body()
            try writeBitmap()
            try cache.flush()
            // 2. Close it only once everything else is on the disc.
            setLVID(open: false)
            try writeLVID()
            try cache.flush()
        } catch {
            cache.discard()
            bm.raw = savedBitmap
            bm.dirtyBlocks.removeAll()
            lvid = savedLVID
            try? writeLVID()
            try? cache.flush()
            throw error
        }
    }

    private func setLVID(open: Bool) {
        Timestamp.encode(Date(), into: &lvid, 16)
        lvid.put32(28, open ? 0 : 1)
        let n = Int(lvid.u32(72))
        if let bm = bitmap, Int(bm.ref) < n { lvid.put32(80 + 4 * Int(bm.ref), UInt32(bm.freeCount)) }
        let iu = 80 + 8 * n
        if lvid.u32(76) >= 32 { EntityID.implementation.write(&lvid, iu) }
    }

    private func writeLVID() throws {
        let n = Int(lvid.u32(72))
        let length = 80 + 8 * n + Int(lvid.u32(76))
        let t = Tag.parse(lvid, checkCRC: false)!
        Tag.write(into: &lvid, id: .integrity, version: t.version, serial: t.serial, location: lvidSector, length: length)
        // The LVID lives at a physical sector outside the partitions.
        try cache.write(lvidSector, padToBlocks(lvid), allowDirect: false)
    }

    private func writeBitmap() throws {
        guard let bm = bitmap, !bm.dirtyBlocks.isEmpty else { return }
        let t = Tag.parse(bm.raw, checkCRC: false)!
        let crcLen = Int(t.crcLength)
        Tag.write(into: &bm.raw, id: .spaceBitmap, version: t.version, serial: t.serial,
                  location: bm.firstBlock, length: 16 + crcLen)
        var blocks = bm.dirtyBlocks
        blocks.insert(0)
        let padded = padToBlocks(bm.raw)
        for b in blocks.sorted() where (b + 1) * blockSize <= padded.count {
            try writeBlocks(LBAddr(block: bm.firstBlock + UInt32(b), partition: bm.ref),
                            Array(padded[(b * blockSize) ..< ((b + 1) * blockSize)]))
        }
        bm.dirtyBlocks.removeAll()
    }

    private func padToBlocks(_ b: [UInt8]) -> [UInt8] {
        let n = (b.count + blockSize - 1) / blockSize * blockSize
        return n == b.count ? b : b + [UInt8](repeating: 0, count: n - b.count)
    }

    // MARK: Counters

    private func nextUniqueID() -> UInt64 {
        if vatRef != nil {
            if nextUnique & 0xFFFF_FFFF < 16 { nextUnique = (nextUnique & ~0xFFFF_FFFF) | 16 }
            defer { nextUnique += 1 }
            return nextUnique
        }
        var id = lvid.u64(40)
        if id & 0xFFFF_FFFF < 16 { id = (id & ~0xFFFF_FFFF) | 16 }
        lvid.put64(40, id + 1)
        return id
    }

    private func adjustCounts(files: Int = 0, dirs: Int = 0) {
        if vatRef != nil {
            guard vatHeader.count >= 144 else { return }
            vatHeader.put32(136, UInt32(max(0, Int(vatHeader.u32(136)) + files)))
            vatHeader.put32(140, UInt32(max(0, Int(vatHeader.u32(140)) + dirs)))
            return
        }
        let n = Int(lvid.u32(72))
        guard lvid.u32(76) >= 40 else { return }
        let o = 80 + 8 * n + 32
        lvid.put32(o, UInt32(max(0, Int(lvid.u32(o)) + files)))
        lvid.put32(o + 4, UInt32(max(0, Int(lvid.u32(o + 4)) + dirs)))
    }

    private var packetAlign: Int {
        switch maps[Int(rootICB.partition)].kind {
        case .sparable(let pl): return Int(pl)
        default: return max(1, device.packetSectors)
        }
    }

    // MARK: Low-level allocation

    private func allocate(_ count: Int, align: Int = 1, near: UInt32? = nil) throws -> [Extent] {
        if let v = vatRef {
            // Virtual block numbers: reuse a freed one for single blocks, else take fresh ones.
            let ref = UInt16(v)
            if count == 1, let i = vat.firstIndex(of: 0xFFFF_FFFF) {
                vat[i] = 0xFFFF_FFFE
                return [Extent(length: UInt32(blockSize), kind: .recorded, location: LBAddr(block: UInt32(i), partition: ref))]
            }
            let first = vat.count
            vat += [UInt32](repeating: 0xFFFF_FFFE, count: count)
            return [Extent(length: UInt32(count * blockSize), kind: .recorded, location: LBAddr(block: UInt32(first), partition: ref))]
        }
        guard let bm = bitmap else { throw UDFError(L("没有空间位图", "There is no space bitmap")) }
        let maxExtentBlocks = (0x3FFF_FFFF / blockSize)
        var out: [Extent] = []
        for run in try bm.allocate(count, align: align, near: near.map { Int($0) }) {
            var start = run.start, left = run.count
            while left > 0 {
                let n = min(left, maxExtentBlocks)
                out.append(Extent(length: UInt32(n * blockSize), kind: .recorded, location: LBAddr(block: start, partition: bm.ref)))
                start += UInt32(n); left -= n
            }
        }
        return out
    }

    private func free(_ e: Extent) {
        if let v = vatRef {
            // Only virtual blocks can be released; recorded sectors stay used forever.
            guard Int(e.location.partition) == v else { return }
            let n = (Int(e.length) + blockSize - 1) / blockSize
            for i in 0 ..< n {
                let b = Int(e.location.block) + i
                if b < vat.count { vat[b] = 0xFFFF_FFFF; staged[UInt32(b)] = nil }
            }
            return
        }
        guard let bm = bitmap, e.location.partition == bm.ref, e.kind != .notAllocated else { return }
        let n = (Int(e.length) + blockSize - 1) / blockSize
        for i in 0 ..< n {
            let b = Int(e.location.block) + i
            if b < bm.numBits { bm.set(b, free: true) }
        }
    }

    private func freeBlock(_ a: LBAddr) { free(Extent(length: UInt32(blockSize), kind: .recorded, location: a)) }

    // MARK: File entry serialisation

    func newFileEntry(at addr: LBAddr, directory: Bool, now: Date, modified: Date?) -> FileEntry {
        var b = [UInt8](repeating: 0, count: blockSize)
        // ICB tag
        b.put32(16, 0)              // prior recorded number of direct entries
        b.put16(20, 4)              // strategy type 4
        b.put16(24, 1)              // maximum number of entries
        b[27] = directory ? 4 : 5   // file type
        b.put16(34, 0)              // flags (allocation type set later)
        b.put32(36, 0xFFFF_FFFF)    // uid
        b.put32(40, 0xFFFF_FFFF)    // gid
        // Read/write/change-attribute/delete for owner, group and others; directories also searchable.
        let p: UInt32 = directory ? 0x1F : 0x1E
        b.put32(44, p | p << 5 | p << 10)
        b.put16(48, 1)              // link count
        Timestamp.encode(now, into: &b, 72)
        Timestamp.encode(modified ?? now, into: &b, 84)
        Timestamp.encode(now, into: &b, 96)
        b.put32(108, 1)             // checkpoint
        EntityID.implementation.write(&b, 128)
        let fe = FileEntry(addr: addr, raw: b, extended: false)
        fe.uniqueID = nextUniqueID()
        return fe
    }

    func writeFileEntry(_ fe: FileEntry, inline: [UInt8]? = nil) throws {
        var ads: [UInt8] = []
        if let data = inline {
            fe.adType = 3
            ads = data
            fe.blocksRecorded = 0
        } else {
            let long = fe.adType == 1
            if fe.adType != 0 && fe.adType != 1 { fe.adType = 0 }
            var recorded: UInt64 = 0
            for e in fe.extents {
                var d = [UInt8](repeating: 0, count: long ? 16 : 8)
                d.put32(0, e.length | (e.kind.rawValue << 30))
                if long { e.location.write(&d, 4) } else { d.put32(4, e.location.block) }
                ads += d
                if e.kind != .notAllocated { recorded += UInt64((Int(e.length) + blockSize - 1) / blockSize) }
            }
            fe.blocksRecorded = recorded
        }
        let base = fe.adOffset
        // Continuation blocks are rebuilt from scratch every time the entry is written.
        for a in fe.aedBlocks { freeBlock(a) }
        fe.aedBlocks.removeAll()
        if base + ads.count > blockSize {
            ads = try spillToAllocationExtents(fe, ads: ads)
        }
        fe.raw.replaceSubrange(base ..< blockSize, with: [UInt8](repeating: 0, count: blockSize - base))
        fe.raw.putBytes(base, ads)
        fe.adLength = ads.count
        let old = Tag.parse(fe.raw, checkCRC: false).flatMap { $0.identifier == 0 ? nil : $0 }
        Tag.write(into: &fe.raw, id: fe.extended ? .extendedFileEntry : .fileEntry,
                  version: old?.version ?? tagVersion, serial: old?.serial ?? tagSerial,
                  location: fe.addr.block, length: base + ads.count)
        try writeBlocks(fe.addr, fe.raw)
    }

    /// A file with more extents than fit in its entry keeps the rest in a chain of Allocation
    /// Extent Descriptors. Returns the descriptors that stay in the entry itself.
    private func spillToAllocationExtents(_ fe: FileEntry, ads: [UInt8]) throws -> [UInt8] {
        let long = fe.adType == 1
        let adSize = long ? 16 : 8
        var entries = stride(from: 0, to: ads.count, by: adSize).map { Array(ads[$0 ..< $0 + adSize]) }
        let inEntry = (blockSize - fe.adOffset) / adSize - 1
        let perAED = (blockSize - 24) / adSize - 1
        guard inEntry >= 1, perAED >= 1 else { throw UDFError(L("文件条目空间不足，无法记录分配信息", "Not enough room in the file entry to record where the data is")) }
        let head = Array(entries.prefix(inEntry))
        entries.removeFirst(inEntry)
        var chunks: [[[UInt8]]] = []
        while !entries.isEmpty {
            let n = entries.count <= perAED + 1 ? entries.count : perAED
            chunks.append(Array(entries.prefix(n)))
            entries.removeFirst(n)
        }
        let addrs = try chunks.map { _ in try allocate(1, near: fe.addr.block)[0].location }
        func continuation(_ a: LBAddr) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: adSize)
            d.put32(0, UInt32(blockSize) | (ExtentKind.continuation.rawValue << 30))
            if long { a.write(&d, 4) } else { d.put32(4, a.block) }
            return d
        }
        for (i, chunk) in chunks.enumerated() {
            var region = chunk.flatMap { $0 }
            if i + 1 < chunks.count { region += continuation(addrs[i + 1]) }
            var b = [UInt8](repeating: 0, count: blockSize)
            b.put32(16, i == 0 ? 0 : addrs[i - 1].block)    // previous allocation extent
            b.put32(20, UInt32(region.count))
            b.putBytes(24, region)
            Tag.write(into: &b, id: .allocationExtent, version: tagVersion, serial: tagSerial,
                      location: addrs[i].block, length: 24 + region.count)
            try writeBlocks(addrs[i], b)
        }
        fe.aedBlocks = addrs
        fe.blocksRecorded += UInt64(addrs.count)
        return head.flatMap { $0 } + continuation(addrs[0])
    }

    private func touch(_ fe: FileEntry, _ now: Date) {
        Timestamp.encode(now, into: &fe.raw, fe.modTimeOffset)
        Timestamp.encode(now, into: &fe.raw, fe.attrTimeOffset)
    }

    // MARK: Directories

    /// Rewrites a directory's FIDs (compacting away deleted ones) and its file entry.
    private func writeDirectory(_ dir: FileEntry, _ fids: [FID], now: Date) throws {
        let size = fids.reduce(0) { $0 + $1.size }
        let inlineCap = blockSize - dir.adOffset
        func serialize(locationFor: (Int) -> UInt32, total: Int) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: total)
            var o = 0
            for f in fids {
                buf.put16(o + 16, f.version)
                buf[o + 18] = f.characteristics
                buf[o + 19] = UInt8(f.nameRaw.count)
                buf.putBytes(o + 20, f.icb)
                buf.put16(o + 36, UInt16(f.implUse.count))
                buf.putBytes(o + 38, f.implUse)
                buf.putBytes(o + 38 + f.implUse.count, f.nameRaw)
                Tag.write(into: &buf, at: o, id: .fileIdentifier, version: tagVersion, serial: tagSerial,
                          location: locationFor(o), length: f.size)
                o += f.size
            }
            return buf
        }

        dir.infoLength = UInt64(size)
        touch(dir, now)
        if dir.adType == 3 && size <= inlineCap {
            let data = serialize(locationFor: { _ in dir.addr.block }, total: size)
            try writeFileEntry(dir, inline: data)
            return
        }
        // Block-backed directory.
        let need = max(1, (size + blockSize - 1) / blockSize)
        var blocks: [LBAddr] = []
        if vatRef != nil {
            // Recorded blocks can't be rewritten: release the old ones, take fresh virtual blocks.
            if dir.adType != 3 { for e in dir.extents { free(e) } }
            dir.adType = 0
        } else if dir.adType != 3 {
            for e in dir.extents where e.kind != .notAllocated {
                let n = (Int(e.length) + blockSize - 1) / blockSize
                for i in 0 ..< n { blocks.append(LBAddr(block: e.location.block + UInt32(i), partition: e.location.partition)) }
            }
        } else {
            dir.adType = 0
        }
        while blocks.count > need { freeBlock(blocks.removeLast()) }
        if blocks.count < need {
            let near = blocks.last.map { $0.block + 1 } ?? dir.addr.block
            for e in try allocate(need - blocks.count, near: near) {
                for i in 0 ..< Int(e.length) / blockSize { blocks.append(LBAddr(block: e.location.block + UInt32(i), partition: e.location.partition)) }
            }
        }
        var data = serialize(locationFor: { blocks[$0 / blockSize].block }, total: size)
        data += [UInt8](repeating: 0, count: need * blockSize - data.count)
        for (i, b) in blocks.enumerated() {
            try writeBlocks(b, Array(data[(i * blockSize) ..< ((i + 1) * blockSize)]))
        }
        // Coalesce into extents; only the last one may end mid-block.
        var extents: [Extent] = []
        for b in blocks {
            if var last = extents.last, last.location.partition == b.partition,
               last.location.block + last.length / UInt32(blockSize) == b.block, Int(last.length) + blockSize <= 0x3FFF_FFFF {
                last.length += UInt32(blockSize)
                extents[extents.count - 1] = last
            } else {
                extents.append(Extent(length: UInt32(blockSize), kind: .recorded, location: b))
            }
        }
        let slack = need * blockSize - size
        extents[extents.count - 1].length -= UInt32(slack)
        dir.extents = extents
        try writeFileEntry(dir)
    }

    private func childFID(name: String, fe: FileEntry, directory: Bool) throws -> FID {
        let raw = CS0.encode(name)
        guard raw.count <= 255 else { throw UDFError(L("文件名太长：\(name)", "File name is too long: \(name)")) }
        return FID(characteristics: directory ? 0x02 : 0,
                   icb: FID.longAD(block: fe.addr.block, partition: fe.addr.partition, length: UInt32(blockSize),
                                   uniqueID: UInt32(truncatingIfNeeded: fe.uniqueID)),
                   nameRaw: raw)
    }

    private static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw UDFError(L("文件名无效：\(name)", "Invalid file name: \(name)"))
        }
    }

    private func parentAndName(_ path: String) throws -> (FileEntry, String, String) {
        var comps = Self.components(path)
        guard let name = comps.popLast() else { throw UDFError(L("路径无效：\(path)", "Invalid path: \(path)")) }
        try Self.validate(name)
        let parentPath = comps.joined(separator: "/")
        let parent = try resolve(parentPath).fe
        guard parent.isDirectory else { throw UDFError(L("不是文件夹：\(parentPath)", "Not a folder: \(parentPath)")) }
        return (parent, name, parentPath)
    }

    // MARK: Public write API

    /// Creates a folder. Intermediate folders must exist.
    public func makeDirectory(_ path: String) throws {
        try transaction {
            let (parent, name, _) = try parentAndName(path)
            var fids = try readFIDs(parent)
            if fids.contains(where: { !$0.isDeleted && !$0.isParent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw UDFError(L("已经存在：\(name)", "Already exists: \(name)"))
            }
            try addDirectory(name: name, parent: parent, fids: &fids, now: Date())
        }
    }

    @discardableResult
    private func addDirectory(name: String, parent: FileEntry, fids: inout [FID], now: Date) throws -> FileEntry {
        let icb = try allocate(1, near: parent.addr.block)[0].location
        let dir = newFileEntry(at: icb, directory: true, now: now, modified: nil)
        dir.adType = 3
        let parentFID = FID(characteristics: 0x0A,
                            icb: FID.longAD(block: parent.addr.block, partition: parent.addr.partition,
                                            length: UInt32(blockSize), uniqueID: UInt32(truncatingIfNeeded: parent.uniqueID)),
                            nameRaw: [])
        try writeDirectory(dir, [parentFID], now: now)
        fids = fids.filter { !$0.isDeleted }
        fids.append(try childFID(name: name, fe: dir, directory: true))
        parent.linkCount += 1
        try writeDirectory(parent, fids, now: now)
        adjustCounts(dirs: 1)
        return dir
    }

    /// Copies a local file or folder onto the disc as `path`.
    public func add(from source: URL, to path: String, overwrite: Bool = false,
                    progress: ((UInt64) -> Void)? = nil) throws {
        try transaction {
            var done: UInt64 = 0
            try addItem(from: source, to: path, overwrite: overwrite) { n in done += n; progress?(done) }
        }
    }

    private func addItem(from source: URL, to path: String, overwrite: Bool, progress: (UInt64) -> Void) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw UDFError(L("找不到本地文件：\(source.path)", "Local file not found: \(source.path)"))
        }
        let (parent, name, _) = try parentAndName(path)
        var fids = try readFIDs(parent)
        let now = Date()
        if let i = fids.firstIndex(where: { !$0.isDeleted && !$0.isParent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let existing = fids[i]
            if isDir.boolValue && existing.isDirectory {
                // Merge into the existing folder.
                try addContents(of: source, into: path, overwrite: overwrite, progress: progress)
                return
            }
            guard overwrite else { throw UDFError(L("已经存在：\(name)", "Already exists: \(name)")) }
            try removeItem(existing, from: parent, fids: &fids, now: now)
            try writeDirectory(parent, fids, now: now)
        }
        if isDir.boolValue {
            try addDirectory(name: name, parent: parent, fids: &fids, now: now)
            try addContents(of: source, into: path, overwrite: overwrite, progress: progress)
            return
        }
        let fe = try writeNewFile(from: source, near: parent.addr.block, now: now, progress: progress)
        fids = fids.filter { !$0.isDeleted }
        fids.append(try childFID(name: name, fe: fe, directory: false))
        try writeDirectory(parent, fids, now: now)
        adjustCounts(files: 1)
    }

    private func addContents(of folder: URL, into path: String, overwrite: Bool, progress: (UInt64) -> Void) throws {
        let items = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [])
        for item in items where item.lastPathComponent != ".DS_Store" {
            try addItem(from: item, to: path + "/" + item.lastPathComponent, overwrite: overwrite, progress: progress)
        }
    }

    private func writeNewFile(from source: URL, near: UInt32, now: Date, progress: (UInt64) -> Void) throws -> FileEntry {
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs[.modificationDate] as? Date
        guard let h = FileHandle(forReadingAtPath: source.path) else { throw UDFError(L("无法读取：\(source.path)", "Can't read: \(source.path)")) }
        defer { try? h.close() }

        let icb = try allocate(1, near: near)[0].location
        let fe = newFileEntry(at: icb, directory: false, now: now, modified: mtime)
        fe.infoLength = size
        let inlineCap = blockSize - fe.adOffset
        if size <= UInt64(inlineCap) {
            let data = [UInt8](try h.readToEnd() ?? Data())
            guard UInt64(data.count) == size else { throw UDFError(L("读取本地文件时大小变化：\(source.lastPathComponent)", "The local file changed size while being read: \(source.lastPathComponent)")) }
            try writeFileEntry(fe, inline: data)
            progress(size)
            return fe
        }
        let blocks = Int((size + UInt64(blockSize) - 1) / UInt64(blockSize))
        if vatRef != nil { return try appendNewFile(fe, handle: h, size: size, blocks: blocks, name: source.lastPathComponent, progress: progress) }
        guard let bm = bitmap, bm.freeCount >= blocks else {
            throw UDFError(L("光盘空间不足：需要 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))", "Not enough space on the disc: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) needed"))
        }
        var extents = try allocate(blocks, align: packetAlign, near: icb.block + 1)
        // Stream the data extent by extent.
        let chunkBlocks = max(packetAlign, 16) * 16
        var remaining = size
        for e in extents {
            var block = e.location.block
            var left = Int(e.length) / blockSize
            while left > 0 {
                let n = min(left, chunkBlocks)
                var chunk = [UInt8](try h.read(upToCount: n * blockSize) ?? Data())
                let real = chunk.count
                if real < n * blockSize && UInt64(real) < remaining {
                    throw UDFError(L("读取本地文件时大小变化：\(source.lastPathComponent)", "The local file changed size while being read: \(source.lastPathComponent)"))
                }
                if chunk.count < n * blockSize { chunk += [UInt8](repeating: 0, count: n * blockSize - chunk.count) }
                try writeBlocks(LBAddr(block: block, partition: e.location.partition), chunk, metadata: false)
                remaining -= UInt64(min(UInt64(real), remaining))
                progress(UInt64(real))
                block += UInt32(n); left -= n
            }
        }
        // The last extent records exact bytes, not whole blocks.
        let slack = UInt64(blocks * blockSize) - size
        extents[extents.count - 1].length -= UInt32(slack)
        fe.extents = extents
        fe.adType = 0
        try writeFileEntry(fe)
        return fe
    }

    /// Deletes a file, or a folder with everything in it.
    public func remove(_ path: String) throws {
        try transaction {
            let (parent, name, _) = try parentAndName(path)
            var fids = try readFIDs(parent)
            guard let f = fids.first(where: { !$0.isDeleted && !$0.isParent && $0.name == name })
                    ?? fids.first(where: { !$0.isDeleted && !$0.isParent && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw UDFError(L("找不到：\(path)", "Not found: \(path)"))
            }
            let now = Date()
            try removeItem(f, from: parent, fids: &fids, now: now)
            try writeDirectory(parent, fids, now: now)
        }
    }

    /// Removes `fid` from `fids` (caller rewrites the parent) and frees its blocks.
    private func removeItem(_ fid: FID, from parent: FileEntry, fids: inout [FID], now: Date) throws {
        let fe = try loadFileEntry(fid.icbAddr)
        if fe.isDirectory {
            var children = try readFIDs(fe)
            for c in children where !c.isDeleted && !c.isParent {
                try removeItem(c, from: fe, fids: &children, now: now)
            }
            parent.linkCount = parent.linkCount > 1 ? parent.linkCount - 1 : 1
            adjustCounts(dirs: -1)
        } else {
            adjustCounts(files: -1)
        }
        fids.removeAll { $0.icb == fid.icb && $0.nameRaw == fid.nameRaw }
        if !fe.isDirectory && fe.linkCount > 1 {
            fe.linkCount -= 1
            touch(fe, now)
            try writeFileEntry(fe, inline: fe.adType == 3 ? fe.inlineData : nil)
            return
        }
        // Frees data, continuation blocks and any macOS stream/attribute entries too.
        for b in try ownedBlocks(fe) { freeBlock(b) }
    }

    /// Re-reads a file from the disc (bypassing nothing but the drive) and compares it with a local copy.
    public func verify(_ path: String, against source: URL) throws -> Bool {
        cache.discard()
        let fe = try resolve(path).fe
        if fe.isDirectory {
            for e in try list(path) {
                if !(try verify(e.path, against: source.appendingPathComponent(e.name))) { return false }
            }
            return true
        }
        guard let h = FileHandle(forReadingAtPath: source.path) else { return false }
        defer { try? h.close() }
        var same = true
        try readData(fe) { chunk in
            guard same else { return }
            let local = [UInt8](try h.read(upToCount: chunk.count) ?? Data())
            if local != chunk { same = false }
        }
        if same, let extra = try h.read(upToCount: 1), !extra.isEmpty { same = false }
        return same
    }
}
