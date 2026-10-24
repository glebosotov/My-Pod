import Foundation

/// GUI device profiles own artwork baselines and explicit resend queues.
extension ArtworkSync {
    private static var defaults: UserDefaults { .standard }

    private static func baselineKey(_ profile: DeviceProfile) -> String {
        profile.storageKey("artworkSyncedAt")
    }

    private static func queueKey(_ profile: DeviceProfile) -> String {
        profile.storageKey("artworkQueue")
    }

    // MARK: - Baseline

    /// When this device last received artwork, or nil if it has no baseline.
    static func baseline(for profile: DeviceProfile) -> Date? {
        defaults.object(forKey: baselineKey(profile)) as? Date
    }

    /// Record a baseline for a device that has none, without moving one that
    /// already exists.
    ///
    /// Called on every connect, which makes it both the migration for profiles
    /// written before this feature and the starting point for newly-seen iPods.
    /// It has to be *now* rather than `.distantPast`: an iPod already holds
    /// whatever art it holds, and treating every album as changed would push
    /// artwork for the entire library on the first sync after upgrading — slow,
    /// alarming, and impossible to explain.
    static func establishBaseline(for profile: DeviceProfile) {
        guard baseline(for: profile) == nil else { return }
        defaults.set(Date(), forKey: baselineKey(profile))
        Log.artwork.info("artwork baseline set for \"\(profile.displayName)\"")
    }

    /// Send every album's cover again on the next sync.
    ///
    /// The one caller is a device that has just gone from unable to receive
    /// artwork to able — the user identified it. `establishBaseline`'s reasoning
    /// inverts there: an iPod libgpod couldn't name has been restored by
    /// something modern and holds no art at all, and every track already on it
    /// was added while libgpod was silently dropping covers. Left alone, the
    /// sync diff calls those tracks `unchanged` forever and the artwork never
    /// arrives, so identifying the iPod would fix the *next* album and nothing
    /// the user already synced.
    /// `reason` is required rather than defaulted because the two callers reach
    /// here for genuinely different reasons — a device that just became able to
    /// take artwork, and a user who pressed the button — and a line that states
    /// the wrong one is the same kind of misreporting this whole area exists to
    /// stop.
    static func resendEverything(to profile: DeviceProfile, reason: String) {
        defaults.set(Date.distantPast, forKey: baselineKey(profile))
        Log.artwork.info("every album's cover will be sent to \"\(profile.displayName)\" on the next sync — \(reason)")
    }

    static func markSynced(_ profile: DeviceProfile, at date: Date = Date()) {
        defaults.set(date, forKey: baselineKey(profile))
        Log.artwork.debug("artwork baseline for \"\(profile.displayName)\" moved to \(date)")
    }

    // MARK: - Explicit queue

    static func queued(for profile: DeviceProfile) -> Set<String> {
        Set(defaults.stringArray(forKey: queueKey(profile)) ?? [])
    }

    static func enqueue(_ albumID: String, for profile: DeviceProfile) {
        var set = queued(for: profile)
        guard set.insert(albumID).inserted else { return }
        defaults.set(Array(set), forKey: queueKey(profile))
        Log.artwork.info("queued artwork for \"\(albumID)\" on \"\(profile.displayName)\"")
    }

    /// Queue an album's art for the next sync, and report which iPods were told.
    ///
    /// With a device connected, that device. With nothing connected the active
    /// profile is the *default* one, which never syncs — so the instruction goes
    /// to every iPod the app knows, which is what "fix this on my iPod" means
    /// when the iPod isn't plugged in.
    @discardableResult
    static func enqueueForNextSync(albumID: String, store: DeviceProfileStore) -> [String] {
        let targets = store.active.isDefault ? store.devices : [store.active]
        if targets.isEmpty {
            // Not an error: this is a first run, or the user has never plugged
            // an iPod in. The file on disk is still newer than any baseline a
            // future device will be given, so it isn't lost.
            Log.artwork.info("artwork for \"\(albumID)\" not queued — no iPod has been seen yet")
        }
        for profile in targets { enqueue(albumID, for: profile) }
        return targets.map(\.displayName)
    }

    static func clearQueue(for profile: DeviceProfile) {
        let pending = queued(for: profile).count
        defaults.removeObject(forKey: queueKey(profile))
        if pending > 0 {
            Log.artwork.info("cleared \(pending) queued artwork request(s) for \"\(profile.displayName)\"")
        }
    }

    /// Drop both keys when a device is forgotten, so they don't outlive it.
    static func forget(_ profile: DeviceProfile) {
        defaults.removeObject(forKey: baselineKey(profile))
        defaults.removeObject(forKey: queueKey(profile))
    }

}
