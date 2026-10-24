import AVFoundation
import Foundation

/// Embedded descriptive tags. No playback history or user ratings are imported.
nonisolated struct EmbeddedTags: Sendable, Hashable, Codable {
    private static let numeric: Set<String> = ["trackNumber", "trackTotal", "discNumber", "discTotal", "year", "bpm", "compilation", "hasLyrics"]
    var values: [String: String] = [:]
    subscript(_ key: String) -> String? {
        get { values[key] }
        set {
            let value = newValue?.precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.numeric.contains(key) {
                if let value, let number = Int(value), number > 0, number <= Int32.max { values[key] = String(number) }
                else { values[key] = nil }
            } else { values[key] = value?.isEmpty == false ? value : nil }
        }
    }
    func number(_ key: String) -> Int { Int(values[key] ?? "") ?? 0 }
    init() {}
    init(_ raw: IPodTagMetadata) {
        self["title"] = raw.title.map { String(cString: $0) }
        self["artist"] = raw.artist.map { String(cString: $0) }
        self["album"] = raw.album.map { String(cString: $0) }
        self["genre"] = raw.genre.map { String(cString: $0) }
        self["albumArtist"] = raw.albumArtist.map { String(cString: $0) }
        self["composer"] = raw.composer.map { String(cString: $0) }
        self["grouping"] = raw.grouping.map { String(cString: $0) }
        self["comment"] = raw.comment.map { String(cString: $0) }
        self["sortTitle"] = raw.sortTitle.map { String(cString: $0) }
        self["sortArtist"] = raw.sortArtist.map { String(cString: $0) }
        self["sortAlbum"] = raw.sortAlbum.map { String(cString: $0) }
        self["sortAlbumArtist"] = raw.sortAlbumArtist.map { String(cString: $0) }
        self["sortComposer"] = raw.sortComposer.map { String(cString: $0) }
        self["trackNumber"] = String(raw.trackNumber)
        self["trackTotal"] = String(raw.trackTotal)
        self["discNumber"] = String(raw.discNumber)
        self["discTotal"] = String(raw.discTotal)
        self["year"] = String(raw.year)
        self["bpm"] = String(raw.bpm)
        self["compilation"] = String(raw.compilation)
        self["hasLyrics"] = String(raw.hasLyrics)
    }

    func withCMetadata<T>(_ body: (IPodTagMetadata) throws -> T) rethrows -> T {
        var raw = IPodTagMetadata()
        var allocated: [UnsafeMutablePointer<CChar>] = []
        func string(_ key: String) -> UnsafePointer<CChar>? {
            guard let value = self[key], let p = strdup(value) else { return nil }
            allocated.append(p)
            return UnsafePointer(p)
        }
        defer { allocated.forEach { free($0) } }
        raw.title = string("title")
        raw.artist = string("artist")
        raw.album = string("album")
        raw.genre = string("genre")
        raw.albumArtist = string("albumArtist")
        raw.composer = string("composer")
        raw.grouping = string("grouping")
        raw.comment = string("comment")
        raw.sortTitle = string("sortTitle")
        raw.sortArtist = string("sortArtist")
        raw.sortAlbum = string("sortAlbum")
        raw.sortAlbumArtist = string("sortAlbumArtist")
        raw.sortComposer = string("sortComposer")
        raw.trackNumber = Int32(clamping: number("trackNumber"))
        raw.trackTotal = Int32(clamping: number("trackTotal"))
        raw.discNumber = Int32(clamping: number("discNumber"))
        raw.discTotal = Int32(clamping: number("discTotal"))
        raw.year = Int32(clamping: number("year"))
        raw.bpm = Int32(clamping: number("bpm"))
        raw.compilation = Int32(clamping: number("compilation"))
        raw.hasLyrics = Int32(clamping: number("hasLyrics"))
        return try body(raw)
    }
}

