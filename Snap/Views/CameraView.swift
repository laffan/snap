//
//  CameraView.swift
//  Snap
//
//  Preview at the top. Below it either the shutter, or the filter editor that
//  replaces it.
//

import SwiftUI
import UIKit

struct CameraView: View {

    @StateObject private var camera = CameraModel()
    @StateObject private var store = PresetStore()
    @Environment(\.scenePhase) private var scenePhase

    @State private var isEditingFilter = false
    @State private var isLoading = false
    @State private var bundle: BundleFile? = nil

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                previewFrame(edge: geometry.size.width)

                if isEditingFilter {
                    FilterPanel(look: camera.look,
                                isBusy: camera.isCapturing,
                                onSnap: { camera.capture(to: .cameraRoll) },
                                onSave: { camera.capture(to: .preset) },
                                onLoad: { isLoading = true },
                                onBundle: makeBundle,
                                onClose: { withAnimation(.easeInOut(duration: 0.22)) { isEditingFilter = false } })
                } else {
                    shutterRow
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
        .sheet(item: $camera.pendingSave) { pending in
            SavePresetSheet(image: UIImage(data: pending.imageData),
                            onCancel: { camera.pendingSave = nil },
                            onSave: { title, notes in
                                save(pending, title: title, notes: notes)
                            })
        }
        .sheet(isPresented: $isLoading) {
            LoadPresetSheet(store: store,
                            onSelect: { preset in
                                camera.look.apply(preset)
                                isLoading = false
                            },
                            onCancel: { isLoading = false })
        }
        .sheet(item: $bundle) { ShareSheet(url: $0.url) }
        .alert("Something went wrong",
               isPresented: Binding(get: { camera.errorMessage != nil },
                                    set: { if !$0 { camera.errorMessage = nil } }),
               presenting: camera.errorMessage) { _ in
            Button("OK", role: .cancel) { camera.errorMessage = nil }
        } message: { reason in
            Text(reason)
        }
    }

    // MARK: - Preview

    @ViewBuilder
    private func previewFrame(edge: CGFloat) -> some View {
        ZStack {
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

            // A short black blink, the way a mechanical shutter reads.
            Color.black
                .opacity(camera.isShutterFlashing ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: edge, height: edge)
        .clipped()
    }

    // MARK: - Shutter

    private var shutterRow: some View {
        ZStack {
            ShutterButton(isBusy: camera.isCapturing) {
                camera.capture(to: .cameraRoll)
            }

            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { isEditingFilter = true }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
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

    private func save(_ pending: CameraModel.PendingSave, title: String, notes: String) {
        do {
            try store.save(profile: pending.profile,
                           title: title,
                           notes: notes,
                           imageData: pending.imageData,
                           imageType: pending.imageType)
            camera.pendingSave = nil
        } catch {
            camera.pendingSave = nil
            camera.errorMessage = error.localizedDescription
        }
    }

    private func makeBundle() {
        do {
            bundle = BundleFile(url: try store.makeBundle())
        } catch {
            camera.errorMessage = error.localizedDescription
        }
    }
}
