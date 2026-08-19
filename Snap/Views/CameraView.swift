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

    private var store: ShotStore { camera.store }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                viewer(edge: geometry.size.width)
                sourceIndicator
                exposureRows

                if isEditingFilter {
                    FilterPanel(look: camera.look,
                                isBusy: camera.isCapturing,
                                isRAWAvailable: camera.isRAWAvailable,
                                negativeStatus: camera.negativeStatus,
                                isMonochromeLocked: camera.isMonochromeLocked,
                                primaryTitle: camera.versionSource == nil ? "Snap" : "Version",
                                onSnap: { primaryAction(titled: false) },
                                onSave: { primaryAction(titled: true) },
                                onLoad: { isLoadingLook = true },
                                onBundle: makeBundle,
                                onClose: { setEditing(false) }) {
                        roll(selection: camera.versionSource,
                             requiresNegative: true,
                             onSelect: selectForVersion)
                    }
                } else {
                    Spacer(minLength: 0)
                    controlRow
                    Spacer(minLength: 0)

                    HStack {
                        textButton("Filter") { setEditing(true) }
                        Spacer()
                    }
                    .padding(.horizontal, 6)

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
    /// the meter knows exactly how far off the settings are.
    @ViewBuilder
    private var exposureMeter: some View {
        if viewing == nil, camera.exposureMode != .auto {
            let offset = camera.exposureOffset
            let magnitude = abs(offset)

            Text(magnitude < 0.05 ? "0.0 EV" : String(format: "%+.1f EV", offset))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(magnitude >= 1.5 ? Color.snapAccent
                                 : .white.opacity(magnitude >= 0.5 ? 0.8 : 0.45))
                .animation(.easeOut(duration: 0.15), value: magnitude >= 1.5)
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
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .frame(height: 18)
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

    /// Shutter and ISO, shown only for the mode that is actually deciding
    /// them. Manual decides both, so it shows both.
    @ViewBuilder
    private var exposureRows: some View {
        if viewing == nil, camera.exposureMode != .auto {
            VStack(spacing: 0) {
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
            .padding(.top, 2)
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
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
                // Just clear of the shutter's 74pt ring, and well clear of the
                // exposure stepper at the trailing edge.
                .offset(x: 64)
                .accessibilityLabel("Capture preview frame")
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    exposureModeRow
                    lensPicker
                    MonochromeToggle(look: camera.look, isLocked: camera.isMonochromeLocked)
                }

                Spacer()

                if viewing == nil {
                    VStack(spacing: 4) {
                        ExposureControl(look: camera.look)
                        isoPicker
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
    }

    /// The f-number sits where an aperture-priority button would, because the
    /// lens has one aperture and nothing to prioritise. S and M are the modes
    /// that mean something here.
    private var exposureModeRow: some View {
        HStack(spacing: 2) {
            if let aperture = camera.aperture {
                Text(String(format: "\u{0192}%.1f", aperture))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
            }

            ForEach([ExposureMode.shutter, .manual]) { mode in
                Button {
                    // Tapping the lit mode drops back to auto.
                    camera.exposureMode = camera.exposureMode == mode ? .auto : mode
                } label: {
                    Text(mode.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(camera.exposureMode == mode ? Color.snapAccent : .white.opacity(0.75))
                        .frame(width: 26)
                        .padding(.vertical, 8)
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

    /// One dot per lens, widening left to right the way the lenses do. Hidden
    /// on a single-camera device, where there is nothing to choose.
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
                            .frame(width: 26, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(lens.name)
                }
            }
            .padding(.leading, 8)
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

    private func setEditing(_ editing: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isEditingFilter = editing
            // The viewer is either the live camera, a saved frame, or a
            // negative being re-filtered — never two at once.
            if editing {
                viewing = nil
            } else {
                camera.endVersioning()
            }
        }
    }

    /// Snap and Save both go through here: they take a live frame normally,
    /// and re-filter the loaded negative when there is one, so the action bar
    /// always acts on whatever the viewer is showing.
    private func primaryAction(titled: Bool) {
        if camera.versionSource == nil {
            camera.capture(titled: titled)
        } else {
            camera.captureVersion(titled: titled)
        }
    }

    /// Tapping a frame while the filter panel is open loads its negative under
    /// the sliders; tapping the same one again lets the camera back through.
    private func selectForVersion(_ shot: Shot) {
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

    private func makeBundle() {
        do {
            share = ShareItem([try store.makeBundle()])
        } catch {
            camera.errorMessage = error.localizedDescription
        }
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

/// Black-and-white mode. Yellow when on — the only colour the interface uses,
/// so switched-on always looks the same.
private struct MonochromeToggle: View {

    @ObservedObject var look: LookModel
    var isLocked: Bool

    var body: some View {
        Button {
            look.profile.blackAndWhite.toggle()
        } label: {
            Text("B&W")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(look.profile.blackAndWhite ? Color.snapAccent : .white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .animation(.easeOut(duration: 0.12), value: look.profile.blackAndWhite)
        .accessibilityLabel("Black and white")
        .accessibilityValue(look.profile.blackAndWhite ? "on" : "off")
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
