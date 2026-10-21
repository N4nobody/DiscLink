import Foundation

/// Result of a consistency check.
public struct CheckReport {
    public var problems: [String] = []
    public var notes: [String] = []
    public var files = 0
    public var directories = 0
    public var isClean: Bool { problems.isEmpty }
}

extension UDFVolume {

    /// Every block a file entry owns: the entry itself, its data, continuation blocks,
    /// and (for EFEs written by macOS) extended-attribute and stream-directory entries.
    func ownedBlocks(_ fe: FileEntry, includeData: Bool = true) throws -> [LBAddr] {
        var out = [fe.addr] + fe.aedBlocks
        if includeData && fe.adType != 3 {
            for e in fe.extents where e.kind != .notAllocated {
                let n = (Int(e.length) + blockSize - 1) / blockSize
                for i in 0 ..< n { out.append(LBAddr(block: e.location.block + UInt32(i), partition: e.location.partition)) }
            }
        }
        for a in sideICBs(fe) {
            let side = try loadFileEntry(a)
            out += try ownedBlocks(side)
            if side.isDirectory || side.fileType == 13 {   // stream directory
                for f in try readFIDs(side) where !f.isDeleted && !f.isParent {
                    out += try ownedBlocks(try loadFileEntry(f.icbAddr))
                }
            }
        }
        return out
    }

    /// Extended-attribute ICB and (EFE only) stream directory ICB, when present.
    func sideICBs(_ fe: FileEntry) -> [LBAddr] {
        var r: [LBAddr] = []
        let offsets = fe.extended ? [136, 152] : [112]
        for o in offsets where fe.raw.u32(o) & 0x3FFF_FFFF > 0 {
            r.append(LBAddr.parse(fe.raw, o + 4))
        }
        return r
    }

    /// Walks the whole tree and cross-checks it against the space bitmap.
    public func check() throws -> CheckReport {
        var report = CheckReport()
        var owner: [LBAddr: String] = [:]
        func claim(_ a: LBAddr, _ who: String) {
            if let prev = owner[a] {
                report.problems.append(L("块 \(a) 同时属于「\(prev)」和「\(who)」", "Block \(a) belongs to both “\(prev)” and “\(who)”"))
            } else {
                owner[a] = who
            }
        }
        var visited = Set<LBAddr>()
        func walk(_ dir: FileEntry, _ path: String) throws {
            for f in try readFIDs(dir) where !f.isDeleted && !f.isParent {
                let p = path + "/" + f.name
                guard !visited.contains(f.icbAddr) else { continue }   // hard link
                visited.insert(f.icbAddr)
                let fe: FileEntry
                do { fe = try loadFileEntry(f.icbAddr) } catch {
                    report.problems.append("\(p)：\(error.localizedDescription)"); continue
                }
                if fe.isDirectory != f.isDirectory { report.problems.append(L("\(p)：目录标记和文件类型不一致", "\(p): the folder flag doesn't match the file type")) }
                for b in try ownedBlocks(fe) { claim(b, p) }
                if fe.adType != 3 {
                    let allocated = fe.extents.filter { $0.kind != .notAllocated }.reduce(UInt64(0)) { $0 + UInt64($1.length) }
                    if allocated < fe.infoLength && fe.extents.allSatisfy({ $0.kind != .notAllocated }) {
                        report.problems.append(L("\(p)：数据段比文件长度短", "\(p): its data is shorter than the file length"))
                    }
                }
                if fe.isDirectory { report.directories += 1; try walk(fe, p) } else { report.files += 1 }
            }
        }
        let root = try loadFileEntry(rootICB)
        visited.insert(rootICB)
        claim(fsdAddr, L("文件集描述符", "File set descriptor"))
        for b in try ownedBlocks(root) { claim(b, "/") }
        try walk(root, "")

        if let bm = bitmap {
            for (a, who) in owner where a.partition == bm.ref {
                if Int(a.block) >= bm.numBits { report.problems.append(L("「\(who)」使用了分区外的块 \(a)", "“\(who)” uses block \(a) outside the partition")); continue }
                if bm.isFree(Int(a.block)) { report.problems.append(L("「\(who)」使用的块 \(a) 在位图里标为空闲", "“\(who)” uses block \(a), which the bitmap marks as free")) }
            }
            let used = bm.numBits - bm.freeCount
            let leaked = used - owner.keys.filter { $0.partition == bm.ref }.count
            report.notes.append(L("位图已用 \(used) 块，文件占用 \(owner.count) 块，其余 \(max(0, leaked)) 块为系统结构或未回收空间", "Bitmap: \(used) blocks used, \(owner.count) by files; the other \(max(0, leaked)) are file system structures or unreclaimed space"))
            let n = Int(lvid.u32(72))
            if Int(bm.ref) < n, lvid.u32(80 + 4 * Int(bm.ref)) != UInt32(bm.freeCount) {
                report.problems.append(L("完整性描述符记录的空闲块数（\(lvid.u32(80 + 4 * Int(bm.ref)))）和位图（\(bm.freeCount)）不一致", "Free blocks in the integrity descriptor (\(lvid.u32(80 + 4 * Int(bm.ref)))) don't match the bitmap (\(bm.freeCount))"))
            }
        }
        if let n = fileCount, n != report.files {
            report.notes.append(L("完整性描述符记录 \(n) 个文件，实际 \(report.files) 个", "The integrity descriptor counts \(n) files; there are \(report.files)"))
        }
        if let v = vatRef {
            var phys: [UInt32: Int] = [:]
            for (i, e) in vat.enumerated() where e < 0xFFFF_FFF0 {
                if let other = phys[e] { report.problems.append(L("虚拟块 \(other) 和 \(i) 映射到同一个扇区", "Virtual blocks \(other) and \(i) map to the same sector")) }
                phys[e] = i
            }
            let used = owner.keys.filter { Int($0.partition) == v }.count
            report.notes.append(L("VAT 共 \(vat.count) 项，在用 \(phys.count) 项，文件系统引用 \(used) 项", "VAT: \(vat.count) entries, \(phys.count) in use, \(used) referenced by the file system"))
            for (a, who) in owner where Int(a.partition) == v && (Int(a.block) >= vat.count || vat[Int(a.block)] >= 0xFFFF_FFF0) {
                report.problems.append(L("「\(who)」引用了未映射的虚拟块 \(a.block)", "“\(who)” refers to unmapped virtual block \(a.block)"))
            }
        }
        if vatRef == nil && !lvid.isEmpty && lvid.u32(28) == 0 { report.problems.append(L("完整性标记为“打开”（上次写入未完成）", "Integrity is marked open (the last write didn't finish)")) }
        return report
    }
}