nonisolated enum TagReader {
    /// AVFoundation exposes iTunes, ID3 and Vorbis keys under different identifiers.
    static func read(_ url: URL) async -> EmbeddedTags {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return EmbeddedTags() }
        var tags = EmbeddedTags()
        for item in items {
            guard let rawIdentifier = item.identifier?.rawValue else { continue }
            // Apple encodes the legacy copyright byte as %A9 rather than UTF-8
            // %C2%A9, so Foundation's strict percent decoder alone returns nil.
            let repaired = rawIdentifier.replacingOccurrences(of: "%A9", with: "©")
            let identifier = repaired.removingPercentEncoding ?? repaired
            let parts = identifier.split(separator: "/", maxSplits: 2).map(String.init)
            var key = parts.count > 1 ? parts[1] : identifier
            if key == "TXXX" {
                let attributes = try? await item.load(.extraAttributes)
                if let description = attributes?[AVMetadataExtraAttributeKey(rawValue: "info")] as? String {
                    key = description.replacingOccurrences(of: "_", with: "").uppercased()
                } else if parts.count > 2 { key = parts[2].uppercased() }
            }
            if parts.first == "vorb" { key = key.replacingOccurrences(of: "_", with: "").uppercased() }
            if key == "trkn" || key == "disk" {
                if let data = try? await item.load(.dataValue), data.count >= 6 {
                    let bytes = Array(data)
                    let field = key == "trkn" ? "track" : "disc"
                    tags[field + "Number"] = String(Int(bytes[2]) * 256 + Int(bytes[3]))
                    tags[field + "Total"] = String(Int(bytes[4]) * 256 + Int(bytes[5]))
                }
                continue
            }
            var value = try? await item.load(.stringValue)
            if value == nil, let number = try? await item.load(.numberValue) { value = number.stringValue }
            guard let value else { continue }
            apply(key: key, value: value, to: &tags)
        }
        return tags
    }

    private static let aliases: [String: String] = [
            "INAM":"title", "IART":"artist", "IPRD":"album", "ICMT":"comment", "IGNR":"genre",
            "©nam":"title", "TIT2":"title", "TITLE":"title",
            "©ART":"artist", "TPE1":"artist", "ARTIST":"artist",
            "©alb":"album", "TALB":"album", "ALBUM":"album",
            "©gen":"genre", "TCON":"genre", "GENRE":"genre",
            "aART":"albumArtist", "TPE2":"albumArtist", "ALBUMARTIST":"albumArtist", "ALBUM ARTIST":"albumArtist",
            "©wrt":"composer", "TCOM":"composer", "COMPOSER":"composer",
            "©grp":"grouping", "TIT1":"grouping", "GROUPING":"grouping",
            "©cmt":"comment", "COMM":"comment", "COMMENT":"comment", "DESCRIPTION":"comment",
            "SORTNAME":"sortTitle", "SORTARTIST":"sortArtist", "SORTALBUM":"sortAlbum",
            "SORTALBUMARTIST":"sortAlbumArtist", "SORTCOMPOSER":"sortComposer",
            "sonm":"sortTitle", "TSOT":"sortTitle", "TITLESORT":"sortTitle",
            "soar":"sortArtist", "TSOP":"sortArtist", "ARTISTSORT":"sortArtist",
            "soal":"sortAlbum", "TSOA":"sortAlbum", "ALBUMSORT":"sortAlbum",
            "soaa":"sortAlbumArtist", "TSO2":"sortAlbumArtist", "ALBUMARTISTSORT":"sortAlbumArtist",
            "soco":"sortComposer", "TSOC":"sortComposer", "COMPOSERSORT":"sortComposer",
            "tmpo":"bpm", "TBPM":"bpm", "BPM":"bpm",
            "cpil":"compilation", "TCMP":"compilation", "COMPILATION":"compilation"
        ]

    static func apply(key: String, value: String, to tags: inout EmbeddedTags) {

        let key = key.hasPrefix("com.apple.iTunes.") ? String(key.dropFirst(17)) : key
        if ["TRCK", "TRACKNUMBER", "TPOS", "DISCNUMBER"].contains(key) {
            let parts = value.split(separator: "/")
            let field = ["TPOS", "DISCNUMBER"].contains(key) ? "disc" : "track"
            tags[field + "Number"] = parts.first.flatMap { Int($0) }.map(String.init)
            if parts.count > 1 { tags[field + "Total"] = Int(parts[1]).map(String.init) }
        } else if ["TRACKTOTAL", "TOTALTRACKS", "DISCTOTAL", "TOTALDISCS"].contains(key) {
            tags[key.contains("DISC") ? "discTotal" : "trackTotal"] = Int(value).map(String.init)
        } else if ["©day", "TDRC", "TYER", "DATE", "YEAR", "ICRD"].contains(key) {
            if let year = Int(value.prefix(4)), (1...9999).contains(year) { tags["year"] = String(year) }
        } else if ["©lyr", "USLT", "LYRICS", "UNSYNCEDLYRICS"].contains(key) {
            tags["hasLyrics"] = value.isEmpty ? nil : "1"
            tags["lyrics"] = value
        } else if let field = aliases[key] {
            if field == "bpm" {
                if let number = Double(value), number.isFinite, number > 0, number <= 32767 {
                    tags[field] = String(Int(number.rounded()))
                }
            } else if field == "compilation" {
                tags[field] = ["1", "true", "yes"].contains(value.lowercased()) ? "1" : nil
            } else {
                tags[field] = value
            }
        }
    }
}
