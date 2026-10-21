import Foundation

/// ECMA-167 / UDF tag identifiers.
enum TagID: UInt16 {
    case sparingTable = 0
    case primaryVolume = 1, anchor = 2, pointer = 3, implUseVolume = 4, partition = 5
    case logicalVolume = 6, unallocatedSpace = 7, terminating = 8, integrity = 9
    case fileSet = 256, fileIdentifier = 257, allocationExtent = 258, indirectEntry = 259
    case terminalEntry = 260, fileEntry = 261, eaHeader = 262, unallocatedSpaceEntry = 263
    case spaceBitmap = 264, partitionIntegrity = 265, extendedFileEntry = 266
}

/// The 16-byte descriptor tag at the start of every UDF descriptor.
struct Tag {
    var identifier: UInt16
    var version: UInt16
    var serial: UInt16
    var crcLength: UInt16
    var location: UInt32

    /// Parses and validates a tag. The CRC is checked when the covered bytes are present.
    static func parse(_ b: [UInt8], at o: Int = 0, checkCRC: Bool = true) -> Tag? {
        guard o + 16 <= b.count else { return nil }
        var sum: UInt8 = 0
        for i in 0 ..< 16 where i != 4 { sum = sum &+ b[o + i] }
        guard sum == b[o + 4] else { return nil }
        let t = Tag(identifier: b.u16(o), version: b.u16(o + 2), serial: b.u16(o + 6),
                    crcLength: b.u16(o + 10), location: b.u32(o + 12))
        if checkCRC, o + 16 + Int(t.crcLength) <= b.count {
            guard CRC16.compute(b[(o + 16) ..< (o + 16 + Int(t.crcLength))]) == b.u16(o + 8) else { return nil }
        }
        return t
    }

    /// Writes a tag for a descriptor of `length` bytes starting at `o`, computing CRC and checksum.
    static func write(into b: inout [UInt8], at o: Int = 0, id: TagID, version: UInt16, serial: UInt16,
                      location: UInt32, length: Int) {
        b.put16(o, id.rawValue)
        b.put16(o + 2, version)
        b.put8(o + 5, 0)
        b.put16(o + 6, serial)
        let crcLen = length - 16
        b.put16(o + 8, CRC16.compute(b[(o + 16) ..< (o + 16 + crcLen)]))
        b.put16(o + 10, UInt16(crcLen))
        b.put32(o + 12, location)
        var sum: UInt8 = 0
        for i in 0 ..< 16 where i != 4 { sum = sum &+ b[o + i] }
        b.put8(o + 4, sum)
    }
}

// MARK: - Addresses

/// Logical block address inside a partition (lb_addr).
public struct LBAddr: Hashable, CustomStringConvertible {
    public var block: UInt32
    public var partition: UInt16
    public var description: String { "p\(partition):\(block)" }

    static func parse(_ b: [UInt8], _ o: Int) -> LBAddr { LBAddr(block: b.u32(o), partition: b.u16(o + 4)) }
    func write(_ b: inout [UInt8], _ o: Int) { b.put32(o, block); b.put16(o + 4, partition) }
}

/// Kind of extent stored in the top two bits of an allocation descriptor length.
enum ExtentKind: UInt32 {
    case recorded = 0, allocatedNotRecorded = 1, notAllocated = 2, continuation = 3
}

/// One allocation extent of a file, normalised to long_ad form.
struct Extent {
    var length: UInt32       // bytes (30 bits)
    var kind: ExtentKind
    var location: LBAddr
}

// MARK: - Entity identifiers

struct EntityID {
    var flags: UInt8 = 0
    var identifier: String
    var suffix: [UInt8] = Array(repeating: 0, count: 8)

    static func parse(_ b: [UInt8], _ o: Int) -> EntityID {
        let raw = b.bytes(o + 1, 23)
        let end = raw.firstIndex(of: 0) ?? raw.count
        return EntityID(flags: b[o], identifier: String(decoding: raw[..<end], as: UTF8.self),
                        suffix: b.bytes(o + 24, 8))
    }

