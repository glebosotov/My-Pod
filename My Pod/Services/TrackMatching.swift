import Foundation

/// Match tagged identities first; migrate an unambiguous old filename identity
/// in place. Never guess between two files or consume the same device track twice.
nonisolated enum TrackMatching {
    static func matches(_ library: [LibraryTrack], device: [TrackInfo]) -> [URL: TrackInfo] {
        let byKey = Dictionary(grouping: device, by: { TrackKey(ipod: $0) })
        var out: [URL: TrackInfo] = [:]
        var used = Set<UInt32>()
        for track in library {
            if let candidates = byKey[TrackKey(library: track)], candidates.count == 1,
               used.insert(candidates[0].id).inserted { out[track.url] = candidates[0] }
        }
        var claims: [UInt32: [(URL, TrackInfo)]] = [:]
        for track in library where out[track.url] == nil {
            let folder = track.url.deletingLastPathComponent()
            let (number, title) = LibraryScanner.parseFilename(track.url.deletingPathExtension().lastPathComponent)
            let artist = folder.deletingLastPathComponent().lastPathComponent
            let keys = Set([folder.lastPathComponent, track.album].map {
                TrackKey(artist: artist, album: $0, trackNumber: number, title: title)
            })
            let candidatesByID = Dictionary(keys.flatMap { byKey[$0] ?? [] }
                .filter { !used.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let candidates = Array(candidatesByID.values)
            if candidates.count == 1 { claims[candidates[0].id, default: []].append((track.url, candidates[0])) }
        }
        for entries in claims.values where entries.count == 1 { out[entries[0].0] = entries[0].1 }
        return out
    }
}
