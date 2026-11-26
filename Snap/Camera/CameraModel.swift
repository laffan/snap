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
    /// A capture that doesn't go through the buffer — PS, a version, the
    /// develop panel's own — is being made, start to finish.
    @Published private(set) var isCapturing = false
    /// A frame is on the sensor: from the press until its data is in hand
    /// (and, for the shutter's frames, on disk in the buffer).
    @Published private(set) var isExposing = false
    /// How many of the shutter's frames are waiting to be developed. Mirrors
    /// the buffer's count, so the screen redraws when it changes and not on
    /// every turn of a ring.
    @Published private(set) var bufferedCount = 0
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

    /// The shutter's frames between the sensor and the roll — see
    /// `CaptureBuffer`.
    let buffer = CaptureBuffer()

    /// A frame is on the sensor, or a capture outside the buffer is being made.
    var isBusy: Bool { isExposing || isCapturing }

    /// The shutter can't take another frame yet: the last one is still coming
    /// off the sensor, or the buffer is full.
    var isShutterBusy: Bool { isBusy || bufferedCount >= CaptureBuffer.capacity }

    /// The panel's captures and a version wait for this to be false, so that
    /// two full-resolution developments never run at once.
    var hasBufferedFrames: Bool { bufferedCount > 0 }

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

    /// True when the ultra wide focuses closer than the wide does, which is
    /// what macro on an iPhone is. False on phones whose ultra wide is fixed
    /// focus, and there the flower is not drawn.
    @Published private(set) var isMacroAvailable = false

    /// The ultra wide, held to its near focus range.
    @Published private(set) var isMacroOn = false

    /// What macro goes back to when it is switched off.
    private var lensBeforeMacro: Lens?

    /// The hourglass after the macro flower: the shutter takes one long
    /// exposure, made of as many frames as fit in the time on the dial. See
    /// `LongExposure`.
    @Published private(set) var isLongExposureOn = false

    /// What the dial says while long exposure is on, in seconds.
    @Published var longExposureSeconds = LongExposure.defaultSeconds

    /// The countdown while one is being taken. Made the first time it is
    /// wanted: nothing to do with long exposure is built on the way up.
    lazy var longExposureClock = LongExposureClock()

    /// The long exposure being taken, held until it lands. The photo output
    /// holds its delegates weakly, so this is what keeps the run alive.
    private var longExposureRun: LongExposureRun?

    /// Frames are added together as sensor data, so it needs Bayer RAW.
    var isLongExposureAvailable: Bool { isRAWAvailable }

    /// The two squares after the hourglass: the shutter's next two frames are
    /// one photograph, the second composed over a ghost of the first. See
    /// `DoubleExposure`.
    @Published private(set) var isDoubleExposureOn = false

    /// The first of the two has been taken and is waiting for the second.
    @Published private(set) var isHoldingExposure = false

    /// Added as sensor data too, so Bayer RAW again.
    var isDoubleExposureAvailable: Bool { isRAWAvailable }

    /// A first exposure waiting for its second. In memory rather than on disk:
    /// it is one negative, and the moments between two exposures are spent in
    /// the app with the camera up. Main thread.
    private struct HeldExposure {
        let dng: Data
        let metadata: [String: Any]
        let profile: PositiveFilmProfile
        let takenAt: Date
        /// How far under the wheel it was taken: none with both pins set,
        /// since compensation moves nothing then.
        let stopsUnder: Float
    }
    private var heldExposure: HeldExposure?

    /// Which of the two the frame on the sensor is, read off as it arrives —
    /// one slot, like `exposureIsBuffered`, since only one frame is ever on the
    /// sensor at a time.
    private enum DoubleStage {
        case first(stopsUnder: Float)
        case second(HeldExposure)
    }
    private var doubleStage: DoubleStage?

    /// The first exposure as the viewfinder showed it, laid over the live
    /// frames while the second is composed. Written on the main thread, read on
    /// the capture queue for every frame.
    private let ghostLock = NSLock()
    private var ghost: CIImage?
    /// The ghost rendered and waiting for its exposure to be held, and a count
    /// that moves whenever it is cleared, so a render that finishes after its
    /// exposure was let go doesn't come back.
    private var renderedGhost: CIImage?
    private var ghostGeneration = 0

    /// Where two exposures are added together, off the photo output's queue.
    private let doubleQueue = DispatchQueue(label: "com.snap.double-exposure", qos: .userInitiated)

    /// A stored negative being re-filtered in place of the live camera.
    @Published private(set) var versionSource: Shot? = nil

    /// True while the loaded negative was shot in black and white.
    ///
    /// A monochrome frame stays monochrome: the colour it was rendered without
    /// isn't recoverable from the JPEG, and re-filtering it back to colour
    /// would quietly produce a different photograph from the one that was
    /// taken. The colour is still in the DNG for anyone who exports it.
    var isMonochromeLocked: Bool { versionSource?.profile.blackAndWhite == true }

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

    /// The pinned shutter, or nil while the camera is choosing it.
    @Published var shutterSpeed: ShutterSpeed? {
        didSet { if !isAdjustingExposure { applyExposure() } }
    }

    /// The pinned ISO, or nil while the camera is choosing it.
    @Published var iso: Float? {
        didSet { if !isAdjustingExposure { applyExposure() } }
    }

    /// Exposure compensation at the sensor, in stops — the wheel beside the
    /// shutter.
    ///
    /// It moves the meter's target rather than the picture: told to sit a stop
    /// under, the camera takes in a stop less light, so a highlight that was
    /// clipping now arrives with its detail in it. Nothing done to a frame
    /// after it is taken can do that — a pixel that reached white came off the
    /// sensor as white — which is why this is a camera setting and the panel's
    /// Exposure is a different one.
    ///
    /// It is the meter's target, so it holds in either priority as well as in
    /// auto: `exposureTargetOffset` is measured against the biased target, and
    /// that offset is what the unpinned half is nudged toward. With both pinned
    /// it moves where the EV readout's zero is and nothing else, the way
    /// compensation does on any camera in manual. Apple writes it into the
    /// capture's EXIF as `ExposureBiasValue`.
    ///
    /// While long exposure is on, the wheel is its timer rather than this, so
    /// the device is held at zero — a compensation nobody can see is not one
    /// anybody chose — and the setting comes back when long exposure goes off.
    @Published var exposureBias: Float = 0 {
        didSet { if exposureBias != oldValue { applyExposureBias() } }
    }

    /// True while both pins are being moved together, so the device is
    /// configured once for the pair rather than once per half.
    private var isAdjustingExposure = false

    /// Which of the two the photographer is holding — read from the pins rather
    /// than set alongside them.
    ///
    /// This used to be a stored mode that owned the pins, and owning them is
    /// what broke ISO: choosing one while the mode said auto set a number the
    /// mode then ignored, because auto handed the whole exposure back to the
    /// camera on its way past. A pin is a pin now. Pinning ISO on its own means
    /// ISO priority, which iOS does not offer either — see `correctShutter`.
    var exposureMode: ExposureMode {
        switch (shutterSpeed != nil, iso != nil) {
        case (false, false): return .auto
        case (true, false):  return .shutterPriority
        case (false, true):  return .isoPriority
        case (true, true):   return .manual
        }
    }

    /// Hands both back to the camera.
    func releaseExposure() {
        guard shutterSpeed != nil || iso != nil else { return }
        adjustExposure {
            shutterSpeed = nil
            iso = nil
        }
    }

    /// Pins both, wherever the camera has them — borrowing what it arrived at
    /// rather than jumping to a number nobody chose.
    func pinExposure() {
        guard shutterSpeed == nil || iso == nil else { return }
        adjustExposure {
            if shutterSpeed == nil {
                shutterSpeed = ShutterSpeed.nearest(toSeconds: meter.duration, in: shutterSpeeds)
            }
            if iso == nil {
                iso = ISOSetting.nearest(to: meter.iso, in: isoOptions)
            }
        }
    }

    private func adjustExposure(_ change: () -> Void) {
        isAdjustingExposure = true
        change()
        isAdjustingExposure = false
        applyExposure()
    }

    @Published private(set) var shutterSpeeds: [ShutterSpeed] = []
    @Published private(set) var isoOptions: [Float] = []

    /// The meter's readings, deliberately not `@Published` here: they move
    /// several times a second, and republishing the camera that often was
    /// rebuilding the whole screen under any menu that happened to be open.
    let meter = ExposureMeter()

    private var meterObservers: Set<AnyCancellable> = []

    /// The portrait frame size as delivered, needed to turn a point on screen
    /// into one the device understands. Written on the capture queue.
    private let frameLock = NSLock()
    private var portraitFrameSize: CGSize = .zero

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?

    /// The angle the preview is pinned at, and the one the interface is built
    /// around. Snap is portrait-only, so the frame on screen never turns.
    private static let previewRotationAngle: CGFloat = 90

    /// Which way up the phone actually is — the one thing about a photograph
    /// that the interface being portrait-only doesn't decide.
    ///
    /// `RotationCoordinator` reads gravity rather than the interface, which is
    /// what makes it work in an app whose interface never turns, and it holds
    /// the last real reading through face-up and face-down where
    /// `UIDevice.orientation` gives an answer no camera can use.
    ///
    /// Main thread only — every one of the three places that reads it is
    /// already there — and rebuilt on a lens change, since it is tied to the
    /// device it was made with.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?

    /// The Bayer format to ask for, resolved at configuration time.
    private var rawPixelFormat: OSType?

    /// Whether the capture in flight should end at the naming sheet.
    /// Only one frame is on the sensor at a time (`isExposing` guards it), and
    /// each of these is read off as that frame arrives, before the shutter is
    /// let go — so a single slot is enough, buffer or no buffer.
    private var wantsTitle = false
    /// Whether the frame on the sensor goes into the buffer when it arrives.
    private var exposureIsBuffered = false
    /// The moment of the press. A buffered frame lands seconds later, and its
    /// place in the roll is when it was taken, not when it was developed.
    private var capturedAt = Date()
    /// The profile as it stood when the shutter fired, so later slider moves
    /// can't change what gets written.
    private var capturedProfile = PositiveFilmProfile()

    /// Where the in-flight capture was started from, held alongside the
    /// profile for the same reason: the delegate callback arrives long after
    /// the button was pressed.
    private var capturedOrigin: Shot.Origin = .camera

    private let stillContext = CIContext(options: [.cacheIntermediates: false])
    /// The buffer's own, asking for a lower priority than the preview's renders
    /// get, so that the viewfinder comes first while frames are developed
    /// behind the shooting.
    private let bufferContext = CIContext(options: [.cacheIntermediates: false,
                                                    .priorityRequestLow: true])
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

        buffer.developer = self
        buffer.$frames
            .map(\.count)
            .removeDuplicates()
            .assign(to: &$bufferedCount)
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
        // The camera stops on the way to the background, which is where the
        // GPU goes too. Frames still waiting are developed when it comes back.
        buffer.suspend()

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
            // Only once the camera is up, so that a frame left over from a run
            // that was ended doesn't slow the camera's own start.
            self.buffer.resume()
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
        bindRotationCoordinator(to: device)
    }

    /// Pins the preview upright. Re-applied after a lens change, since swapping
    /// the input rebuilds the connections.
    ///
    /// Only the preview. The photo output used to be pinned here alongside it,
    /// which is what made a photograph taken with the phone on its side come
    /// out on its side: the interface being portrait-only is a fact about the
    /// screen, and it was being written into the file. What that connection is
    /// set to is decided at the shutter now, by `captureRotationAngle`.
    private func applyRotation() {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(CameraModel.previewRotationAngle) else {
            return
        }
        connection.videoRotationAngle = CameraModel.previewRotationAngle
    }

    /// Points the coordinator at the device now in use.
    ///
    /// Handed the device rather than reading `videoDevice`, because this is
    /// called from the session queue and read from the main one, and the
    /// device is the only thing that has to cross.
    private func bindRotationCoordinator(to device: AVCaptureDevice) {
        DispatchQueue.main.async { [weak self] in
            self?.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                                            previewLayer: nil)
        }
    }

    /// The rotation that puts a capture the right way up whichever way up the
    /// phone is holding it. Main thread.
    ///
    /// Falls back to the preview's own angle, which is what every capture used
    /// before this was asked — a phone held in portrait is the case where the
    /// two agree anyway.
    private var captureRotationAngle: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
            ?? CameraModel.previewRotationAngle
    }

    /// Set immediately before the shutter rather than once at setup: it is a
    /// reading of where the phone is at the moment the photograph is taken, and
    /// a stale one would be worse than never having asked.
    private func applyCaptureRotation(_ angle: CGFloat) {
        guard let connection = photoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// Turns a frame taken off the preview the way the photo output turns one
    /// taken off the sensor.
    ///
    /// The preview is pinned to portrait and a capture no longer is, so a frame
    /// saved straight from the screen would be the one photograph in the app
    /// that still came out sideways. The difference between the two angles is
    /// the quarter turn it needs — and a quarter turn of a centred square is
    /// the same square, so nothing is reframed, only turned.
    ///
    /// Both angles are measured the same way round from the sensor's own
    /// orientation, so the turn is simply the difference. Hold the phone with
    /// its top edge to the left and the world arrives in the preview with its
    /// own top toward the right-hand edge — a quarter turn anticlockwise from
    /// upright, and the capture angle sits a quarter turn below the preview's
    /// to say so.
    private func uprighted(_ image: CIImage) -> CIImage {
        let turn = (Int(captureRotationAngle.rounded())
                    - Int(CameraModel.previewRotationAngle) + 360) % 360

        let orientation: CGImagePropertyOrientation
        switch turn {
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: return image
        }

        // Back to the origin afterwards, so a turned frame has the same extent
        // a squared one does and everything downstream can go on assuming it.
        let turned = image.oriented(orientation)
        return turned.transformed(by: CGAffineTransform(translationX: -turned.extent.minX,
                                                        y: -turned.extent.minY))
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

    /// Pushes the pins to the device.
    ///
    /// iOS offers auto or custom and nothing between: `setExposureModeCustom`
    /// fixes the shutter *and* the ISO. So either priority is built on top of
    /// custom — both are pinned, and whichever one the photographer isn't
    /// holding gets nudged toward the meter afterwards, which is what
    /// `correctExposure` does. Only with neither pinned does the device go back
    /// to metering for itself.
    ///
    /// `currentExposureDuration` and `currentISO` are the sentinels for "leave
    /// that half where it is", which is what makes the half-pinned states
    /// possible at all.
    private func applyExposure() {
        let speed = shutterSpeed
        let chosenISO = iso

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }

                if speed == nil, chosenISO == nil {
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    return
                }

                guard device.isExposureModeSupported(.custom) else { return }

                let duration = speed?.duration ?? AVCaptureDevice.currentExposureDuration
                let isoValue = chosenISO.map {
                    min(max($0, device.activeFormat.minISO), device.activeFormat.maxISO)
                } ?? AVCaptureDevice.currentISO

                device.setExposureModeCustom(duration: duration, iso: isoValue)
            } catch {
                return
            }
        }
    }

    /// Pushes the compensation to the device, within what this lens allows.
    ///
    /// Held per device, so a lens swap has to send it again.
    private func applyExposureBias() {
        // Long exposure's wheel is its timer, so no compensation; a double
        // exposure's two frames are each a stop under it, so that the two add
        // up to what the wheel says.
        let bias: Float
        if isLongExposureOn {
            bias = 0
        } else if isDoubleExposureOn {
            bias = exposureBias - DoubleExposure.stopsUnder
        } else {
            bias = exposureBias
        }

        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice else { return }
            let clamped = min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(clamped, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {
            }
        }
    }

    /// What the camera is doing, watched in three places at once.
    ///
    /// `exposureTargetOffset` is how far the current exposure sits from what
    /// the meter wants, in stops — the number a photographer needs when driving
    /// the exposure by hand, and the one either priority corrects against.
    /// `iso` and `exposureDuration` are what the camera has actually settled
    /// on, which is what the two buttons show while it is the camera choosing
    /// and where pinning starts from when it takes over. All three are read off
    /// the device rather than remembered from the last thing this code set, so
    /// they are right in auto as well.
    ///
    /// Rebuilt rather than kept across a lens swap: the old subscriptions are
    /// watching a device that is no longer running.
    private func startMetering() {
        meterObservers.removeAll()
        guard let device = videoDevice else { return }

        device.publisher(for: \.exposureTargetOffset)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] offset in
                guard let self else { return }
                self.meter.report(offset: offset)
                self.correctExposure(by: offset)
            }
            .store(in: &meterObservers)

        device.publisher(for: \.iso)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] value in self?.meter.report(iso: value) }
            .store(in: &meterObservers)

        device.publisher(for: \.exposureDuration)
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] duration in
                self?.meter.report(duration: Float(CMTimeGetSeconds(duration)))
            }
            .store(in: &meterObservers)
    }

    /// Moves whichever half the photographer isn't holding.
    ///
    /// With both pinned there is nothing to move and the meter is only a
    /// reading; with neither, the device is metering for itself.
    private func correctExposure(by offset: Float) {
        guard abs(offset) > 0.12 else { return }
        // A long exposure's frames are all taken at the one exposure it
        // planned; nudging it between frames would only have to be undone in
        // the merge.
        guard longExposureRun == nil else { return }

        switch exposureMode {
        case .shutterPriority: correctISO(by: offset)
        case .isoPriority:     correctShutter(by: offset)
        case .auto, .manual:   break
        }
    }

    /// Shutter priority: the shutter is held and ISO is nudged toward the
    /// meter. ISO scales in stops, which is what the offset is measured in, so
    /// the correction is a single multiply.
    private func correctISO(by offset: Float) {
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
        }
    }

    /// ISO priority, the same trick the other way up: the ISO is held and the
    /// shutter is nudged. Duration scales linearly with exposure, so a stop is
    /// a doubling, and the offset is already in stops.
    ///
    /// It bottoms out where the format does. A dark room at ISO 100 runs out of
    /// shutter before it runs out of dark, and the frame is simply under —
    /// which the EV readout says, and which is the honest answer rather than
    /// quietly moving the ISO the photographer pinned.
    private func correctShutter(by offset: Float) {
        let pinnedISO = iso

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice,
                  device.exposureMode == .custom else { return }

            let format = device.activeFormat
            let current = CMTimeGetSeconds(device.exposureDuration)
            guard current > 0 else { return }

            let wanted = current * pow(2, Double(offset))
            let target = min(max(wanted, CMTimeGetSeconds(format.minExposureDuration)),
                             CMTimeGetSeconds(format.maxExposureDuration))
            guard target > 0, abs(log2(target / current)) > 0.05 else { return }

            do {
                try device.lockForConfiguration()
                device.setExposureModeCustom(
                    duration: CMTime(seconds: target, preferredTimescale: 1_000_000),
                    iso: pinnedISO.map { min(max($0, format.minISO), format.maxISO) }
                        ?? AVCaptureDevice.currentISO
                )
                device.unlockForConfiguration()
            } catch {
                return
            }
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
        let macro = CameraModel.supportsMacro(discovery.devices)
        DispatchQueue.main.async { [weak self] in
            self?.lenses = found
            self?.currentLens = active
            self?.isMacroAvailable = macro
        }
    }

    /// Whether the ultra wide is a macro lens on this phone.
    ///
    /// Asked of the hardware rather than of a list of models: an ultra wide
    /// that can autofocus and gets closer than the wide is the whole of what
    /// Apple's macro is built on. `minimumFocusDistance` is in millimetres,
    /// and −1 when the device doesn't know.
    private static func supportsMacro(_ devices: [AVCaptureDevice]) -> Bool {
        guard let ultraWide = devices.first(where: { $0.deviceType == .builtInUltraWideCamera }),
              ultraWide.isFocusModeSupported(.continuousAutoFocus),
              ultraWide.minimumFocusDistance > 0 else { return false }
        guard let wide = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }),
              wide.minimumFocusDistance > 0 else { return true }
        return ultraWide.minimumFocusDistance < wide.minimumFocusDistance
    }

    /// Macro on or off.
    ///
    /// On is the ultra wide, with its autofocus told to look near. Apple's
    /// Camera does the same with the same lens, and then crops it to the
    /// wide's field of view; Snap doesn't crop, since a crop here is a zoom,
    /// and a zoom would have to follow the frame into its negative. At two
    /// centimetres the subject fills the square without it.
    ///
    /// Off goes back to whichever lens was up when it went on.
    func toggleMacro() {
        // Not mid-exposure, nor with a first exposure waiting: the frames are
        // added photosite by photosite, and a frame through other glass came
        // off another sensor.
        guard longExposureRun == nil, heldExposure == nil else { return }
        if isMacroOn {
            let back = lensBeforeMacro
                ?? lenses.first { $0.deviceType == .builtInWideAngleCamera }
            endMacro()
            if let back { selectLens(back) }
            return
        }

        guard isMacroAvailable,
              let ultraWide = lenses.first(where: { $0.deviceType == .builtInUltraWideCamera }) else { return }
        lensBeforeMacro = currentLens
        switchLens(to: ultraWide)
        isMacroOn = true
        // Queued behind the swap, so it lands on the ultra wide.
        applyMacroFocus(true)
    }

    /// Lets go of the near range without moving lens.
    private func endMacro() {
        guard isMacroOn else { return }
        isMacroOn = false
        lensBeforeMacro = nil
        applyMacroFocus(false)
    }

    /// Holds the autofocus to the near range, or lets it roam again.
    ///
    /// Not every lens offers the restriction; where it doesn't, macro is the
    /// ultra wide's own continuous autofocus, which reaches its closest
    /// distance anyway and only hunts a little more on the way. The setting
    /// lives on the device, which outlasts the session's hold on it, so it is
    /// cleared on the way out rather than left for the next visit to find.
    private func applyMacroFocus(_ near: Bool) {
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice,
                  device.deviceType == .builtInUltraWideCamera else { return }
            do {
                try device.lockForConfiguration()
                // The focus mode is left alone: a point held by a long press
                // stays held, and the range applies to whichever is running.
                if device.isAutoFocusRangeRestrictionSupported {
                    device.autoFocusRangeRestriction = near ? .near : .none
                }
                device.unlockForConfiguration()
            } catch {
            }
        }
    }

    /// A lens chosen by hand, which is also the end of macro: the dots say
    /// which glass is in use, and choosing one — the ultra wide included —
    /// means wanting it as it comes.
    func selectLens(_ lens: Lens) {
        guard longExposureRun == nil, heldExposure == nil else { return }
        endMacro()
        switchLens(to: lens)
    }

    // MARK: - Long exposure

    /// Long exposure on or off. Not while one is being taken.
    ///
    /// On makes the wheel a timer and the shutter a long exposure; it doesn't
    /// touch the lens, the pins or the look, so it combines with all of them.
    func toggleLongExposure() {
        guard longExposureRun == nil else { return }
        if isLongExposureOn {
            endLongExposure()
        } else {
            guard isLongExposureAvailable, !isExposing else { return }
            // One or the other: a long exposure is one photograph made of
            // many frames, a double exposure two photographs on one.
            endDoubleExposure()
            isLongExposureOn = true
            applyExposureBias()
        }
    }

    /// Back to the ordinary shutter, and the wheel back to compensation.
    func endLongExposure() {
        guard isLongExposureOn, longExposureRun == nil else { return }
        isLongExposureOn = false
        applyExposureBias()
    }

    // MARK: - Double exposure

    /// Double exposure on or off. Not while a frame is on the sensor.
    func toggleDoubleExposure() {
        guard !isExposing else { return }
        if isDoubleExposureOn {
            endDoubleExposure()
        } else {
            guard isDoubleExposureAvailable else { return }
            endLongExposure()
            isDoubleExposureOn = true
            applyExposureBias()
        }
    }

    /// Back to the ordinary shutter.
    ///
    /// A first exposure still waiting is kept, as a photograph of its own and
    /// brought back up the stop it was taken under: a frame nobody wanted is a
    /// swipe away in the roll, and a frame that was never kept is gone.
    func endDoubleExposure() {
        guard isDoubleExposureOn, !isExposing else { return }
        isDoubleExposureOn = false
        applyExposureBias()
        releaseHeldExposure()
    }

    private func releaseHeldExposure() {
        clearGhost()
        guard let held = heldExposure else { return }
        heldExposure = nil
        isHoldingExposure = false

        doubleQueue.async { [weak self] in
            guard let self else { return }
            let negative = (try? DoubleExposure.alone(held.dng, stopsUnder: held.stopsUnder)) ?? held.dng
            do {
                try self.buffer.admit(data: negative,
                                      isRAW: true,
                                      metadata: held.metadata,
                                      profile: held.profile,
                                      takenAt: held.takenAt)
            } catch {
                self.reportError(error.localizedDescription)
            }
        }
    }

    /// The viewfinder as it stands, rendered once so it no longer depends on
    /// the camera's buffers, to be laid over the live frames once the
    /// exposure it shows is held.
    private func renderGhost() {
        guard let image = renderer.currentImage else { return }
        let generation = ghostGeneration
        developQueue.async { [weak self] in
            guard let self, let rendered = self.stillContext.createCGImage(image, from: image.extent) else { return }
            DispatchQueue.main.async {
                guard self.ghostGeneration == generation else { return }
                self.renderedGhost = CIImage(cgImage: rendered)
                self.showGhostIfHeld()
            }
        }
    }

    private func showGhostIfHeld() {
        let image = isHoldingExposure ? renderedGhost : nil
        ghostLock.lock()
        ghost = image
        ghostLock.unlock()
    }

    private func clearGhost() {
        ghostGeneration += 1
        renderedGhost = nil
        ghostLock.lock()
        ghost = nil
        ghostLock.unlock()
    }

    private var currentGhost: CIImage? {
        ghostLock.lock()
        defer { ghostLock.unlock() }
        return ghost
    }

    /// The first exposure is in: held, and the ghost goes up. Called on the
    /// photo output's queue.
    private func holdExposure(_ held: HeldExposure) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Long enough for the mode to have been switched off with the
            // frame on the sensor? Then it is a photograph of its own.
            self.heldExposure = held
            self.isHoldingExposure = true
            if self.isDoubleExposureOn {
                self.showGhostIfHeld()
            } else {
                self.releaseHeldExposure()
            }
            self.isExposing = false
        }
    }

    /// The second exposure is in: the two added, and the result into the
    /// buffer like any other frame. Should they refuse to add, both are kept as
    /// they are rather than either lost. Called on the photo output's queue.
    private func completeDoubleExposure(_ held: HeldExposure,
                                        second: Data,
                                        metadata: [String: Any],
                                        profile: PositiveFilmProfile,
                                        takenAt: Date) {
        doubleQueue.async { [weak self] in
            guard let self else { return }
            do {
                let merged = try DoubleExposure.merge(held.dng, second)
                try self.buffer.admit(data: merged,
                                      isRAW: true,
                                      metadata: held.metadata,
                                      profile: profile,
                                      takenAt: held.takenAt)
            } catch {
                try? self.buffer.admit(data: held.dng, isRAW: true, metadata: held.metadata,
                                       profile: held.profile, takenAt: held.takenAt)
                try? self.buffer.admit(data: second, isRAW: true, metadata: metadata,
                                       profile: profile, takenAt: takenAt)
                self.reportError("The two exposures couldn't be added together, so both were kept as they are. \(error.localizedDescription)")
            }

            // After the buffer's own hop that adds the frame's square, so the
            // count the shutter checks has gone up before it can be pressed
            // again.
            DispatchQueue.main.async {
                self.heldExposure = nil
                self.isHoldingExposure = false
                self.clearGhost()
                self.isExposing = false
            }
        }
    }

    /// Swaps the session's input. RAW support is per-lens, so it is resolved
    /// again afterwards rather than carried over.
    private func switchLens(to lens: Lens) {
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
            self.bindRotationCoordinator(to: device)
            self.session.commitConfiguration()

            self.resolveRAWSupport()
            self.discoverLenses()
            self.resolveExposureCapabilities()
            self.disableVideoHDR()
            DispatchQueue.main.async {
                self.releaseFocus()
                self.startMetering()
                self.applyExposure()
                self.applyExposureBias()
            }
        }
    }

    /// Back to the lens the app opens on.
    ///
    /// The wide one is the phone's own idea of no zoom, and it is what a
    /// camera reached from the lock screen should be pointing through
    /// whichever lens the last visit left selected. A no-op when it is already
    /// the one in use, and while the lenses are still being discovered — the
    /// session configures itself on the wide camera anyway, so a launch that
    /// arrives before the list does is already there.
    func selectDefaultLens() {
        guard let wide = lenses.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return }
        selectLens(wide)
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
            // A lens without Bayer RAW can't take a long exposure, so arriving
            // on one puts the ordinary shutter and the compensation back.
            if bayerFormat == nil { self?.endLongExposure() }
        }
    }

    // MARK: - Capture

    /// Takes a photo. Every capture is written as a JPEG carrying its own
    /// settings in EXIF, saved to the camera roll, and recorded in the store.
    /// `titled` only decides whether the naming sheet follows, and `origin`
    /// only marks where the shot came from for the strip.
    ///
    /// The shutter's frames — the ring, the volume buttons, StreetPad — go
    /// through the buffer, and the shutter is free again as soon as the frame
    /// is off the sensor. The develop panel's captures don't: they are made
    /// start to finish while you wait, as they always were, and wait for the
    /// buffer to be empty before they start.
    func capture(titled: Bool = false, origin: Shot.Origin = .camera) {
        let isBuffered = !titled && origin == .camera
        guard state == .running else { return }
        // The shutter's frames, and only those, become long exposures. The
        // develop panel's own captures stay single frames: they are made while
        // you wait, and half a minute is a long time to wait at a slider.
        if isBuffered, isLongExposureOn, isLongExposureAvailable {
            captureLongExposure()
            return
        }
        if isBuffered {
            guard !isShutterBusy else { return }
        } else {
            guard !isBusy, !hasBufferedFrames else { return }
            isCapturing = true
        }
        // The shutter's frames, and only those, are one half of a double
        // exposure or the other. The first is seen as the viewfinder showed it,
        // so that is what is kept for the ghost.
        doubleStage = nil
        if isBuffered, isDoubleExposureOn, isDoubleExposureAvailable {
            if let held = heldExposure {
                doubleStage = .second(held)
            } else {
                doubleStage = .first(stopsUnder: exposureMode == .manual ? 0 : DoubleExposure.stopsUnder)
                renderGhost()
            }
        }

        isExposing = true
        exposureIsBuffered = isBuffered
        wantsTitle = titled
        capturedOrigin = origin
        capturedProfile = look.profile
        capturedAt = Date()

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashShutter()

        // Read here, on the main thread and at the moment of the press, and
        // carried across rather than looked up again on the session queue.
        let angle = captureRotationAngle

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyCaptureRotation(angle)
            self.photoOutput.capturePhoto(with: self.makeSettings(), delegate: self)
        }
    }

    /// Asks for sensor data and nothing else.
    ///
    /// `processedFormat: nil` means AVFoundation produces no JPEG at all — the
    /// capture is the negative, and the JPEG is something Snap derives from it
    /// afterwards. The processed path below is only for cameras that can't
    /// deliver Bayer RAW.
    ///
    /// Either way, without the shutter sound wherever iOS allows it. The
    /// shutter already knocks and the frame already blinks, which is two ways
    /// of saying a photograph was taken to the one person who needs telling;
    /// the sound says it to everybody else, and StreetPad exists so that
    /// nobody else is told. In the places where the law requires the sound,
    /// `isShutterSoundSuppressionSupported` is false and it plays as before —
    /// asking regardless would throw.
    private func makeSettings() -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        if let rawPixelFormat {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawPixelFormat,
                                              processedFormat: nil)
        } else {
            settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        }

        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        return settings
    }

    /// One long exposure, in as many frames as fit in the time on the dial.
    ///
    /// The shutter is busy from the press until the merged negative is in the
    /// buffer, and then it is a frame like any other: developed behind the
    /// shooting, filed in the roll at the moment of the press. The device is
    /// held at the plan's exposure for the length of the run and handed back to
    /// the pins, or to the camera, once it ends.
    private func captureLongExposure() {
        guard !isShutterBusy, isLongExposureAvailable else { return }
        isExposing = true

        let profile = look.profile
        let takenAt = Date()
        let seconds = longExposureSeconds
        let pinnedShutter = shutterSpeed?.duration
        let pinnedISO = iso
        // Read now, at the press, like every capture's.
        let angle = captureRotationAngle

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        flashShutter()

        let run = LongExposureRun(
            seconds: TimeInterval(seconds),
            request: { [weak self] run in
                self?.sessionQueue.async { [weak self] in
                    guard let self, let format = self.rawPixelFormat else {
                        run.abandon("The camera can't take RAW frames now.")
                        return
                    }
                    self.photoOutput.capturePhoto(with: self.makeLongExposureSettings(format),
                                                  delegate: run)
                }
            },
            opened: { [weak self] in
                DispatchQueue.main.async { self?.longExposureClock.start(seconds: seconds) }
            },
            completion: { [weak self] result in
                self?.finishLongExposure(result, profile: profile, takenAt: takenAt)
            })
        longExposureRun = run

        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else {
                run.abandon("The camera isn't available.")
                return
            }
            self.applyCaptureRotation(angle)

            let plan = LongExposure.plan(for: device,
                                         total: TimeInterval(seconds),
                                         pinnedShutter: pinnedShutter,
                                         pinnedISO: pinnedISO)

            // The first frame waits for the device to be exposing at the plan,
            // which is what the completion handler says.
            guard device.isExposureModeSupported(.custom),
                  (try? device.lockForConfiguration()) != nil else {
                // Frames as the camera has them, and the sum brought back to
                // one of them, since nothing was shared out.
                let seconds = CMTimeGetSeconds(device.exposureDuration)
                let exposure = seconds * Double(device.iso)
                run.start(frameSeconds: seconds, target: exposure, frameExposure: exposure)
                return
            }
            device.setExposureModeCustom(duration: plan.duration, iso: plan.iso) { _ in
                run.start(frameSeconds: plan.seconds, target: plan.target, frameExposure: plan.frameExposure)
            }
            device.unlockForConfiguration()

            // In case that answer never comes: a run that never started would
            // leave the shutter waiting for it.
            self.sessionQueue.asyncAfter(deadline: .now() + plan.seconds + 2) {
                run.start(frameSeconds: plan.seconds, target: plan.target, frameExposure: plan.frameExposure)
            }
        }
    }

    /// A long exposure's frames: sensor data only, like the shutter's, and as
    /// quiet. Each frame's exposure is read back out of its own metadata
    /// before it is added, so a frame the system exposed differently from the
    /// plan is weighted for what it got rather than averaged in as if it hadn't.
    private func makeLongExposureSettings(_ format: OSType) -> AVCapturePhotoSettings {
        let settings = AVCapturePhotoSettings(rawPixelFormatType: format, processedFormat: nil)
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        return settings
    }

    /// The run is over. Called on the run's own queue, which is as good a
    /// place as the photo output's for writing the negative to the buffer.
    private func finishLongExposure(_ result: Result<LongExposureRun.Outcome, Error>,
                                    profile: PositiveFilmProfile,
                                    takenAt: Date) {
        switch result {
        case .success(let outcome):
            do {
                try buffer.admit(data: outcome.dng,
                                 isRAW: true,
                                 metadata: placed(outcome.metadata),
                                 profile: profile,
                                 takenAt: takenAt)
            } catch {
                reportError(error.localizedDescription)
            }
            if let note = outcome.note { reportError(note) }
        case .failure(let error):
            reportError(error.localizedDescription)
        }

        // After the buffer's own hop that adds the frame's square, so the
        // count the shutter checks has gone up before it can be pressed again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.longExposureRun = nil
            self.longExposureClock.stop()
            self.applyExposure()
            self.restoreFrameDurations()
            self.isExposing = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    /// A one-second frame needs a one-second video frame to fit in, and Apple
    /// doesn't say the frame rate comes back by itself once the exposure is
    /// handed back to the camera. If it didn't, the viewfinder would go on at
    /// a frame a second — and since coming back to the app restarts the
    /// session without configuring it again, coming back would look like
    /// waiting for the camera to start. So with the camera choosing the
    /// exposure again, the frame durations go back to the format's own.
    ///
    /// Not with a pin: a pinned slow shutter still needs its long frames, and
    /// that is how a slow shutter has always looked here. Queued behind
    /// `applyExposure`, so auto exposure is back before the frame rate is.
    private func restoreFrameDurations() {
        guard shutterSpeed == nil, iso == nil else { return }
        sessionQueue.async { [weak self] in
            guard let device = self?.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = .invalid
                device.activeVideoMaxFrameDuration = .invalid
                device.unlockForConfiguration()
            } catch {
            }
        }
    }

    // MARK: - Focus

    /// Pins focus to a point, given in the displayed square's own normalised
    /// coordinates: x right, y down, 0...1.
    ///
    /// What is pinned is the point on the screen, not the distance it was at.
    /// This used to be `.autoFocus`, which focuses once and then holds that
    /// distance — so moving the camera left the ring over something that had
    /// gone soft. Continuous autofocus with the point of interest set keeps
    /// refocusing on whatever is under the ring as the frame moves. Single-shot
    /// is the fallback for a device that can't do continuous.
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
                if device.isFocusPointOfInterestSupported {
                    // The point is only read when the mode is set, so the
                    // mode goes after it.
                    device.focusPointOfInterest = target
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
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

    /// Puts a stored negative under the sliders in place of the live camera,
    /// wearing the settings it was taken with.
    ///
    /// A frame arrives as itself. Loading one under whatever happened to be on
    /// the sliders showed a photograph nobody had ever taken — the last frame's
    /// grade over this frame's negative — and made the roll under the panel a
    /// row of thumbnails that lied about what tapping them would produce. So
    /// the shot's own look comes with it, off the file the way everything else
    /// about it is read, and the sliders say what the frame is.
    ///
    /// Its settings then stay on the sliders when the panel closes. Whatever
    /// was last developed is where the develop screen was left, and the camera
    /// picks up from there rather than from something it put back quietly.
    func beginVersioning(from shot: Shot) {
        guard let rawURL = store.rawURL(for: shot) else { return }
        versionSource = shot

        var profile = store.profile(for: shot)
        // A monochrome frame stays monochrome whatever its stored look says:
        // the colour it was rendered without isn't in the JPEG, and the panel's
        // toggle is locked for the same reason.
        if shot.profile.blackAndWhite { profile.blackAndWhite = true }
        look.apply(profile)

        setVersioning(true)
        developSource(at: rawURL)
    }

    /// Puts the negative down and hands the live camera back. What it does
    /// *not* do is put the look back: the sliders keep the last frame that was
    /// developed, which is what the develop screen was left showing.
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
              !isBusy, !hasBufferedFrames else { return }

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

        pendingSnapshot = try? PhotoEncoder.jpeg(from: uprighted(image),
                                                 profile: look.profile,
                                                 sourceMetadata: described([:]),
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
        // Not held up by the buffer: PS develops nothing, and its preview-sized
        // encode is nothing beside a frame being developed behind it.
        guard state == .running, !isBusy, let image = renderer.currentImage else { return }
        isCapturing = true

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        flashShutter()

        let profile = look.profile
        // Turned here rather than in the task below, because which way up the
        // phone is is a main-thread reading and belongs to the moment PS was
        // pressed, not to whenever the encode gets round to running.
        let frame = uprighted(image)

        Task { [weak self] in
            guard let self else { return }
            do {
                let jpeg = try PhotoEncoder.jpeg(from: frame,
                                                 profile: profile,
                                                 sourceMetadata: self.described([:]),
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

    /// Adds the moment as well as the place, for a frame the camera handed us
    /// no metadata for at all — a preview frame, or one the app left behind on
    /// the way out. Both of those are photographs of somewhere at some time
    /// like any other, and the file is where that belongs.
    ///
    /// A real capture arrives with its own timestamp; this never overwrites it.
    private func described(_ metadata: [String: Any]) -> [String: Any] {
        var stamped = placed(metadata)

        var exif = stamped[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        if exif[kCGImagePropertyExifDateTimeOriginal as String] == nil {
            exif[kCGImagePropertyExifDateTimeOriginal as String] = ShotInfo.exifTimestamp(for: Date())
        }
        stamped[kCGImagePropertyExifDictionary as String] = exif

        return stamped
    }

    // MARK: - Deleting

    /// Deletes a frame from the app and from the camera roll.
    func delete(_ shot: Shot) {
        delete([shot])
    }

    /// Deletes several, which is what the grid hands over.
    ///
    /// The two copies of a frame were written together and go together: a
    /// photograph deleted here should be gone rather than merely out of the
    /// strip. iOS puts its own confirmation in front of the second half, and
    /// declining it leaves the camera roll's copy standing — a decision, not a
    /// failure, so nothing is said about it. Frames taken before the app
    /// started recording which asset it had created have only the app's copy
    /// to remove.
    ///
    /// The library is asked for the whole set in one request, so a dozen
    /// frames is one confirmation rather than a dozen.
    func delete(_ shots: [Shot]) {
        guard !shots.isEmpty else { return }
        store.delete(shots)

        let identifiers = shots.compactMap(\.assetIdentifier)
        guard !identifiers.isEmpty else { return }
        Task { [weak self] in
            do {
                try await self?.library.delete(assetIdentifiers: identifiers)
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

    /// The sensor is free. For a buffered frame this is the shutter coming
    /// back; anything else still has `isCapturing` to clear.
    ///
    /// Hops to the main thread after the buffer's own hop that adds the frame's
    /// square, so the count the shutter checks has already gone up by the time
    /// it can be pressed again.
    private func finishExposure() {
        DispatchQueue.main.async { [weak self] in
            self?.isExposing = false
        }
    }

    /// A first exposure that never arrived takes its ghost with it; a second
    /// that never arrived leaves the first held, to be tried again.
    private func dropGhostIfFirst(_ stage: DoubleStage?) {
        guard case .first? = stage else { return }
        DispatchQueue.main.async { [weak self] in self?.clearGhost() }
    }

    /// A frame that never arrived. Nothing reached the buffer, so a buffered
    /// one has only the shutter to give back.
    private func failExposure(_ message: String, isBuffered: Bool) {
        finishExposure()
        if isBuffered {
            reportError(message)
        } else {
            finishCapture(error: message)
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorMessage = message
        }
    }

    // MARK: - Developing

    /// Develops, crops, grades and encodes a frame off the sensor: the half of
    /// a capture that reaches for the GPU. Shared by a capture made while you
    /// wait and one the buffer develops later, so the two are the same file.
    private func renderJPEG(from data: Data,
                            isRAW: Bool,
                            metadata: [String: Any],
                            profile: PositiveFilmProfile,
                            context: CIContext) throws -> Data {
        // A RAW capture is demosaiced here rather than by Apple, so the look
        // lands on sensor data instead of on their finished JPEG.
        let upright: CIImage
        if isRAW {
            upright = try RAWDeveloper.develop(
                dngData: data,
                profile: profile,
                orientation: RAWDeveloper.orientation(from: metadata)
            )
        } else {
            guard let decoded = CIImage(data: data,
                                        options: [.applyOrientationProperty: true]) else {
                throw RAWDeveloper.DevelopError.undecodable
            }
            upright = decoded
        }

        // Same crop, same look, same order as the preview — just at full size,
        // and always through a full-resolution LUT even if the preview was
        // running on a draft one mid-drag.
        let graded = look.finalFilter(for: profile)
            .apply(to: upright.centerSquareCropped())

        return try PhotoEncoder.jpeg(from: graded,
                                     profile: profile,
                                     sourceMetadata: metadata,
                                     context: context)
    }

    /// The other half: squares the negative and records the shot. Files only.
    ///
    /// The negative is kept in the app's store, where the strip can share it.
    /// Only the graded frame goes to the camera roll.
    private func fileShot(jpeg: Data,
                          negative data: Data,
                          isRAW: Bool,
                          profile: PositiveFilmProfile,
                          origin: Shot.Origin,
                          id: UUID = UUID(),
                          createdAt: Date = Date()) throws -> Shot {
        var negative: Data?
        var xmp: String?

        if isRAW {
            let prepared = prepareNegative(data, profile: profile)
            negative = prepared.data
            xmp = prepared.xmp
        }

        return try store.add(id: id,
                             createdAt: createdAt,
                             imageData: jpeg,
                             rawData: negative,
                             xmp: xmp,
                             origin: origin,
                             profile: profile)
    }
}

// MARK: - The buffer

extension CameraModel: BufferDeveloper {

    /// Through the buffer's own context, at the lower priority.
    func develop(_ negative: CaptureBuffer.Negative) throws -> Data {
        try renderJPEG(from: negative.data,
                       isRAW: negative.isRAW,
                       metadata: negative.metadata,
                       profile: negative.profile,
                       context: bufferContext)
    }

    /// Filed under the id its square in the roll has had all along, so the
    /// thumbnail takes the square's place rather than arriving beside it, and
    /// dated by the press.
    ///
    /// The camera roll isn't waited for. The next frame can start developing
    /// while Photos takes this one.
    func finish(_ negative: CaptureBuffer.Negative, jpeg: Data) throws {
        let shot = try fileShot(jpeg: jpeg,
                                negative: negative.data,
                                isRAW: negative.isRAW,
                                profile: negative.profile,
                                origin: .camera,
                                id: negative.id,
                                createdAt: negative.takenAt)

        Task { [weak self] in
            guard let self else { return }
            do {
                let identifier = try await self.library.save(jpeg)
                self.store.setAssetIdentifier(identifier, for: shot)
            } catch {
                self.reportError(error.localizedDescription)
            }
        }
    }

    func report(_ error: Error) {
        reportError(error.localizedDescription)
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

        var graded = look.filter.apply(to: image)

        // A first exposure waiting for its second, added to the live frame in
        // light the way the two negatives will be — each a stop under, so the
        // sum on screen is the photograph the second press will make.
        if let ghost = currentGhost, !ghost.extent.isEmpty, !graded.extent.isEmpty {
            let target = graded.extent
            let fitted = ghost
                .transformed(by: CGAffineTransform(scaleX: target.width / ghost.extent.width,
                                                   y: target.height / ghost.extent.height))
            let placed = fitted.transformed(by: CGAffineTransform(translationX: target.minX - fitted.extent.minX,
                                                                  y: target.minY - fitted.extent.minY))
            graded = placed.applyingFilter("CIAdditionCompositing",
                                           parameters: [kCIInputBackgroundImageKey: graded])
                .cropped(to: target)
        }

        renderer.setImage(graded)
    }
}

// MARK: - Still capture

extension CameraModel: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let isBuffered = exposureIsBuffered
        let stage = doubleStage

        if let error {
            dropGhostIfFirst(stage)
            failExposure(error.localizedDescription, isBuffered: isBuffered)
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            dropGhostIfFirst(stage)
            failExposure("The photo could not be read.", isBuffered: isBuffered)
            return
        }

        let profile = capturedProfile
        let origin = capturedOrigin
        let takenAt = capturedAt
        // The coordinate is read now, as the frame comes off the sensor. A
        // buffered frame can be developed a minute later and a street away.
        let metadata = placed(photo.metadata)
        let isRAW = photo.isRawPhoto
        let wantsTitle = self.wantsTitle

        if isBuffered {
            switch stage {
            case .first(let stopsUnder)? where isRAW:
                holdExposure(HeldExposure(dng: data, metadata: metadata, profile: profile,
                                          takenAt: takenAt, stopsUnder: stopsUnder))
                return
            case .second(let held)? where isRAW:
                completeDoubleExposure(held, second: data, metadata: metadata,
                                       profile: profile, takenAt: takenAt)
                return
            default:
                break
            }
            do {
                try buffer.admit(data: data,
                                 isRAW: isRAW,
                                 metadata: metadata,
                                 profile: profile,
                                 takenAt: takenAt)
            } catch {
                reportError(error.localizedDescription)
            }
            finishExposure()
            return
        }

        finishExposure()

        Task { [weak self] in
            guard let self else { return }
            do {
                let jpeg = try self.renderJPEG(from: data,
                                               isRAW: isRAW,
                                               metadata: metadata,
                                               profile: profile,
                                               context: self.stillContext)
                let shot = try self.fileShot(jpeg: jpeg,
                                             negative: data,
                                             isRAW: isRAW,
                                             profile: profile,
                                             origin: origin,
                                             createdAt: takenAt)
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
