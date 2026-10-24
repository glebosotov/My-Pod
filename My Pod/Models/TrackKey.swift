import Foundation

/// Tagged musical identity, including disc number. Paths identify sources in
/// selections and M3Us; this key matches the metadata on the iPod.
nonisolated struct TrackKey: Hashable, Sendable {
    let artist: String
    let album: String
    let discNumber: Int
    let trackNumber: Int
    let title: String

    init(plan: PlannedTrack) {
        self.init(library: plan.library)
    }

    init(library: LibraryTrack) {
        self.init(artist: library.artist, album: library.album, trackNumber: library.trackNumber, title: library.title, discNumber: library.discNumber)
    }

    init(ipod: TrackInfo) {
        self.init(artist: ipod.artist, album: ipod.album, trackNumber: ipod.trackNumber, title: ipod.title, discNumber: ipod.discNumber)
    }

    init(artist: String, album: String, trackNumber: Int, title: String, discNumber: Int = 0) {
        self.discNumber = discNumber
        self.artist = Self.normalize(artist)
        self.album = Self.normalize(album)
        self.trackNumber = trackNumber
        self.title = Self.normalize(title)
    }

    private static func normalize(_ s: String) -> String {
        // NFC-normalize so a plan-side string parsed from a macOS filename
        // (NFD: "u" + combining diaeresis) compares equal to the iPod-side
        // string we wrote in NFC ("ü"). Without this, every accented title
        // would round-trip as a "not on iPod" miss, defeating the diff.
        s.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
