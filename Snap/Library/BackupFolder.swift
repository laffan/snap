//
//  BackupFolder.swift
//  Snap
//
//  The folder the user picked, and how the app gets back into it.
//
//  Snap does not sync anything. It copies files into a folder somebody chose
//  with the system picker — iCloud Drive, Dropbox, Google Drive, anything with
//  a file provider behind it — and whatever owns that folder does the carrying.
//  That is the whole of the arrangement: one directory, and iOS handles the
//  rest.
//

import Foundation

enum BackupFolder {

    /// The picker hands over a URL that stops working the moment the app is
    /// relaunched, so what is kept is a bookmark rather than a path — the one
    /// thing that survives the folder being renamed, moved, or handed to a
    /// different provider.
    private static let bookmarkKey = "backupFolderBookmark"
    private static let nameKey = "backupFolderName"

    /// What to call the folder in the menu.
    ///
    /// Remembered separately rather than read back off the bookmark, because
    /// reading the bookmark means resolving it, and resolving it can go out to
    /// a file provider. The menu should be able to say where things are going
    /// without touching a disk.
    static var name: String? {
        UserDefaults.standard.string(forKey: nameKey)
    }

    static var isSet: Bool {
        UserDefaults.standard.data(forKey: bookmarkKey) != nil
    }

    /// Records the folder the picker returned.
    static func set(_ url: URL) throws {
        // The picker's URL arrives security-scoped, and a bookmark made from
        // one inside its own scope is security-scoped too. There is no option
        // to ask for that here: `.withSecurityScope` is a macOS spelling and
        // throws on iOS.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let bookmark = try url.bookmarkData()
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(url.lastPathComponent, forKey: nameKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)
    }

    /// Opens the folder, hands it to `body`, and closes it again. Nil when
    /// there is no folder, or when the bookmark no longer resolves to one.
    ///
    /// The scope is held for exactly as long as the work takes. Holding one
    /// open across the life of the app would be one dropped `stop` away from
    /// leaking the only handle there is, and none of this is urgent enough to
    /// be worth that.
    static func withFolder<T>(_ body: (URL) throws -> T) rethrows -> T? {
        guard let url = resolve() else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return try body(url)
    }

    /// What a file in the folder is called, with iCloud's placeholder spelling
    /// undone.
    ///
    /// A file that is in the folder but not on this phone is listed as
    /// `.name.jpg.icloud`. It is still there — it is the backup working, not
    /// the backup failing — and a check that called it missing would be exactly
    /// wrong.
    static func visibleName(of url: URL) -> String {
        var name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return name }
        name.removeFirst()
        name.removeLast(".icloud".count)
        return name
    }

    /// Resolves the bookmark. Off the main thread — this can go out to a file
    /// provider, and a provider can be slow or asleep.
    private static func resolve() -> URL? {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }

        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 bookmarkDataIsStale: &isStale) else { return nil }

        // A stale bookmark still resolves; it just won't next time. Rewriting
        // it here is what keeps a folder that moved from quietly becoming one
        // the app can no longer find.
        if isStale {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData() {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
            }
        }

        return url
    }
}
