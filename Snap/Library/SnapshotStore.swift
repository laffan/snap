//
//  SnapshotStore.swift
//  Snap
//
//  The frames the app leaves behind.
//
//  Backgrounding a camera app freezes its last preview frame on screen; come
//  back an hour later and there it still is, a photograph of wherever you were
//  standing when the phone went in your pocket. Every camera does this and
//  nobody keeps it — the frame is thrown away the moment the session restarts.
//
//  This keeps it. `Documents/Snapshots` holds one JPEG per frame, apart from
//  the roll and never written to the camera roll: these are not photographs
//  anybody took, and they shouldn't turn up in a year's worth of ones that
//  were. They carry their look in EXIF like everything else the app writes,
//  because they were graded on the way to the screen.
//
//  Nothing here has a sidecar. A snapshot is a file and a date, and the date is
//  the one the file system already keeps.
//

import Combine
import Foundation

struct Snapshot: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let date: Date
}

final class SnapshotStore: ObservableObject {

    /// Newest first.
    @Published private(set) var snapshots: [Snapshot] = []

    /// How many are kept. One lands every time the app is put down with the
    /// preview up, which over a month is a great many frames of the inside of a
    /// pocket; past this the oldest go. An experiment shouldn't quietly fill a
    /// phone.
    static let limit = 200

    private let directory: URL
    private let fileManager = FileManager.default
    private static let dateKeys: Set<URLResourceKey> = [.creationDateKey]

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Snapshots", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Reading

    func reload() {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(SnapshotStore.dateKeys)
        )) ?? []

        snapshots = urls
            .filter { $0.pathExtension == "jpg" }
            .compactMap { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
                    return nil
                }
                let created = (try? url.resourceValues(forKeys: SnapshotStore.dateKeys))?.creationDate
                return Snapshot(id: id, url: url, date: created ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Writing

    /// Keeps a frame. Called on the way into the background, where there is no
    /// later to do it in, so it does its work where it stands.
    func add(jpeg: Data) throws {
        let id = UUID()
        try jpeg.write(to: directory.appendingPathComponent("\(id.uuidString).jpg"))
        reload()
        pruneToLimit()
    }

    func delete(_ snapshot: Snapshot) {
        try? fileManager.removeItem(at: snapshot.url)
        reload()
    }

    func deleteAll() {
        for snapshot in snapshots {
            try? fileManager.removeItem(at: snapshot.url)
        }
        reload()
    }

    private func pruneToLimit() {
        guard snapshots.count > SnapshotStore.limit else { return }
        for snapshot in snapshots.dropFirst(SnapshotStore.limit) {
            try? fileManager.removeItem(at: snapshot.url)
        }
        reload()
    }
}
