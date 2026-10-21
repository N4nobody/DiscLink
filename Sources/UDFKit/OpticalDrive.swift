import CMMC
import Foundation

public struct DriveInfo: Identifiable, Hashable, Sendable {
    public let vendor: String
    public let product: String
    public let bsdName: String
    public let registryID: UInt64
    /// Same drive before and after we take exclusive access (the registry ID changes then).
    public let stableID: UInt64
    public var id: UInt64 { stableID }
    public var displayName: String {
        let n = [vendor, product].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? L("光驱", "Optical drive") : n
    }
}

/// A real optical drive driven through raw MMC commands. Opening it unmounts the disc and
/// takes exclusive access, so macOS's own (read-only) UDF driver gets out of the way.
public final class OpticalDrive: SectorDevice {
    public let info: DriveInfo
    public let label: String
    public let sectorSize = 2048
    public private(set) var sectorCount: UInt32 = 0
    public private(set) var readOnlyReason: String?
    public private(set) var packetSectors = 1
    public private(set) var packetBase: UInt32 = 0
    public private(set) var profileName = ""
    public private(set) var isSequential = false
    public private(set) var appendAlignment = 1
    private var lastTrack: UInt16 = 1
    /// One past the last recorded sector (from READ CAPACITY, moved forward by our own writes).
    /// The next writable address is no substitute: on DVD-R there are unrecorded sectors before
    /// it, and reading those makes the drive retry for a long time.
    private var recordedEnd: UInt32 = 0
    private var discStatus: UInt8 = 0xFF
    /// Track facts for troubleshooting write-once discs.
    public private(set) var trackSummary: String?
    private var handle: OpaquePointer?

    public static func list() -> [DriveInfo] {
        var buf = [cmmc_drive_info](repeating: cmmc_drive_info(), count: 8)
        let n = Int(cmmc_list(&buf, 8))
        return buf.prefix(n).map { d in
            var d = d
            func s<T>(_ t: inout T) -> String {
                withUnsafePointer(to: &t) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
            }
            return DriveInfo(vendor: s(&d.vendor).trimmingCharacters(in: .whitespaces),
                             product: s(&d.product).trimmingCharacters(in: .whitespaces),
                             bsdName: s(&d.bsd_name), registryID: d.registry_id, stableID: d.stable_id)
        }
    }

    public init(_ info: DriveInfo, allowWrite: Bool) throws {
        self.info = info
        label = info.displayName
        // Right after a disc goes in, macOS may mount it again between our unmount and taking
        // exclusive access ("busy"). Unmount again and retry for a few seconds.
        var attempt = 0
        while true {
            if !info.bsdName.isEmpty { try Self.unmount(info.bsdName) }
            do {
                handle = try Self.openHandle(info)
                break
            } catch let e as UDFError where e.message == Self.busyMessage && attempt < 8 {
                attempt += 1
                Thread.sleep(forTimeInterval: 1)
            }
        }
        do { try probe(allowWrite: allowWrite) } catch { close(); throw error }
    }

    deinit { close() }

    public func close() {
        if let h = handle { cmmc_close(h); handle = nil }
    }

    private static let busyMessage = L("光盘仍被系统占用（可能有文件在其他程序里打开着），请关闭后再试", "The disc is still in use by macOS (a file on it may be open in another app). Close it and try again")

    private static func openHandle(_ info: DriveInfo) throws -> OpaquePointer {
        var err: Int32 = 0
        guard let h = cmmc_open(info.registryID, &err) else {
            switch UInt32(bitPattern: err) {
            case 0xE00002D5: throw UDFError(busyMessage)                                        // kIOReturnBusy
            case 0xE00002C5: throw UDFError(L("另一个程序（例如刻录软件）正在使用这台光驱", "Another app (such as burning software) is using this drive"))     // kIOReturnExclusiveAccess
            default: throw UDFError(String(format: L("无法打开光驱（IOReturn 0x%08X）", "Can't open the drive (IOReturn 0x%08X)"), UInt32(bitPattern: err)))
            }
        }
        return h
    }

    // MARK: Eject

    private static let allowRemoval: [UInt8] = [0x1E, 0, 0, 0, 0, 0]       // PREVENT ALLOW MEDIUM REMOVAL: allow
    private static let ejectCommand: [UInt8] = [0x1B, 0, 0, 0, 0x02, 0]    // START STOP UNIT: LoEj, stop

