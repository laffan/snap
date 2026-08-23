//
//  FavoritesBackup.swift
//  Snap
//
//  Every kept frame, copied into the folder the user chose.
//
//  The job is small and stated as such: make sure each favourite's files are in
//  that folder. Nothing here syncs, reconciles, or resolves conflicts — the
//  folder belongs to a file provider that already does all of that, and the one
//  useful thing an app can add is putting the files where it can see them.
//
//  It is arranged around a single rule: **none of this may cost anything at
//  launch or at capture.** So nothing runs on the way up, nothing is called
//  from the shutter, and every pass happens on one background queue at utility
//  priority. There are exactly three moments that start one:
//
//  - a frame was just kept, which is the natural moment to copy one file;
//  - the favourites pane opened, which is the one screen that shows any of
//    this and so the one that should be right;
//  - the app came forward, deferred by `settleDelay` and thrown away entirely
//    if the folder was looked at within `checkInterval`.
//
//  What the folder has is *checked* rather than assumed, because the user can
//  reach into it and take things out. A file that was copied and is gone is not
//  a file to quietly put back — that is an app arguing with a person about
//  their own folder — so it raises a warning and waits to be told.
//

import Combine
import Foundation

// MARK: - What a frame is, in the folder

/// The two things a frame is. The negative's sidecar is a third file but not a
/// third thing: apart from the DNG it means nothing, which is why Share RAW
/// sends the two together, so here it travels with the negative and goes
/// missing with it.
enum BackupKind: String, Codable {
    case jpeg
    case raw

    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .raw: return "RAW"
        }
    }
}

/// One kept frame reduced to what copying it needs.
///
/// Plain values only, so a pass can leave the main thread without taking the
/// store with it.
struct BackupItem: Equatable {

    /// One file this frame puts in the folder.
    struct File: Equatable {
        let kind: BackupKind
        let source: URL
        let name: String
    }

    let id: UUID
    let baseName: String
    let jpeg: URL
    let raw: URL?
    let xmp: URL?

    /// What goes across, and what it is called when it gets there.
    ///
    /// The sidecar takes the negative's base name rather than its own, since
    /// Adobe finds one by the other and the two are renamed together or not at
    /// all.
    var files: [File] {
        var files = [File(kind: .jpeg, source: jpeg, name: "\(baseName).jpg")]
        if let raw {
            files.append(File(kind: .raw, source: raw, name: "\(baseName).dng"))
            if let xmp {
                files.append(File(kind: .raw, source: xmp, name: "\(baseName).xmp"))
            }
        }
        return files
    }

    var kinds: [BackupKind] {
        raw == nil ? [.jpeg] : [.jpeg, .raw]
    }

    func names(of kind: BackupKind) -> [String] {
        files.filter { $0.kind == kind }.map(\.name)
    }
}

/// What a pass needs from the roll.
///
/// A type rather than a tuple because the backup reads it through a closure,
/// and a closure that returns a labelled tuple is one that has to be spelled
/// out at every call site to stay unambiguous.
struct BackupSource {
    let favorites: [Shot]
    let directory: URL
}

/// What the folder has of one frame, as the row under a caption says it.
enum BackupState: Equatable {
    /// Nothing known — no folder chosen, or this frame hasn't been reached
    /// yet. Says nothing at all, which is what a list should say before it has
    /// looked.
    case unknown
    /// Queued, or being copied now.
    case copying
    /// Everything this frame has is in the folder.
    case done(kinds: [BackupKind])
    /// It was copied, and it isn't there now. The yellow warning.
    case missing(kinds: [BackupKind])
    /// A copy that didn't finish. Yellow for the same reason: something the
    /// user asked for hasn't happened.
    case failed(reason: String)
}

// MARK: - The record of what was sent

/// A cache rather than a record. The folder is the truth; this is only what
/// spares the app a directory listing to say something it already knew, and
/// what lets it tell "never copied" apart from "copied, then taken out" —
/// which are the two cases that want opposite answers.
private struct BackupLedger: Codable {

    struct Entry: Codable {
        var baseName: String
        var kinds: [BackupKind]
        /// What the last look at the folder found gone, so a warning survives
        /// the app being put down without costing another listing to rebuild.
        var missing: [BackupKind]?
    }

    /// Which folder these entries describe. A different one makes every one of
    /// them meaningless, and wants filling from scratch.
    var folder: String = ""
    /// Shot id, as a string, to what was put in the folder for it.
    var entries: [String: Entry] = [:]
    /// When the folder was last listed, so coming back to the app twice in a
    /// minute doesn't mean two listings.
    var checkedAt: Date?
}

