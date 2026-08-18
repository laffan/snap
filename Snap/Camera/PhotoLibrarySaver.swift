//
//  PhotoLibrarySaver.swift
//  Snap
//

import Foundation
import Photos
import UniformTypeIdentifiers

/// Writes finished photos to the camera roll.
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

    func save(_ data: Data, type: UTType) async throws {
        try await requestAuthorization()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = type.identifier
            request.addResource(with: .photo, data: data, options: options)
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
