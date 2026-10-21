import Foundation

/// One item in a directory listing.
public struct UDFEntry: Identifiable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modified: Date?
    public let isHidden: Bool
    let icb: LBAddr
}

struct PartitionDesc {
    var number: UInt16
    var start: UInt32
    var length: UInt32
    var accessType: UInt32
    var bitmap: (position: UInt32, length: UInt32)?
    var usesSpaceTable: Bool
}

enum MapKind {
    case physical
    case sparable(packetLength: UInt32)
    case virtual
    case metadata(fileLocation: UInt32)
}

struct PartitionMap {
    var kind: MapKind
    var partition: PartitionDesc
}

/// A parsed file entry (FE or EFE) plus where it lives.
final class FileEntry {
    let addr: LBAddr
    var raw: [UInt8]
    let extended: Bool
    var extents: [Extent] = []
    var aedBlocks: [LBAddr] = []

    init(addr: LBAddr, raw: [UInt8], extended: Bool) {
        self.addr = addr; self.raw = raw; self.extended = extended
    }

    var fileType: UInt8 { raw[16 + 11] }
    var isDirectory: Bool { fileType == 4 }
    var icbFlags: UInt16 { get { raw.u16(16 + 18) } set { raw.put16(16 + 18, newValue) } }
    var adType: Int { get { Int(icbFlags & 7) } set { icbFlags = (icbFlags & ~7) | UInt16(newValue) } }
    var linkCount: UInt16 { get { raw.u16(48) } set { raw.put16(48, newValue) } }
    var infoLength: UInt64 { get { raw.u64(56) } set { raw.put64(56, newValue); if extended { raw.put64(64, newValue) } } }
    var blocksRecorded: UInt64 { get { raw.u64(extended ? 72 : 64) } set { raw.put64(extended ? 72 : 64, newValue) } }
    var accessTimeOffset: Int { extended ? 80 : 72 }
    var modTimeOffset: Int { extended ? 92 : 84 }
    var attrTimeOffset: Int { extended ? 116 : 96 }
    var implIDOffset: Int { extended ? 168 : 128 }
    var uniqueID: UInt64 { get { raw.u64(extended ? 200 : 160) } set { raw.put64(extended ? 200 : 160, newValue) } }
    var eaLength: Int { Int(raw.u32(extended ? 208 : 168)) }
    var adLengthOffset: Int { extended ? 212 : 172 }
    var adLength: Int { get { Int(raw.u32(adLengthOffset)) } set { raw.put32(adLengthOffset, UInt32(newValue)) } }
    var adOffset: Int { (extended ? 216 : 176) + eaLength }
    var modified: Date? { Timestamp.decode(raw, modTimeOffset) }
    var inlineData: [UInt8] { Array(raw[adOffset ..< adOffset + adLength]) }
}

/// A File Identifier Descriptor (one name in a directory).
struct FID {
    var version: UInt16 = 1
    var characteristics: UInt8
    var icb: [UInt8]          // 16-byte long_ad
    var implUse: [UInt8] = []
    var nameRaw: [UInt8]

    var icbAddr: LBAddr { LBAddr.parse(icb, 4) }
    var isHidden: Bool { characteristics & 0x01 != 0 }
    var isDirectory: Bool { characteristics & 0x02 != 0 }
    var isDeleted: Bool { characteristics & 0x04 != 0 }
    var isParent: Bool { characteristics & 0x08 != 0 }
    var name: String { CS0.decode(nameRaw[...]) }
    var size: Int { (38 + implUse.count + nameRaw.count + 3) & ~3 }

    static func longAD(block: UInt32, partition: UInt16, length: UInt32, uniqueID: UInt32 = 0) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 16)
        b.put32(0, length)
        LBAddr(block: block, partition: partition).write(&b, 4)
        b.put32(12, uniqueID)   // ADImpUse: flags (2 bytes, 0) + UDF unique id (4 bytes)
        return b
    }
}