// MARK: - The model

final class FavoritesBackup: ObservableObject {

    /// The folder's name, for the menu. Nil when none is set, which is also
    /// what puts the whole feature away.
    @Published private(set) var folderName: String?

    /// What the folder has, a frame at a time. A frame that isn't in here is
    /// `.unknown`.
    @Published private(set) var states: [UUID: BackupState] = [:]

    /// True while files are going across. The pane says so once, at the top,
    /// rather than a row at a time.
    @Published private(set) var isCopying = false

    /// Where the kept frames come from.
    ///
    /// The backup reads the roll rather than being handed it, so that nothing
    /// else in the app has to remember to keep it informed. Called on the main
    /// thread, where the store lives, and only ever for plain values.
    var source: (() -> BackupSource)?

    /// How long a pass waits after the app comes forward before it goes near a
    /// disk. Nothing here is more urgent than the camera being ready, and the
    /// difference between backing up now and backing up in four seconds is not
    /// a difference anybody can be harmed by.
    private static let settleDelay: TimeInterval = 4

    /// How often the folder is listed without being asked. A file somebody
    /// took out this morning can be reported this afternoon; a folder polled
    /// every time the app comes forward is a file provider woken for nothing.
    private static let checkInterval: TimeInterval = 60 * 60

    /// One queue, serial, below the app's own priority. Every file operation in
    /// this type happens on it and nowhere else.
    private let queue = DispatchQueue(label: "com.laffan.snapsquarecamera.backup",
                                      qos: .utility)
    private let fileManager = FileManager.default
    private let ledgerURL: URL

    /// Read and written on `queue` only.
    private var ledger = BackupLedger()
    private var isLedgerLoaded = false

    /// Main thread only. Set while a deferred pass is waiting, so three
    /// arrivals in the same breath mean one pass.
    private var isDeferredPassWaiting = false

