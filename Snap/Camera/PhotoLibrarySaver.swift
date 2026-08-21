//
//  PhotoLibrarySaver.swift
//  Snap
//

import Foundation
import Photos
import UniformTypeIdentifiers

/// Writes finished photos to the camera roll, and takes them back out again.
///
/// Only the graded JPEG goes here. The negative from a RAW capture stays in
/// the app's own store, where the strip can share it, rather than being
/// attached to the asset as an alternate resource — `PHAssetCreationRequest`
/// will not accept a RAW alternate as raw bytes, and duplicating tens of
/// megabytes per shot to work around that isn't worth it.
struct PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case notAuthorized
        case notAuthorizedToDelete

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Snap needs permission to add photos to your library."
            case .notAuthorizedToDelete:
                return "Snap needs permission to your photo library to remove a photo from it."
            }
        }
    }

    /// Saves the frame and hands back the camera roll's own name for it, so a
    /// later delete can find the asset again. Nil if the library declined to
    /// name it, which leaves the shot deletable here and nowhere else.
    @discardableResult
    func save(_ jpeg: Data) async throws -> String? {
        try await requestAuthorization(for: .addOnly)

        // The placeholder is only valid inside the change block, so its
        // identifier is carried out in a box rather than returned from it.
        let created = Placeholder()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, data: jpeg, options: options)
            created.identifier = request.placeholderForCreatedAsset?.localIdentifier
        }

        return created.identifier
    }

    /// Removes the asset a shot became, so deleting a frame in Snap deletes
    /// the photograph rather than only the app's copy of it.
    ///
    /// iOS puts its own confirmation in front of this, and declining it throws
    /// — which is a decision rather than a failure, so the caller treats it as
    /// one. Adding photos only needs `.addOnly`; removing one needs the whole
    /// library, since it means reaching an asset rather than making one.
    func delete(assetIdentifier: String) async throws {
        try await requestAuthorization(for: .readWrite)

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        // Already gone — deleted from Photos, or never made it there.
        guard assets.count > 0 else { return }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    private func requestAuthorization(for level: PHAccessLevel) async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: level)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: level)
            : current

        switch status {
        case .authorized, .limited:
            return
        default:
            throw level == .addOnly ? SaveError.notAuthorized : SaveError.notAuthorizedToDelete
        }
    }
}

/// A reference the change block can write the new asset's name into.
private final class Placeholder {
    var identifier: String?
}
