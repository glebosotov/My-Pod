import AppKit
import Foundation
import Darwin

/// Headless adapter over the GUI's scanner, planner and transfer engine.
@MainActor enum MyPodCLI {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    struct Options {
        let command: String
        var values: [String: String] = [:]
        var flags = Set<String>()
        var excludedPaths: [String] = []
        init(_ arguments: [String]) throws {
            command = arguments.first ?? "help"
            guard ["help", "--help", "devices", "scan", "plan", "sync", "eject"].contains(command) else {
                throw Failure("Unknown command: \(command). Run mypod help.")
            }
            let allowedValues: Set<String> = switch command {
            case "scan": ["--library"]
            case "plan", "sync": ["--library", "--device", "--device-id", "--playlists", "--quality", "--cache", "--exclude"]
            case "eject": ["--device", "--device-id"]
            default: []
            }
            let allowedFlags: Set<String> = command == "sync" ? ["--delete", "--eject", "--resend-artwork"] : (command == "plan" ? ["--delete", "--resend-artwork"] : [])
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                if key == "--exclude", allowedValues.contains(key) {
                    guard index + 1 < arguments.count, arguments[index + 1].hasPrefix("/") else {
                        throw Failure("--exclude requires an absolute file path")
                    }
                    excludedPaths.append(URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL.resolvingSymlinksInPath().path)
                    index += 2
                    continue
                }
                guard values[key] == nil, !flags.contains(key) else { throw Failure("Repeated option: \(key)") }
                if allowedFlags.contains(key) { flags.insert(key) }
                else if allowedValues.contains(key), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    index += 1
                    values[key] = arguments[index]
                } else { throw Failure("Unknown option or missing value: \(key)") }
                index += 1
            }
        }
        func path(_ key: String) throws -> URL {
            guard let value = values[key], value.hasPrefix("/") else { throw Failure("\(key) requires an absolute path") }
            return URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        }
    }

    static let help = """
    Usage: mypod devices
           mypod scan --library /path/to/music
           mypod plan --library /path/to/music --device /Volumes/IPOD [options]
           mypod sync --library /path/to/music --device /Volumes/IPOD --device-id ID [options]
           mypod eject --device /Volumes/IPOD --device-id ID

    Options for plan/sync:
      --quality aac44|aac48|alac44|alac48  Explicit quality ceiling (default: aac44)
      --playlists /path/to/m3us           Replace user playlists with these M3Us
      --cache /path/to/cache              Conversion cache (default: ~/Library/Caches/MyPodCLI)
      --exclude /path/to/file             Exclude a source (repeatable; useful for duplicate formats)
      --resend-artwork                   Refresh every matched album cover
      --delete                           Remove device tracks absent from the library
      --eject                            Eject after a fully successful sync (sync only)

    Plan/scan/devices print JSON and never save the device database. Sync is additive
    unless --delete is supplied. Without --playlists, device playlists are preserved.
    Sync/eject require the device ID printed by devices. Exit 0 means success;
    exit 1 means failure; exit 130 means an interrupted, safely saved partial sync.
    Close the GUI before using a device from the CLI. SIGINT/SIGTERM requests a safe
    stop between tracks; wait for saving to finish before disconnecting the cable.
    """

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            let options = try Options(arguments)
            switch options.command {
            case "help", "--help": print(help)
            case "devices": try await devices()
            case "scan":
                let library = await LibraryScanner.scan(root: try options.path("--library"))
                guard library.scanErrors.isEmpty else { throw Failure(library.scanErrors.joined(separator: "\n")) }
                try output(["tracks": library.artists.flatMap(\.albums).flatMap(\.tracks).map { track in
                    ["path": track.url.path, "tags": track.importedTags.values] as [String: Any]
                }])
            default: return try await withDevice(options)
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("mypod: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func deviceID(_ info: DeviceInfo) throws -> String {
        if let uuid = info.uuid, !uuid.isEmpty { return uuid }
        if let uuid = try info.mountpoint.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString { return uuid }
        throw Failure("Device has no stable ID; refusing unattended writes")
    }

    static func devices() async throws {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil) ?? []
        var found: [[String: Any]] = []
        for volume in volumes where FileManager.default.fileExists(atPath: volume.appendingPathComponent("iPod_Control/iTunes/iTunesDB").path) {
            let device = IPodDevice(mountpoint: volume)
            do {
                try await device.open()
                guard let info = await device.deviceInfo() else { throw Failure("Cannot read device at \(volume.path)") }
                found.append(["path": volume.path, "id": try deviceID(info), "model": info.modelName,
                              "tracks": info.trackCount, "supportsArtwork": info.supportsArtwork])
                await device.close()
            } catch { await device.close(); throw error }
        }
        try output(["devices": found])
    }

    static func withDevice(_ options: Options) async throws -> Int32 {
        let mountpoint = try options.path("--device")
        // A directory resembling an iPod is insufficient for an unattended write.
        let volume = try mountpoint.resourceValues(forKeys: [.volumeURLKey]).volume
        guard volume?.standardizedFileURL.resolvingSymlinksInPath() == mountpoint else {
            throw Failure("--device must name the root of a mounted iPod volume")
        }
        guard FileManager.default.fileExists(atPath: mountpoint.appendingPathComponent("iPod_Control/iTunes/iTunesDB").path) else {
            throw Failure("No iPod database at \(mountpoint.path)")
        }
        let device = IPodDevice(mountpoint: mountpoint)
        do {
            try await device.open()
            guard let info = await device.deviceInfo() else { throw Failure("Cannot read device") }
            let id = try deviceID(info)
            if let expected = options.values["--device-id"], expected != id { throw Failure("Device ID does not match; refusing to continue") }
            if options.command != "plan", options.values["--device-id"] == nil { throw Failure("Supply --device-id \(id) to confirm the target device") }
            if options.command == "eject" {
                await device.close()
                try await eject(mountpoint)
                try output(["ejected": mountpoint.path])
                return 0
            }
            let root = try options.path("--library")
            guard root != mountpoint, !root.path.hasPrefix(mountpoint.path + "/"),
                  !mountpoint.path.hasPrefix(root.path + "/") else { throw Failure("Library and iPod must be separate directories") }
            let quality = options.values["--quality"] ?? "aac44"
            guard let ceiling = ConversionCeiling(rawValue: quality) else { throw Failure("Unknown quality: \(quality)") }
            let playlists = try loadPlaylists(options.values["--playlists"])
            let library = await LibraryScanner.scan(root: root)
            guard library.totalTracks > 0 else { throw Failure("Library is empty or unreadable; refusing sync") }
            let free = try FileManager.default.attributesOfFileSystem(forPath: mountpoint.path)[.systemFreeSize] as? NSNumber
            guard let free else { throw Failure("Cannot determine free device capacity") }
            let engine = SyncEngine()
            var interrupted = false
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler {
                    MainActor.assumeIsolated { interrupted = true; engine.cancel() }
                }
                source.resume()
                return source
            }
            defer {
                signals.forEach { $0.cancel() }
                signal(SIGINT, SIG_DFL)
                signal(SIGTERM, SIG_DFL)
            }
            let allPaths = Set(library.artists.flatMap(\.albums).flatMap(\.tracks).map { $0.url.path })
            guard Set(options.excludedPaths).isSubset(of: allPaths) else { throw Failure("An --exclude path was not found in the scanned library") }
            let paths = allPaths.subtracting(options.excludedPaths)
            guard !paths.isEmpty else { throw Failure("No selected source tracks") }
            let database = mountpoint.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
            let modified = try FileManager.default.attributesOfItem(atPath: database.path)[.modificationDate] as? Date
            await engine.plan(libraryRoot: root, library: library, selectedPaths: paths, playlists: playlists,
                device: device, ceiling: ceiling, freeBytes: free.uint64Value,
                allowRemoval: options.flags.contains("--delete"), replacePlaylists: options.values["--playlists"] != nil,
                cacheRoot: options.values["--cache"] != nil ? try options.path("--cache") :
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MyPodCLI"),
                artworkSince: options.flags.contains("--resend-artwork") ? .distantPast : modified)
            guard !interrupted else { await device.close(); return 130 }
            guard case .planned(let plan) = engine.state else {
                if case .failed(let message) = engine.state { throw Failure(message) }
                throw Failure("Planning failed")
            }
            guard plan.playlistChanges.allSatisfy({ $0.unresolvedCount == 0 }) else { throw Failure("An M3U references missing tracks; refusing partial playlists") }
            if options.command == "plan" {
                try output(["deviceID": id, "add": plan.toAdd.map { $0.library.url.path },
                    "remove": plan.toRemove.map { "\($0.artist) — \($0.title)" },
                    "metadataUpdates": plan.metadataUpdates.map { $0.library.url.path },
                    "excluded": options.excludedPaths, "convert": plan.pendingConversion.count, "addedBytes": plan.addedBytes,
                    "artworkUpdates": plan.artworkUpdates.count, "replacePlaylists": options.values["--playlists"] != nil])
                await device.close()
                return 0
            }
            await engine.execute(plan: plan, libraryRoot: root, playlists: playlists, device: device,
                replacePlaylists: options.values["--playlists"] != nil)
            guard case .finished(let outcome) = engine.state else {
                if case .failed(let message) = engine.state { throw Failure(message) }
                throw Failure("Sync did not finish")
            }
            await device.close()
            guard !outcome.cancelled, !interrupted else { return 130 }
            guard outcome.failed == 0, outcome.convertedFailures == 0 else {
                throw Failure("Sync saved with \(outcome.failed) transfer/metadata/playlist/artwork failures and \(outcome.convertedFailures) conversion failures; device was not ejected")
            }
            if options.flags.contains("--eject") { try await eject(mountpoint) }
            try output(["added": outcome.added, "removed": outcome.removed,
                "metadataUpdated": plan.metadataUpdates.count, "tracks": outcome.totalOnDevice,
                "ejected": options.flags.contains("--eject")])
            return 0
        } catch { await device.close(); throw error }
    }

    static func loadPlaylists(_ path: String?) throws -> [Playlist] {
        guard let path else { return [] }
        guard path.hasPrefix("/") else { throw Failure("--playlists requires an absolute directory") }
        let directory = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["m3u", "m3u8"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        let lists = try files.map { url in
            let parsed = try M3UParser.parse(url)
            return Playlist(id: UUID(), name: parsed.name ?? url.deletingPathExtension().lastPathComponent,
                            entries: parsed.entries, fileURL: url)
        }
        guard Set(lists.map(\.nameKey)).count == lists.count else { throw Failure("Duplicate playlist names") }
        return lists
    }

    static func eject(_ volume: URL) async throws {
        try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
    }

    static func output(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
