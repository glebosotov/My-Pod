import Foundation

/// Identity used to match a library track against a track already on the iPod.
/// The iPod database doesn't store source file paths, so artist, album, track
/// number and title are the fields both sides share. Track number keeps two
/// identically titled tracks on the same album distinct. Repeated titles with
/// the same number on different discs still collide until the scanner also
/// supplies disc numbers.
///
/// Shared by the sync planner (what to add/remove) and the Music tab's
/// "new music" highlight (what isn't on the device yet) so both agree on what
/// counts as the same track.
///
/// `nonisolated` — built from `IPodDevice` (an actor) and the detached library
/// scanner alike; overrides the project-wide MainActor default.
nonisolated struct TrackKey: Hashable, Sendable {
    let artist: String
    let album: String
    let trackNumber: Int
    let title: String

    init(plan: PlannedTrack) {
        self.init(library: plan.library)
    }

    init(library: LibraryTrack) {
        self.init(artist: library.artist, album: library.album, trackNumber: library.trackNumber, title: library.title)
    }

    init(ipod: TrackInfo) {
        self.init(artist: ipod.artist, album: ipod.album, trackNumber: ipod.trackNumber, title: ipod.title)
    }

    init(artist: String, album: String, trackNumber: Int, title: String) {
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
