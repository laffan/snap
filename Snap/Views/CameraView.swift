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

    private var store: ShotStore { camera.store }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                viewer(edge: geometry.size.width)

                if isEditingFilter {
                    FilterPanel(look: camera.look,
                                isBusy: camera.isCapturing,
                                isRAWEnabled: $camera.isRAWEnabled,
                                isRAWAvailable: camera.isRAWAvailable,
                                onSnap: { camera.capture() },
                                onSave: { camera.capture(titled: true) },
                                onLoad: { isLoadingLook = true },
                                onBundle: makeBundle,
                                onClose: { setEditing(false) })
                } else {
                    Spacer(minLength: 0)
                    controlRow
                    Spacer(minLength: 0)
                    FilmStrip(store: store,
                              selection: viewing,
                              onSelect: { viewing = $0 },
                              onUseLook: useLook,
                              onShare: { share = ShareItem(url: $0) },
                              onDelete: delete)
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
        .sheet(item: $share) { ShareSheet(url: $0.url) }
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
                ShotView(store: store, shot: viewing, edge: edge)
            } else {
                livePreview
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

    // MARK: - Controls

    private var controlRow: some View {
        ZStack {
            if viewing != nil {
                CloseButton { viewing = nil }
            } else {
                ShutterButton(isBusy: camera.isCapturing) { camera.capture() }
            }

            HStack {
                Spacer()
                Button {
                    setEditing(true)
                } label: {
                    Text("Filter")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity)
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
            // The strip goes away with the shutter, so a frame being viewed
            // would have no way back.
            if editing { viewing = nil }
        }
    }

    private func useLook(_ shot: Shot) {
        camera.look.apply(store.profile(for: shot))
    }

    private func delete(_ shot: Shot) {
        if viewing?.id == shot.id { viewing = nil }
        store.delete(shot)
    }

    private func makeBundle() {
        do {
            share = ShareItem(url: try store.makeBundle())
        } catch {
            camera.errorMessage = error.localizedDescription
        }
    }
}

/// A saved frame shown in the viewer area.
private struct ShotView: View {

    @ObservedObject var store: ShotStore
    let shot: Shot
    let edge: CGFloat

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: shot.id) {
            let url = store.imageURL(for: shot)
            let pixels = edge * 3
            image = await Task.detached(priority: .userInitiated) {
                ShotStore.image(at: url, maxPixelSize: pixels)
            }.value
        }
    }
}
