import Foundation

/// Unallocated-space bitmap of a partition (bit set = block free), kept in memory while writing.
final class SpaceBitmap {
    let ref: UInt16
    let firstBlock: UInt32
    var raw: [UInt8]
    let numBits: Int
    var dirtyBlocks = Set<Int>()
    let blockSize: Int
    var hint = 0

    init(ref: UInt16, firstBlock: UInt32, raw: [UInt8], blockSize: Int) throws {
        guard let t = Tag.parse(raw, checkCRC: false), t.identifier == TagID.spaceBitmap.rawValue else {
            throw UDFError(L("空间位图损坏，无法写入", "The space bitmap is damaged; writing isn't possible"))
        }
        self.ref = ref; self.firstBlock = firstBlock; self.raw = raw; self.blockSize = blockSize
        numBits = Int(raw.u32(16))
        guard 24 + (numBits + 7) / 8 <= raw.count else { throw UDFError(L("空间位图长度异常", "The space bitmap has an unexpected length")) }
    }

    func isFree(_ i: Int) -> Bool { raw[24 + i >> 3] & (1 << UInt8(i & 7)) != 0 }
    func set(_ i: Int, free: Bool) {
        let o = 24 + i >> 3
        if free { raw[o] |= 1 << UInt8(i & 7) } else { raw[o] &= ~(1 << UInt8(i & 7)) }
        dirtyBlocks.insert(o / blockSize)
    }

    var freeCount: Int {
        var n = 0
        for i in 0 ..< numBits / 8 { n += raw[24 + i].nonzeroBitCount }
        for i in (numBits / 8 * 8) ..< numBits where isFree(i) { n += 1 }
        return n
    }

    /// Allocates `count` blocks, preferring one contiguous run starting on an `align` boundary.
    func allocate(_ count: Int, align: Int = 1, near: Int? = nil) throws -> [(start: UInt32, count: Int)] {
        guard count > 0 else { return [] }
        let start = near ?? hint
        // A single contiguous run: first on an `align` boundary, then anywhere.
        for pass in 0 ..< 2 {
            let a = pass == 0 ? max(1, align) : 1
            var i = ((start + a - 1) / a) * a
            var wrapped = false
            while true {
                if i + count > numBits {
                    if wrapped { break }
                    wrapped = true; i = 0; continue
                }
                if wrapped && i >= start { break }
                var run = 0
                while run < count && isFree(i + run) { run += 1 }
                if run == count {
                    for j in i ..< i + count { set(j, free: false) }
                    hint = i + count
                    return [(UInt32(i), count)]
                }
                i += run + 1
                if a > 1 { i = ((i + a - 1) / a) * a }
            }
        }
        // Otherwise gather fragments from the start.
        guard freeCount >= count else { throw UDFError(L("光盘空间不足", "Not enough space on the disc")) }
        var out: [(UInt32, Int)] = []
        var need = count
        var i = 0
        while need > 0 && i < numBits {
            if isFree(i) {
                var run = 0
                while run < need && i + run < numBits && isFree(i + run) { set(i + run, free: false); run += 1 }
                out.append((UInt32(i), run)); need -= run; i += run
            } else { i += 1 }
        }
        return out
    }
}
