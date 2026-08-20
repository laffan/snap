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
//  the negative and puts it in the bundle. It also makes the store grow
//  quickly: a DNG runs to tens of megabytes.
//

import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class ShotStore: ObservableObject {

    /// Newest first.
    @Published private(set) var shots: [Shot] = []

    private let directory: URL
    private let fileManager = FileManager.default

    enum StoreError: LocalizedError {
        case nothingToBundle
        case bundleFailed

        var errorDescription: String? {
            switch self {
            case .nothingToBundle: return "There's nothing saved to bundle yet."
            case .bundleFailed:    return "The bundle could not be created."
            }
        }
    }

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

    func update(_ shot: Shot, title: String, notes: String) {
        var updated = shot
        updated.title = title
        updated.notes = notes
        try? writeSidecar(updated)
        publishReload()
    }

    func delete(_ shot: Shot) {
        try? fileManager.removeItem(at: imageURL(for: shot))
        if let rawURL = rawURL(for: shot) {
            try? fileManager.removeItem(at: rawURL)
        }
        if let xmpURL = xmpURL(for: shot) {
            try? fileManager.removeItem(at: xmpURL)
        }
        try? fileManager.removeItem(at: sidecarURL(for: shot))
        publishReload()
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

    // MARK: - Bundling

    /// Zips the whole store.
    ///
    /// `NSFileCoordinator`'s `.forUploading` option hands back a zip of a
    /// directory, which avoids taking on an archiving dependency for one
    /// button. The archive it produces is temporary, so it gets copied out
    /// before the accessor block returns.
    func makeBundle() throws -> URL {
        guard !shots.isEmpty else { throw StoreError.nothingToBundle }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let destination = fileManager.temporaryDirectory
            .appendingPathComponent("Snap-\(formatter.string(from: Date())).zip")

        var accessorResult: Result<URL, Error>?
        var coordinatorError: NSError?

        NSFileCoordinator().coordinate(readingItemAt: directory,
                                       options: [.forUploading],
                                       error: &coordinatorError) { zipURL in
            do {
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: zipURL, to: destination)
                accessorResult = .success(destination)
            } catch {
                accessorResult = .failure(error)
            }
        }

        if let coordinatorError { throw coordinatorError }
        guard let accessorResult else { throw StoreError.bundleFailed }
        return try accessorResult.get()
    }
}