    /// Deliberately does no work. A `UserDefaults` read and a string of path
    /// components — the ledger isn't opened and the bookmark isn't resolved
    /// until something asks for a pass.
    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        ledgerURL = documents.appendingPathComponent("Backup.json")
        folderName = BackupFolder.name
    }

    var isConfigured: Bool { folderName != nil }

    func state(for shot: Shot) -> BackupState {
        states[shot.id] ?? .unknown
    }

    // MARK: - The folder

    /// The picker's answer. Everything kept is new to a folder just chosen, so
    /// this is the one pass that copies the lot.
    func folderChosen(_ url: URL) {
        do {
            try BackupFolder.set(url)
        } catch {
            return
        }
        folderName = BackupFolder.name
        states = [:]
        begin(verify: true, force: nil)
    }

    /// Stops backing up. What is already in the folder stays there: those files
    /// are the user's, in the user's folder, and an app that took them back out
    /// because a setting changed would not be a backup.
    func stop() {
        BackupFolder.clear()
        folderName = nil
        states = [:]
        queue.async { [weak self] in
            guard let self else { return }
            self.ledger = BackupLedger()
            self.isLedgerLoaded = true
            try? self.fileManager.removeItem(at: self.ledgerURL)
        }
    }

    // MARK: - The three moments

    /// A heart went on or off. Copies whatever the folder hasn't got, which
    /// most of the time is the one frame just kept.
    func rollChanged() {
        guard isConfigured else { return }
        begin(verify: false, force: nil)
    }

    /// The favourites pane opened — the one screen any of this is visible on,
    /// and so the one worth a look at the folder.
    func paneOpened() {
        guard isConfigured else { return }
        begin(verify: true, force: nil)
    }

    /// Back Up Now, from the pane's menu. The same pass, asked for rather than
    /// arrived at.
    func checkNow() {
        guard isConfigured else { return }
        begin(verify: true, force: nil)
    }

    /// The app came forward. Waits for the camera to have its moment, and does
    /// nothing at all if the folder was listed within the hour and there is
    /// nothing outstanding to send.
    func resumed() {
        guard isConfigured, !isDeferredPassWaiting, let input = source?() else { return }
        isDeferredPassWaiting = true
        queue.asyncAfter(deadline: .now() + FavoritesBackup.settleDelay) { [weak self] in
            self?.pass(favorites: input.favorites,
                       directory: input.directory,
                       verify: true,
                       force: nil,
                       throttled: true)
        }
    }

    /// Resend, under a yellow warning. The one thing that copies a file the
    /// folder is known to have lost.
    func resend(_ shot: Shot) {
        guard isConfigured else { return }
        states[shot.id] = .copying
        begin(verify: false, force: shot.id)
    }

    private func begin(verify: Bool, force: UUID?) {
        guard let input = source?() else { return }
        queue.async { [weak self] in
            self?.pass(favorites: input.favorites,
                       directory: input.directory,
                       verify: verify,
                       force: force,
                       throttled: false)
        }
    }

    // MARK: - A pass

    /// On `queue`.
    private func pass(favorites: [Shot],
                      directory: URL,
                      verify: Bool,
                      force: UUID?,
                      throttled: Bool) {
        // `throttled` is set by the deferred pass and nothing else, so it is
        // also what says whose flag this is to clear.
        defer { finish(wasDeferred: throttled) }

        let items = FavoritesBackup.items(from: favorites, directory: directory)

        guard BackupFolder.isSet else {
            publish([:])
            return
        }

        loadLedgerIfNeeded()

        let opened = BackupFolder.withFolder { folder -> Bool in
            work(items: items, in: folder, verify: verify, force: force, throttled: throttled)
            return true
        }

        // The bookmark is there and the folder is not: renamed away, signed out
        // of, a provider uninstalled. Worth saying, rather than reporting every
        // frame as safely backed up somewhere unreachable.
        if opened != true {
            publish(Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, BackupState.failed(reason: "Can't reach the folder"))
            }))
        }
    }

    /// One pass over the kept frames, inside an open folder. On `queue`.
    private func work(items: [BackupItem],
                      in folder: URL,
                      verify: Bool,
                      force: UUID?,
                      throttled: Bool) {
        if ledger.folder != folder.path {
            ledger = BackupLedger(folder: folder.path)
        }

        // Nothing kept means nothing to send and nothing to look for, and a
        // listing asked for anyway is a file provider woken for no reason. The
        // ledger still wants emptying: a folder that was filled and then let go
        // stops being watched.
        guard !items.isEmpty else {
            ledger.entries = [:]
            saveLedger()
            publish([:])
            return
        }

        // A frame the folder has never had. The base name is a function of the
        // shot, so an entry filed under a different one belongs to a frame this
        // build would name differently — the same as never having sent it.
        let pending = Set(items.filter { item in
            guard let entry = ledger.entries[item.id.uuidString] else { return true }
            return entry.baseName != item.baseName || item.id == force
        }.map(\.id))

        // Coming back to the app twice in an hour shouldn't mean two listings —
        // but a frame kept while the app was away is waiting, and that is not
        // something to sit on until the hour is up.
        if throttled, pending.isEmpty, let checkedAt = ledger.checkedAt,
           Date().timeIntervalSince(checkedAt) < FavoritesBackup.checkInterval {
            publish(remembered(for: items))
            return
        }

        if !pending.isEmpty { setCopying(true) }

        // One listing is the whole of what checking costs. Asking after each
        // file on its own would be a round trip to the provider per frame per
        // format.
        let present: Set<String>? = verify ? names(in: folder) : nil

        // Seeded with what is already known, so that publishing part-way
        // through a copy doesn't blank the rows underneath it and fill them
        // back in a frame later.
        var result = remembered(for: items)

        for item in items {
            let key = item.id.uuidString

            if pending.contains(item.id) {
                result[item.id] = .copying
                publish(result)
                do {
                    for file in item.files {
                        try copy(file.source, to: folder.appendingPathComponent(file.name))
                    }
                    ledger.entries[key] = BackupLedger.Entry(baseName: item.baseName,
                                                             kinds: item.kinds,
                                                             missing: nil)
                    result[item.id] = .done(kinds: item.kinds)
                } catch {
                    result[item.id] = .failed(reason: FavoritesBackup.reason(for: error))
                }
                // Said as it happens, since a copy is the only part of this
                // that takes any time. The frames that only had to be checked
                // are published together at the end.
                publish(result)
            } else if let present {
                let missing = item.kinds.filter { kind in
                    item.names(of: kind).contains { !present.contains($0) }
                }
                ledger.entries[key]?.missing = missing.isEmpty ? nil : missing
                result[item.id] = missing.isEmpty ? BackupState.done(kinds: item.kinds)
                                                  : BackupState.missing(kinds: missing)
            } else if let entry = ledger.entries[key] {
                result[item.id] = FavoritesBackup.state(from: entry)
            }
        }

        // Frames that stopped being favourites stop being watched. Their files
        // stay where they are, for the same reason Stop leaves the folder
        // alone: letting a frame go is a change of mind about a heart, not an
        // instruction to reach into somebody's folder.
        let kept = Set(items.map { $0.id.uuidString })
        ledger.entries = ledger.entries.filter { kept.contains($0.key) }
        if verify { ledger.checkedAt = Date() }
        saveLedger()

        publish(result)
    }

    // MARK: - Files

    /// Copies one file into the folder, replacing whatever is under that name.
    ///
    /// Through `NSFileCoordinator` rather than `FileManager` alone: the folder
    /// belongs to a provider that is syncing it, and a write it doesn't know
    /// about is a write it can race.
    private func copy(_ original: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?

        NSFileCoordinator().coordinate(writingItemAt: destination,
                                       options: .forReplacing,
                                       error: &coordinationError) { url in
            do {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
                try fileManager.copyItem(at: original, to: url)
            } catch {
                writeError = error
            }
        }

        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func names(in folder: URL) -> Set<String> {
        let urls = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )) ?? []
        return Set(urls.map { BackupFolder.visibleName(of: $0) })
    }

    // MARK: - The ledger

    private func loadLedgerIfNeeded() {
        guard !isLedgerLoaded else { return }
        isLedgerLoaded = true

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // If it doesn't decode, nothing is lost that the folder can't say
        // again: an empty ledger means one listing and a few copies.
        guard let data = try? Data(contentsOf: ledgerURL),
              let decoded = try? decoder.decode(BackupLedger.self, from: data) else { return }
        ledger = decoded
    }

    private func saveLedger() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(ledger).write(to: ledgerURL)
    }

    /// What the ledger already knows, without going near the folder.
    private func remembered(for items: [BackupItem]) -> [UUID: BackupState] {
        var states: [UUID: BackupState] = [:]
        for item in items {
            guard let entry = ledger.entries[item.id.uuidString] else { continue }
            states[item.id] = FavoritesBackup.state(from: entry)
        }
        return states
    }

    private static func state(from entry: BackupLedger.Entry) -> BackupState {
        if let missing = entry.missing, !missing.isEmpty {
            return .missing(kinds: missing)
        }
        return .done(kinds: entry.kinds)
    }

    // MARK: - Back to the main thread

    private func publish(_ states: [UUID: BackupState]) {
        DispatchQueue.main.async { [weak self] in
            self?.states = states
        }
    }

    private func setCopying(_ copying: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isCopying = copying
        }
    }

    private func finish(wasDeferred: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isCopying = false
            if wasDeferred { self?.isDeferredPassWaiting = false }
        }
    }

    // MARK: - Naming

    /// The kept frames as plain values.
    ///
    /// String work only — no file is opened and nothing is stat'd — so it costs
    /// the same wherever it is called from.
    static func items(from favorites: [Shot], directory: URL) -> [BackupItem] {
        favorites.map { shot in
            BackupItem(id: shot.id,
                       baseName: baseName(for: shot),
                       jpeg: directory.appendingPathComponent(shot.imageFileName),
                       raw: shot.rawFileName.map { directory.appendingPathComponent($0) },
                       xmp: shot.xmpFileName.map { directory.appendingPathComponent($0) })
        }
    }

    /// What a frame is called in the folder.
    ///
    /// The store names its files by UUID, which is the right name for a file
    /// nobody is going to look at and the wrong one for a folder somebody
    /// opens. This reads as a date and sorts as one, with the head of the UUID
    /// after it so that two frames taken in the same second stay two files —
    /// and so that the name is a function of the shot, which is what lets a
    /// re-favourited frame recognise its own copy rather than send a second.
    static func baseName(for shot: Shot) -> String {
        let stamp = fileDateFormatter.string(from: shot.createdAt)
        return "Snap-\(stamp)-\(shot.id.uuidString.prefix(8))"
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed rather than localised: this names a file, and a file name
        // shouldn't change with the phone's region.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Short enough for the one line there is under a caption.
    private static func reason(for error: Error) -> String {
        switch (error as NSError).code {
        case NSFileWriteOutOfSpaceError: return "The folder is full"
        case NSFileWriteNoPermissionError: return "No permission to write there"
        default: return "Couldn't copy"
        }
    }
}
