//
//  CameraView.swift
//  Snap
//
//  Preview at the top. Below it either the shutter and the app's own roll, or
//  the develop editor that replaces them.
//

import SwiftUI
import UIKit

struct CameraView: View {

    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDeveloping = false
    @State private var isLoadingLook = false
    @State private var isShowingFavorites = false
    /// Whether the roll is showing under the bar. The grid button on the bar
    /// owns this; it starts up, since the roll is most of what the bar is for.
    @State private var isShowingStrip = true
    @State private var share: ShareItem? = nil
    /// A saved frame being viewed in place of the live preview.
    @State private var viewing: Shot? = nil
    /// Which list a swipe in the viewer walks: the whole roll, or the
    /// favourites the frame was opened from.
    @State private var viewerScope: ViewerScope = .roll
    /// True while a caption is being typed, which is when the square gives up
    /// height to the keyboard.
    @State private var isCaptioning = false
    /// True while the viewer is being held down to show the negative.
    @State private var showsRAW = false
    /// Where focus is pinned, in the preview's own coordinates.
    @State private var focusPoint: CGPoint? = nil
    @State private var pressLocation: CGPoint = .zero
    /// Set when a hold pinned focus, so the touch ending doesn't immediately
    /// read as the tap that releases it.
    @State private var didLockFocus = false
    /// How far the develop panel has been pulled up over the preview, in
    /// points. The square gives up exactly this much.
    @State private var panelLift: CGFloat = 0

    private var store: ShotStore { camera.store }

    /// Where the frame in the viewer was chosen, which is the sequence a swipe
    /// moves along. Opening a frame from the grid keeps you among the ones you
    /// kept; opening it from the roll walks the roll.
    private enum ViewerScope {
        case roll
        case favorites
    }

    /// One cell of the lens column and of the mode column beside it, so the two
    /// stay level whatever the font does.
    private static let controlCellHeight: CGFloat = 30

    /// The mode column is the tallest thing in the control row: one cell per
    /// mode.
    private static let controlColumnHeight =
        CameraView.controlCellHeight * CGFloat(ExposureMode.allCases.count)

    /// What the same row needs while a saved frame is up, which is the X's
    /// touch target and nothing else.
    private static let closeRowHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let liftLimit = CameraView.liftLimit(for: width)
            // Clamped on the way out as well as on the way in, so a width that
            // changed under a lift can't leave the square oversubscribed.
            let lift = isDeveloping ? min(panelLift, liftLimit) : 0

