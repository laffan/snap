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

    /// The live look. Owned here, observed by the develop panel.
    let look = LookModel()

    /// Everything the app has shot. Every capture lands here as well as in the
    /// camera roll, which is what the film strip reads from.
    let store = ShotStore()

    /// The frames left frozen on screen by walking away. Kept apart from the
    /// roll and never sent to the camera roll — see `SnapshotStore`.
    let snapshots = SnapshotStore()

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

    /// True while the loaded negative was shot in black and white.
    ///
    /// A monochrome frame stays monochrome: the colour it was rendered without
    /// isn't recoverable from the JPEG, and re-filtering it back to colour
    /// would quietly produce a different photograph from the one that was
    /// taken. The colour is still in the DNG for anyone who exports it.
    var isMonochromeLocked: Bool { versionSource?.profile.blackAndWhite == true }

    /// Set when loading a negative turned monochrome on, so ending the session
    /// can put it back rather than leaving the camera in a mode nobody chose.
    private var forcedMonochrome = false

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

    /// True while focus is pinned to a point rather than roaming.
    @Published private(set) var isFocusLocked = false

    // MARK: - Exposure

    @Published var exposureMode: ExposureMode = .auto {
        didSet {
            guard exposureMode != oldValue else { return }
            switch exposureMode {
            case .manual:
                // Manual needs a number to hold; borrow whatever the camera had
                // arrived at rather than jumping to an arbitrary one.
                if iso == nil { iso = meter.iso }
            case .auto, .shutter:
                // ISO is the camera's to decide in both of these — auto meters
                // everything, and shutter priority moves ISO itself. Keeping
                // the last chosen number would leave the readout lit, claiming
                // a pin that is no longer there.
                iso = nil
            }
            applyExposure()
        }
    }

    /// The chosen shutter. Nil in auto.
    @Published var shutterSpeed: ShutterSpeed? {
        didSet { applyExposure() }
    }

    /// The chosen ISO, or nil for AUTO.
    @Published var iso: Float? {
        didSet { applyExposure() }
    }

    @Published private(set) var shutterSpeeds: [ShutterSpeed] = []
    @Published private(set) var isoOptions: [Float] = []

    /// The meter's readings, deliberately not `@Published` here: they move
    /// several times a second, and republishing the camera that often was
    /// rebuilding the whole screen under any menu that happened to be open.
    let meter = ExposureMeter()

    private var meterObserver: AnyCancellable?

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

    /// Where the in-flight capture was started from, held alongside the
    /// profile for the same reason: the delegate callback arrives long after
    /// the button was pressed.
    private var capturedOrigin: Shot.Origin = .camera

    private let stillContext = CIContext(options: [.cacheIntermediates: false])
    private let library = PhotoLibrarySaver()

    /// Where the phone is, for the GPS block AVFoundation never writes.
    private let locationTagger = LocationTagger()

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
        locationTagger.start()

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
        locationTagger.stop()

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
                    self.resolveExposureCapabilities()
                    self.disableVideoHDR()
                    DispatchQueue.main.async { self.startMetering() }
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

    /// Turns off the video pipeline's HDR.
    ///
    /// The preview and the still come off the same sensor, so exposure already
    /// matches — but the video stream gets Apple's local tone mapping, while
    /// the still has `localToneMapAmount` at zero. Left on, the preview shows
    /// recovered highlights and lifted shadows the negative will not have.
    private func disableVideoHDR() {
        guard let device = videoDevice, device.activeFormat.isVideoHDRSupported else { return }
        do {
            try device.lockForConfiguration()
            // Has to stop adjusting itself before the value will hold.
            device.automaticallyAdjustsVideoHDREnabled = false
            device.isVideoHDREnabled = false
            device.unlockForConfiguration()
        } catch {
        }
    }

    /// Reads what this lens and format will accept.
    private func resolveExposureCapabilities() {
        guard let device = videoDevice else { return }
        let speeds = ShutterSpeed.supported(by: device.activeFormat)
        let isos = ISOSetting.supported(by: device.activeFormat)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.shutterSpeeds = speeds
            self.isoOptions = isos
            // A speed the previous lens allowed may be out of range on this one.
            if let current = self.shutterSpeed, !speeds.contains(current) {
                self.shutterSpeed = speeds.first { CMTimeCompare($0.duration, current.duration) >= 0 } ?? speeds.last
            }
        }
    }

    /// Pushes the current mode to the device.
    ///
    /// iOS has no shutter-priority mode of its own: `setExposureModeCustom`
    /// fixes both the shutter and the ISO. So priority is built on top of it —
    /// the shutter is pinned and ISO is nudged to follow the meter, which is
    /// what `startMetering` does. Manual pins both and lets the meter drift.
    private func applyExposure() {
        let mode = exposureMode
        let speed = shutterSpeed
        let chosenISO = iso

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                switch mode {
                case .auto:
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }

                case .shutter, .manual:
                    guard device.isExposureModeSupported(.custom) else { return }

                    let duration = speed?.duration ?? AVCaptureDevice.currentExposureDuration
                    let isoValue = chosenISO.map {
                        min(max($0, device.activeFormat.minISO), device.activeFormat.maxISO)
                    } ?? device.iso

                    device.setExposureModeCustom(duration: duration, iso: isoValue)
                }
            } catch {
                return
            }
        }
    }

    /// One subscription to the meter, serving both readers.
    ///
    /// `exposureTargetOffset` is how far the current exposure sits from what
    /// the meter wants, in stops. That is the number a photographer needs when
    /// driving the exposure by hand, and it is also what shutter priority
    /// corrects against — ISO scales in the same units, so the correction is a
    /// single multiply. Keeping it as one always-on subscription means there is
    /// no tracker lifecycle to get wrong when the mode or the lens changes.
    private func startMetering() {
        // Rebuilt rather than kept: after a lens swap the old subscription is
        // watching a device that is no longer running.
        meterObserver = nil
        guard let device = videoDevice else { return }

        meterObserver = device.publisher(for: \.exposureTargetOffset)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] offset in
                guard let self else { return }
                self.meter.report(offset: offset)
                // Manual holds its own ISO; nothing should be moving it.
                if self.exposureMode == .shutter { self.correctISO(by: offset) }
            }
    }

    private func correctISO(by offset: Float) {
        guard exposureMode == .shutter, abs(offset) > 0.12 else { return }
        let speed = shutterSpeed

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice,
                  device.exposureMode == .custom else { return }

            let format = device.activeFormat
            let target = min(max(device.iso * pow(2, offset), format.minISO), format.maxISO)
            guard abs(target - device.iso) > 1 else { return }

            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(duration: speed?.duration ?? AVCaptureDevice.currentExposureDuration,
                                             iso: target)
                device.unlockForConfiguration()
            } catch {
                return
            }
            DispatchQueue.main.async { self.meter.report(iso: target) }
        }
    }

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
            self.resolveExposureCapabilities()
            self.disableVideoHDR()
            DispatchQueue.main.async {
                self.releaseFocus()
                self.startMetering()
                self.applyExposure()
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
    /// `titled` only decides whether the naming sheet follows, and `origin`
    /// only marks where the shot came from for the strip.
    func capture(titled: Bool = false, origin: Shot.Origin = .camera) {
        guard state == .running, !isCapturing else { return }
        isCapturing = true
        wantsTitle = titled
        capturedOrigin = origin
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

    /// Pins focus to a point, given in the displayed square's own normalised
    /// coordinates: x right, y down, 0...1.
    ///
    /// Focus only. Metering is left where it is, so choosing what is sharp
    /// doesn't also decide what is bright — those are separate decisions and
    /// the exposure controls own the second one.
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
                if device.isFocusPointOfInterestSupported,
                   device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                    device.focusMode = .continuousAutoFocus
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

        if shot.profile.blackAndWhite, !look.profile.blackAndWhite {
            forcedMonochrome = true
            look.profile.blackAndWhite = true
        }

        setVersioning(true)
        developSource(at: rawURL)
    }

    func endVersioning() {
        // Only undo what loading the negative turned on; a mode the user
        // chose while it was open is theirs to keep.
        if forcedMonochrome {
            look.profile.blackAndWhite = false
            forcedMonochrome = false
        }
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
            renderer.setImage(look.profile.blackAndWhite || isMonochromeLocked
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

        var profile = look.profile
        if shot.profile.blackAndWhite { profile.blackAndWhite = true }
        let wantsTitle = titled

        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: rawURL)
                var properties = RAWDeveloper.properties(of: data)
                // A version is the same photograph, taken in the same place —
                // but the negative was never given a coordinate, so the one
                // written into the frame it came from is carried across.
                if properties[kCGImagePropertyGPSDictionary as String] == nil,
                   let gps = ShotInfo.gpsProperties(at: self.store.imageURL(for: shot)) {
                    properties[kCGImagePropertyGPSDictionary as String] = gps
                }

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
                                                 origin: .develop,
                                                 profile: profile)
                let identifier = try await self.library.save(jpeg)
                self.store.setAssetIdentifier(identifier, for: version)

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

    // MARK: - The frame left behind

    /// Rendered when the app loses focus, written only if it actually goes
    /// away. See `prepareBackgroundSnapshot`.
    private var pendingSnapshot: Data?

    /// Renders whatever the preview is showing, and holds it.
    ///
    /// The frame the renderer has is the one iOS will leave frozen on screen
    /// for as long as the app is in the background, so this is not a new
    /// photograph — it is the one that was going to be thrown away when the
    /// session restarts.
    ///
    /// It has to happen *here*, on the way to inactive, rather than on the way
    /// to the background: the graded frame is a recipe until something draws
    /// it, drawing it is Metal, and an app that touches the GPU once it is in
    /// the background gets its command buffer killed. Inactive is still the
    /// foreground — it is the same moment an app blurs itself before the
    /// switcher takes its picture.
    ///
    /// Nothing is kept while a negative is under the sliders: what freezes then
    /// is a re-development of a frame already in the roll, not a moment about
    /// to be lost.
    func prepareBackgroundSnapshot() {
        guard state == .running,
              versionSource == nil,
              let image = renderer.currentImage else { return }

        pendingSnapshot = try? PhotoEncoder.jpeg(from: image,
                                                 profile: look.profile,
                                                 sourceMetadata: placed([:]),
                                                 context: stillContext)
    }

    /// Writes the held frame, now that the app is going. Files only — no GPU
    /// work happens here.
    func commitBackgroundSnapshot() {
        guard let jpeg = pendingSnapshot else { return }
        pendingSnapshot = nil
        try? snapshots.add(jpeg: jpeg)
    }

    /// Coming back without ever having left — a notification, the control
    /// centre, a glance at the switcher — is not leaving a frame behind.
    func discardBackgroundSnapshot() {
        pendingSnapshot = nil
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
                                                 sourceMetadata: self.placed([:]),
                                                 context: self.stillContext)
                let shot = try self.store.add(imageData: jpeg,
                                              rawData: nil,
                                              xmp: nil,
                                              origin: .preview,
                                              profile: profile)
                let identifier = try await self.library.save(jpeg)
                self.store.setAssetIdentifier(identifier, for: shot)
                self.finishCapture(error: nil)
            } catch {
                self.finishCapture(error: error.localizedDescription)
            }
        }
    }

    /// Adds the current fix to a capture's metadata. AVFoundation hands over
    /// exposure, lens and timestamp but never a coordinate, so this is the only
    /// place a Snap frame gets one.
    private func placed(_ metadata: [String: Any]) -> [String: Any] {
        guard metadata[kCGImagePropertyGPSDictionary as String] == nil,
              let gps = locationTagger.gpsProperties else { return metadata }
        var tagged = metadata
        tagged[kCGImagePropertyGPSDictionary as String] = gps
        return tagged
    }

    // MARK: - Deleting

    /// Deletes a frame from the app and from the camera roll.
    ///
    /// The two copies were written together and go together: a photograph
    /// deleted here should be gone rather than merely out of the strip. iOS
    /// puts its own confirmation in front of the second half, and declining it
    /// leaves the camera roll's copy standing — a decision, not a failure, so
    /// nothing is said about it. Frames taken before the app started recording
    /// which asset it had created have only the app's copy to remove.
    func delete(_ shot: Shot) {
        store.delete(shot)

        guard let identifier = shot.assetIdentifier else { return }
        Task { [weak self] in
            do {
                try await self?.library.delete(assetIdentifier: identifier)
            } catch PhotoLibrarySaver.SaveError.notAuthorizedToDelete {
                // The one outcome worth reporting: it can be fixed in Settings,
                // where cancelling the confirmation cannot.
                DispatchQueue.main.async {
                    self?.errorMessage = PhotoLibrarySaver.SaveError.notAuthorizedToDelete.errorDescription
                }
            } catch {
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
        let origin = capturedOrigin
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
                                                 sourceMetadata: self.placed(sourceMetadata),
                                                 context: self.stillContext)

                // The negative is kept in the app's store, where the strip
                // can share it. Only the graded frame goes to the camera roll.
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
                                              origin: origin,
                                              profile: profile)
                let identifier = try await self.library.save(jpeg)
                self.store.setAssetIdentifier(identifier, for: shot)

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
