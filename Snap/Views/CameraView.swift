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

    private var store: ShotStore { camera.store }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                viewer(edge: geometry.size.width)
                sourceIndicator

                if isEditingFilter {
                    FilterPanel(look: camera.look,
                                isBusy: camera.isCapturing,
                                isRAWAvailable: camera.isRAWAvailable,
                                negativeStatus: camera.negativeStatus,
                                primaryTitle: camera.versionSource == nil ? "Snap" : "Version",
                                onSnap: { primaryAction(titled: false) },
                                onSave: { primaryAction(titled: true) },
                                onLoad: { isLoadingLook = true },
                                onBundle: makeBundle,
                                onClose: { setEditing(false) }) {
                        roll(selection: camera.versionSource, onSelect: selectForVersion)
                    }
                } else {
                    Spacer(minLength: 0)
                    controlRow
                    Spacer(minLength: 0)
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
            } else {
                livePreview
                    // Holding a negative that is under the sliders shows the
                    // development with no look on it, the same way the
                    // saved-frame viewer peeks.
                    .onLongPressGesture(minimumDuration: 0.25, pressing: { pressing in
                        if !pressing { camera.setPeekingSource(false) }
                    }, perform: {
                        guard camera.versionSource != nil else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        camera.setPeekingSource(true)
                    })
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

    @ViewBuilder
    private var sourceIndicator: some View {
        HStack {
            Spacer()
            Text(indicatorLabel)
                .font(.system(size: 10, weight: .medium))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(showsRAW || camera.isPeekingSource ? 0.85 : 0.5))
                .animation(.easeOut(duration: 0.12), value: indicatorLabel)
        }
        .padding(.trailing, 14)
        .padding(.top, 6)
        .frame(height: 18)
        .opacity(indicatorLabel.isEmpty ? 0 : 1)
    }

    private func roll(selection: Shot?, onSelect: @escaping (Shot) -> Void) -> some View {
        FilmStrip(store: store,
                  selection: selection,
                  onSelect: onSelect,
                  onUseLook: useLook,
                  onShare: { share = ShareItem($0) },
                  onDelete: delete)
    }

    // MARK: - Controls

    private var controlRow: some View {
        ZStack {
            if viewing != nil {
                CloseButton { viewing = nil }
            } else {
                ShutterButton(isBusy: camera.isCapturing) { camera.capture() }
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    textButton("Filter") { setEditing(true) }
                    lensMenu
                }

                Spacer()

                if viewing == nil {
                    ExposureControl(look: camera.look)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(maxWidth: .infinity)
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

    /// Lens picker. Hidden on a single-camera device, where there is nothing
    /// to choose.
    @ViewBuilder
    private var lensMenu: some View {
        if camera.lenses.count > 1 {
            Menu {
                ForEach(camera.lenses) { lens in
                    Button {
                        camera.selectLens(lens)
                    } label: {
                        if lens == camera.currentLens {
                            Label(lens.name, systemImage: "checkmark")
                        } else {
                            Text(lens.name)
                        }
                    }
                }
            } label: {
                Text("Camera")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
