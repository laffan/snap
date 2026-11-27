//
//  DevelopPanel.swift
//  Snap
//
//  Every knob the look exposes, laid out the way Lightroom's develop module
//  lays them out on a phone: a histogram across the top, one tool open at a
//  time, and the row of tools along the bottom where the thumb already is.
//
//  It used to be one long list of collapsible groups. Forty sliders in a list
//  is a wall, however it folds, and it made the one group being worked on
//  share the screen with every group that wasn't. A tool open on its own is
//  the solo mode Lightroom's panels have always had, made the only mode.
//
//  Just the controls: the bar that opens and closes this, and the roll it
//  carries, live above it in `ActionBar` — one row of buttons in one place,
//  whichever screen is up.
//

import SwiftUI
import UIKit

// MARK: - Tools

/// The tools along the bottom of the panel, in Lightroom's order.
enum DevelopTool: String, CaseIterable, Identifiable {
    case light, curve, color, grading, effects, detail, geometry, calibration, more

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .curve: return "Curve"
        case .color: return "Color"
        case .grading: return "Grading"
        case .effects: return "Effects"
        case .detail: return "Detail"
        case .geometry: return "Geometry"
        case .calibration: return "Calibrate"
        case .more: return "RAW"
        }
    }

    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .curve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .color: return "thermometer"
        case .grading: return "circle.lefthalf.filled"
        case .effects: return "camera.filters"
        case .detail: return "triangle"
        case .geometry: return "perspective"
        case .calibration: return "camera.aperture"
        case .more: return "ellipsis.circle"
        }
    }
}

/// The groups inside the tools: what each section heading resets, and which
/// tool it belongs to — which is what lights the dot over a tool that has
/// something moved in it.
enum DevelopGroup: CaseIterable {
    case light
    case parametricCurve, pointCurve, lookCurve
    case whiteBalance, presence, mixer
    case grading
    case effects, vignette, grain
    case sharpening, noiseReduction
    case transform
    case calibration, infrared
    case raw

    var tool: DevelopTool {
        switch self {
        case .light: return .light
        case .parametricCurve, .pointCurve, .lookCurve: return .curve
        case .whiteBalance, .presence, .mixer: return .color
        case .grading: return .grading
        case .effects, .vignette, .grain: return .effects
        case .sharpening, .noiseReduction: return .detail
        case .transform: return .geometry
        case .calibration, .infrared: return .calibration
        case .raw: return .more
        }
    }

    /// Puts this group's settings back to the built-in look's.
    ///
    /// Black and white is in none of them: it is a way of shooting that
    /// outlives the app, and has its own switch beside the shutter. Neither
    /// are the sub-profiles, which are switches too.
    func reset(_ profile: inout PositiveFilmProfile) {
        let base = DevelopGroup.base
        switch self {
        case .light:
            profile.exposure = base.exposure
            profile.contrast = base.contrast
            profile.highlights = base.highlights
            profile.shadows = base.shadows
            profile.whites = base.whites
            profile.blacks = base.blacks
        case .parametricCurve:
            profile.parametricCurve = base.parametricCurve
        case .pointCurve:
            profile.pointCurve = base.pointCurve
        case .lookCurve:
            profile.toneCurveS = base.toneCurveS
            profile.blackLift = base.blackLift
        case .whiteBalance:
            profile.temperature = base.temperature
            profile.tint = base.tint
        case .presence:
            profile.vibrance = base.vibrance
            profile.saturation = base.saturation
        case .mixer:
            profile.bands = base.bands
        case .grading:
            profile.colorGrade = base.colorGrade
        case .effects:
            profile.texture = base.texture
            profile.clarity = base.clarity
            profile.dehaze = base.dehaze
        case .vignette:
            profile.vignetteAmount = base.vignetteAmount
            profile.vignetteMidpoint = base.vignetteMidpoint
            profile.vignetteFeather = base.vignetteFeather
        case .grain:
            profile.grainAmount = base.grainAmount
            profile.grainSize = base.grainSize
            profile.grainRoughness = base.grainRoughness
        case .sharpening:
            profile.sharpness = base.sharpness
            profile.sharpenRadius = base.sharpenRadius
        case .noiseReduction:
            profile.luminanceNoiseReduction = base.luminanceNoiseReduction
            profile.colorNoiseReduction = base.colorNoiseReduction
        case .transform:
            profile.straighten = base.straighten
            profile.perspectiveVertical = base.perspectiveVertical
            profile.perspectiveHorizontal = base.perspectiveHorizontal
        case .calibration:
            profile.redPrimary = base.redPrimary
            profile.greenPrimary = base.greenPrimary
            profile.bluePrimary = base.bluePrimary
        case .infrared:
            profile.infrared = base.infrared
        case .raw:
            profile.rawBoost = base.rawBoost
        }
    }