extension UDFVolume {
    /// Human-readable dump of a file's entry, for troubleshooting.
    public func debugDescription(of path: String) throws -> String {
        let fe = try resolve(path).fe
        var s = "ICB \(fe.addr) -> sector \(try sector(fe.addr)), \(fe.extended ? "EFE" : "FE"), file type \(fe.fileType), AD type \(fe.adType)\n"
        s += "length \(fe.infoLength), links \(fe.linkCount), unique ID \(fe.uniqueID)\n"
        for e in fe.extents {
            s += "  extent \(e.location) length \(e.length) kind \(e.kind) -> sector \((try? sector(e.location)).map(String.init) ?? "?")\n"
        }
        if !sparing.isEmpty { s += "sparing table: \(sparing.sorted { $0.key < $1.key }.prefix(10))\n" }
        return s
    }
}

extension UDFVolume {
    /// One-line description of a raw sector: descriptor type and, for file entries, the key fields.
    public func describeSector(_ b: [UInt8], at lba: UInt32) -> String {
        guard let t = Tag.parse(b, checkCRC: false), t.identifier != 0 || b[0 ..< 16].contains(where: { $0 != 0 }) else {
            return b.allSatisfy { $0 == 0 } ? "sector \(lba): all zero" : "sector \(lba): not a UDF descriptor"
        }
        var s = "sector \(lba): tag \(t.identifier) version \(t.version) serial \(t.serial) location \(t.location) CRC length \(t.crcLength)"
        if t.identifier == TagID.fileEntry.rawValue || t.identifier == TagID.extendedFileEntry.rawValue {
            let fe = FileEntry(addr: LBAddr(block: t.location, partition: 0), raw: b, extended: t.identifier == TagID.extendedFileEntry.rawValue)
            s += "\n  \(fe.extended ? "EFE" : "FE") file type \(fe.fileType) AD type \(fe.adType) length \(fe.infoLength) links \(fe.linkCount) unique ID \(fe.uniqueID)"
            s += "\n  ICB flags 0x\(String(fe.icbFlags, radix: 16)) permissions 0x\(String(b.u32(44), radix: 16)) EA length \(fe.eaLength) implementation: \(EntityID.parse(b, fe.implIDOffset).identifier)"
            if fe.fileType == 248 && fe.adType == 3 {
                let d = fe.inlineData
                if d.count >= 152 {
                    s += "\n  VAT header \(d.u16(0)) previous VAT \(d.u32(132)) files \(d.u32(136)) folders \(d.u32(140)) read/write revisions \(String(d.u16(144), radix: 16))/\(String(d.u16(146), radix: 16))-\(String(d.u16(148), radix: 16)) entries \((d.count - Int(d.u16(0))) / 4)"
                }
            }
        }
        return s
    }
}
