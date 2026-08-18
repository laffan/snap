//
//  FilterPanel.swift
//  Snap
//
//  The lower half of the screen when the filter editor is open: every knob the
//  look exposes, grouped the way Lightroom groups them, over a sticky action
//  bar.
//

import SwiftUI

struct FilterPanel: View {

    @ObservedObject var look: LookModel

    var isBusy: Bool
    var onSnap: () -> Void
    var onSave: () -> Void
    var onLoad: () -> Void
    var onBundle: () -> Void
    var onClose: () -> Void

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
                    grain
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

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
            SliderRow(label: "Vibrance", value: $look.profile.vibrance,
                      onEditingChanged: editing)
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
            ForEach(look.profile.bands.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    Text(look.profile.bands[index].name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    SliderRow(label: "Hue", value: $look.profile.bands[index].hue,
                              onEditingChanged: editing)
                    SliderRow(label: "Saturation", value: $look.profile.bands[index].saturation,
                              onEditingChanged: editing)
                }
                .padding(.bottom, 6)
            }
        }
    }

    private var calibration: some View {
        FilterSection(title: "Calibration") {
            primary("Red Primary", $look.profile.redPrimary)
            primary("Green Primary", $look.profile.greenPrimary)
            primary("Blue Primary", $look.profile.bluePrimary)
        }
    }

    private func primary(_ name: String,
                         _ binding: Binding<PositiveFilmProfile.Primary>) -> some View {
        VStack(spacing: 2) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)

            SliderRow(label: "Hue", value: binding.hue, onEditingChanged: editing)
            SliderRow(label: "Saturation", value: binding.saturation, onEditingChanged: editing)
        }
        .padding(.bottom, 6)
    }

    private var grain: some View {
        FilterSection(title: "Grain") {
            SliderRow(label: "Amount", value: $look.profile.grainAmount,
                      range: 0...100, onEditingChanged: editing)
            SliderRow(label: "Size", value: $look.profile.grainSize,
                      range: 0.5...4, decimals: 2, neutral: 1, onEditingChanged: editing)
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            action("Snap", weight: .semibold, action: onSnap)
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
