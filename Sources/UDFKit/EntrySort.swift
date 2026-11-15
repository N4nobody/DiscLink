import Foundation

/// How a folder listing is ordered. Folders always come first (like the Finder's “Keep folders
/// on top”); names compare the way the Finder does (“file2” before “file10”), and entries that
/// tie on the chosen key fall back to name order.
public enum EntrySort: String, CaseIterable, Sendable {
    case name, kind, size, date

    public var title: String {
        switch self {
        case .name: return L("名称", "Name")
        case .kind: return L("种类", "Kind")
        case .size: return L("大小", "Size")
        case .date: return L("修改日期", "Date Modified")
        }
    }

    /// Sorts `entries`. `kind` gives each entry's kind name (it depends on the app's file types).
    public func sorted(_ entries: [UDFEntry], ascending: Bool, kind: (UDFEntry) -> String = { _ in "" }) -> [UDFEntry] {
        let kinds = self == .kind ? Dictionary(entries.map { ($0.id, kind($0)) }, uniquingKeysWith: { a, _ in a }) : [:]
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let primary: ComparisonResult
            switch self {
            case .name: primary = a.name.localizedStandardCompare(b.name)
            case .kind: primary = (kinds[a.id] ?? "").localizedStandardCompare(kinds[b.id] ?? "")
            case .size: primary = Self.compare(a.size, b.size)
            case .date: primary = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast)
            }
            if primary != .orderedSame {
                return ascending ? primary == .orderedAscending : primary == .orderedDescending
            }
            // Ties: by name, in the chosen direction when sorting by name, otherwise A to Z.
            let byName = a.name.localizedStandardCompare(b.name)
            return (self == .name && !ascending) ? byName == .orderedDescending : byName == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}
