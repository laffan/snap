//
//  CameraModel.swift
//  Snap
//
//  Owns the capture session, feeds graded frames to the preview, and turns a
//  shutter press into a square, graded file in the camera roll.
//

import AVFoundation
import CoreImage
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class CameraModel: NSObject, ObservableObject {

    enum State: Equatable {
        case starting
        case running
        case denied
        case failed(String)
    }

    // MARK: - Published state

    @Published private(set) var state: State = .starting
    @Published private(set) var isCapturing = false
    @Published private(set) var isShutterFlashing = false
    @Published var errorMessage: String? = nil

    /// Set when a capture that asked to be named completes; drives the save
    /// sheet.
    @Published var pendingTitle: Shot? = nil

    let renderer = PreviewRenderer()

    // MARK: - Capture plumbing

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    private let sessionQueue = DispatchQueue(label: "com.snap.session")
    private let videoQueue = DispatchQueue(label: "com.snap.video", qos: .userInitiated)

    /// The live look. Owned here, observed by the filter panel.
    let look = LookModel()

    /// Everything the app has shot. Every capture lands here as well as in the
    /// camera roll, which is what the film strip reads from.
    let store = ShotStore()

    /// Whether the capture in flight should end at the naming sheet.
    /// Only one capture runs at a time (`isCapturing` guards it), so a single
    /// slot is enough.
    private var wantsTitle = false
    /// The profile as it stood when the shutter fired, so later slider moves
    /// can't change what gets written.
    private var capturedProfile = PositiveFilmProfile()
    private let stillContext = CIContext(options: [.cacheIntermediates: false])
    private let library = PhotoLibrarySaver()

    /// Frames are graded at roughly display resolution rather than sensor
    /// resolution. The clarity pass is the expensive stage and its radius is
    /// relative to the image, so downscaling first costs nothing in fidelity.
    private let previewEdge: CGFloat = 1080

    private var isConfigured = false

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                granted ? self.configureAndRun() : self.setState(.denied)
            }
        default:
            setState(.denied)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
        renderer.clear()
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    self.setState(.failed(error.localizedDescription))
                    return
                }
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            self.setState(.running)
        }
    }

    private enum SetupError: LocalizedError {
        case noCamera
        case cannotAddInput
        case cannotAddOutput

        var errorDescription: String? {
            switch self {
            case .noCamera:        return "No camera is available on this device."
            case .cannotAddInput:  return "The camera could not be opened."
            case .cannotAddOutput: return "The camera could not be configured."
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw SetupError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else { throw SetupError.cannotAddOutput }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        // Don't assume the list is sorted — pick the largest by pixel count.
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }) {
            photoOutput.maxPhotoDimensions = dimensions
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { throw SetupError.cannotAddOutput }
        session.addOutput(videoOutput)

        // Snap is portrait-only, so both outputs are pinned upright.
        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    // MARK: - Capture

    /// Takes a photo. Every capture is written as a JPEG carrying its own
    /// settings in EXIF, saved to the camera roll, and recorded in the store.
    /// `titled` only decides whether the naming sheet follows.
    func capture(titled: Bool = false) {
        guard state == .running, !isCapturing else { return }
        isCapturing = true
        wantsTitle = titled
        capturedProfile = look.profile

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashShutter()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func flashShutter() {
        withAnimation(.easeIn(duration: 0.06)) { isShutterFlashing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            withAnimation(.easeOut(duration: 0.18)) { self?.isShutterFlashing = false }
        }
    }

    // MARK: - Helpers

    private func setState(_ newState: State) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }

    private func finishCapture(error: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            if let error {
                self?.errorMessage = error
            }
        }
    }
}

// MARK: - Live preview

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var image = CIImage(cvPixelBuffer: pixelBuffer).centerSquareCropped()

        // Grade at preview resolution, never larger.
        let edge = image.extent.width
        if edge > previewEdge {
            let scale = previewEdge / edge
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        renderer.setImage(look.filter.apply(to: image))
    }
}

// MARK: - Still capture

extension CameraModel: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error {
            finishCapture(error: error.localizedDescription)
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let raw = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            finishCapture(error: "The photo could not be read.")
            return
        }

        // Same crop, same look, same order as the preview — just at full size,
        // and always through a full-resolution LUT even if the preview was
        // running on a draft one mid-drag.
        let profile = capturedProfile
        let graded = look.finalFilter(for: profile).apply(to: raw.centerSquareCropped())
        let sourceMetadata = photo.metadata
        let wantsTitle = self.wantsTitle

        Task { [weak self] in
            guard let self else { return }
            do {
                let jpeg = try PhotoEncoder.jpeg(from: graded,
                                                 profile: profile,
                                                 sourceMetadata: sourceMetadata,
                                                 context: self.stillContext)

                let shot = try self.store.add(imageData: jpeg, profile: profile)
                try await self.library.save(jpeg, type: .jpeg)

                if wantsTitle {
                    await MainActor.run { self.pendingTitle = shot }
                }
                self.finishCapture(error: nil)
            } catch {
                self.finishCapture(error: error.localizedDescription)
            }
        }
    }
}
