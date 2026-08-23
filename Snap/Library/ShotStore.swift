//
//  ShotStore.swift
//  Snap
//
//  Every photo the app has taken, on disk in the app's Documents directory:
//  one JPEG and one JSON sidecar per shot, sharing a UUID.
//
//  The settings live in the JPEG's EXIF as well. The sidecar is the fast path
//  — listing the strip shouldn't mean opening every image — and EXIF is the
//  durable one, so a file that leaves the app still describes itself.
//
//  A RAW capture keeps its DNG here too, which is what lets the strip share
//  the negative. It also makes the store grow quickly: a DNG runs to tens of
//  megabytes.
//

import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class ShotStore: ObservableObject {

    /// Newest first.
    @Published private(set) var shots: [Shot] = []

    /// The kept frames, in the same order the roll shows them.
    var favorites: [Shot] { shots.filter(\.isFavorite) }

    /// Where the store keeps its files. Not private because the favourites'
    /// backup builds its list of what to copy off the main thread, from file
    /// names and this, rather than by asking the store one URL at a time.
    let directory: URL
    private let fileManager = FileManager.default

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Snaps", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Reading

    func reload() {
        let urls = (try? fileManager.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        shots = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Shot.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func imageURL(for shot: Shot) -> URL {
        directory.appendingPathComponent(shot.imageFileName)
    }

    /// The negative, when the capture was RAW.
    func rawURL(for shot: Shot) -> URL? {
        guard let rawFileName = shot.rawFileName else { return nil }
        let url = directory.appendingPathComponent(rawFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// The Camera Raw sidecar for the negative.
    func xmpURL(for shot: Shot) -> URL? {
        guard let xmpFileName = shot.xmpFileName else { return nil }
        let url = directory.appendingPathComponent(xmpFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Everything that has to travel together for a raw converter to read the
    /// look: the negative first, then its sidecar.
    func negativeURLs(for shot: Shot) -> [URL] {
        [rawURL(for: shot), xmpURL(for: shot)].compactMap { $0 }
    }

    /// The look this shot was taken with. Prefers the sidecar and falls back to
    /// the JPEG's own EXIF, so a shot whose sidecar went missing is still
    /// usable.
    func profile(for shot: Shot) -> PositiveFilmProfile {
        PhotoEncoder.profile(fromImageAt: imageURL(for: shot)) ?? shot.profile
    }

    /// Downsampled on the way in — thumbnails are small and the originals are
    /// full-resolution captures.
    static func image(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    // MARK: - Writing

    /// Records a capture. Safe to call off the main thread — the file work
    /// happens on the caller's thread and only the published list hops back.
    @discardableResult
    func add(imageData: Data,
             rawData: Data?,
             xmp: String?,
             origin: Shot.Origin,
             profile: PositiveFilmProfile) throws -> Shot {
        let id = UUID()
        // Adobe looks for the sidecar under the negative's own base name.
        let shot = Shot(id: id,
                        imageFileName: "\(id.uuidString).jpg",
                        rawFileName: rawData == nil ? nil : "\(id.uuidString).dng",
                        xmpFileName: (rawData == nil || xmp == nil) ? nil : "\(id.uuidString).xmp",
                        origin: origin,
                        profile: profile)

        try imageData.write(to: imageURL(for: shot))
        // Not `rawURL(for:)`/`xmpURL(for:)` — those check for existence, and
        // the files are about to be created.
        if let rawData, let rawFileName = shot.rawFileName {
            try rawData.write(to: directory.appendingPathComponent(rawFileName))
        }
        if let xmp, let xmpFileName = shot.xmpFileName {
            try xmp.write(to: directory.appendingPathComponent(xmpFileName),
                          atomically: true,
                          encoding: .utf8)
        }
        try writeSidecar(shot)
        publishReload()
        return shot
    }

    func update(_ shot: Shot, title: String, caption: String) {
        mutate(shot) {
            $0.title = title
            $0.caption = caption
        }
        embed(caption, in: shot)
    }

    /// The caption from the review screen, under the frame it belongs to.
    func setCaption(_ caption: String, for shot: Shot) {
        mutate(shot) { $0.caption = caption }
        embed(caption, in: shot)
    }

    /// The other half of a caption: the frame's own EXIF, which is what a file
    /// leaving the app carries with it. The sidecar is the fast path the lists
    /// read; this is the durable one, exactly as with the look.
    ///
    /// Off the main thread, because it rewrites a full-resolution JPEG's
    /// metadata — no pixel is re-encoded, but it is still several megabytes
    /// read and written, and a caption is typed while the frame it belongs to
    /// is on screen.
    private func embed(_ caption: String, in shot: Shot) {
        let url = imageURL(for: shot)
        Task.detached(priority: .utility) {
            try? PhotoEncoder.write(caption: caption, toImageAt: url)
        }
    }

    /// Keeps or lets go of a frame. Called from a double tap, so it says what
    /// it did back to the caller for the haptic.
    @discardableResult
    func toggleFavorite(_ shot: Shot) -> Bool {
        let kept = !(storedShot(id: shot.id) ?? shot).isFavorite
        mutate(shot) { $0.isFavorite = kept }
        return kept
    }

    /// Records which camera-roll asset this shot became, once the library has
    /// accepted it — deleting the shot later is what wants it.
    func setAssetIdentifier(_ identifier: String?, for shot: Shot) {
        guard let identifier else { return }
        mutate(shot) { $0.assetIdentifier = identifier }
    }

    func delete(_ shot: Shot) {
        delete([shot])
    }

    /// Several at once, reloading the list once at the end rather than once a
    /// frame — a wall of squares can hand over a dozen in one go.
    func delete(_ shots: [Shot]) {
        guard !shots.isEmpty else { return }
        for shot in shots { removeFiles(for: shot) }
        publishReload()
    }

    /// Everything one shot owns on disk: the frame, its negative, the sidecar
    /// that travels with the negative, and the app's own record of it.
    private func removeFiles(for shot: Shot) {
        try? fileManager.removeItem(at: imageURL(for: shot))
        if let rawURL = rawURL(for: shot) {
            try? fileManager.removeItem(at: rawURL)
        }
        if let xmpURL = xmpURL(for: shot) {
            try? fileManager.removeItem(at: xmpURL)
        }
        try? fileManager.removeItem(at: sidecarURL(for: shot))
    }

    /// Edits a shot's sidecar in place.
    ///
    /// Always starts from what is on disk rather than from the copy the caller
    /// is holding: a view can be showing a `Shot` from before a capture wrote
    /// its asset identifier, and writing that copy back would drop the newer
    /// field.
    private func mutate(_ shot: Shot, _ change: (inout Shot) -> Void) {
        var current = storedShot(id: shot.id) ?? shot
        change(&current)
        try? writeSidecar(current)
        publishReload()
    }

    private func storedShot(id: UUID) -> Shot? {
        let url = directory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Shot.self, from: data)
    }

    private func sidecarURL(for shot: Shot) -> URL {
        directory.appendingPathComponent("\(shot.id.uuidString).json")
    }

    private func writeSidecar(_ shot: Shot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(shot).write(to: sidecarURL(for: shot))
    }

    private func publishReload() {
        if Thread.isMainThread {
            reload()
        } else {
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }
}
