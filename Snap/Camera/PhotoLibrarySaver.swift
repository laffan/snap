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

    /// Saves the graded JPEG, attaching the untouched DNG as the alternate
    /// resource when the capture was RAW. Photos then shows one asset that
    /// still carries the negative, the way any RAW camera app behaves.
    func save(_ jpeg: Data, rawData: Data? = nil) async throws {
        try await requestAuthorization()

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()

            let jpegOptions = PHAssetResourceCreationOptions()
            jpegOptions.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, data: jpeg, options: jpegOptions)

            if let rawData {
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                request.addResource(with: .alternatePhoto, data: rawData, options: rawOptions)
            }
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
