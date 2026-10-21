import Foundation

/// Reading: file entries, directories, paths and the public read API.
extension UDFVolume {

    // MARK: File entries and directories

    func loadFileEntry(_ addr: LBAddr) throws -> FileEntry {
        let b = try readBlocks(addr, 1)
        guard let t = Tag.parse(b) else { throw UDFError(L("文件条目损坏：\(addr)", "File entry is damaged: \(addr)")) }
        let fe: FileEntry
        switch TagID(rawValue: t.identifier) {
        case .fileEntry: fe = FileEntry(addr: addr, raw: b, extended: false)
        case .extendedFileEntry: fe = FileEntry(addr: addr, raw: b, extended: true)
        default: throw UDFError(L("不支持的文件条目类型 \(t.identifier)：\(addr)", "Unsupported file entry type \(t.identifier): \(addr)"))
        }
        guard fe.adOffset + fe.adLength <= blockSize else { throw UDFError(L("文件条目长度异常：\(addr)", "File entry has an unexpected length: \(addr)")) }
        if fe.raw.u16(16 + 4) != 4 { throw UDFError(L("不支持的 ICB 策略 \(fe.raw.u16(16 + 4))", "Unsupported ICB strategy \(fe.raw.u16(16 + 4))")) }
        switch fe.adType {
        case 0, 1:
            try parseADs(fe, region: Array(fe.raw[fe.adOffset ..< fe.adOffset + fe.adLength]), long: fe.adType == 1)
        case 3: break
        default: throw UDFError(L("不支持的分配描述符类型 \(fe.adType)", "Unsupported allocation descriptor type \(fe.adType)"))
        }
        return fe
    }

    private func parseADs(_ fe: FileEntry, region: [UInt8], long: Bool) throws {
        let size = long ? 16 : 8
        var o = 0
        var guardHops = 0
        var region = region
        while o + size <= region.count {
            let lenField = region.u32(o)
            let len = lenField & 0x3FFF_FFFF
            let kind = ExtentKind(rawValue: lenField >> 30)!
            if len == 0 { break }
            let loc = long ? LBAddr.parse(region, o + 4) : LBAddr(block: region.u32(o + 4), partition: fe.addr.partition)
            if kind == .continuation {
                guardHops += 1
                guard guardHops < 10000 else { throw UDFError(L("分配描述符链过长", "The allocation descriptor chain is too long")) }
                let aed = try readBlocks(loc, 1)
                guard let t = Tag.parse(aed), t.identifier == TagID.allocationExtent.rawValue else { throw UDFError(L("分配扩展描述符损坏", "An allocation extent descriptor is damaged")) }
                fe.aedBlocks.append(loc)
                let l = Int(aed.u32(20))
                region = Array(aed[24 ..< min(aed.count, 24 + l)])
                o = 0
                continue
            }
            fe.extents.append(Extent(length: len, kind: kind, location: loc))
            o += size
        }
    }

    /// Streams a file's bytes in chunks.
    func readData(_ fe: FileEntry, _ sink: ([UInt8]) throws -> Void) throws {
        var remaining = fe.infoLength
        if fe.adType == 3 { try sink(Array(fe.inlineData.prefix(Int(remaining)))); return }
        for e in fe.extents where remaining > 0 {
            var left = min(UInt64(e.length), remaining)
            var block = e.location.block
            while left > 0 {
                let n = Int(min(UInt64(256 * blockSize), left))
                let blocks = (n + blockSize - 1) / blockSize
                if e.kind == .recorded {
                    let d = try readBlocks(LBAddr(block: block, partition: e.location.partition), blocks)
                    try sink(Array(d.prefix(n)))
                } else {
                    try sink([UInt8](repeating: 0, count: n))
                }
                block += UInt32(blocks); left -= UInt64(n); remaining -= UInt64(n)
            }
        }
        if remaining > 0 { throw UDFError(L("文件数据不完整（缺少 \(remaining) 字节）", "File data is incomplete (\(remaining) bytes missing)")) }
    }