            VStack(spacing: 0) {
                // The frame and the two rows that describe it. Drawn over
                // everything below, so the capture controls slide up behind it
                // rather than across it when the panel opens.
                VStack(spacing: 0) {
                    viewer(edge: CameraView.viewerEdge(width: width,
                                                       height: geometry.size.height,
                                                       lift: lift,
                                                       isCaptioning: isCaptioning))
                    sourceIndicator
                    exposureRows
                }
                .background(Color.black)
                .zIndex(1)

                // Everything that belongs to taking a photograph rather than
                // developing one. It leaves upward, which is what makes room
                // for the sliders and what the bar below rides up into.
                if !isDeveloping {
                    VStack(spacing: 0) {
                        caption
                        // The caption keeps its distance from what is under it
                        // however much room the screen has to spare.
                        Spacer(minLength: 15)
                        controlRow
                        Spacer(minLength: 0)
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // The bar and the roll under it: the same two things in the
                // same order on every screen. Opening the panel doesn't move
                // them apart, it lifts the pair.
                actionBar(liftLimit: liftLimit)

                if isDeveloping {
                    Divider().overlay(Color.white.opacity(0.12))
                }

                if isShowingStrip {
                    roll
                        .padding(.top, 2)
                        .padding(.bottom, 10)
                        .transition(.opacity)

                    if isDeveloping {
                        Divider().overlay(Color.white.opacity(0.12))
                    }
                }

                if isDeveloping {
                    DevelopPanel(look: camera.look,
                                 isRAWAvailable: camera.isRAWAvailable,
                                 negativeStatus: camera.negativeStatus,
                                 isMonochromeLocked: camera.isMonochromeLocked,
                                 info: developInfo)
                        .transition(.opacity)
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
                          onSave: { title, caption in
                              store.update(shot, title: title, caption: caption)
                              camera.pendingTitle = nil
                          })
        }
        .sheet(isPresented: $isLoadingLook) {
            LoadLookSheet(store: store,
                          onSelect: { shot in
                              useLook(shot)
                              isLoadingLook = false
                          },
                          onDelete: delete,
                          onCancel: { isLoadingLook = false })
        }
        .sheet(isPresented: $isShowingFavorites) {
            FavoritesGrid(store: store,
                          onSelect: openFromFavorites,
                          onToggleFavorite: toggleFavorite,
                          onClose: { isShowingFavorites = false })
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
                    .gesture(swipe { step(by: $0) })
                    .onTapGesture(count: 2) { toggleFavorite(viewing) }
            } else if let source = camera.versionSource {
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
                    // A negative under the sliders is still a frame being
                    // looked at, so it moves and is kept the same way.
                    .gesture(swipe { stepVersion(by: $0) })
                    .onTapGesture(count: 2) { toggleFavorite(source) }
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

    /// Whether the frame in the viewer is kept, shown in the row below the
    /// frame rather than on top of it — a photograph is worth more undisturbed
    /// than a corner of it is worth as a label.
    @ViewBuilder
    private var viewerFavoriteMark: some View {
        if let id = viewing?.id ?? camera.versionSource?.id {
            FavoriteMark(store: store, id: id)
        }
    }

    /// The caption for the frame being reviewed, under what the frame says
    /// about itself and above the button that puts it down.
    ///
    /// Keyed to the frame, so swiping to the next one starts a new draft rather
    /// than carrying the last one along — and the view that goes away on the
    /// way saves what was in it.
    @ViewBuilder
    private var caption: some View {
        if let viewing {
            CaptionField(shot: viewing,
                         isEditing: $isCaptioning,
                         onCommit: { setCaption($0, for: viewing) })
                .id(viewing.id)
                .padding(.horizontal, 14)
                .padding(.top, 15)
        }
    }

    /// A horizontal drag on a frame moves to the one beside it.
    ///
    /// The roll runs newest to oldest, left to right, so a swipe that carries
    /// the frame leftward moves the way the strip does: to the older one. The
    /// distance is long enough, and vertical drift disqualifying enough, that a
    /// hold that wandered still peeks rather than turning the page.
    private func swipe(_ step: @escaping (Int) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let width = value.translation.width
                guard abs(width) > 44, abs(width) > abs(value.translation.height) else { return }
                step(width < 0 ? 1 : -1)
            }
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
    /// Up whenever the camera is what is on screen, in auto as well as by hand.
    /// It used to appear only for the modes that drive the exposure themselves,
    /// on the grounds that auto holds it at zero and a permanent zero teaches
    /// nothing — but it doesn't sit at zero: it wanders as auto chases the
    /// scene, and watching it settle is how you know the meter has. A frame in
    /// the viewer is the one thing that puts it away, since the reading belongs
    /// to the camera and not to a photograph already taken.
    ///
    /// This is the honest way to answer "am I about to underexpose this": the
    /// preview can't show noise the sensor hasn't produced yet, but the meter
    /// knows exactly how far off the settings are. Tapping it hands the reading
    /// back as an Exposure setting — see `ExposureMeterReadout`.
    @ViewBuilder
    private var exposureMeter: some View {
        if viewing == nil {
            ExposureMeterReadout(meter: camera.meter, look: camera.look)
        }
    }

    @ViewBuilder
    private var sourceIndicator: some View {
        HStack(spacing: 6) {
            // Opposite the label that says what is being shown: one side of the
            // row says which frame this is, the other says which of its two
            // renderings.
            viewerFavoriteMark
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

    /// The roll, laid once and carried by the bar above it wherever that bar
    /// goes. Which frame it outlines and what tapping one means are the only
    /// things that change with the screen: a negative to put under the sliders
    /// while the panel is open, a frame to look at otherwise.
    private var roll: some View {
        FilmStrip(store: store,
                  selection: isDeveloping ? camera.versionSource : viewing,
                  onSelect: isDeveloping ? selectForVersion : openFromRoll,
                  onToggleFavorite: toggleFavorite,
                  onUseLook: useLook,
                  onShare: { share = ShareItem($0) },
                  onDelete: delete,
                  requiresNegative: isDeveloping)
            // Rebuilt when the panel opens or closes, which is what makes it
            // scroll to the frame it opened with: the strip reveals its
            // selection as it appears.
            .id(isDeveloping)
    }

    /// How much room the value rows hold open.
    ///
    /// Both rows' worth on the camera screen, whichever mode is lit. The develop
    /// panel gets whatever the rows actually need instead: the mode buttons
    /// aren't reachable from there, so nothing can appear that would push
    /// anything, and the sliders would rather have the height.
    private var reservedRowHeight: CGFloat? {
        isDeveloping ? nil : ValueRowMetrics.height * 2
    }

    /// Shutter and ISO, shown only for the mode that is actually deciding
    /// them. S/I decides both, so it shows both.
    ///
    /// The block holds the height of both rows whether or not either is in it.
    /// Switching mode should reveal a row, not shove the shutter and the roll
    /// down the screen — the frame above is the thing being composed, and it
    /// shouldn't move because the exposure is being talked about.
    ///
    /// A saved frame borrows the space. The rows decide how the *next*
    /// photograph is exposed and say nothing about one already taken, while the
    /// readout that does — when and where it was taken, and on what — has
    /// exactly this room to say it in.
    private var exposureRows: some View {
        VStack(spacing: 0) {
            if let viewing {
                ShotInfoBar(source: infoSource(for: viewing))
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
            } else if camera.exposureMode != .auto {
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
            // Above the shutter, since they decide how the next photograph is
            // taken. Held in place but hidden while a saved frame is up, for
            // the same reason the lens dots are.
            SubProfileToggles(look: camera.look)
                .opacity(viewing == nil ? 1 : 0)
                .allowsHitTesting(viewing == nil)

            shutterRow

            // Held in place but hidden while a saved frame is up. The dots
            // mean nothing for a photograph already taken, and keeping their
            // space is what stops the X sliding down into it while the row
            // above them gives its height to the caption.
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
        // The live row is held to the height of the mode column, the tallest
        // thing in it, so nothing moves as modes come and go. A saved frame
        // needs only the X, and the height it hands back goes to the caption.
        .frame(maxWidth: .infinity,
               minHeight: viewing == nil ? CameraView.controlColumnHeight : CameraView.closeRowHeight)
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

    /// The one bar of buttons, in the one place it lives. What it can do grows
    /// while the panel is open; where it sits and what is already on it do not
    /// change.
    private func actionBar(liftLimit: CGFloat) -> some View {
        ActionBar(store: store,
                  isDeveloping: isDeveloping,
                  canDevelop: canDevelop,
                  isBusy: camera.isCapturing,
                  isStripVisible: isShowingStrip,
                  primaryTitle: camera.versionSource == nil ? "Snap" : "Capture Version",
                  lift: $panelLift,
                  liftLimit: liftLimit,
                  onDevelop: { setEditing(true) },
                  onFavorites: { isShowingFavorites = true },
                  onToggleStrip: toggleStrip,
                  onLoad: { isLoadingLook = true },
                  onSave: { primaryAction(titled: true) },
                  onSnap: { primaryAction(titled: false) },
                  onReset: { camera.look.reset() },
                  onClose: { setEditing(false) })
    }

    private func toggleStrip() {
        withAnimation(.easeInOut(duration: 0.22)) { isShowingStrip.toggle() }
    }

    /// What the develop panel says about the frame under the sliders. The live
    /// camera has nothing to say there — it isn't a photograph yet, and its
    /// exposure is on the rows above.
    private var developInfo: ShotInfoSource? {
        camera.versionSource.map(infoSource)
    }

    /// The frame's own file is what the readout reads, in the viewer and under
    /// the sliders alike. The sub-profiles are the one thing it is handed
    /// rather than reads: they are in the file's EXIF too, inside the look, but
    /// the sidecar already has them in hand.
    private func infoSource(for shot: Shot) -> ShotInfoSource {
        ShotInfoSource(id: shot.id,
                       url: store.imageURL(for: shot),
                       date: shot.createdAt,
                       subProfiles: shot.profile.activeSubProfiles)
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

    /// What sits between the bottom of the square and the bottom of the caption
    /// field: the row that names the rendering, the room the value rows hold
    /// open, the field itself, and a little air under it.
    private static let captionReserve: CGFloat = 160

    /// The edge of the square.
    ///
    /// Normally the width, less whatever the develop panel has been pulled over
    /// it. While a caption is being typed the keyboard takes the bottom of the
    /// screen with it, and the square gives up the difference the same way it
    /// gives up height to the panel — so the frame, what it says about itself
    /// and the words being written about it all stay above the keys. It never
    /// gives up more than half, since a caption is written about a photograph
    /// and the photograph has to still be there.
    private static func viewerEdge(width: CGFloat,
                                   height: CGFloat,
                                   lift: CGFloat,
                                   isCaptioning: Bool) -> CGFloat {
        let edge = width - lift
        guard isCaptioning else { return edge }
        return min(edge, max(width * 0.5, height - captionReserve))
    }

    /// Whether Develop can be pressed.
    ///
    /// A frame in the viewer comes into the panel as a negative under the
    /// sliders, so one that has no negative has nowhere to go: a preview frame
    /// is a finished JPEG and there is nothing left to re-grade. The button is
    /// out rather than misleading, and putting the frame down brings it back.
    private var canDevelop: Bool {
        guard let viewing else { return true }
        return store.rawURL(for: viewing) != nil
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isDeveloping = editing
            // The lift belongs to one visit to the panel: the square is whole
            // when it opens and whole again when it closes.
            panelLift = 0

            if editing {
                // The frame being looked at comes along, as the negative
                // behind it rather than as the finished JPEG — otherwise the
                // sliders would be moving under a photograph they cannot
                // touch. Same square, same subject, now live.
                if let viewing { camera.beginVersioning(from: viewing) }
                viewing = nil
            } else {
                camera.endVersioning()
            }
        }
    }

    /// Snap and Save both go through here: they take a live frame normally,
    /// and re-filter the loaded negative when there is one, so the panel's
    /// menu always acts on whatever the viewer is showing. Either way the
    /// frame is marked as having come out of the develop screen.
    private func primaryAction(titled: Bool) {
        if camera.versionSource == nil {
            camera.capture(titled: titled, origin: .develop)
        } else {
            camera.captureVersion(titled: titled)
        }
    }

    /// Tapping a frame while the develop panel is open loads its negative under
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

    /// Opening a frame is also what decides which list a swipe will walk.
    private func openFromRoll(_ shot: Shot) {
        viewerScope = .roll
        viewing = shot
    }

    private func openFromFavorites(_ shot: Shot) {
        isShowingFavorites = false

        // The panel's own strip loads a frame as the negative under the
        // sliders, and a frame chosen from the grid while the panel is open
        // should mean the same thing. One with no negative can't be developed,
        // so it goes to the viewer instead, which means putting the panel down.
        if isDeveloping {
            if store.rawURL(for: shot) != nil {
                viewing = nil
                camera.beginVersioning(from: shot)
                return
            }
            setEditing(false)
        }

        viewerScope = .favorites
        viewing = shot
    }

    /// Moves the viewer along the list the frame was opened from.
    ///
    /// Stops at either end rather than wrapping: the roll has a beginning and
    /// an end, and a swipe that jumped silently from one to the other would
    /// lose your place in it.
    private func step(by offset: Int) {
        guard let viewing else { return }
        let sequence = viewerSequence(containing: viewing)
        guard let index = sequence.firstIndex(where: { $0.id == viewing.id }),
              sequence.indices.contains(index + offset) else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.viewing = sequence[index + offset]
    }

    /// The favourites while the viewer is walking those and the frame is still
    /// one of them. Letting a frame go mid-walk hands the rest of it back to
    /// the roll rather than stranding the swipe.
    private func viewerSequence(containing shot: Shot) -> [Shot] {
        guard viewerScope == .favorites else { return store.shots }
        let favorites = store.favorites
        return favorites.contains(where: { $0.id == shot.id }) ? favorites : store.shots
    }

    /// The same swipe over a negative under the sliders, walking only the
    /// frames that have one — the rest have nothing to develop.
    private func stepVersion(by offset: Int) {
        guard let source = camera.versionSource else { return }
        let sequence = store.shots.filter { store.rawURL(for: $0) != nil }
        guard let index = sequence.firstIndex(where: { $0.id == source.id }),
              sequence.indices.contains(index + offset) else { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        camera.beginVersioning(from: sequence[index + offset])
    }

    /// Saves a caption, and takes the viewer's own copy of the frame with it so
    /// the field isn't left comparing what was typed against what used to be
    /// there.
    private func setCaption(_ caption: String, for shot: Shot) {
        store.setCaption(caption, for: shot)
        if viewing?.id == shot.id {
            viewing = store.shots.first { $0.id == shot.id }
        }
    }

    /// A double tap keeps a frame or lets it go, from the roll, the viewer or
    /// the grid. Keeping is the firmer of the two knocks, since it is the one
    /// that adds something.
    private func toggleFavorite(_ shot: Shot) {
        let kept = withAnimation(.easeOut(duration: 0.18)) {
            store.toggleFavorite(shot)
        }
        UIImpactFeedbackGenerator(style: kept ? .medium : .light).impactOccurred()
    }

    private func delete(_ shot: Shot) {
        if viewing?.id == shot.id { viewing = nil }
        if camera.versionSource?.id == shot.id { camera.endVersioning() }
        camera.delete(shot)
    }
}

/// The heart under the viewer, at the leading end of the row the JPEG/RAW
/// label sits at the other end of.
///
/// Watches the roll rather than being handed a frame, because the frame the
/// viewer is holding is a copy taken before the double tap that changed it.
private struct FavoriteMark: View {

    @ObservedObject var store: ShotStore
    let id: UUID

    var body: some View {
        if store.shots.contains(where: { $0.id == id && $0.isFavorite }) {
            Image(systemName: "heart.fill")
                // The size and the weight of the label opposite it, so the two
                // ends of the row read as one line.
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.leading, 6)
                .allowsHitTesting(false)
                .transition(.scale.combined(with: .opacity))
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

/// Indoor and Night, above the shutter.
///
/// A house and a moon, lit in the one colour this interface has for something
/// switched on. They lay a few settings over the base look rather than editing
/// it — see `SubProfile` — so the panel's sliders go on showing the base while
/// one of these is on, and switching it off puts the frame back exactly.
///
/// Watches the look itself, so a toggle redraws two glyphs rather than the
/// whole camera screen.
private struct SubProfileToggles: View {

    @ObservedObject var look: LookModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SubProfile.allCases) { subProfile in
                let isOn = look.profile.subProfiles.contains(subProfile)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    look.profile.toggle(subProfile)
                } label: {
                    Image(systemName: subProfile.symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isOn ? Color.snapAccent : .white.opacity(0.5))
                        // Small glyphs, ordinary-sized targets.
                        .frame(width: 36, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(subProfile.label)
                .accessibilityValue(isOn ? "on" : "off")
            }
        }
        .animation(.easeOut(duration: 0.12), value: look.profile.subProfiles)
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
