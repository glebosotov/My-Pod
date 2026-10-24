import Foundation

/// Add lyrics to afconvert's container without remuxing audio. Its original
/// sample tables and media offsets stay byte-for-byte intact: the old moov is
/// turned into free space and the expanded moov is appended at EOF.
nonisolated enum MP4Lyrics {
    struct InvalidContainer: Error {}
    struct Atom {
        let type: Data
        let payload: Data
    }
    static func u32(_ data: Data, _ offset: Int) -> UInt64 {
        data.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | UInt64($1) }
    }
    static func box(_ type: Data, _ payload: Data) throws -> Data {
        guard payload.count <= Int(UInt32.max) - 8 else { throw InvalidContainer() }
        var length = UInt32(payload.count + 8).bigEndian
        return withUnsafeBytes(of: &length) { Data($0) } + type + payload
    }
    static func atoms(_ data: Data) throws -> [Atom] {
        var offset = 0
        var result: [Atom] = []
        while offset < data.count {
            guard data.count - offset >= 8 else { throw InvalidContainer() }
            let length = Int(u32(data, offset))
            guard length >= 8, length <= data.count - offset else { throw InvalidContainer() }
            result.append(Atom(type: data.subdata(in: offset + 4..<offset + 8),
                               payload: data.subdata(in: offset + 8..<offset + length)))
            offset += length
        }
        return result
    }
    static let lyricsType = Data([0xa9, 0x6c, 0x79, 0x72])
    static func updated(_ payload: Data, path: [String], lyrics: Data) throws -> Data {
        if path.isEmpty {
            var items = try atoms(payload).filter { $0.type != lyricsType }
            let text = try box(Data("data".utf8), Data([0, 0, 0, 1, 0, 0, 0, 0]) + lyrics)
            items.append(Atom(type: lyricsType, payload: text))
            return try items.reduce(into: Data()) { $0 += try box($1.type, $1.payload) }
        }
        let name = path[0]
        var prefix = Data()
        var body = payload
        // meta is a FullBox: its flags precede the children.
        if name == "ilst" {
            guard payload.count >= 4 else { throw InvalidContainer() }
            prefix = payload.prefix(4)
            body = Data(payload.dropFirst(4))
        }
        var items = try atoms(body)
        let type = Data(name.utf8)
        if let index = items.firstIndex(where: { $0.type == type }) {
            items[index] = Atom(type: type, payload: try updated(items[index].payload, path: Array(path.dropFirst()), lyrics: lyrics))
        } else {
            let empty: Data
            if name == "meta" {
                // FullBox flags and a conventional iTunes metadata handler.
                let handler = Data(repeating: 0, count: 8) + Data("mdirappl".utf8) + Data(repeating: 0, count: 9)
                empty = Data(repeating: 0, count: 4) + (try box(Data("hdlr".utf8), handler))
            } else { empty = Data() }
            items.append(Atom(type: type, payload: try updated(empty, path: Array(path.dropFirst()), lyrics: lyrics)))
        }
        return try items.reduce(into: prefix) { $0 += try box($1.type, $1.payload) }
    }
    static func write(_ lyrics: String, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var offset: UInt64 = 0
        var movie: (UInt64, Data)?
        while offset < end {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8 else { throw InvalidContainer() }
            var length = u32(header, 0)
            var headerLength: UInt64 = 8
            if length == 1 {
                guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { throw InvalidContainer() }
                length = extended.reduce(0) { ($0 << 8) | UInt64($1) }
                headerLength = 16
            }
            // afconvert doesn't emit an unbounded mdat. Appending after one
            // would put metadata inside the audio atom, so refuse that layout.
            guard length >= headerLength, length <= end - offset else { throw InvalidContainer() }
            if header.suffix(4) == Data("moov".utf8) {
                guard movie == nil, length < 64 * 1024 * 1024,
                      let data = try handle.read(upToCount: Int(length - headerLength)), data.count == Int(length - headerLength)
                else { throw InvalidContainer() }
                movie = (offset, data)
            }
            offset += length
        }
        guard let (movieOffset, payload) = movie else { throw InvalidContainer() }
        let replacement = try box(Data("moov".utf8), updated(payload, path: ["udta", "meta", "ilst"], lyrics: Data(lyrics.utf8)))
        try handle.seek(toOffset: end)
        try handle.write(contentsOf: replacement)
        try handle.seek(toOffset: movieOffset + 4)
        try handle.write(contentsOf: Data("free".utf8))
        try handle.synchronize()
    }
}
