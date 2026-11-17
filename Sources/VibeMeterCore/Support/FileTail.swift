import Foundation

enum FileTail {
    /// 讀取檔案最後 `maxBytes` 位元組，回傳完整的行（捨棄被截斷的第一行）。
    static func lastLines(of url: URL, maxBytes: Int = 512 * 1024) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// 讀取第一行（最多 `maxBytes`）。
    static func firstLine(of url: URL, maxBytes: Int = 1024 * 1024) -> Substring? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first
    }
}
