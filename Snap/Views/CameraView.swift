//
//  CameraView.swift
//  Snap
//
//  Preview at the top. Below it either the shutter and the app's own roll, or
//  the filter editor that replaces them.
//

import SwiftUI
import UIKit

struct CameraView: View {

    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isEditingFilter = false
    @State private var isLoadingLook = false
    @State private var share: ShareItem? = nil
    /// A saved frame being viewed in place of the live preview.
    @State private var viewing: Shot? = nil
    /// True while the viewer is being held down to show the negative.
    @State private var showsRAW = false
    /// Where focus is pinned, in the preview's own coordinates.
    @State private var focusPoint: CGPoint? = nil
    @State private var pressLocation: CGPoint = .zero
    /// Set when a hold pinned focus, so the touch ending doesn't immediately
    /// read as the tap that releases it.
    @State private var didLockFocus = false
    /// How far the filter panel has been pulled up over the preview, in
    /// points. The square gives up exactly this much.
    @State private var panelLift: CGFloat = 0

    private var store: ShotStore { camera.store }

    /// One cell of the lens column and of the mode column beside it, so the two
    /// stay level whatever the font does.
    private static let controlCellHeight: CGFloat = 30

    /// The mode column is the tallest thing in the control row: one cell per
    /// mode.
    private static let controlColumnHeight =
        CameraView.controlCellHeight * CGFloat(ExposureMode.allCases.count)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let liftLimit = CameraView.liftLimit(for: width)
            // Clamped on the way out as well as on the way in, so a width that
            // changed under a lift can't leave the square oversubscribed.
            let lift = isEditingFilter ? min(panelLift, liftLimit) : 0