    /// Made once: every heading and every tool's dot asks this on each redraw.
    private static let base = PositiveFilmProfile()

    func isChanged(_ profile: PositiveFilmProfile) -> Bool {
        var reset = profile
        self.reset(&reset)
        return reset != profile
    }
}

// MARK: - Panel

struct DevelopPanel: View {

    @ObservedObject var look: LookModel
    /// What the viewer is drawing, for the histogram.
    let renderer: PreviewRenderer

    var isRAWAvailable: Bool
    var negativeStatus: CameraModel.NegativeStatus?
    /// True when the loaded negative was shot monochrome, which it stays.
    var isMonochromeLocked: Bool
    /// True while a capture is in flight, which is when saving a look — which
    /// takes one — has nothing to do.
    var isBusy: Bool
    /// The frame under the sliders, for the readout at the top. Nil while the
    /// sliders are moving over the live camera, which is not a photograph and
    /// has no timestamp, place or settings to report.
    var info: ShotInfoSource?
    /// Deletes the frame under the sliders. Nil over the live camera, which is
    /// not a photograph yet and has nothing to throw away.
    var onDelete: (() -> Void)?
    var onLoad: () -> Void
    var onSave: () -> Void

    /// Which tool is open. Kept across launches: whichever one was last in use
    /// is the likeliest to be wanted next.
    @AppStorage("develop.tool") private var tool: DevelopTool = .light
    /// The mixer's band, the curve's channel and the grading wheel on show.
    @State private var band = 0
    @State private var curveChannel: CurveChannel = .parametric
    @State private var gradeRange: GradeRange = .midtones

    @StateObject private var histogram = HistogramModel()

    /// A few times a second is plenty for a histogram, and costs nothing when
    /// the frame hasn't changed.
    private static let ticker = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    /// The built-in look, for the marks on the sliders that show where it sits.
    private static let base = PositiveFilmProfile()

    init(look: LookModel,
         renderer: PreviewRenderer,
         isRAWAvailable: Bool,
         negativeStatus: CameraModel.NegativeStatus?,
         isMonochromeLocked: Bool,
         isBusy: Bool,
         info: ShotInfoSource?,
         onDelete: (() -> Void)?,
         onLoad: @escaping () -> Void,
         onSave: @escaping () -> Void) {
        self.look = look
        self.renderer = renderer
        self.isRAWAvailable = isRAWAvailable
        self.negativeStatus = negativeStatus
        self.isMonochromeLocked = isMonochromeLocked
        self.isBusy = isBusy
        self.info = info
        self.onDelete = onDelete
        self.onLoad = onLoad
        self.onSave = onSave
    }

    private var editing: (Bool) -> Void {
        { look.setInteracting($0) }
    }

    /// A binding to one of the settings a sub-profile is allowed to hold,
    /// which takes it back off whichever one is holding it as it moves.
    ///
    /// Indoor sets Temperature, Night sets Exposure and Shadows, and Infrared
    /// sets its own amount, and a sub-profile sets rather than nudges — so
    /// without this, moving one of those sliders with one lit changed a number the
    /// renderer then overwrote, and the photograph did not move. Every slider
    /// in this panel changes the photograph; that is what a develop panel is.
    private func byHand(_ setting: SubProfile.Setting) -> Binding<Float> {
        // The model rather than the view: a binding outlives the redraw that
        // made it, and what it needs to hold on to is the one object, not a
        // copy of the panel around it.
        let look = self.look
        return Binding(get: { look.profile[keyPath: setting.keyPath] },
                       set: { look.setByHand(setting, to: $0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let info {
                            ShotInfoBar(source: info, onDelete: onDelete)
                            Divider().overlay(Color.white.opacity(0.12))
                        }

                        content
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
                    .id("top")
                }
                .scrollIndicators(.hidden)
                // A new tool starts at its own top, not wherever the last one
                // was scrolled to.
                .onChange(of: tool) { _, _ in reader.scrollTo("top", anchor: .top) }
            }

            Divider().overlay(Color.white.opacity(0.12))
            toolBar
        }
        .background(Color.black)
        .onReceive(DevelopPanel.ticker) { _ in histogram.sample(renderer.currentImage) }
        .onAppear { look.markBefore() }
        .onDisappear { look.setShowingBefore(false) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            HistogramView(bins: histogram.bins)
                .frame(height: 46)
            BeforeButton(look: look)
        }
    }

