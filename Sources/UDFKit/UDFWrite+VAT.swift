import Foundation

/// Writing to write-once discs (CD-R, DVD±R) recorded the way Windows' Live File System does:
/// a virtual partition whose blocks are mapped through a Virtual Allocation Table (VAT).
extension UDFVolume {

    /// On CD-R/DVD-R nothing can be overwritten. File data is appended straight away, changed
    /// metadata blocks are staged under their virtual block numbers, and at commit they are
    /// appended followed by a new VAT, which becomes the disc's current state.
    func vatTransaction(_ body: () throws -> Void) throws {
        let savedVAT = vat, savedHeader = vatHeader, savedUnique = nextUnique
        let startNWA = try device.nextWritableAddress()
        staged.removeAll()
        do {
            try body()
            try commitVAT()
        } catch {
            staged.removeAll()
            vat = savedVAT; vatHeader = savedHeader; nextUnique = savedUnique
            cache.discard()
            // Anything appended so far would hide the VAT; record the old one again after it.
            if (try? device.nextWritableAddress()) != startNWA { try? writeVATFile() }
            throw error
        }
    }

    private func commitVAT() throws {
        let start = maps[Int(physRef)].partition.start
        let blocks = staged.keys.sorted()
        if !blocks.isEmpty {
            var data = [UInt8]()
            data.reserveCapacity(blocks.count * blockSize)
            for b in blocks { data += staged[b]! }
            var i = 0
            for run in try cache.append(data) {
                for k in 0 ..< run.count { vat[Int(blocks[i])] = run.start + UInt32(k) - start; i += 1 }
            }
        }
        staged.removeAll()
        guard !vat.contains(0xFFFF_FFFE) else { throw UDFError(L("内部错误：有虚拟块分配了但没有写入", "Internal error: a virtual block was allocated but never written")) }
        try writeVATFile()
    }

    /// Appends the VAT (header + table) and its file entry, which must be the last sector.
    private func writeVATFile() throws {
        let start = maps[Int(physRef)].partition.start
        var header = vatHeader
        header.put32(132, vatICBSector >= start ? vatICBSector - start : 0xFFFF_FFFF)   // previous VAT ICB
        header.put16(146, max(header.u16(146), 0x0150))
        var data = header
        for e in vat { var b = [UInt8](repeating: 0, count: 4); b.put32(0, e); data += b }

        let fe = newFileEntry(at: LBAddr(block: 0, partition: physRef), directory: false, now: Date(), modified: nil)
        fe.raw[27] = 248          // file type: VAT
        fe.uniqueID = 0
        fe.linkCount = 0          // no directory refers to it (Windows writes 0 as well)
        fe.infoLength = UInt64(data.count)
        let inlineCap = blockSize - fe.adOffset
        var ads: [UInt8] = []
        var recorded: UInt64 = 0
        if data.count <= inlineCap {
            fe.adType = 3
            ads = data
        } else {
            fe.adType = 0
            let padded = data + [UInt8](repeating: 0, count: (blockSize - data.count % blockSize) % blockSize)
            var left = data.count
            for run in try cache.append(padded) {
                let len = min(left, run.count * blockSize)
                var d = [UInt8](repeating: 0, count: 8)
                d.put32(0, UInt32(len)); d.put32(4, run.start - start)
                ads += d
                left -= len
                recorded += UInt64(run.count)
            }
            guard fe.adOffset + ads.count <= blockSize else { throw UDFError(L("VAT 太分散，无法写入", "The VAT is too fragmented to write")) }
        }
        fe.blocksRecorded = recorded
        // Pad so the VAT's entry is the last sector of the drive's recording unit (an ECC block
        // on DVD±R). The drive fills the rest of the unit with empty sectors when it flushes, and
        // Windows looks for the VAT at the end of the unit, as it writes it there itself.
        let nwa = try device.nextWritableAddress()
        let align = UInt32(device.appendAlignment)
        let padding = Int((align - 1 - nwa % align) % align)
        let at = nwa + UInt32(padding)
        fe.raw.putBytes(fe.adOffset, ads)
        fe.adLength = ads.count
        Tag.write(into: &fe.raw, id: .fileEntry, version: tagVersion, serial: tagSerial,
                  location: at - start, length: fe.adOffset + ads.count)
        let runs = try cache.append([UInt8](repeating: 0, count: padding * blockSize) + fe.raw)
        guard runs.count == 1, runs[0].start == nwa else { throw UDFError(L("VAT 没有写在预期位置（光驱报告的地址变了）", "The VAT didn't land where expected (the drive reported a different address)")) }
        try device.synchronize()
        vatICBSector = at
    }

    /// Records the current VAT again at the end of the disc (aligned as above), without
    /// changing any files. Repairs discs whose newest VAT another program can't find.
    public func rewriteVAT() throws {
        guard vatRef != nil else { throw UDFError(L("这不是一次性写入盘", "This is not a write-once disc")) }
        try transaction {}
    }

    /// Physical sector holding the current VAT's file entry.
    public var vatLocation: UInt32? { vatRef == nil ? nil : vatICBSector }

    /// Write-once data path: stream the file to the end of the disc, recording where each
    /// piece actually landed as long_ad extents in the physical partition.
    func appendNewFile(_ fe: FileEntry, handle h: FileHandle, size: UInt64, blocks: Int, name: String,
                               progress: (UInt64) -> Void) throws -> FileEntry {
        let needed = UInt64(blocks) + UInt64(blocks / 32 + 64) * 8   // room for link blocks and the VAT
        guard UInt64(appendableSectors) >= needed else {
            throw UDFError(L("光盘空间不足：需要 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))", "Not enough space on the disc: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) needed"))
        }
        let start = maps[Int(physRef)].partition.start
        var extents: [Extent] = []
        var remaining = size
        let maxLen = UInt32(0x3FFF_FFFF / blockSize * blockSize)
        while remaining > 0 {
            var chunk = [UInt8](try h.read(upToCount: 256 * blockSize) ?? Data())
            guard !chunk.isEmpty else { throw UDFError(L("读取本地文件时大小变化：\(name)", "The local file changed size while being read: \(name)")) }
            let real = UInt64(min(UInt64(chunk.count), remaining))
            chunk = Array(chunk.prefix(Int(real)))
            if chunk.count % blockSize != 0 { chunk += [UInt8](repeating: 0, count: blockSize - chunk.count % blockSize) }
            var left = real
            for run in try cache.append(chunk) {
                let bytes = UInt32(min(UInt64(run.count * blockSize), left))
                let loc = LBAddr(block: run.start - start, partition: physRef)
                if var last = extents.last, last.length % UInt32(blockSize) == 0,
                   last.location.block + last.length / UInt32(blockSize) == loc.block, last.length + bytes <= maxLen {
                    last.length += bytes
                    extents[extents.count - 1] = last
                } else {
                    extents.append(Extent(length: bytes, kind: .recorded, location: loc))
                }
                left -= UInt64(bytes)
            }
            remaining -= real
            progress(real)
        }
        fe.extents = extents
        fe.adType = 1
        try writeFileEntry(fe)
        return fe
    }
}
