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

    /// Set once the session is configured: true when the sensor can hand us
    /// Bayer RAW.
    @Published private(set) var isRAWAvailable = false

    /// What could actually be written into the last negative. Nil until a RAW
    /// capture has been taken.
    @Published private(set) var negativeStatus: NegativeStatus? = nil

    struct NegativeStatus {
        /// The square was written into the DNG's own default-crop rectangle,
        /// so every converter sees it — not just the ones that read XMP.
        var croppedInFile: Bool
        /// The Camera Raw settings were embedded in the DNG. Adobe stores
        /// settings inside a DNG rather than beside it, so this is what makes
        /// the look travel reliably.
        var settingsEmbedded: Bool
    }

    /// The Bayer format to ask for, resolved at configuration time.
    private var rawPixelFormat: OSType?

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
                    // Only meaningful once the configuration is committed,
                    // which the `defer` in configureSession has just done.
                    self.resolveRAWSupport()
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

    /// Bayer RAW rather than Apple ProRAW: ProRAW is already demosaiced and
    /// carries Apple's rendering, which is the thing we are trying to step
    /// around. `isAppleProRAWEnabled` stays off so this list stays Bayer.
    private func resolveRAWSupport() {
        let bayerFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
        }
        rawPixelFormat = bayerFormat
        DispatchQueue.main.async { [weak self] in
            self?.isRAWAvailable = bayerFormat != nil
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
            self.photoOutput.capturePhoto(with: self.makeSettings(), delegate: self)
        }
    }

    /// Asks for sensor data and nothing else.
    ///
    /// `processedFormat: nil` means AVFoundation produces no JPEG at all — the
    /// capture is the negative, and the JPEG is something Snap derives from it
    /// afterwards. The processed path below is only for cameras that can't
    /// deliver Bayer RAW.
    private func makeSettings() -> AVCapturePhotoSettings {
        if let rawPixelFormat {
            return AVCapturePhotoSettings(rawPixelFormatType: rawPixelFormat,
                                          processedFormat: nil)
        }

        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        return settings
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

        guard let data = photo.fileDataRepresentation() else {
            finishCapture(error: "The photo could not be read.")
            return
        }

        let profile = capturedProfile
        let sourceMetadata = photo.metadata
        let isRAW = photo.isRawPhoto
        let wantsTitle = self.wantsTitle

        Task { [weak self] in
            guard let self else { return }
            do {
                // A RAW capture is demosaiced here rather than by Apple, so the
                // look lands on sensor data instead of on their finished JPEG.
                let upright: CIImage
                if isRAW {
                    upright = try RAWDeveloper.develop(
                        dngData: data,
                        profile: profile,
                        orientation: RAWDeveloper.orientation(from: sourceMetadata)
                    )
                } else {
                    guard let decoded = CIImage(data: data,
                                                options: [.applyOrientationProperty: true]) else {
                        throw RAWDeveloper.DevelopError.undecodable
                    }
                    upright = decoded
                }

                // Same crop, same look, same order as the preview — just at
                // full size, and always through a full-resolution LUT even if
                // the preview was running on a draft one mid-drag.
                let graded = self.look.finalFilter(for: profile)
                    .apply(to: upright.centerSquareCropped())

                let jpeg = try PhotoEncoder.jpeg(from: graded,
                                                 profile: profile,
                                                 sourceMetadata: sourceMetadata,
                                                 context: self.stillContext)

                // The negative is kept in the app's store, where the strip can
                // share it and the bundle can carry it. Only the graded frame
                // goes to the camera roll.
                var negative: Data?
                var xmp: String?

                if isRAW {
                    // Square the file itself first — that narrows its
                    // default-crop rectangle without moving a pixel, and holds
                    // in every converter. If iOS won't author the container,
                    // the same rectangle travels in the XMP instead. Only ever
                    // one of the two, or the frame would be cropped twice.
                    let squared = RAWCropper.squareCropped(data)
                    let cropInXMP = squared == nil ? RAWCropper.squareCropFractions(data) : nil
                    let settings = CameraRawSidecar.xmp(for: profile, crop: cropInXMP)

                    // Adobe keeps develop settings inside a DNG rather than
                    // beside it, so embedding is what actually makes the look
                    // travel. The sidecar is written either way as a fallback.
                    let embedded = RAWCropper.embedding(settings, into: squared ?? data)
                    negative = embedded ?? squared ?? data
                    xmp = settings

                    let status = NegativeStatus(croppedInFile: squared != nil,
                                                settingsEmbedded: embedded != nil)
                    await MainActor.run { self.negativeStatus = status }
                }

                let shot = try self.store.add(imageData: jpeg,
                                              rawData: negative,
                                              xmp: xmp,
                                              profile: profile)
                try await self.library.save(jpeg)

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