    /// Ejects the disc from a drive this object has open, then lets go of the drive.
    public func eject() throws {
        defer { close() }
        _ = try? exec(Self.allowRemoval)
        _ = try execRetrying(Self.ejectCommand, timeout: 30_000)
    }

    /// Ejects a drive nobody here has open. With a disc, macOS unmounts and ejects it the way
    /// the Finder does; an empty drive just gets its tray opened.
    public static func eject(_ info: DriveInfo) throws {
        if !info.bsdName.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
            p.arguments = ["eject", "/dev/" + info.bsdName]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try p.run(); p.waitUntilExit()
            if p.terminationStatus != 0 { throw UDFError(L("无法推出光盘（可能有文件正在被其他程序使用）", "Can't eject the disc (a file on it may be in use by another app)")) }
            return
        }
        let h = try openHandle(info)
        defer { cmmc_close(h) }
        for cdb in [allowRemoval, ejectCommand] {
            var key: UInt8 = 0, asc: UInt8 = 0, ascq: UInt8 = 0, moved: UInt64 = 0, io: Int32 = 0
            let status = cdb.withUnsafeBufferPointer { c in
                cmmc_execute(h, c.baseAddress, UInt8(cdb.count), nil, 0, Int32(CMMC_DIR_NONE), 30_000, &key, &asc, &ascq, &moved, &io)
            }
            if cdb == ejectCommand && status != 0 {
                throw UDFError(status == 2 ? describe(Sense(key: key, asc: asc, ascq: ascq)) : L("光驱没有响应推出命令", "The drive didn't respond to the eject command"))
            }
        }
    }

    private static func unmount(_ bsd: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["unmountDisk", "/dev/" + bsd]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw UDFError(L("无法卸载光盘（可能有文件在其他程序里打开着）", "Can't unmount the disc (a file on it may be open in another app)")) }
    }

    // MARK: Command plumbing

    struct Sense: Error { let key: UInt8, asc: UInt8, ascq: UInt8 }

    @discardableResult
    private func exec(_ cdb: [UInt8], in length: Int = 0, out data: [UInt8]? = nil, timeout: UInt32 = 30_000) throws -> [UInt8] {
        guard let h = handle else { throw UDFError(L("光驱已关闭", "The drive has been closed")) }
        var buf = data ?? [UInt8](repeating: 0, count: length)
        let dir = data != nil ? Int32(CMMC_DIR_OUT) : (length > 0 ? Int32(CMMC_DIR_IN) : Int32(CMMC_DIR_NONE))
        var key: UInt8 = 0, asc: UInt8 = 0, ascq: UInt8 = 0
        var moved: UInt64 = 0
        var io: Int32 = 0
        let status = cdb.withUnsafeBufferPointer { c in
            buf.withUnsafeMutableBytes { b in
                cmmc_execute(h, c.baseAddress, UInt8(cdb.count), b.baseAddress, UInt64(b.count), dir, timeout,
                             &key, &asc, &ascq, &moved, &io)
            }
        }
        if status < 0 { throw UDFError(String(format: L("光驱通信失败（IOReturn 0x%08X）", "Communication with the drive failed (IOReturn 0x%08X)"), UInt32(bitPattern: io))) }
        if status == 2 { throw Sense(key: key, asc: asc, ascq: ascq) }
        if status != 0 { throw UDFError(L("光驱返回状态 \(status)", "The drive returned status \(status)")) }
        return buf
    }

    /// Retries while the drive says "becoming ready" / "long write in progress".
    private func execRetrying(_ cdb: [UInt8], in length: Int = 0, out data: [UInt8]? = nil, timeout: UInt32 = 30_000) throws -> [UInt8] {
        var attempt = 0
        while true {
            do { return try exec(cdb, in: length, out: data, timeout: timeout) }
            catch let s as Sense where s.key == 2 && s.asc == 0x04 && attempt < 200 {
                attempt += 1
                Thread.sleep(forTimeInterval: 0.1)
            } catch let s as Sense where s.key == 6 && attempt < 3 {   // unit attention after media change
                attempt += 1
            } catch let s as Sense {
                throw UDFError(Self.describe(s))
            }
        }
    }

    static func describe(_ s: Sense) -> String {
        switch (s.key, s.asc) {
        case (2, 0x3A): return L("光驱里没有光盘", "There is no disc in the drive")
        case (2, 0x04): return L("光驱还没准备好", "The drive isn't ready yet")
        case (3, _): return String(format: L("光盘介质错误（%02X/%02X），可能有坏块或划痕", "Disc media error (%02X/%02X); the disc may be damaged or scratched"), s.asc, s.ascq)
        case (5, 0x21): return L("地址超出光盘范围", "Address is beyond the end of the disc")
        case (5, 0x30): return L("光驱不支持这种盘或写入方式", "The drive doesn't support this disc or way of writing")
        case (7, _): return L("光盘写保护", "The disc is write-protected")
        default: return String(format: L("光驱报错：Sense %X/%02X/%02X", "Drive error: sense %X/%02X/%02X"), s.key, s.asc, s.ascq)
        }
    }

    // MARK: Probe

    private func probe(allowWrite: Bool) throws {
        _ = try execRetrying([0x00, 0, 0, 0, 0, 0])                       // TEST UNIT READY
        let conf = try execRetrying([0x46, 0x01, 0, 0, 0, 0, 0, 0, 16, 0], in: 16)   // GET CONFIGURATION
        let profile = conf.be16(6)
        profileName = Self.profileNames[profile] ?? String(format: L("未知盘型 0x%04X", "Unknown disc type 0x%04X"), profile)

        let cap = try execRetrying([0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0], in: 8)  // READ CAPACITY
        sectorCount = cap.be32(0) &+ 1
        recordedEnd = sectorCount
        guard cap.be32(4) == 2048 || cap.be32(4) == 0 else { throw UDFError(L("扇区大小 \(cap.be32(4)) 不是 2048", "Sector size \(cap.be32(4)) is not 2048")) }

        // Track 1 tells us about fixed packets on CD-RW.
        var track: [UInt8]?
        track = try? execRetrying([0x52, 0x01, 0, 0, 0, 1, 0, 0, 36, 0], in: 36)
        if let t = track {
            let size = t.be32(24), start = t.be32(8)
            if start &+ size > sectorCount && size > 0 && size < 0x1000_0000 { sectorCount = start + size }
        }

        if Self.writeOnceProfiles.contains(profile) { locateRecordedEnd() }

        if !allowWrite { readOnlyReason = L("以只读方式打开", "Opened read-only"); return }
        switch profile {
        case 0x0A:  // CD-RW
            guard let t = track, t[6] & 0x10 != 0, t.be32(20) > 0 else {
                readOnlyReason = L("这张 CD-RW 不是固定包格式（需要先在 Windows 上用“类似于 USB 闪存驱动器”格式化）", "This CD-RW isn't formatted for fixed packets (format it in Windows with “Like a USB flash drive” first)")
                return
            }
            packetSectors = Int(t.be32(20))
            packetBase = t.be32(8)
            try setWriteParameters(writeType: 1, fixedPacket: true, trackMode: t[5] & 0x0F, dataMode: t[6] & 0x0F, packet: UInt32(packetSectors))
        case 0x13: packetSectors = 16                                   // DVD-RW restricted overwrite
        case 0x12, 0x1A, 0x2A: packetSectors = 16                       // DVD-RAM, DVD+RW (DL)
        case 0x43: packetSectors = 32                                   // BD-RE
        case 0x09, 0x11, 0x14, 0x15, 0x16, 0x1B, 0x2B:  // CD-R, DVD-R, DVD-RW sequential, DVD±R DL
            try prepareAppend(profile: profile)
        case 0x41, 0x42: readOnlyReason = L("BD-R 暂不支持写入", "Writing BD-R isn't supported yet")
        default: readOnlyReason = L("这种盘（\(profileName)）不支持写入", "This kind of disc (\(profileName)) can't be written")
        }
    }

    /// Write-once media written like Windows' Live File System: an open session with one
    /// incremental track that we keep appending to.
    static let writeOnceProfiles: Set<UInt16> = [0x09, 0x11, 0x14, 0x15, 0x16, 0x1B, 0x2B, 0x41, 0x42]

    /// Where the newest data on a write-once disc ends, so the latest VAT is found.
    /// READ CAPACITY keeps reporting the old end after appending, so prefer the track's
    /// Last Recorded Address and fall back to the next writable address.
    private func locateRecordedEnd() {
        guard let di = try? execRetrying([0x51, 0, 0, 0, 0, 0, 0, 0, 34, 0], in: 34) else { return }   // READ DISC INFORMATION
        discStatus = di[2] & 0x03
        lastTrack = UInt16(di[11]) << 8 | UInt16(di[6])
        guard let t = try? trackInfo() else { return }
        let start = t.be32(8), nwa = t.be32(12), lra = t.be32(28)
        trackSummary = L("轨道 \(lastTrack)：起点 \(start)", "Track \(lastTrack): starts at \(start)")
            + (t[7] & 0x01 != 0 ? L("，下一个可写 \(nwa)", ", next writable \(nwa)") : "")
            + (t[7] & 0x02 != 0 ? L("，最后刻录 \(lra)", ", last recorded \(lra)") : "")
            + L("，剩余 \(t.be32(16)) 扇区", ", \(t.be32(16)) sectors free")
        if t[7] & 0x02 != 0 && lra >= start {
            recordedEnd = max(recordedEnd, lra + 1)
        } else if t[7] & 0x01 != 0 && nwa > start {
            recordedEnd = max(recordedEnd, nwa)
        }
        sectorCount = max(sectorCount, recordedEnd)
    }

    private func prepareAppend(profile: UInt16) throws {
        switch discStatus {
        case 0: readOnlyReason = L("这是空白盘，请先在 Windows 上用“类似于 USB 闪存驱动器”格式化", "This disc is blank. Format it in Windows with “Like a USB flash drive” first"); return
        case 2: readOnlyReason = L("光盘已封盘（完成），不能再追加", "The disc is finalized and can't be added to"); return
        case 1: break
        default: readOnlyReason = L("读不到光盘状态，不能追加", "Can't read the disc status, so nothing can be added"); return
        }
        let t = try trackInfo()
        guard t[7] & 0x01 != 0 else { readOnlyReason = L("光驱没有报告可写入位置，光盘可能已关闭", "The drive reports no writable position; the disc may be closed"); return }
        isSequential = true
        sectorCount = max(sectorCount, t.be32(12))
        appendAlignment = [0x11, 0x14, 0x15, 0x16, 0x1B, 0x2B].contains(profile) ? 16 : 1
        switch profile {
        case 0x09: try setWriteParameters(writeType: 1, fixedPacket: false, trackMode: t[5] & 0x0F, dataMode: t[6] & 0x0F, packet: 0)
        case 0x11, 0x14, 0x15, 0x16: try setWriteParameters(writeType: 0, fixedPacket: false, trackMode: t[5] & 0x0F, dataMode: 1, packet: 0)
        default: break   // DVD+R needs no write parameters
        }
    }

    private func trackInfo() throws -> [UInt8] {
        try execRetrying([0x52, 0x01, 0, 0, UInt8(lastTrack >> 8), UInt8(lastTrack & 0xFF), 0, 0, 36, 0], in: 36)
    }

    public func nextWritableAddress() throws -> UInt32 {
        guard isSequential else { throw UDFError(L("这不是一次性写入盘", "This is not a write-once disc")) }
        let t = try trackInfo()
        guard t[7] & 0x01 != 0 else { throw UDFError(L("光驱没有报告可写入位置", "The drive reports no writable position")) }
        return t.be32(12)
    }

    public var lastRecordedSector: UInt32 {
        if recordedEnd > 0 { return recordedEnd - 1 }
        return sectorCount &- 1
    }

    public var appendableSectors: UInt32 {
        guard isSequential, let t = try? trackInfo() else { return 0 }
        return t.be32(16)
    }

    /// MODE SELECT the write parameters page: fixed packets on CD-RW, variable packets on CD-R,
    /// incremental recording on DVD-R.
    private func setWriteParameters(writeType: UInt8, fixedPacket: Bool, trackMode: UInt8, dataMode: UInt8, packet: UInt32) throws {
        let sense = try execRetrying([0x5A, 0x08, 0x05, 0, 0, 0, 0, 0, 64, 0], in: 64)
        let bdLen = Int(sense.be16(6))
        let p = 8 + bdLen
        guard sense.count >= p + 14, sense[p] & 0x3F == 0x05 else { throw UDFError(L("光驱不支持包写入参数页", "The drive doesn't support the packet writing parameters page")) }
        let pageLen = Int(sense[p + 1]) + 2
        var page = Array(sense[p ..< min(sense.count, p + pageLen)])
        page[0] &= 0x3F
        page[2] = (page[2] & 0xE0) | writeType                          // no test write
        page[3] = (page[3] & 0xC0) | (fixedPacket ? 0x20 : 0) | (trackMode & 0x0F)
        page[4] = dataMode == 2 ? 10 : 8                                // Mode 2 Form 1 or Mode 1, 2048 bytes
        page[8] = dataMode == 2 ? 0x20 : 0x00                           // session format
        page[10] = UInt8(packet >> 24); page[11] = UInt8((packet >> 16) & 0xFF)
        page[12] = UInt8((packet >> 8) & 0xFF); page[13] = UInt8(packet & 0xFF)
        let data = [UInt8](repeating: 0, count: 8) + page
        _ = try execRetrying([0x55, 0x10, 0, 0, 0, 0, 0, UInt8(data.count >> 8), UInt8(data.count & 0xFF), 0], out: data)
    }

    static let profileNames: [UInt16: String] = [
        0x08: "CD-ROM", 0x09: "CD-R", 0x0A: "CD-RW", 0x10: "DVD-ROM", 0x11: "DVD-R", 0x12: "DVD-RAM",
        0x13: L("DVD-RW（限制性覆盖）", "DVD-RW (restricted overwrite)"), 0x14: L("DVD-RW（顺序）", "DVD-RW (sequential)"), 0x15: "DVD-R DL", 0x16: "DVD-R DL", 0x1A: "DVD+RW",
        0x1B: "DVD+R", 0x2A: "DVD+RW DL", 0x2B: "DVD+R DL", 0x40: "BD-ROM", 0x41: "BD-R", 0x42: "BD-R",
        0x43: "BD-RE",
    ]

    // MARK: SectorDevice

    public func readSectors(_ lba: UInt32, count: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(count * 2048)
        var cur = lba, left = count
        while left > 0 {
            let n = min(left, 32)
            let cdb: [UInt8] = [0x28, 0, UInt8(cur >> 24), UInt8((cur >> 16) & 0xFF), UInt8((cur >> 8) & 0xFF), UInt8(cur & 0xFF),
                                0, UInt8(n >> 8), UInt8(n & 0xFF), 0]
            out += try execRetrying(cdb, in: n * 2048)
            cur += UInt32(n); left -= n
        }
        return out
    }

    public func writeSectors(_ lba: UInt32, _ data: [UInt8]) throws {
        if let r = readOnlyReason { throw UDFError(r) }
        let total = data.count / 2048
        if isSequential {
            var cur = lba, done = 0
            while done < total {
                let n = min(32, total - done)
                let cdb: [UInt8] = [0x2A, 0, UInt8(cur >> 24), UInt8((cur >> 16) & 0xFF), UInt8((cur >> 8) & 0xFF), UInt8(cur & 0xFF),
                                    0, UInt8(n >> 8), UInt8(n & 0xFF), 0]
                _ = try execRetrying(cdb, out: Array(data[(done * 2048) ..< ((done + n) * 2048)]), timeout: 120_000)
                cur += UInt32(n); done += n
            }
            sectorCount = max(sectorCount, cur)
            recordedEnd = max(recordedEnd, cur)
            return
        }
        precondition(total % packetSectors == 0 && Int(lba - packetBase) % packetSectors == 0, "unaligned packet write")
        let perCommand = max(packetSectors, (32 / packetSectors) * packetSectors)
        var cur = lba, done = 0
        while done < total {
            let n = min(perCommand, total - done)
            let cdb: [UInt8] = [0x2A, 0, UInt8(cur >> 24), UInt8((cur >> 16) & 0xFF), UInt8((cur >> 8) & 0xFF), UInt8(cur & 0xFF),
                                0, UInt8(n >> 8), UInt8(n & 0xFF), 0]
            _ = try execRetrying(cdb, out: Array(data[(done * 2048) ..< ((done + n) * 2048)]), timeout: 120_000)
            cur += UInt32(n); done += n
        }
    }

    public func synchronize() throws {
        _ = try execRetrying([0x35, 0, 0, 0, 0, 0, 0, 0, 0, 0], timeout: 300_000)
    }
}
