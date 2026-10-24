#if MYPOD_TESTS
import Foundation

@MainActor enum RegressionTests {
    struct Failed: Error { let message: String }
    static func expect(_ ok: Bool, _ message: String) throws { if !ok { throw Failed(message: message) } }
    static func run() async {
        do { try await test(); print("All regression checks passed"); exit(0) }
        catch { fputs("Regression failure: \(error)\n", stderr); exit(1) }
    }
    static func test() async throws {
        let args = CommandLine.arguments
        guard args.count == 3 else { throw Failed(message: "Expected fixture library and device paths") }
        let root = URL(fileURLWithPath: args[1])
        let mount = URL(fileURLWithPath: args[2])
        var tags = EmbeddedTags()
        TagReader.apply(key: "TRCK", value: "3/12", to: &tags)
        TagReader.apply(key: "TPOS", value: "2/3", to: &tags)
        TagReader.apply(key: "TDRC", value: "2024-02-01", to: &tags)
        tags["title"] = "0"
        try expect(tags.number("trackTotal") == 12 && tags.number("discNumber") == 2 && tags.number("year") == 2024 && tags["title"] == "0", "ID3 numbers/date/title parsing")
        try expect((try? MyPodCLI.Options(["sync", "--unknown"])) == nil, "Unknown CLI options must fail")
        let library = await LibraryScanner.scan(root: root)
        let all = library.artists.flatMap(\.albums).flatMap(\.tracks)
        try expect(all.count == 5 && library.scanErrors.isEmpty, "Recursive scanner must find five fixtures")
        let tagged = all.filter { $0.tags["genre"] != nil }
        try expect(tagged.count == 4, "Read MP3, M4A and FLAC genres")
        try expect(tagged.allSatisfy { $0.artist == "Tagged Artist" && $0.album == "Tagged Album" && $0.title == "Tagged Title" }, "Embedded identities override misleading paths")
        try expect(tagged.allSatisfy { $0.tags["comment"] == "Test Comment" && $0.tags["composer"] == "Test Composer"
            && $0.tags.number("bpm") == 123 && $0.tags.number("year") == 2024
            && $0.tags.number("compilation") == 1 && $0.tags["sortArtist"] == "Artist Sort" }, "Extended tags across all formats")
        let mp4 = tagged.first { $0.fileExtension == "m4a" }!
        try expect(mp4.trackNumber == 3 && mp4.discNumber == 2 && mp4.tags.number("trackTotal") == 12 && mp4.tags.number("discTotal") == 3, "M4A binary track/disc numbers")
        try expect(mp4.tags["albumArtist"] == "Various Artists" && mp4.tags["composer"] == "Test Composer" && mp4.tags.number("compilation") == 1, "Album artist, composer, compilation")
        try expect(mp4.tags["sortTitle"] == "Title Sort" && mp4.tags["grouping"] == "Test Group" && mp4.tags["comment"] == "Test Comment", "Sort/group/comment tags: \(mp4.tags)")
        let lyricCopy = root.deletingLastPathComponent().appendingPathComponent("lyrics.m4a")
        try FileManager.default.copyItem(at: mp4.url, to: lyricCopy)
        let digest = try decodedHash(lyricCopy)
        try MP4Lyrics.write("Replacement lyrics", to: lyricCopy)
        try expect(try decodedHash(lyricCopy) == digest, "Adding lyrics must preserve decoded audio")
        let replacedTags = await TagReader.read(lyricCopy)
        try expect(replacedTags["lyrics"] == "Replacement lyrics", "Replace existing lyrics metadata")
        let fallback = all.first { $0.tags["genre"] == nil }!
        try expect(fallback.title == "Fallback" && fallback.trackNumber == 7 && fallback.artist == "Folder Artist", "Untagged fallback")
        try expect(Set(tagged.map { TrackKey(library: $0) }).count == tagged.count, "Disc numbers distinguish otherwise identical titles")
        let excluded = try MyPodCLI.Options(["plan", "--exclude", "/one", "--exclude", "/two"])
        try expect(excluded.excludedPaths.count == 2, "Repeated explicit exclusions")
        let device = IPodDevice(mountpoint: mount)
        try await device.open()
        let other = IPodDevice(mountpoint: mount)
        var locked = false
        do { try await other.open() } catch { locked = true }
        try expect(locked, "Second writer must be refused")
        // Seed one old folder-based import and migrate it without copying again.
        let legacyFolder = mp4.url.deletingLastPathComponent()
        let legacyName = LibraryScanner.parseFilename(mp4.url.deletingPathExtension().lastPathComponent)
        let props = await AudioMetadataReader.read(mp4.url)
        try await device.addTrack(filepath: mp4.url, title: legacyName.1,
            artist: legacyFolder.deletingLastPathComponent().lastPathComponent,
            album: legacyFolder.lastPathComponent, trackNumber: legacyName.0,
            durationMS: props.durationMS, bitrate: props.bitrate, sampleRate: props.sampleRate)
        try await device.save()
        await device.close()
        try await device.open()
        let before = await device.tracks()
        let selected = Set(all.map { $0.url.path })
        let engine = SyncEngine()
        await engine.plan(libraryRoot: root, library: library, selectedPaths: selected, playlists: [],
            device: device, ceiling: .aac48, freeBytes: 1_000_000_000, useDeviceProfile: false, cacheRoot: root.deletingLastPathComponent().appendingPathComponent("cache"))
        guard case .planned(let plan) = engine.state else { throw Failed(message: "Plan failed: \(engine.state)") }
        try expect(plan.metadataUpdates.count == 1 && plan.toAdd.count == 4 && plan.toRemove.isEmpty, "Migrate legacy import in place")
        await engine.execute(plan: plan, libraryRoot: root, playlists: [], device: device, recordArtworkState: false)
        guard case .finished(let result) = engine.state else { throw Failed(message: "Sync failed: \(engine.state)") }
        try expect(result.failed == 0 && result.convertedFailures == 0 && result.totalOnDevice == 5, "Transfer and conversion succeed")
        let converted = tagged.first { $0.fileExtension == "flac" }!
        let convertedURL = engine.conversionService.iPodPlayableURL(for: converted)
        let convertedTags = await TagReader.read(convertedURL)
        try expect(convertedTags["lyrics"] == "Test lyrics", "Lyrics survive conversion")
        await device.close()
        try await device.open()
        let after = await device.tracks()
        try expect(after.first { $0.id == before[0].id }?.tags == mp4.importedTags, "Legacy ID retained and all imported tags saved")
        for track in all {
            try expect(after.contains { $0.tags == track.importedTags }, "All metadata round trips through iTunesDB: \(track.url.path)")
        }
        await engine.plan(libraryRoot: root, library: library, selectedPaths: selected, playlists: [],
            device: device, ceiling: .aac48, freeBytes: 1_000_000_000, useDeviceProfile: false, cacheRoot: root.deletingLastPathComponent().appendingPathComponent("cache"))
        guard case .planned(let repeatPlan) = engine.state else { throw Failed(message: "Repeat planning failed") }
        try expect(repeatPlan.toAdd.isEmpty && repeatPlan.toRemove.isEmpty && repeatPlan.metadataUpdates.isEmpty, "Second sync is idempotent")
        var changed = library
        changed.artists[0].albums[0].tracks[0].tags["genre"] = "Changed Genre"
        await engine.plan(libraryRoot: root, library: changed, selectedPaths: selected, playlists: [],
            device: device, ceiling: .aac48, freeBytes: 1_000_000_000, useDeviceProfile: false, cacheRoot: root.deletingLastPathComponent().appendingPathComponent("cache"))
        guard case .planned(let changedPlan) = engine.state else { throw Failed(message: "Changed-tag planning failed") }
        try expect(changedPlan.metadataUpdates.count == 1 && changedPlan.toAdd.isEmpty, "Tag edits update metadata without recopying")
        var withDuplicate = library
        var alternate = mp4
        let alternateURL = mp4.url.deletingLastPathComponent().appendingPathComponent("alternate.m4a")
        alternate = LibraryTrack(id: alternateURL, artist: mp4.artist, album: mp4.album,
            trackNumber: mp4.trackNumber, title: mp4.title, fileExtension: mp4.fileExtension,
            sizeBytes: mp4.sizeBytes, format: mp4.format, tags: mp4.tags)
        withDuplicate.artists[0].albums[0].tracks.append(alternate)
        withDuplicate.totalTracks += 1
        await engine.plan(libraryRoot: root, library: withDuplicate, selectedPaths: selected, playlists: [],
            device: device, ceiling: .aac48, freeBytes: 1_000_000_000, useDeviceProfile: false)
        guard case .planned(let excludedPlan) = engine.state else { throw Failed(message: "Deselected duplicate must not block planning") }
        try expect(excludedPlan.playlistKeysByPath[alternateURL.path.precomposedStringWithCanonicalMapping] == TrackKey(library: mp4), "M3Us referencing excluded alternate formats retain musical identity")
        let keys = Dictionary(uniqueKeysWithValues: all.map { ($0.url.path.precomposedStringWithCanonicalMapping, TrackKey(library: $0)) })
        let entry = PlaylistEntry(path: mp4.url.path)
        let playlist = Playlist(id: UUID(), name: "Test", entries: [entry], fileURL: root.appendingPathComponent("test.m3u"))
        let diff = SyncEngine.computePlaylistChanges(playlists: [playlist], devicePlaylists: [], iPodTracks: after,
            postSyncKeys: Set(all.map { TrackKey(library: $0) }), libraryRoot: root, keysByPath: keys)
        try expect(diff.first?.unresolvedCount == 0 && diff.first?.finalCount == 1, "M3U resolves tag identity through source path")
        let partialArtwork = ArtworkUpdate(albumID: "test", artist: "Test", album: "Test",
            coverURL: root.appendingPathComponent("test-cover.png"), trackIDs: [after[0].id, UInt32.max])
        let artworkSucceeded = await ArtworkSync.apply(partialArtwork, to: device)
        try expect(!artworkSucceeded, "Partial artwork failure must prevent successful auto-eject")
        await device.close()
    }
    static func decodedHash(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-v", "error", "-xerror", "-i", url.path,
                             "-map", "0:a:0", "-f", "hash", "-hash", "sha256", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "Converted MP4 must decode successfully")
        return data
    }

}
#endif
