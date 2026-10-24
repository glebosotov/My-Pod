import Foundation

/// One album whose cover art on disk is newer than what a device holds, or has
/// been pushed by hand.
nonisolated struct ArtworkUpdate: Sendable, Equatable, Identifiable {
    /// `LibraryAlbum.id` — `<artist>/<name>`.
    let albumID: String
    let artist: String
    let album: String
    /// The image libgpod renders thumbnails from. It must still exist when
    /// `save()` runs — `itdb_write` renders lazily — which is free here, unlike
    /// the add path: this file lives in the user's album folder, not a scratch
    /// directory.
    let coverURL: URL
    /// iPod track IDs to attach it to. Every track of the album that's on the
    /// device, since artwork on the iPod is per-track and not per-album.
    let trackIDs: [UInt32]

    var id: String { albumID }
}

/// Decides which albums already on an iPod need their cover art refreshed.
///
/// The problem it exists for: `SyncEngine.plan` treats a track already on the
/// device as `unchanged` and never revisits it, and artwork is only attached
/// inside the add phase. So art acquired *after* an album was synced would never
/// reach the device — the album stays blank, with no error and no way for the
/// user to tell why.
///
/// Two triggers, because neither covers the other's case:
///
/// - **The cover file is newer than the device's baseline.** Catches "I just set
///   the artwork". The timestamp lives on the file, so art replaced in Finder
///   counts exactly like art set through the app, and there's no queue to fall
///   out of step with the filesystem.
/// - **The album was queued explicitly.** Catches "the file on disk is already
///   right, the *iPod* is wrong" — nothing changed, so no date comparison would
///   ever fire.
@MainActor
enum ArtworkSync {
    // MARK: - Planning

    /// Albums the device already holds whose art needs pushing.
    ///
    /// A nil `changedSince` means no baseline was recorded, and the answer is
    /// "nothing" rather than "everything" — see `establishBaseline`. Explicitly
    /// queued albums still go, since those are a direct instruction.
    nonisolated static func updates(
        library: MusicLibrary,
        deviceTracks: [TrackInfo],
        queued: Set<String>,
        changedSince: Date?
    ) -> [ArtworkUpdate] {
        guard !deviceTracks.isEmpty else { return [] }

        // Artwork is per-track on the iPod, so one album maps to as many IDs as
        // it has tracks on the device. Duplicate keys accumulate rather than
        // overwrite — two files that normalize to the same key are two rows in
        // the database, and leaving one of them blank looks like a bug.
        var idsByKey: [TrackKey: [UInt32]] = [:]
        for track in deviceTracks {
            idsByKey[TrackKey(ipod: track), default: []].append(track.id)
        }

        var out: [ArtworkUpdate] = []
        for artist in library.artists {
            for album in artist.albums {
                // Cheapest test first, deliberately. An album the device
                // doesn't hold can't have its artwork refreshed, and this is
                // a dictionary lookup where the two tests below are a directory
                // enumeration and a stat. On a library where only part is
                // synced, most albums exit here and never touch the disk.
                let trackIDs = album.tracks.flatMap { idsByKey[TrackKey(library: $0)] ?? [] }
                guard !trackIDs.isEmpty else { continue }

                guard let cover = ArtworkLocator.imageInDirectory(album.directory) else {
                    if queued.contains(album.id) {
                        // Asked for, but there is no file to send. Only reachable
                        // if the image was deleted between queueing and syncing —
                        // the button that queues is gated on one existing.
                        Log.artwork.warning(
                            "queued artwork for \(album.artist) — \(album.name) has no image file in the folder; skipping"
                        )
                    }
                    continue
                }
                if !queued.contains(album.id) {
                    guard let since = changedSince,
                          let modified = try? cover.resourceValues(
                              forKeys: [.contentModificationDateKey]
                          ).contentModificationDate,
                          modified > since
                    else { continue }
                }
                out.append(ArtworkUpdate(
                    albumID: album.id,
                    artist: album.artist,
                    album: album.name,
                    coverURL: cover,
                    trackIDs: trackIDs
                ))
            }
        }
        return out.sorted {
            $0.artist == $1.artist
                ? $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending
                : $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending
        }
    }

    /// Attach `update`'s cover to every track. Report success only when every
    /// track took it; the caller still has to `save()`.
    ///
    /// Failures are logged and swallowed per track: a single unreadable image or
    /// a track that vanished between plan and execute is not a reason to abandon
    /// a sync that has already mutated the database.
    static func apply(_ update: ArtworkUpdate, to device: IPodDevice) async -> Bool {
        var applied = 0
        Log.artwork.debug(
            "applying \(update.coverURL.lastPathComponent) to \(update.trackIDs.count) track(s) of \(update.artist) — \(update.album)"
        )
        for trackID in update.trackIDs {
            do {
                try await device.setTrackArtwork(trackID: trackID, imagePath: update.coverURL.path)
                applied += 1
            } catch {
                Log.artwork.warning(
                    "artwork failed for \(update.artist) — \(update.album) (track \(trackID)): \(error.localizedDescription)"
                )
            }
        }
        return !update.trackIDs.isEmpty && applied == update.trackIDs.count
    }
}
