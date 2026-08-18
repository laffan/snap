//
//  PresetStore.swift
//  Snap
//
//  Saved looks live as plain files in the app's Documents directory: one JSON
//  and one image per entry, sharing a UUID. Flat and boring on purpose — it
//  means "Bundle" is just a zip of the folder, and the archive is readable by
//  anything.
//

import Combine
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

final class PresetStore: ObservableObject {

    @Published private(set) var presets: [Preset] = []

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

        let loaded = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Preset? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Preset.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }

        presets = loaded
    }

    func imageURL(for preset: Preset) -> URL {
        directory.appendingPathComponent(preset.imageFileName)
    }

    /// Downsampled on the way in — the cards are small and the originals are
    /// full-resolution captures.
    static func thumbnail(at url: URL, maxPixelSize: CGFloat) -> UIImage? {
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

    @discardableResult
    func save(profile: PositiveFilmProfile,
              title: String,
              notes: String,
              imageData: Data,
              imageType: UTType) throws -> Preset {
        let id = UUID()
        let imageExtension = imageType.preferredFilenameExtension ?? "jpg"
        let preset = Preset(id: id,
                            title: title,
                            notes: notes,
                            imageFileName: "\(id.uuidString).\(imageExtension)",
                            profile: profile)

        try imageData.write(to: directory.appendingPathComponent(preset.imageFileName))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(preset).write(to: directory.appendingPathComponent("\(id.uuidString).json"))

        reload()
        return preset
    }

    func delete(_ preset: Preset) {
        try? fileManager.removeItem(at: imageURL(for: preset))
        try? fileManager.removeItem(at: directory.appendingPathComponent("\(preset.id.uuidString).json"))
        reload()
    }

    // MARK: - Bundling

    /// Zips the whole store.
    ///
    /// `NSFileCoordinator`'s `.forUploading` option hands back a zip of a
    /// directory, which avoids taking on an archiving dependency for one
    /// button. The archive it produces is temporary, so it gets copied out
    /// before the accessor block returns.
    func makeBundle() throws -> URL {
        guard !presets.isEmpty else { throw StoreError.nothingToBundle }

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
