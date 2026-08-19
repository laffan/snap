//
//  CameraModel.swift
//  Snap
//
//  Owns the capture session, feeds graded frames to the preview, and turns a
//  shutter press into a square, graded file in the camera roll.
//

import AVFoundation
import Combine
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

    /// The lenses this device offers, and the one in use.
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var currentLens: Lens?

    struct Lens: Identifiable, Equatable {
        var id: String { deviceType.rawValue }
        var deviceType: AVCaptureDevice.DeviceType
        var name: String
    }

    /// A stored negative being re-filtered in place of the live camera.
    @Published private(set) var versionSource: Shot? = nil

    /// The source developed once at preview size. Re-grading it is cheap;
    /// re-developing it is not, so it is only redone when a setting that feeds
    /// the RAW pipeline itself changes.
    private var developedSource: CIImage?
    private var developedBoost: Float?

    /// True while the viewer is being held during a re-filter, which shows the
    /// developed negative with no look on it.
    @Published private(set) var isPeekingSource = false
    private var lookRevisionObserver: AnyCancellable?

    /// Mirrors `versionSource != nil` for the capture queue, which reads it on
    /// every frame and must not touch main-thread published state.
    private let versionLock = NSLock()
    private var isVersioning = false

    private let developQueue = DispatchQueue(label: "com.snap.develop", qos: .userInitiated)

    /// True while focus and exposure are pinned to a point rather than
    /// roaming.
    @Published private(set) var isFocusLocked = false

    /// The portrait frame size as delivered, needed to turn a point on screen
    /// into one the device understands. Written on the capture queue.
    private let frameLock = NSLock()
    private var portraitFrameSize: CGSize = .zero

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?

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

    override init() {
        super.init()
        lookRevisionObserver = look.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVersionPreview() }
    }

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
                    self.discoverLenses()
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
        videoDevice = device
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw SetupError.cannotAddInput }
        session.addInput(input)
        videoInput = input

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

        applyRotation()
    }

    /// Snap is portrait-only, so both outputs are pinned upright. Re-applied
    /// after a lens change, since swapping the input rebuilds the connections.
    private func applyRotation() {
        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    // MARK: - Lenses

    private static let lensNames: [AVCaptureDevice.DeviceType: String] = [
        .builtInUltraWideCamera: "Ultra Wide",
        .builtInWideAngleCamera: "Wide",
        .builtInTelephotoCamera: "Telephoto",
    ]

    private func discoverLenses() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: Array(CameraModel.lensNames.keys),
            mediaType: .video,
            position: .back
        )

        // Widest first, which is the order they sit on the phone.
        let order: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera,
        ]
        let found = order.compactMap { type -> Lens? in
            guard discovery.devices.contains(where: { $0.deviceType == type }),
                  let name = CameraModel.lensNames[type] else { return nil }
            return Lens(deviceType: type, name: name)
        }

        let active = videoDevice.flatMap { device in
            found.first { $0.deviceType == device.deviceType }
        }
        DispatchQueue.main.async { [weak self] in
            self?.lenses = found
            self?.currentLens = active
        }
    }

    /// Swaps the session's input. RAW support is per-lens, so it is resolved
    /// again afterwards rather than carried over.
    func selectLens(_ lens: Lens) {
        guard lens != currentLens else { return }

        sessionQueue.async { [weak self] in
            guard let self,
                  let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
                  let existing = self.videoInput else { return }

            self.session.beginConfiguration()
            self.session.removeInput(existing)

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw SetupError.cannotAddInput }
                self.session.addInput(input)
                self.videoInput = input
                self.videoDevice = device
            } catch {
                // Put the working lens back rather than leaving no input at all.
                self.session.addInput(existing)
                self.session.commitConfiguration()
                return
            }

            self.applyRotation()
            self.session.commitConfiguration()

            self.resolveRAWSupport()
            self.discoverLenses()
            DispatchQueue.main.async { self.releaseFocus() }
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

    // MARK: - Focus

    /// Pins focus and exposure to a point, given in the displayed square's own
    /// normalised coordinates: x right, y down, 0...1.
    func lockFocus(at point: CGPoint) {
        let target = devicePoint(from: point)
        isFocusLocked = true

        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                    device.focusPointOfInterest = target
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                    device.exposurePointOfInterest = target
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {
                // Another configuration holds the lock; the next tap retries.
            }
        }
    }

    func releaseFocus() {
        guard isFocusLocked else { return }
        isFocusLocked = false

        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                let centre = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = centre
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported,
                   device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = centre
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {
            }
        }
    }

    /// Turns a point on the square preview into one `focusPointOfInterest`
    /// understands.
    ///
    /// Two conversions stack. The square is a centred crop of the portrait
    /// frame, so the point first has to be placed back into the whole frame.
    /// Then the device wants it in the sensor's own landscape frame — (0,0) at
    /// the top left with the device in landscape, home button right — which is
    /// a quarter turn away from what the viewer shows.
    private func devicePoint(from point: CGPoint) -> CGPoint {
        frameLock.lock()
        let size = portraitFrameSize
        frameLock.unlock()

        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }

        let edge = min(size.width, size.height)
        let inFrame = CGPoint(x: (point.x * edge + (size.width - edge) / 2) / size.width,
                              y: (point.y * edge + (size.height - edge) / 2) / size.height)

        return CGPoint(x: inFrame.y, y: 1 - inFrame.x)
    }

    // MARK: - Re-filtering a stored negative

    /// Puts a stored negative under the sliders in place of the live camera.
    func beginVersioning(from shot: Shot) {
        guard let rawURL = store.rawURL(for: shot) else { return }
        versionSource = shot
        setVersioning(true)
        developSource(at: rawURL)
    }

    func endVersioning() {
        versionSource = nil
        developedSource = nil
        developedBoost = nil
        isPeekingSource = false
        setVersioning(false)
        renderer.clear()
    }

    /// The same peek the saved-frame viewer offers, for a negative under the
    /// sliders: the ungraded development is already in hand, so showing it is
    /// just a matter of pushing that to the renderer instead.
    func setPeekingSource(_ peeking: Bool) {
        guard versionSource != nil, peeking != isPeekingSource else { return }
        isPeekingSource = peeking
        refreshVersionPreview()
    }

    private func setVersioning(_ versioning: Bool) {
        versionLock.lock()
        isVersioning = versioning
        versionLock.unlock()
    }

    private func developSource(at url: URL) {
        let profile = look.profile
        let edge = previewEdge

        developQueue.async { [weak self] in
            let developed = RAWDeveloper.developedImage(at: url,
                                                        profile: profile,
                                                        maxPixelSize: edge)
            DispatchQueue.main.async {
                guard let self, self.versionSource != nil else { return }
                self.developedSource = developed
                self.developedBoost = profile.rawBoost
                self.refreshVersionPreview()
            }
        }
    }

    /// Redraws the negative under the current look. Applying a filter to a
    /// CIImage only composes a recipe — the work happens when Metal draws — so
    /// this is cheap enough to run on every slider tick.
    private func refreshVersionPreview() {
        guard let versionSource, let developedSource else { return }

        // Everything except the RAW pipeline's own tone curve can be re-graded
        // off the developed image; changing that means demosaicing again.
        if developedBoost != look.profile.rawBoost, let url = store.rawURL(for: versionSource) {
            developSource(at: url)
            return
        }

        if isPeekingSource {
            renderer.setImage(look.profile.blackAndWhite
                              ? RAWDeveloper.desaturated(developedSource)
                              : developedSource)
        } else {
            renderer.setImage(look.filter.apply(to: developedSource))
        }
    }

    /// Runs the capture pipeline over the selected negative instead of the
    /// sensor: develop, crop, grade, encode, and store as a new shot with its
    /// own settings.
    func captureVersion(titled: Bool = false) {
        guard let shot = versionSource,
              let rawURL = store.rawURL(for: shot),
              !isCapturing else { return }

        isCapturing = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashShutter()

        let profile = look.profile
        let wantsTitle = titled

        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: rawURL)
                let properties = RAWDeveloper.properties(of: data)

                let upright = try RAWDeveloper.develop(
                    dngData: data,
                    profile: profile,
                    orientation: RAWDeveloper.orientation(from: properties)
                )
                let graded = self.look.finalFilter(for: profile)
                    .apply(to: upright.centerSquareCropped())

                let jpeg = try PhotoEncoder.jpeg(from: graded,
                                                 profile: profile,
                                                 sourceMetadata: properties,
                                                 context: self.stillContext)

                let negative = self.prepareNegative(data, profile: profile)

                let version = try self.store.add(imageData: jpeg,
                                                 rawData: negative.data,
                                                 xmp: negative.xmp,
                                                 profile: profile)
                try await self.library.save(jpeg)

                if wantsTitle {
                    await MainActor.run { self.pendingTitle = version }
                }
                self.finishCapture(error: nil)
            } catch {
                self.finishCapture(error: error.localizedDescription)
            }
        }
    }

    /// Squares the negative and writes the look into it, reporting what landed.
    ///
    /// Shared by a live capture and a re-filter so the two produce identical
    /// files — the only difference between them is where the sensor data came
    /// from.
    private func prepareNegative(_ data: Data,
                                 profile: PositiveFilmProfile) -> (data: Data, xmp: String) {
        // Square the file itself first — that narrows its default-crop
        // rectangle without moving a pixel, and holds in every converter. If
        // iOS won't author the container, the same rectangle travels in the XMP
        // instead. Only ever one of the two, or the frame would be cropped
        // twice.
        let squared = RAWCropper.squareCropped(data)
        let cropInXMP = squared == nil ? RAWCropper.squareCropFractions(data) : nil
        let settings = CameraRawSidecar.xmp(for: profile, crop: cropInXMP)

        // Adobe keeps develop settings inside a DNG rather than beside it, so
        // embedding is what actually makes the look travel. The sidecar is
        // written either way as a fallback.
        let embedded = RAWCropper.embedding(settings, into: squared ?? data)

        let status = NegativeStatus(croppedInFile: squared != nil,
                                    settingsEmbedded: embedded != nil)
        DispatchQueue.main.async { [weak self] in self?.negativeStatus = status }

        return (embedded ?? squared ?? data, settings)
    }

    /// Saves the preview frame itself, skipping the RAW loop entirely.
    ///
    /// There is no sensor round trip, no demosaic and no full-resolution
    /// grade — the graded frame is already on screen, so this is as close to
    /// zero shutter lag as the app gets. The trade is resolution: it comes out
    /// at preview size rather than sensor size, and there is no negative
    /// behind it.
    func capturePreviewFrame() {
        guard state == .running, !isCapturing, let image = renderer.currentImage else { return }
        isCapturing = true

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flashShutter()

        let profile = look.profile

        Task { [weak self] in
            guard let self else { return }
            do {
                let jpeg = try PhotoEncoder.jpeg(from: image,
                                                 profile: profile,
                                                 sourceMetadata: [:],
                                                 context: self.stillContext)
                _ = try self.store.add(imageData: jpeg,
                                       rawData: nil,
                                       xmp: nil,
                                       profile: profile)
                try await self.library.save(jpeg)
                self.finishCapture(error: nil)
            } catch {
                self.finishCapture(error: error.localizedDescription)
            }
        }
    }

    private func flashShutter() {
        withAnimation(.easeIn(duration: 0.06)) { isShutterFlashing = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            withAnimation(.easeOut(duration: 0.18)) { self?.isShutterFlashing = false }
        }
    }

    // MARK: - Helpers

    /// Read from the capture queue on every frame, so it is kept as a plain
    /// flag rather than reaching into published state.
    private var isShowingVersion: Bool {
        versionLock.lock()
        defer { versionLock.unlock() }
        return isVersioning
    }

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

        // A negative is on screen being re-filtered; the camera keeps running
        // but its frames aren't what the viewer is showing.
        if isShowingVersion { return }

        let frame = CIImage(cvPixelBuffer: pixelBuffer)
        frameLock.lock()
        portraitFrameSize = frame.extent.size
        frameLock.unlock()

        var image = frame.centerSquareCropped()

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
                    let prepared = self.prepareNegative(data, profile: profile)
                    negative = prepared.data
                    xmp = prepared.xmp
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
