//
//  FilterPanel.swift
//  Snap
//
//  The lower half of the screen when the filter editor is open: every knob the
//  look exposes, grouped the way Lightroom groups them, over a sticky action
//  bar.
//

import SwiftUI

struct FilterPanel<Strip: View>: View {

    @ObservedObject var look: LookModel

    var isBusy: Bool
    var isRAWAvailable: Bool
    var negativeStatus: CameraModel.NegativeStatus?
    /// "Snap" for a live capture, "Version" when a stored negative is loaded.
    var primaryTitle: String
    var onSnap: () -> Void
    var onSave: () -> Void
    var onLoad: () -> Void
    var onBundle: () -> Void
    var onClose: () -> Void
    /// The roll, handed in so the panel doesn't need to know about the store.
    @ViewBuilder var strip: Strip

    private var editing: (Bool) -> Void {
        { look.setInteracting($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    basic
                    toneCurve
                    colorMixer
                    calibration
                    raw
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            Divider().overlay(Color.white.opacity(0.12))
            strip
                .padding(.vertical, 8)
            Divider().overlay(Color.white.opacity(0.12))
            actionBar
        }
        .background(Color.black)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Filter")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Button("Reset") { look.reset() }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))

            Button("Done", action: onClose)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.leading, 16)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var basic: some View {
        FilterSection(title: "Basic") {
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
            .padding(.top, 2)
        }
    }

    private var toneCurve: some View {
        FilterSection(title: "Tone Curve") {
            SliderRow(label: "S-Curve", value: $look.profile.toneCurveS,
                      range: 0...100, onEditingChanged: editing)
            SliderRow(label: "Black Lift", value: $look.profile.blackLift,
                      range: 0...0.15, decimals: 3, onEditingChanged: editing)
        }
    }

    private var colorMixer: some View {
        FilterSection(title: "Color Mixer") {
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
        FilterSection(title: "Calibration") {
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
        FilterSection(title: "RAW") {
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

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            action(primaryTitle, weight: .semibold, action: onSnap)
            action("Save", action: onSave)
            action("Load", action: onLoad)
            action("Bundle", action: onBundle)
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.4 : 1)
        .padding(.vertical, 10)
        .padding(.bottom, 4)
    }

    private func action(_ title: String,
                        weight: Font.Weight = .regular,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: weight))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
