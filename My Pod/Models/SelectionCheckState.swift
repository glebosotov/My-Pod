/// Whether a row is fully checked, unchecked, or partially checked because
/// only some of what it contains is. Shared by the library tree (artists and
/// albums) and the playlist list, which is why it isn't nested in either
/// store — `MusicLibraryStore.CheckState` is a typealias onto this.
enum SelectionCheckState: Equatable { case off, on, mixed }