    func write(_ b: inout [UInt8], _ o: Int) {
        b.replaceSubrange(o ..< o + 32, with: [UInt8](repeating: 0, count: 32))
        b[o] = flags
        let id = Array(identifier.utf8.prefix(23))
        b.putBytes(o + 1, id)
        b.putBytes(o + 24, suffix)
    }

    /// Implementation identifier this tool stamps on descriptors it writes.
    static var implementation: EntityID {
        // Implementation identifier suffix: OS class 3 (Macintosh), OS identifier 0.
        EntityID(identifier: "*UDFDisc for macOS", suffix: [3, 0, 0, 0, 0, 0, 0, 0])
    }

    /// UDF identifier suffix (used by "*UDF FE" style ids): UDF revision + OS class.
    static func udfSuffix(revision: UInt16) -> [UInt8] {
        [UInt8(revision & 0xFF), UInt8(revision >> 8), 3, 0, 0, 0, 0, 0]
    }
}

// MARK: - Timestamps

enum Timestamp {
    static func decode(_ b: [UInt8], _ o: Int) -> Date? {
        let typeTz = b.u16(o)
        let year = Int(Int16(bitPattern: b.u16(o + 2)))
        guard year > 0 else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = Int(b[o + 4]); comps.day = Int(b[o + 5])
        comps.hour = Int(b[o + 6]); comps.minute = Int(b[o + 7]); comps.second = Int(b[o + 8])
        comps.nanosecond = Int(b[o + 9]) * 10_000_000 + Int(b[o + 10]) * 100_000 + Int(b[o + 11]) * 1000
        var tz = Int(typeTz & 0x0FFF)
        if tz & 0x800 != 0 { tz -= 0x1000 }
        let zone: TimeZone = (tz == -2047 || (typeTz >> 12) != 1) ? .current : (TimeZone(secondsFromGMT: tz * 60) ?? .current)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: comps)
    }

    static func encode(_ date: Date, into b: inout [UInt8], _ o: Int) {
        let zone = TimeZone.current
        let offsetMin = zone.secondsFromGMT(for: date) / 60
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let tz = UInt16(bitPattern: Int16(offsetMin)) & 0x0FFF
        b.put16(o, (1 << 12) | tz)
        b.put16(o + 2, UInt16(c.year ?? 2000))
        b[o + 4] = UInt8(c.month ?? 1); b[o + 5] = UInt8(c.day ?? 1)
        b[o + 6] = UInt8(c.hour ?? 0); b[o + 7] = UInt8(c.minute ?? 0); b[o + 8] = UInt8(c.second ?? 0)
        let micro = (c.nanosecond ?? 0) / 1000
        b[o + 9] = UInt8(micro / 10000)
        b[o + 10] = UInt8((micro / 100) % 100)
        b[o + 11] = UInt8(micro % 100)
    }
}

// MARK: - OSTA Compressed Unicode (CS0)

enum CS0 {
    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        guard let comp = bytes.first else { return "" }
        let body = bytes.dropFirst()
        switch comp {
        case 8, 254:
            return String(String.UnicodeScalarView(body.map { Unicode.Scalar($0) }))
        case 16, 255:
            var units: [UInt16] = []
            var it = body.makeIterator()
            while let hi = it.next(), let lo = it.next() { units.append(UInt16(hi) << 8 | UInt16(lo)) }
            return String(decoding: units, as: UTF16.self)
        default:
            return String(decoding: body, as: UTF8.self)
        }
    }

    static func encode(_ s: String) -> [UInt8] {
        if s.unicodeScalars.allSatisfy({ $0.value < 256 }) {
            return [8] + s.unicodeScalars.map { UInt8($0.value) }
        }
        var out: [UInt8] = [16]
        for u in s.utf16 { out.append(UInt8(u >> 8)); out.append(UInt8(u & 0xFF)) }
        return out
    }

    /// Decodes a fixed-size dstring field whose last byte holds the used length.
    static func decodeD(_ b: [UInt8], _ o: Int, _ size: Int) -> String {
        let len = Int(b[o + size - 1])
        guard len > 0, len < size else { return "" }
        return decode(b[o ..< o + len])
    }
}
