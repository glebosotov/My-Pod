import Foundation

/// Tags are authoritative. Paths remain stable selection/playlist identities and
/// supply artist, album, title and track number only when a file has no tag.
nonisolated enum LibraryScanner {
    static func scan(root: URL) async -> MusicLibrary {
        await Task.detached(priority: .userInitiated) { await scanFiles(root: root) }.value
    }

    private static func scanFiles(root: URL) async -> MusicLibrary {
        let (files, errors) = enumerate(root)
        var tracks: [LibraryTrack] = []
        // Bound simultaneously open AVAssets. Sorting below makes results deterministic.
        for offset in stride(from: 0, to: files.count, by: 8) {
            let batch = Array(files[offset..<min(offset + 8, files.count)])
            let results = await withTaskGroup(of: LibraryTrack.self) { group in
                for url in batch { group.addTask { await readTrack(url) } }
                var out: [LibraryTrack] = []
                for await track in group { out.append(track) }
                return out
            }
            tracks.append(contentsOf: results)
        }
        let groups = Dictionary(grouping: tracks) { track in
            (track.tags["albumArtist"] ?? track.artist) + "\u{0}" + track.album
        }
        var albumsByArtist: [String: [LibraryAlbum]] = [:]
        for members in groups.values {
            let sorted = members.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.url.path < $1.url.path
            }
            guard let first = sorted.first else { continue }
            let artist = first.tags["albumArtist"] ?? first.artist
            let directory = first.url.deletingLastPathComponent()
            let date = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            albumsByArtist[artist, default: []].append(LibraryAlbum(
                artist: artist, name: first.album, directory: directory, createdAt: date, tracks: sorted))
        }
        let artists = albumsByArtist.keys.sorted().map { name in
            LibraryArtist(name: name, albums: albumsByArtist[name]!.sorted { $0.name < $1.name })
        }
        return MusicLibrary(root: root, artists: artists, totalTracks: tracks.count,
                            scannedAt: Date(), scanErrors: errors)
    }

    private static func enumerate(_ root: URL) -> ([URL], [String]) {
        let fm = FileManager.default
        var errors: [String] = []
        var files: [URL] = []
        if let walker = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles], errorHandler: { url, error in
                errors.append("\(url.path): \(error.localizedDescription)")
                return true
            }) {
            for case let url as URL in walker {
                if url.lastPathComponent.caseInsensitiveCompare("Playlists") == .orderedSame {
                    walker.skipDescendants()
                    continue
                }
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink == true { walker.skipDescendants(); continue }
                    if values.isRegularFile == true, AudioFormat.canSync(url.pathExtension) { files.append(url) }
                } catch { errors.append("\(url.path): \(error.localizedDescription)") }
            }
        } else { errors.append("Cannot enumerate library: \(root.path)") }
        return (files, errors)
    }

    static func readTrack(_ url: URL) async -> LibraryTrack {
        let tags = await TagReader.read(url)
        let folder = url.deletingLastPathComponent()
        let (number, title) = parseFilename(url.deletingPathExtension().lastPathComponent)
        let ext = url.pathExtension
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
        let probe = AudioFormat.shouldProbe(ext) ? AudioProbe.read(url) : nil
        var format = AudioFormat.sourceFormat(ext: ext, probe: probe)
        if format.alwaysConverts, probe == nil {
            let flac = FLACHeader.streamInfo(of: url)
            format.sampleRate = flac.sampleRate
            format.bitDepth = flac.bitDepth
            format.durationMS = flac.durationMS
        }
        return LibraryTrack(id: url, artist: tags["artist"] ?? folder.deletingLastPathComponent().lastPathComponent,
            album: tags["album"] ?? folder.lastPathComponent,
            trackNumber: tags["trackNumber"].flatMap(Int.init) ?? number,
            title: tags["title"] ?? title, fileExtension: ext.lowercased(), sizeBytes: size,
            format: format, tags: tags)
    }

    /// Mirrors the regex from ipod-sync.c:
    ///   `01 - Track Title`  → (1, "Track Title")
    ///   `01. Track Title`   → (1, "Track Title")
    ///   `01 Track Title`    → (1, "Track Title")
    ///   `Track Title`       → (0, "Track Title")
    static func parseFilename(_ base: String) -> (Int, String) {
        var i = base.startIndex
        // Read leading digits.
        var digits = ""
        while i < base.endIndex, base[i].isNumber {
            digits.append(base[i])
            i = base.index(after: i)
        }
        guard let n = Int(digits), !digits.isEmpty else {
            return (0, base)
        }
        // Skip a separator: optional "." or "-" surrounded by spaces, or a single space.
        var j = i
        while j < base.endIndex, base[j].isWhitespace { j = base.index(after: j) }
        if j < base.endIndex, "-.".contains(base[j]) {
            j = base.index(after: j)
            while j < base.endIndex, base[j].isWhitespace { j = base.index(after: j) }
        }
        let title = String(base[j...]).trimmingCharacters(in: .whitespaces)
        return (n, title.isEmpty ? base : title)
    }

}
