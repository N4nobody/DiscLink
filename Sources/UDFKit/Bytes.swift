import Foundation

/// Errors raised anywhere in UDFKit. Messages are shown to the user, so they are in Chinese.
public struct UDFError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

// MARK: - Little-endian access on byte arrays

extension Array where Element == UInt8 {
    @inline(__always) func u8(_ o: Int) -> UInt8 { self[o] }
    @inline(__always) func u16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    @inline(__always) func u32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    @inline(__always) func u64(_ o: Int) -> UInt64 { UInt64(u32(o)) | UInt64(u32(o + 4)) << 32 }
    func bytes(_ o: Int, _ n: Int) -> [UInt8] { Array(self[o ..< o + n]) }

    @inline(__always) mutating func put8(_ o: Int, _ v: UInt8) { self[o] = v }
    @inline(__always) mutating func put16(_ o: Int, _ v: UInt16) {
        self[o] = UInt8(v & 0xFF); self[o + 1] = UInt8(v >> 8)
    }
    @inline(__always) mutating func put32(_ o: Int, _ v: UInt32) {
        for i in 0 ..< 4 { self[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }
    @inline(__always) mutating func put64(_ o: Int, _ v: UInt64) {
        put32(o, UInt32(v & 0xFFFF_FFFF)); put32(o + 4, UInt32(v >> 32))
    }
    mutating func putBytes(_ o: Int, _ b: [UInt8]) {
        replaceSubrange(o ..< o + b.count, with: b)
    }
}

// MARK: - Big-endian helpers (SCSI/MMC)

extension Array where Element == UInt8 {
    func be16(_ o: Int) -> UInt16 { UInt16(self[o]) << 8 | UInt16(self[o + 1]) }
    func be32(_ o: Int) -> UInt32 {
        UInt32(self[o]) << 24 | UInt32(self[o + 1]) << 16 | UInt32(self[o + 2]) << 8 | UInt32(self[o + 3])
    }
}

// MARK: - CRC-ITU-T (x^16 + x^12 + x^5 + 1), as used by ECMA-167 descriptor tags

enum CRC16 {
    static let table: [UInt16] = (0 ..< 256).map { n -> UInt16 in
        var c = UInt16(n) << 8
        for _ in 0 ..< 8 { c = (c & 0x8000) != 0 ? (c << 1) ^ 0x1021 : c << 1 }
        return c
    }

    static func compute(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in data { crc = (crc << 8) ^ table[Int((crc >> 8) ^ UInt16(b))] }
        return crc
    }
}