            VStack(spacing: 0) {
                viewer(edge: width - lift)
                sourceIndicator
                exposureRows

                if isEditingFilter {
                    FilterPanel(look: camera.look,
                                isBusy: camera.isCapturing,
                                isRAWAvailable: camera.isRAWAvailable,
                                negativeStatus: camera.negativeStatus,
                                isMonochromeLocked: camera.isMonochromeLocked,
                                primaryTitle: camera.versionSource == nil ? "Snap" : "Capture Version",
                                lift: $panelLift,
                                liftLimit: liftLimit,
                                onSnap: { primaryAction(titled: false) },
                                onSave: { primaryAction(titled: true) },
                                onLoad: { isLoadingLook = true },
                                onClose: { setEditing(false) }) {
                        roll(selection: camera.versionSource,
                             requiresNegative: true,
                             onSelect: selectForVersion)
                    }
                } else {
                    Spacer(minLength: 0)
                    controlRow
                    Spacer(minLength: 0)

                    textButton("Filter") { setEditing(true) }
                        .offset(y: -10)

                    roll(selection: viewing, onSelect: { viewing = $0 })
                        .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     camera.start()
            case .background: camera.stop()
            default:          break
            }
        }
        .sheet(item: $camera.pendingTitle) { shot in
            SaveShotSheet(store: store,
                          shot: shot,
                          onCancel: { camera.pendingTitle = nil },
                          onSave: { title, notes in
                              store.update(shot, title: title, notes: notes)
                              camera.pendingTitle = nil
                          })
        }
        .sheet(isPresented: $isLoadingLook) {
            LoadLookSheet(store: store,
                          onSelect: { shot in
                              useLook(shot)
                              isLoadingLook = false
                          },
                          onCancel: { isLoadingLook = false })
        }
        .sheet(item: $share) { ShareSheet(urls: $0.urls) }
        .alert("Something went wrong",
               isPresented: Binding(get: { camera.errorMessage != nil },
                                    set: { if !$0 { camera.errorMessage = nil } }),
               presenting: camera.errorMessage) { _ in
            Button("OK", role: .cancel) { camera.errorMessage = nil }
        } message: { reason in
            Text(reason)
        }
    }

    // MARK: - Viewer

    @ViewBuilder
    private func viewer(edge: CGFloat) -> some View {
        ZStack {
            if let viewing {
                ShotView(store: store, shot: viewing, edge: edge, showsRAW: $showsRAW)
            } else if camera.versionSource != nil {
                livePreview
                    // Holding a negative that is under the sliders shows the
                    // development with no look on it, the same way the
                    // saved-frame viewer peeks.
                    .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                        if !pressing { camera.setPeekingSource(false) }
                    }, perform: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        camera.setPeekingSource(true)
                    })
            } else {
                livePreview
                    .overlay { ThirdsGrid() }
                    .overlay { focusRing(edge: edge) }
                    // The two gestures are kept apart: a tap anywhere lets
                    // focus go, a second of holding pins it where the finger
                    // is. A long press carries no location of its own, so the
                    // drag alongside it is what supplies one.
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { pressLocation = $0.location }
                            .onEnded { _ in
                                // A touch that never became a hold is a tap,
                                // and a tap lets focus go.
                                if didLockFocus {
                                    didLockFocus = false
                                } else {
                                    camera.releaseFocus()
                                    withAnimation(.easeOut(duration: 0.15)) { focusPoint = nil }
                                }
                            }
                            .simultaneously(with: LongPressGesture(minimumDuration: 1)
                                .onEnded { _ in
                                    didLockFocus = true
                                    lockFocus(at: pressLocation, edge: edge)
                                })
                    )
            }

            // A short black blink, the way a mechanical shutter reads.
            Color.black
                .opacity(camera.isShutterFlashing ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: edge, height: edge)
        .clipped()
    }

    @ViewBuilder
    private var livePreview: some View {
        switch camera.state {
        case .running:
            CameraPreview(renderer: camera.renderer)
        case .starting:
            Color.black
        case .denied:
            message("Snap needs access to your camera.", showsSettingsLink: true)
        case .failed(let reason):
            message(reason, showsSettingsLink: false)
        }
    }

    /// Names what the viewer is currently showing. Only meaningful while a
    /// saved frame is up — the live preview is neither.
    private var indicatorLabel: String {
        if camera.versionSource != nil {
            return camera.isPeekingSource ? "RAW" : "VERSION"
        }
        guard viewing != nil else { return "" }
        return showsRAW ? "RAW" : "JPEG"
    }

    /// How far the chosen exposure sits from what the meter wants, in stops.
    ///
    /// Shown only when the exposure is being driven by hand — in auto the
    /// camera holds this at zero, so it would be a permanent zero teaching
    /// nothing. This is the honest way to answer "am I about to underexpose
    /// this": the preview can't show noise the sensor hasn't produced yet, but
    /// the meter knows exactly how far off the settings are. Tapping it hands
    /// the reading back as an Exposure setting — see `ExposureMeterReadout`.
    @ViewBuilder
    private var exposureMeter: some View {
        if viewing == nil, camera.exposureMode != .auto {
            ExposureMeterReadout(meter: camera.meter, look: camera.look)
        }
    }

    @ViewBuilder
    private var sourceIndicator: some View {
        HStack {
            exposureMeter
            Spacer()
            Text(indicatorLabel)
                .font(.system(size: 10, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(showsRAW || camera.isPeekingSource ? 0.85 : 0.5))
                .animation(.easeOut(duration: 0.12), value: indicatorLabel)
                .padding(.trailing, 6)
        }
        // The inset is 8 here and 6 inside the readout, so both numbers still
        // sit 14 from the edge while the meter carries a target worth aiming at.
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .frame(height: 22)
    }

    private func roll(selection: Shot?,
                      requiresNegative: Bool = false,
                      onSelect: @escaping (Shot) -> Void) -> some View {
        FilmStrip(store: store,
                  selection: selection,
                  onSelect: onSelect,
                  onUseLook: useLook,
                  onShare: { share = ShareItem($0) },
                  onDelete: delete,
                  requiresNegative: requiresNegative)
    }

    /// How much room the value rows hold open.
    ///
    /// Both rows' worth on the camera screen, whichever mode is lit. The filter
    /// panel gets whatever the rows actually need instead: the mode buttons
    /// aren't reachable from there, so nothing can appear that would push
    /// anything, and the sliders would rather have the height.
    private var reservedRowHeight: CGFloat? {
        isEditingFilter ? nil : ValueRowMetrics.height * 2
    }

    /// Shutter and ISO, shown only for the mode that is actually deciding
    /// them. S/I decides both, so it shows both.
    ///
    /// The block holds the height of both rows whether or not either is in it.
    /// Switching mode should reveal a row, not shove the shutter and the roll
    /// down the screen — the frame above is the thing being composed, and it
    /// shouldn't move because the exposure is being talked about.
    private var exposureRows: some View {
        VStack(spacing: 0) {
            if viewing == nil, camera.exposureMode != .auto {
                ValueRow(label: "S",
                         values: camera.shutterSpeeds,
                         title: { $0.label },
                         selection: $camera.shutterSpeed)

                if camera.exposureMode == .manual {
                    ValueRow(label: "ISO",
                             values: camera.isoOptions.map(ISOChoice.init),
                             title: { ISOSetting.label($0.value) },
                             selection: Binding(
                                get: { camera.iso.map(ISOChoice.init) },
                                set: { camera.iso = $0?.value }
                             ))
                }
            }
        }
        .frame(height: reservedRowHeight, alignment: .top)
        .padding(.top, 2)
    }

    // MARK: - Controls

    private var controlRow: some View {
        VStack(spacing: 4) {
            shutterRow

            // Held in place but hidden while a saved frame is up, so nothing
            // moves when the shutter becomes an X.
            lensPicker
                .opacity(viewing == nil ? 1 : 0)
                .allowsHitTesting(viewing == nil)
        }
    }

    private var shutterRow: some View {
        ZStack {
            if viewing != nil {
                CloseButton { viewing = nil }
            } else {
                ShutterButton(isBusy: camera.isCapturing) { camera.capture() }

                Button {
                    camera.capturePreviewFrame()
                } label: {
                    Text("PS")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 38, height: 38)
                        .overlay { Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1) }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(camera.isCapturing)
                // Just clear of the shutter's ring, and well clear of the
                // exposure stepper at the trailing edge.
                .offset(x: 68)
                .accessibilityLabel("Capture preview frame")

                // The same distance out on the other side, so the two round
                // buttons sit level and equally far from their own edge.
                MonochromeToggle(look: camera.look, isLocked: camera.isMonochromeLocked)
                    .offset(x: -68)

                // These sit in the live branch, like the two round buttons
                // beside the shutter, so a saved frame being looked at leaves
                // the X on its own: none of it applies to a photograph that
                // has already been taken.
                HStack(alignment: .center) {
                    exposureModeColumn

                    Spacer()

                    VStack(spacing: 4) {
                        ExposureControl(look: camera.look)
                        isoPicker
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        // Held to the height of the mode column so that swapping the shutter
        // for the X, which is shorter than both, doesn't move the row.
        .frame(maxWidth: .infinity, minHeight: CameraView.controlColumnHeight)
    }

    /// A, S and S/I — the three that mean anything on a fixed iris, see
    /// ExposureSettings. A is a mode like the others rather than the absence of
    /// one: leaving by tapping the lit button was a hidden move, and it made
    /// the row's state depend on what had been tapped before.
    ///
    /// Stacked rather than laid across, which keeps this column narrow enough
    /// to leave the row's outer thirds to the two round buttons.
    private var exposureModeColumn: some View {
        VStack(spacing: 0) {
            ForEach(ExposureMode.allCases) { mode in
                Button {
                    camera.exposureMode = mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(camera.exposureMode == mode ? Color.snapAccent : .white.opacity(0.75))
                        // A fixed cell, so the column's height is a number this
                        // file knows rather than whatever the font decides.
                        .frame(width: 30, height: CameraView.controlCellHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeOut(duration: 0.12), value: camera.exposureMode)
    }

    /// ISO, under the exposure stepper. AUTO sits at the top of the list.
    private var isoPicker: some View {
        Menu {
            Button("AUTO") { camera.iso = nil }
            ForEach(camera.isoOptions, id: \.self) { value in
                Button(ISOSetting.label(value)) { camera.iso = value }
            }
        } label: {
            Text(ISOSetting.label(camera.iso))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(camera.iso == nil ? .white.opacity(0.5) : Color.snapAccent)
                .frame(minWidth: 34)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("ISO")
    }

    @ViewBuilder
    private func focusRing(edge: CGFloat) -> some View {
        if let focusPoint, camera.isFocusLocked {
            Circle()
                .strokeBorder(Color.snapAccent, lineWidth: 1.5)
                .frame(width: 20, height: 20)
                .position(focusPoint)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    private func lockFocus(at location: CGPoint, edge: CGFloat) {
        guard edge > 0 else { return }
        let normalized = CGPoint(x: min(max(location.x / edge, 0), 1),
                                 y: min(max(location.y / edge, 0), 1))
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) { focusPoint = location }
        camera.lockFocus(at: normalized)
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One dot per lens, widening left to right the way the lenses do, centred
    /// under the shutter. Hidden on a single-camera device, where there is
    /// nothing to choose.
    @ViewBuilder
    private var lensPicker: some View {
        if camera.lenses.count > 1 {
            HStack(spacing: 0) {
                ForEach(Array(camera.lenses.enumerated()), id: \.element.id) { index, lens in
                    let diameter = 7 + CGFloat(index) * 3.5
                    let isCurrent = lens == camera.currentLens

                    Button {
                        camera.selectLens(lens)
                    } label: {
                        Circle()
                            .fill(isCurrent ? Color.white : Color.clear)
                            .overlay {
                                Circle().strokeBorder(Color.white.opacity(isCurrent ? 0 : 0.55),
                                                      lineWidth: 1)
                            }
                            .frame(width: diameter, height: diameter)
                            // The dot is far too small to aim at; the tap
                            // target isn't.
                            .frame(width: 26, height: CameraView.controlCellHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lens.name)
                }
            }
        }
    }

    @ViewBuilder
    private func message(_ text: String, showsSettingsLink: Bool) -> some View {
        VStack(spacing: 16) {
            Text(text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            if showsSettingsLink, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(32)
    }

    // MARK: - Actions

    /// How far the panel may be pulled up. Past this the square stops being a
    /// viewfinder, so the drag stops here rather than letting it go.
    private static func liftLimit(for width: CGFloat) -> CGFloat {
        max(0, width * 0.45)
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isEditingFilter = editing
            // The lift belongs to one visit to the panel: the square is whole
            // when it opens and whole again when it closes.
            panelLift = 0
            // A frame that was being looked at stays up. Filter is a change of
            // controls, not of subject, and throwing the photograph away to
            // show a live preview nobody asked for is the wrong half to keep.
            // Only what versioning borrowed is handed back on the way out.
            if !editing { camera.endVersioning() }
        }
    }

    /// Snap and Save both go through here: they take a live frame normally,
    /// and re-filter the loaded negative when there is one, so the panel's
    /// menu always acts on whatever the viewer is showing. Either way the
    /// frame is marked as having come out of the filter screen.
    private func primaryAction(titled: Bool) {
        if camera.versionSource == nil {
            camera.capture(titled: titled, origin: .filter)
        } else {
            camera.captureVersion(titled: titled)
        }
    }

    /// Tapping a frame while the filter panel is open loads its negative under
    /// the sliders; tapping the same one again lets the camera back through.
    private func selectForVersion(_ shot: Shot) {
        // The viewer shows one thing at a time: a negative under the sliders
        // takes it back from a saved frame that was carried in from the camera
        // screen.
        viewing = nil

        if camera.versionSource?.id == shot.id {
            camera.endVersioning()
        } else {
            camera.beginVersioning(from: shot)
        }
    }

    private func useLook(_ shot: Shot) {
        camera.look.apply(store.profile(for: shot))
    }

    private func delete(_ shot: Shot) {
        if viewing?.id == shot.id { viewing = nil }
        if camera.versionSource?.id == shot.id { camera.endVersioning() }
        store.delete(shot)
    }
}

/// A rule-of-thirds guide, light enough to compose against without competing
/// with the frame.
private struct ThirdsGrid: View {

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                for step in 1...2 {
                    let fraction = CGFloat(step) / 3
                    let x = geometry.size.width * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geometry.size.height))

                    let y = geometry.size.height * fraction
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// Black-and-white mode, sitting to the left of the shutter as PS sits to its
/// right.
///
/// A circle cut rim to rim by one diagonal, the same size as PS. Switching it
/// on inverts the whole thing — white disc, black cut — so the state reads from
/// across the room rather than from three letters.
private struct MonochromeToggle: View {

    @ObservedObject var look: LookModel
    var isLocked: Bool

    private var isOn: Bool { look.profile.blackAndWhite }

    var body: some View {
        Button {
            look.profile.blackAndWhite.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(isOn ? Color.white : Color.clear)
                    .overlay {
                        Circle().strokeBorder(Color.white.opacity(isOn ? 0 : 0.5), lineWidth: 1)
                    }

                Diagonal()
                    .stroke(isOn ? Color.black : Color.white.opacity(0.8),
                            // The same hairline as the ring around it, and as
                            // PS's ring across the shutter.
                            style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    // Just enough inset that the round caps stop at the rim
                    // rather than poking through it.
                    .padding(1)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.45 : 1)
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityLabel("Black and white")
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// One line across the circle that shares its bounds, bottom-left to top-right,
/// landing on the rim at both ends rather than on the corners of the square.
private struct Diagonal: Shape {

    func path(in rect: CGRect) -> Path {
        // A 45° line meets a circle of radius r at r/√2 in each direction.
        let reach = min(rect.width, rect.height) / 2 / CGFloat(2).squareRoot()
        var path = Path()
        path.move(to: CGPoint(x: rect.midX - reach, y: rect.midY + reach))
        path.addLine(to: CGPoint(x: rect.midX + reach, y: rect.midY - reach))
        return path
    }
}

/// The meter reading, and the correction one tap of it makes.
///
/// The sign flips on the way through: a frame the meter says is 1.5 stops under
/// is a frame that wants +1.5 of Exposure. It replaces rather than accumulates,
/// because the reading is about what the camera is doing and doesn't move when
/// the develop exposure does — adding would double a correction already made,
/// and tapping twice should mean the same thing as tapping once.
private struct ExposureMeterReadout: View {

    @ObservedObject var meter: ExposureMeter
    /// Written, not watched. The readout has no reason to redraw because a
    /// slider somewhere else moved.
    let look: LookModel

    var body: some View {
        let offset = meter.offset
        let magnitude = abs(offset)

        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            look.profile.exposure = min(max(-offset, -5), 5)
        } label: {
            Text(magnitude < 0.05 ? "0.0 EV" : String(format: "%+.1f EV", offset))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(magnitude >= 1.5 ? Color.snapAccent
                                 : .white.opacity(magnitude >= 0.5 ? 0.8 : 0.45))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: magnitude >= 1.5)
        .accessibilityLabel("Exposure meter")
        .accessibilityHint("Applies the reading to the exposure setting")
    }
}

/// Owns the binding to the look's exposure, so the stepper stays in step with
/// the panel's slider and only this redraws when either moves.
private struct ExposureControl: View {

    @ObservedObject var look: LookModel

    var body: some View {
        ExposureStepper(value: $look.profile.exposure, range: -5...5)
    }
}

/// A saved frame shown in the viewer area.
///
/// Holding on it swaps to the negative — same square, no look — so the two can
/// be compared without leaving the screen.
private struct ShotView: View {

    @ObservedObject var store: ShotStore
    let shot: Shot
    let edge: CGFloat
    @Binding var showsRAW: Bool

    @State private var jpeg: UIImage? = nil
    @State private var raw: UIImage? = nil

    private var hasRAW: Bool { store.rawURL(for: shot) != nil }

    var body: some View {
        ZStack {
            Color.black

            if let image = (showsRAW ? raw : jpeg) ?? jpeg {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
            if !pressing { showsRAW = false }
        }, perform: {
            guard hasRAW, raw != nil else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showsRAW = true
        })
        .task(id: shot.id) {
            showsRAW = false
            let pixels = edge * 3

            let jpegURL = store.imageURL(for: shot)
            jpeg = await Task.detached(priority: .userInitiated) {
                ShotStore.image(at: jpegURL, maxPixelSize: pixels)
            }.value

            // Developed up front, not on the gesture — demosaicing takes long
            // enough that peeking would otherwise stutter.
            raw = nil
            guard let rawURL = store.rawURL(for: shot) else { return }
            let profile = shot.profile
            raw = await Task.detached(priority: .utility) {
                RAWDeveloper.previewImage(at: rawURL,
                                          profile: profile,
                                          maxPixelSize: pixels,
                                          context: CIContext(options: [.cacheIntermediates: false]))
            }.value
        }
    }
}