    // MARK: - Tool bar

    private var toolBar: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(DevelopTool.allCases) { item in
                        toolButton(item)
                            .id(item)
                    }
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
            .onAppear { reader.scrollTo(tool, anchor: .center) }
        }
        .frame(height: 52)
    }

    private func toolButton(_ item: DevelopTool) -> some View {
        let isSelected = item == tool
        let isChanged = DevelopGroup.allCases.contains { $0.tool == item && $0.isChanged(look.profile) }

        return Button {
            guard item != tool else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            tool = item
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                    .frame(height: 18)
                Text(item.label)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(.white.opacity(isSelected ? 1 : 0.45))
            .frame(width: 52, height: 46)
            // A dot over any tool with something in it moved off the look, so
            // what has been done can be found without opening each one.
            .overlay(alignment: .topTrailing) {
                if isChanged {
                    Circle()
                        .fill(Color.white.opacity(isSelected ? 0.9 : 0.6))
                        .frame(width: 4, height: 4)
                        .padding(.top, 6)
                        .padding(.trailing, 12)
                }
            }
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 16, height: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tool {
        case .light: lightTool
        case .curve: curveTool
        case .color: colorTool
        case .grading: gradingTool
        case .effects: effectsTool
        case .detail: detailTool
        case .geometry: geometryTool
        case .calibration: calibrationTool
        case .more: moreTool
        }
    }

    /// A section heading with its reset wired to the group it names.
    private func section<Content: View>(_ title: String,
                                        _ group: DevelopGroup,
                                        @ViewBuilder content: () -> Content) -> some View {
        DevelopSection(title: title,
                       isChanged: group.isChanged(look.profile),
                       onReset: { reset(group) },
                       content: content)
    }

    private func reset(_ group: DevelopGroup) {
        var profile = look.profile
        group.reset(&profile)
        look.profile = profile
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func slider(_ label: String,
                        _ value: Binding<Float>,
                        range: ClosedRange<Float> = -100...100,
                        decimals: Int = 0,
                        neutral: Float = 0,
                        lookDefault: Float? = nil,
                        track: SliderTrack = .plain,
                        labelColor: Color = .white.opacity(0.75)) -> some View {
        DevelopSlider(label: label, value: value, range: range, decimals: decimals,
                      neutral: neutral, lookDefault: lookDefault, track: track,
                      labelColor: labelColor, onEditingChanged: editing)
    }

    // MARK: Light

    private var lightTool: some View {
        let base = DevelopPanel.base
        return section("Light", .light) {
            slider("Exposure", byHand(.exposure), range: -5...5, decimals: 2,
                   lookDefault: base.exposure, track: .exposure)
            slider("Contrast", $look.profile.contrast, lookDefault: base.contrast)
            slider("Highlights", $look.profile.highlights, lookDefault: base.highlights)
            slider("Shadows", byHand(.shadows), lookDefault: base.shadows)
            slider("Whites", $look.profile.whites, lookDefault: base.whites)
            slider("Blacks", $look.profile.blacks, lookDefault: base.blacks)
        }
    }

    // MARK: Curve

    enum CurveChannel: String, CaseIterable, Identifiable {
        case parametric, rgb, red, green, blue
        var id: String { rawValue }

        var label: String {
            switch self {
            case .parametric: return "Region"
            case .rgb: return "RGB"
            case .red: return "Red"
            case .green: return "Green"
            case .blue: return "Blue"
            }
        }

        var color: Color {
            switch self {
            case .parametric, .rgb: return .white
            case .red: return Color(red: 1, green: 0.4, blue: 0.4)
            case .green: return Color(red: 0.4, green: 0.9, blue: 0.45)
            case .blue: return Color(red: 0.45, green: 0.6, blue: 1)
            }
        }
    }

    private func pointCurveBinding(_ channel: CurveChannel) -> Binding<PointCurve> {
        switch channel {
        case .red: return $look.profile.pointCurve.red
        case .green: return $look.profile.pointCurve.green
        case .blue: return $look.profile.pointCurve.blue
        case .parametric, .rgb: return $look.profile.pointCurve.master
        }
    }

    private func isChanged(_ channel: CurveChannel) -> Bool {
        let profile = look.profile
        switch channel {
        case .parametric: return !profile.parametricCurve.isIdentity
        case .rgb: return !profile.pointCurve.master.isIdentity
        case .red: return !profile.pointCurve.red.isIdentity
        case .green: return !profile.pointCurve.green.isIdentity
        case .blue: return !profile.pointCurve.blue.isIdentity
        }
    }

    private var curveTool: some View {
        let base = DevelopPanel.base
        return VStack(alignment: .leading, spacing: 18) {
            // Region or point, and which channel: one row, the way
            // Lightroom's curve panel picks between them.
            HStack(spacing: 6) {
                ForEach(CurveChannel.allCases) { channel in
                    chip(channel.label,
                         color: channel.color,
                         isSelected: curveChannel == channel,
                         isChanged: isChanged(channel)) {
                        curveChannel = channel
                    }
                }
            }

            if curveChannel == .parametric {
                section("Region Curve", .parametricCurve) {
                    ParametricCurvePreview(curve: look.profile.parametricCurve,
                                           histogram: histogram.bins?.luminance)
                        .frame(maxWidth: 240)
                        .frame(maxWidth: .infinity)
                    slider("Highlights", $look.profile.parametricCurve.highlights)
                    slider("Lights", $look.profile.parametricCurve.lights)
                    slider("Darks", $look.profile.parametricCurve.darks)
                    slider("Shadows", $look.profile.parametricCurve.shadows)
                }
            } else {
                section("Point Curve", .pointCurve) {
                    ToneCurveEditor(curve: pointCurveBinding(curveChannel),
                                    tint: curveChannel.color,
                                    histogram: histogramFor(curveChannel),
                                    onEditingChanged: editing)
                        .frame(maxWidth: 260)
                        .frame(maxWidth: .infinity)
                    note("Touch the curve to add a point and drag it. Drag a point out of the box to take it off, double-tap to straighten.")
                }
            }

            // The look's own curve, which every frame wears under whatever is
            // drawn above.
            section("Look Curve", .lookCurve) {
                slider("S-Curve", $look.profile.toneCurveS, range: 0...100,
                       lookDefault: base.toneCurveS)
                slider("Black Lift", $look.profile.blackLift, range: 0...0.15, decimals: 3,
                       lookDefault: base.blackLift)
            }
        }
    }

    private func histogramFor(_ channel: CurveChannel) -> [Float]? {
        guard let bins = histogram.bins else { return nil }
        switch channel {
        case .red: return bins.red
        case .green: return bins.green
        case .blue: return bins.blue
        case .parametric, .rgb: return bins.luminance
        }
    }

    // MARK: Color

    private var colorTool: some View {
        let base = DevelopPanel.base
        return VStack(alignment: .leading, spacing: 18) {
            treatment

            section("White Balance", .whiteBalance) {
                slider("Temp", byHand(.temperature), lookDefault: base.temperature,
                       track: .temperature)
                slider("Tint", $look.profile.tint, lookDefault: base.tint, track: .tint)
            }

            section("Presence", .presence) {
                slider("Vibrance", $look.profile.vibrance, lookDefault: base.vibrance,
                       track: .saturation)
                slider("Saturation", $look.profile.saturation, lookDefault: base.saturation,
                       track: .saturation)
            }

            section("Color Mixer", .mixer) {
                mixer
            }
        }
    }

    /// Color or Black & White, as two halves of one switch — the way
    /// Lightroom puts the treatment at the head of its colour controls.
    private var treatment: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                treatmentHalf("Color", isOn: !look.profile.blackAndWhite) {
                    look.profile.blackAndWhite = false
                }
                treatmentHalf("Black & White", isOn: look.profile.blackAndWhite) {
                    look.profile.blackAndWhite = true
                }
            }
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(isMonochromeLocked)
            .opacity(isMonochromeLocked ? 0.5 : 1)

            if isMonochromeLocked {
                note("This frame was shot in black and white and stays that way. The colour is still in its DNG if you export it.")
            }
        }
    }

    private func treatmentHalf(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.black : .white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(isOn ? Color.white.opacity(0.9) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    /// One band at a time, picked from a row of its colours — Lightroom's
    /// mobile mixer — so the three sliders that matter are the only three on
    /// screen.
    @ViewBuilder
    private var mixer: some View {
        let bands = look.profile.bands
        let index = min(max(band, 0), max(bands.count - 1, 0))

        HStack(spacing: 0) {
            ForEach(bands.indices, id: \.self) { item in
                let isSelected = item == index
                let reference = DevelopPanel.base.bands.first { $0.name == bands[item].name }
                let isMoved = reference.map { $0 != bands[item] } ?? false

                Button {
                    band = item
                } label: {
                    Circle()
                        .fill(swatch(bands[item].center))
                        .frame(width: isSelected ? 22 : 18, height: isSelected ? 22 : 18)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white, lineWidth: isSelected ? 2 : 0)
                                .padding(-3)
                        }
                        .overlay(alignment: .bottom) {
                            if isMoved {
                                Circle()
                                    .fill(Color.white.opacity(0.7))
                                    .frame(width: 3, height: 3)
                                    .offset(y: 8)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bands[item].name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }

        if bands.indices.contains(index) {
            let center = bands[index].center
            let reference = DevelopPanel.base.bands.first { $0.name == bands[index].name }
            let name = bands[index].name

            slider("\(name) Hue", $look.profile.bands[index].hue,
                   lookDefault: reference?.hue,
                   track: .gradient([swatch(center - 30), swatch(center), swatch(center + 30)]))
            slider("\(name) Saturation", $look.profile.bands[index].saturation,
                   lookDefault: reference?.saturation,
                   track: .gradient([Color(white: 0.55), swatch(center, saturation: 0.9)]))
            slider("\(name) Luminance", $look.profile.bands[index].luminance,
                   lookDefault: reference?.luminance,
                   track: .gradient([swatch(center, brightness: 0.25), swatch(center),
                                     swatch(center, saturation: 0.25, brightness: 1)]))
        }
    }

    /// A band's colour, held back from full saturation so it stays legible on
    /// black.
    private func swatch(_ hue: Float, saturation: Double = 0.55, brightness: Double = 1) -> Color {
        var degrees = Double(hue).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        return Color(hue: degrees / 360, saturation: saturation, brightness: brightness)
    }

    // MARK: Grading

    enum GradeRange: String, CaseIterable, Identifiable {
        case shadows, midtones, highlights, global
        var id: String { rawValue }

        var label: String {
            switch self {
            case .shadows: return "Shadows"
            case .midtones: return "Midtones"
            case .highlights: return "Highlights"
            case .global: return "Global"
            }
        }
    }

    private func wheelBinding(_ range: GradeRange) -> Binding<GradeWheel> {
        switch range {
        case .shadows: return $look.profile.colorGrade.shadows
        case .midtones: return $look.profile.colorGrade.midtones
        case .highlights: return $look.profile.colorGrade.highlights
        case .global: return $look.profile.colorGrade.global
        }
    }

    private var gradingTool: some View {
        let wheel = wheelBinding(gradeRange)

        return section("Color Grading", .grading) {
            // The four ranges, each shown in the tint it is carrying, so the
            // whole grade can be read before any one wheel is opened.
            HStack(spacing: 0) {
                ForEach(GradeRange.allCases) { range in
                    let value = wheelBinding(range).wrappedValue
                    let isSelected = range == gradeRange

                    Button {
                        gradeRange = range
                    } label: {
                        VStack(spacing: 5) {
                            Circle()
                                .fill(Color(hue: Double(value.hue) / 360,
                                            saturation: Double(value.saturation) / 100 * 0.85,
                                            brightness: 0.55 + Double(value.luminance) / 100 * 0.3))
                                .frame(width: 20, height: 20)
                                .overlay {
                                    Circle()
                                        .strokeBorder(Color.white.opacity(isSelected ? 1 : 0.25),
                                                      lineWidth: isSelected ? 2 : 1)
                                }
                            Text(range.label)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(.white.opacity(isSelected ? 1 : 0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(range.label)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }

            HStack(alignment: .center, spacing: 16) {
                ColorWheel(hue: wheel.hue, saturation: wheel.saturation,
                           onEditingChanged: editing)
                    .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 4) {
                    readout("Hue", "\(Int(wheel.wrappedValue.hue.rounded()))°")
                    readout("Saturation", "\(Int(wheel.wrappedValue.saturation.rounded()))")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            slider("Luminance", wheel.luminance)

            Divider().overlay(Color.white.opacity(0.08))

            slider("Blending", $look.profile.colorGrade.blending, range: 0...100,
                   neutral: 50)
            slider("Balance", $look.profile.colorGrade.balance)
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    // MARK: Effects

    private var effectsTool: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Effects", .effects) {
                slider("Texture", $look.profile.texture)
                slider("Clarity", $look.profile.clarity)
                slider("Dehaze", $look.profile.dehaze)
            }

            section("Vignette", .vignette) {
                slider("Amount", $look.profile.vignetteAmount)
                slider("Midpoint", $look.profile.vignetteMidpoint, range: 0...100, neutral: 50)
                slider("Feather", $look.profile.vignetteFeather, range: 0...100, neutral: 50)
            }

            section("Grain", .grain) {
                slider("Amount", $look.profile.grainAmount, range: 0...100)
                slider("Size", $look.profile.grainSize, range: 0...100, neutral: 25)
                slider("Roughness", $look.profile.grainRoughness, range: 0...100, neutral: 50)
            }
        }
    }

    // MARK: Detail

    private var detailTool: some View {
        let base = DevelopPanel.base
        return VStack(alignment: .leading, spacing: 18) {
            section("Sharpening", .sharpening) {
                slider("Amount", $look.profile.sharpness, range: 0...100,
                       lookDefault: base.sharpness)
                slider("Radius", $look.profile.sharpenRadius, range: 0.5...3, decimals: 1,
                       neutral: 1)
            }

            section("Noise Reduction", .noiseReduction) {
                slider("Luminance", $look.profile.luminanceNoiseReduction, range: 0...100)
                slider("Color", $look.profile.colorNoiseReduction, range: 0...100)
            }

            note("Detail is easiest to judge at 100%: hold the frame with the loupe on to look while you move these.")
        }
    }

    // MARK: Geometry

    private var geometryTool: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Transform", .transform) {
                slider("Straighten", $look.profile.straighten, range: -45...45, decimals: 1)
                slider("Vertical", $look.profile.perspectiveVertical)
                slider("Horizontal", $look.profile.perspectiveHorizontal)
            }

            note("The square is kept full: turning or tilting the frame scales it up just far enough that no corner shows an edge.")
        }
    }

    // MARK: Calibration

    /// The three calibration primaries, and the hue each one sits at.
    private var primaries: [(name: String, hue: Float, binding: Binding<PositiveFilmProfile.Primary>)] {
        [("Red", 0, $look.profile.redPrimary),
         ("Green", 120, $look.profile.greenPrimary),
         ("Blue", 240, $look.profile.bluePrimary)]
    }

    private var calibrationTool: some View {
        let base = DevelopPanel.base
        let defaults = [base.redPrimary, base.greenPrimary, base.bluePrimary]

        return VStack(alignment: .leading, spacing: 18) {
            section("Calibration", .calibration) {
                ForEach(0..<3, id: \.self) { index in
                    let primary = primaries[index]
                    slider("\(primary.name) Hue", primary.binding.hue,
                           lookDefault: defaults[index].hue,
                           labelColor: swatch(primary.hue))
                    slider("\(primary.name) Saturation", primary.binding.saturation,
                           lookDefault: defaults[index].saturation,
                           labelColor: swatch(primary.hue))
                }
            }

            // What the Infrared sub-profile sets. Here because it is the same
            // kind of thing as the rows above — a remapping of what each
            // channel records — and by hand, like the other three a
            // sub-profile holds, so moving it under a lit leaf moves the
            // photograph.
            section("Infrared", .infrared) {
                slider("Amount", byHand(.infrared), range: 0...100)
            }
        }
    }

    // MARK: RAW and settings

    private var moreTool: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("RAW", .raw) {
                if isRAWAvailable {
                    note("Every shot is captured as sensor data — no JPEG is asked of the camera. The negative is developed here with Apple's noise reduction, sharpening and local tone mapping off, then cropped and graded into the JPEG.")

                    note(negativeNote)

                    slider("Apple Tone Curve", $look.profile.rawBoost, range: 0...100,
                           lookDefault: DevelopPanel.base.rawBoost)

                    note("0 is the fullest bypass and gives a linear response to the scene, which starts flatter than the live preview. Raise it to meet the preview.")
                } else {
                    note("This camera doesn't offer Bayer RAW, so captures fall back to the processed frame.")
                }
            }

            settingsActions
            CopyAdjustmentsButton(profile: look.profile)
        }
    }

    /// Loading and saving a look, at the foot of the panel's last tool.
    ///
    /// These were in a menu on the action bar, where they sat beside Reset and
    /// Done as though they were also ways out of the panel. They are neither
    /// that nor sliders, so they get the one place that is: beside each other,
    /// since they are the same errand in two directions.
    private var settingsActions: some View {
        HStack(spacing: 10) {
            settingsButton("Load Settings", action: onLoad)
            settingsButton("Save Settings", action: onSave)
        }
    }

    private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.4 : 1)
    }

    // MARK: Pieces

    private func chip(_ title: String,
                      color: Color,
                      isSelected: Bool,
                      isChanged: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                if isChanged {
                    Circle()
                        .fill(color.opacity(0.8))
                        .frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(isSelected ? Color.black : color.opacity(0.8))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(isSelected ? color.opacity(0.9) : Color.white.opacity(0.07))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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

// MARK: - Before

/// Hold to see the frame as it was when it came under the sliders; let go to
/// come back. Lightroom's before and after, as a press rather than a mode, so
/// it can never be left on by mistake.
private struct BeforeButton: View {

    @ObservedObject var look: LookModel

    var body: some View {
        let isAvailable = look.hasBefore || look.showsBefore

        VStack(spacing: 3) {
            Image(systemName: "square.split.2x1")
                .font(.system(size: 15, weight: .regular))
            Text("Before")
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(look.showsBefore ? Color.snapAccent : .white.opacity(isAvailable ? 0.75 : 0.3))
        .frame(width: 48, height: 46)
        .background(Color.white.opacity(look.showsBefore ? 0.12 : 0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isAvailable, !look.showsBefore else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    look.setShowingBefore(true)
                }
                .onEnded { _ in look.setShowingBefore(false) }
        )
        .accessibilityLabel("Before")
        .accessibilityHint("Hold to see the frame as it was before these changes.")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Region curve preview

/// The region curve as it stands, drawn over the frame's luminance. Shown,
/// not touched: the four sliders under it are how it moves, as in Lightroom.
private struct ParametricCurvePreview: View {

    let curve: ParametricCurve
    let histogram: [Float]?

    var body: some View {
        Canvas { context, size in
            if let histogram, histogram.count > 1 {
                let peak = max(histogram.dropFirst().dropLast().max() ?? 0, 0.0001)
                var shape = Path()
                let step = size.width / CGFloat(histogram.count - 1)
                shape.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in histogram.enumerated() {
                    let height = min(CGFloat(value / peak), 1) * size.height * 0.85
                    shape.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
                }
                shape.addLine(to: CGPoint(x: size.width, y: size.height))
                shape.closeSubpath()
                context.fill(shape, with: .color(.white.opacity(0.07)))
            }

            // The four regions' edges.
            var grid = Path()
            for quarter in 1...3 {
                let x = size.width * CGFloat(quarter) / 4
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 0.5)
            context.stroke(Path(CGRect(origin: .zero, size: size)),
                           with: .color(.white.opacity(0.18)), lineWidth: 1)

            var diagonal = Path()
            diagonal.move(to: CGPoint(x: 0, y: size.height))
            diagonal.addLine(to: CGPoint(x: size.width, y: 0))
            context.stroke(diagonal, with: .color(.white.opacity(0.15)),
                           style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))

            let samples = curve.sampled(count: 96)
            var line = Path()
            for (index, value) in samples.enumerated() {
                let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(samples.count - 1),
                                    y: size.height * (1 - CGFloat(value)))
                if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
        }
        .aspectRatio(1.6, contentMode: .fit)
        .accessibilityHidden(true)
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

        VStack(alignment: .leading, spacing: 10) {
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

            // The clipboard is not a place you can look, so what would be
            // copied is written out under the button that would copy it —
            // which also makes this the shortest way to read what this frame
            // is, without walking every tool looking for the ones that moved.
            ForEach(adjustments, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.easeOut(duration: 0.15), value: adjustments)
    }

    private func label(for adjustments: [String]) -> String {
        if adjustments.isEmpty { return "Nothing Adjusted" }
        if didCopy { return "Copied" }
        return "Copy Adjustments"
    }
}
