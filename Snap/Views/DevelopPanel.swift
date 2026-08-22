//
//  DevelopPanel.swift
//  Snap
//
//  The lower half of the screen when the develop editor is open: every knob the
//  look exposes, grouped the way Lightroom groups them. The roll stays where it
//  always is, on the floor of the screen below this.
//
//  The header carries the panel's own actions in a menu beside its title, a
//  heart beside that, and a handle at its centre that trades preview for panel.
//

import SwiftUI
import UIKit

struct DevelopPanel<Favorites: View>: View {

    @ObservedObject var look: LookModel

    var isBusy: Bool
    var isRAWAvailable: Bool
    var negativeStatus: CameraModel.NegativeStatus?
    /// True when the loaded negative was shot monochrome, which it stays.
    var isMonochromeLocked: Bool
    /// "Snap" for a live capture, "Capture Version" when a stored negative is
    /// loaded.
    var primaryTitle: String
    /// The frame under the sliders, for the header's readout. Nil while the
    /// sliders are moving over the live camera, which is not a photograph and
    /// has no timestamp, place or settings to report.
    var info: ShotInfoSource?
    /// How far the panel has been pulled up over the preview, and how far it
    /// may go. The handle in the header owns the first and the camera screen
    /// decides the second.
    @Binding var lift: CGFloat
    var liftLimit: CGFloat
    var onSnap: () -> Void
    var onSave: () -> Void
    var onLoad: () -> Void
    var onClose: () -> Void
    /// The heart beside the menu, handed in so the panel doesn't need to know
    /// about the store.
    @ViewBuilder var favorites: Favorites

    private var editing: (Bool) -> Void {
        { look.setInteracting($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let info {
                        ShotInfoBar(source: info)
                        Divider().overlay(Color.white.opacity(0.12))
                    }

                    basic
                    toneCurve
                    colorMixer
                    calibration
                    raw
                    CopyAdjustmentsButton(profile: look.profile)
                        .padding(.top, 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            // The panel closes on a rule, with the roll under it.
            Divider().overlay(Color.white.opacity(0.12))
        }
        .background(Color.black)
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            HStack(spacing: 0) {
                Text("Develop")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                actionMenu

                favorites

                Spacer()

                Button("Reset") { look.reset() }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))

                Button("Done", action: onClose)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.leading, 16)
            }

