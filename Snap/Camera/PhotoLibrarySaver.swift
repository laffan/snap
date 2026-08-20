//
//  PhotoLibrarySaver.swift
//  Snap
//

import Foundation
import Photos
import UniformTypeIdentifiers

/// Writes finished photos to the camera roll.
///
/// Only the graded JPEG goes here. The negative from a RAW capture stays in
/// the app's own store, where the strip can share it, rather than being
/// attached to the asset as an alternate resource — `PHAssetCreationRequest`
/// will not accept a RAW alternate as raw bytes, and duplicating tens of
/// megabytes per shot to work around that isn't worth it.
struct PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Snap needs permission to add photos to your library."
            }
        }
    }

    func save(_ jpeg: Data) async throws {
        try await requestAuthorization()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, data: jpeg, options: options)
        }
    }

    private func requestAuthorization() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : current

        switch status {
        case .authorized, .limited:
            return
        default:
            throw SaveError.notAuthorized
        }
    }
}