    func readAll(_ fe: FileEntry) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(Int(fe.infoLength))
        try readData(fe) { out += $0 }
        return out
    }

    func readFIDs(_ dir: FileEntry) throws -> [FID] {
        guard dir.isDirectory else { throw UDFError(L("不是文件夹", "Not a folder")) }
        let d = try readAll(dir)
        var fids: [FID] = []
        var o = 0
        while o + 38 <= d.count {
            guard let t = Tag.parse(d, at: o), t.identifier == TagID.fileIdentifier.rawValue else {
                throw UDFError(L("目录内容损坏（偏移 \(o)）", "Folder contents are damaged (offset \(o))"))
            }
            let lfi = Int(d[o + 19]), liu = Int(d.u16(o + 36))
            guard o + 38 + liu + lfi <= d.count else { throw UDFError(L("目录条目越界", "A folder entry runs past the end")) }
            let f = FID(version: d.u16(o + 16), characteristics: d[o + 18], icb: d.bytes(o + 20, 16),
                        implUse: d.bytes(o + 38, liu), nameRaw: d.bytes(o + 38 + liu, lfi))
            fids.append(f)
            o += f.size
        }
        return fids
    }

    // MARK: Paths

    static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." }
    }

    func resolve(_ path: String) throws -> (fe: FileEntry, fid: FID?) {
        var cur = try loadFileEntry(rootICB)
        var curFID: FID?
        for name in Self.components(path) {
            let fids = try readFIDs(cur).filter { !$0.isDeleted && !$0.isParent }
            guard let f = fids.first(where: { $0.name == name }) ?? fids.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw UDFError(L("找不到：\(path)", "Not found: \(path)"))
            }
            cur = try loadFileEntry(f.icbAddr)
            curFID = f
        }
        return (cur, curFID)
    }

    // MARK: Public read API

    public func list(_ path: String) throws -> [UDFEntry] {
        let dir = try resolve(path).fe
        guard dir.isDirectory else { throw UDFError(L("不是文件夹：\(path)", "Not a folder: \(path)")) }
        let base = Self.components(path).joined(separator: "/")
        return try readFIDs(dir).filter { !$0.isDeleted && !$0.isParent }.map { f in
            let fe = try? loadFileEntry(f.icbAddr)
            let name = f.name
            return UDFEntry(name: name, path: base.isEmpty ? name : base + "/" + name,
                            isDirectory: f.isDirectory, size: fe?.infoLength ?? 0,
                            modified: fe?.modified, isHidden: f.isHidden, icb: f.icbAddr)
        }.sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }

    public func exists(_ path: String) -> Bool { (try? resolve(path)) != nil }

    public func readFile(_ path: String) throws -> [UInt8] {
        let fe = try resolve(path).fe
        guard !fe.isDirectory else { throw UDFError(L("这是文件夹：\(path)", "This is a folder: \(path)")) }
        return try readAll(fe)
    }

    /// Copies a file (or a whole folder) from the disc to `destination`.
    public func export(_ path: String, to destination: URL, progress: ((UInt64) -> Void)? = nil) throws {
        let fe = try resolve(path).fe
        if fe.isDirectory {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for e in try list(path) {
                try export(e.path, to: destination.appendingPathComponent(e.name), progress: progress)
            }
            return
        }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: destination.path) else { throw UDFError(L("无法写入 \(destination.path)", "Can't write \(destination.path)")) }
        defer { try? h.close() }
        var done: UInt64 = 0
        try readData(fe) { chunk in
            try h.write(contentsOf: Data(chunk))
            done += UInt64(chunk.count)
            progress?(done)
        }
        if let m = fe.modified { try? FileManager.default.setAttributes([.modificationDate: m], ofItemAtPath: destination.path) }
    }

    public var totalBytes: UInt64 {
        if vatRef != nil { return UInt64(maps[Int(physRef)].partition.length) * UInt64(blockSize) }
        return UInt64(maps[Int(rootICB.partition)].partition.length) * UInt64(blockSize)
    }

    public var freeBytes: UInt64 {
        if vatRef != nil { return UInt64(appendableSectors) * UInt64(blockSize) }
        if let bm = bitmap { return UInt64(bm.freeCount) * UInt64(blockSize) }
        guard !lvid.isEmpty, lvid.u32(72) > rootICB.partition else { return 0 }
        let v = lvid.u32(80 + 4 * Int(rootICB.partition))
        return v == 0xFFFF_FFFF ? 0 : UInt64(v) * UInt64(blockSize)
    }

    public var fileCount: Int? {
        if vatRef != nil { return vatHeader.count >= 152 ? Int(vatHeader.u32(136)) : nil }
        guard !lvid.isEmpty else { return nil }
        let n = Int(lvid.u32(72))
        return Int(lvid.u32(80 + 8 * n + 32))
    }
}