            // Above the row rather than in it, so it sits at the centre of the
            // header and not at the centre of whatever is left over.
            PanelHandle(lift: $lift, limit: liftLimit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    /// Everything the panel can do that isn't a slider. These used to be a bar
    /// across the bottom; the room is better spent on the sliders.
    ///
    /// Ordered so the capture — the one that ends a session at the panel — sits
    /// nearest the thumb, with the two settings errands above it.
    private var actionMenu: some View {
        Menu {
            Button {
                onLoad()
            } label: {
                Label("Load Develop Settings", systemImage: "tray.and.arrow.down")
            }

            Button {
                onSave()
            } label: {
                Label("Save Develop Settings", systemImage: "square.and.pencil")
            }

            Button {
                onSnap()
            } label: {
                Label(primaryTitle, systemImage: "camera")
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.4 : 1)
        .accessibilityLabel("Develop actions")
    }

    // MARK: - Sections

    private var basic: some View {
        DevelopSection(title: "Basic") {
            SliderRow(label: "Exposure", value: $look.profile.exposure,
                      range: -5...5, decimals: 2, onEditingChanged: editing)
            SliderRow(label: "Contrast", value: $look.profile.contrast,
                      onEditingChanged: editing)
            SliderRow(label: "Highlights", value: $look.profile.highlights,
                      onEditingChanged: editing)
            SliderRow(label: "Shadows", value: $look.profile.shadows,
                      onEditingChanged: editing)
            SliderRow(label: "Blacks", value: $look.profile.blacks,
                      onEditingChanged: editing)
            SliderRow(label: "Clarity", value: $look.profile.clarity,
                      onEditingChanged: editing)
            SliderRow(label: "Sharpness", value: $look.profile.sharpness,
                      range: 0...100, onEditingChanged: editing)
            SliderRow(label: "Vibrance", value: $look.profile.vibrance,
                      onEditingChanged: editing)

            Toggle(isOn: $look.profile.blackAndWhite) {
                Text("Black & White")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .tint(Color.snapAccent)
            .disabled(isMonochromeLocked)
            .padding(.top, 2)

            if isMonochromeLocked {
                note("This frame was shot in black and white and stays that way. The colour is still in its DNG if you export it.")
            }
        }
    }

    private var toneCurve: some View {
        DevelopSection(title: "Tone Curve") {
            SliderRow(label: "S-Curve", value: $look.profile.toneCurveS,
                      range: 0...100, onEditingChanged: editing)
            SliderRow(label: "Black Lift", value: $look.profile.blackLift,
                      range: 0...0.15, decimals: 3, onEditingChanged: editing)
        }
    }

    private var colorMixer: some View {
        DevelopSection(title: "Color Mixer") {
            subheading("Hue")
            ForEach(look.profile.bands.indices, id: \.self) { index in
                SliderRow(label: look.profile.bands[index].name,
                          value: $look.profile.bands[index].hue,
                          labelColor: swatch(look.profile.bands[index].center),
                          onEditingChanged: editing)
            }

            subheading("Saturation")
            ForEach(look.profile.bands.indices, id: \.self) { index in
                SliderRow(label: look.profile.bands[index].name,
                          value: $look.profile.bands[index].saturation,
                          labelColor: swatch(look.profile.bands[index].center),
                          onEditingChanged: editing)
            }
        }
    }

    /// The three calibration primaries, and the hue each one sits at.
    private var primaries: [(name: String, hue: Float, binding: Binding<PositiveFilmProfile.Primary>)] {
        [("Red", 0, $look.profile.redPrimary),
         ("Green", 120, $look.profile.greenPrimary),
         ("Blue", 240, $look.profile.bluePrimary)]
    }

    private var calibration: some View {
        DevelopSection(title: "Calibration") {
            subheading("Hue")
            ForEach(primaries, id: \.name) { primary in
                SliderRow(label: primary.name,
                          value: primary.binding.hue,
                          labelColor: swatch(primary.hue),
                          onEditingChanged: editing)
            }

            subheading("Saturation")
            ForEach(primaries, id: \.name) { primary in
                SliderRow(label: primary.name,
                          value: primary.binding.saturation,
                          labelColor: swatch(primary.hue),
                          onEditingChanged: editing)
            }
        }
    }

    private func subheading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }

    /// Each band labelled in its own colour. Taken straight from the band's
    /// centre hue, held back from full saturation so it stays legible on black.
    private func swatch(_ hue: Float) -> Color {
        Color(hue: Double(hue) / 360, saturation: 0.55, brightness: 1)
    }

    @ViewBuilder
    private var raw: some View {
        DevelopSection(title: "RAW") {
            if isRAWAvailable {
                note("Every shot is captured as sensor data — no JPEG is asked of the camera. The negative is developed here with Apple's noise reduction, sharpening and local tone mapping off, then cropped and graded into the JPEG.")

                note(negativeNote)

                SliderRow(label: "Apple Tone Curve", value: $look.profile.rawBoost,
                          range: 0...100, onEditingChanged: editing)

                note("0 is the fullest bypass and gives a linear response to the scene, which starts flatter than the live preview. Raise it to meet the preview.")
            } else {
                note("This camera doesn't offer Bayer RAW, so captures fall back to the processed frame.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Reports what actually landed in the last negative rather than what the
    /// APIs advertise — guessing from the writable-type list is what hid the
    /// first failure.
    private var negativeNote: String {
        guard let negativeStatus else {
            return "The crop and the look are written for Camera Raw. Take a shot to see how much of it lands in the DNG itself."
        }
        switch (negativeStatus.croppedInFile, negativeStatus.settingsEmbedded) {
        case (true, true):
            return "Last negative: square crop written into the DNG, settings embedded. Any converter sees the crop; Lightroom sees the look."
        case (true, false):
            return "Last negative: square crop written into the DNG, but the settings wouldn't embed — they're in the .xmp sidecar, which Lightroom often skips for DNG files."
        case (false, true):
            return "Last negative: crop and settings both embedded in the DNG. Lightroom sees both; Photos and Preview show the full frame."
        case (false, false):
            return "Last negative: iOS wouldn't rewrite the DNG, so crop and settings are only in the .xmp sidecar. Keep the two files together, and use Metadata ▸ Read Metadata from File in Lightroom Classic."
        }
    }
}

// MARK: - Handle

/// The grab handle at the centre of the header.
///
/// Dragging it up pulls the panel over the preview square, which gives the
/// sliders room without ever hiding what the camera is looking at. The camera
/// screen puts it back when the panel closes.
private struct PanelHandle: View {

    @Binding var lift: CGFloat
    let limit: CGFloat

    /// Where the lift stood when this drag started. A drag reports its
    /// translation from where the finger went down, so without this every
    /// change would be measured from zero again.
    @State private var start: CGFloat? = nil

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 22, height: 1.5)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        // Measured globally: the handle is being carried by the panel it is
        // resizing, so a local translation would feed back into itself.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? lift
                    if start == nil { start = base }
                    lift = min(max(base - value.translation.height, 0), limit)
                }
                .onEnded { _ in start = nil }
        )
        .accessibilityLabel("Resize the develop panel")
    }
}

// MARK: - Copy adjustments

/// Copies everything that has moved off the built-in look, one setting per
/// line — the fastest way to get a look out of the app and into a note, a
/// message, or `PositiveFilmProfile.swift` itself.
private struct CopyAdjustmentsButton: View {

    let profile: PositiveFilmProfile

    @State private var didCopy = false

    var body: some View {
        let adjustments = profile.adjustments

        Button {
            UIPasteboard.general.string = adjustments.joined(separator: "\n")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(.easeOut(duration: 0.12)) { didCopy = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
            }
        } label: {
            Text(label(for: adjustments))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(adjustments.isEmpty ? 0.35 : 0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(adjustments.isEmpty)
    }

    private func label(for adjustments: [String]) -> String {
        if adjustments.isEmpty { return "Nothing Adjusted" }
        if didCopy { return "Copied" }
        return "Copy Adjustments"
    }
}
