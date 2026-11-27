//
//  Grade.swift
//  Snap
//
//  The per-pixel half of the look: everything that is a pure function of a
//  colour, in the order Lightroom applies it. `PositiveFilmFilter` samples
//  this into a 3D lookup table, so however much is added here the frame still
//  costs one texture fetch per pixel.
//
//  Kept apart from Core Image on purpose. This is the maths; the filter is the
//  plumbing that runs it over a frame.
//

import Foundation
import simd

struct Grade {

    let profile: PositiveFilmProfile

    private let calibration: simd_float3x3
    private let bands: [ResolvedBand]

    private let parametric: CurveTable?
    private let master: CurveTable?
    private let red: CurveTable?
    private let green: CurveTable?
    private let blue: CurveTable?

    private let colorGrade: ResolvedColorGrade?

    init(profile: PositiveFilmProfile) {
        self.profile = profile
        self.calibration = Grade.calibrationMatrix(for: profile)
        self.bands = Grade.resolvedBands(for: profile)

        func table(_ curve: PointCurve) -> CurveTable? {
            curve.isIdentity ? nil : CurveTable(curve.sampled(count: CurveTable.samples))
        }
        self.parametric = profile.parametricCurve.isIdentity
            ? nil
            : CurveTable(profile.parametricCurve.sampled(count: CurveTable.samples))
        self.master = table(profile.pointCurve.master)
        self.red = table(profile.pointCurve.red)
        self.green = table(profile.pointCurve.green)
        self.blue = table(profile.pointCurve.blue)

        self.colorGrade = profile.colorGrade.isNeutral ? nil : ResolvedColorGrade(profile.colorGrade)
    }

    /// The grade, in Lightroom's order: white balance, calibration, dehaze,
    /// the basic tones, presence, the colour mixer, the tone curves, black and
    /// white, and colour grading last of all — so grading a black-and-white
    /// frame tones it, the way split toning always has.
    func callAsFunction(_ input: RGB) -> RGB {
        // First, as white balance always is: everything downstream is built on
        // an assumption about what colour the light was.
        var color = clamp01(whiteBalanced(input,
                                          amount: profile.temperatureAmount,
                                          tint: profile.tintAmount))
        color = clamp01(calibration * color)
        // The scene as the sensor saw it, before the look has had its say
        // about greens — which is the only thing the infrared estimate can be
        // made from, and the look would otherwise have crushed half of it.
        let scene = color

        color = dehazed(color, amount: profile.dehazeAmount)
        color = clamp01(shiftBlacks(color, by: profile.blacksShift))
        color = clamp01(shiftWhites(color, by: profile.whitesShift))
        color = sCurve(color, amount: profile.contrastAmount)
        color = clamp01(applyVibrance(color, amount: profile.vibranceAmount))
        color = clamp01(applySaturation(color, scale: profile.saturationScale))
        color = applyColorMixer(color)

        // After the mixer rather than before it: the look takes Purple and
        // Magenta almost out, and those are exactly the colours infrared
        // foliage comes out as.
        let infraredAmount = profile.infraredAmount
        if infraredAmount > 0 {
            color = Grade.infrared(color, scene: scene, amount: infraredAmount)
        }

        // The tone curve stage. Region curve, then the look's own S, then the
        // hand-drawn point curve, then the matte foot — which is the order the
        // Camera Raw sidecar describes them in, so the negative opens wearing
        // the same curve — and the three channel curves after all of it.
        if let parametric {
            color = RGB(parametric(color.x), parametric(color.y), parametric(color.z))
        }
        color = sCurve(color, amount: profile.toneCurveAmount)
        if let master {
            color = RGB(master(color.x), master(color.y), master(color.z))
        }
        color = liftBlacks(color, by: profile.blackLift)
        if let red { color.x = red(color.x) }
        if let green { color.y = green(color.y) }
        if let blue { color.z = blue(color.z) }

        // Late, so the colour mixer still shapes the result: a band that was
        // desaturated arrives here darker or lighter than one that wasn't,
        // which is exactly how a black-and-white mixer works.
        if profile.blackAndWhite {
            let graded = clamp01(color)
            // Black-and-white infrared is the infrared record on its own:
            // white trees under a black sky. After the mapping above, that
            // record is the red channel.
            color = RGB(repeating: lerp(luma(graded), graded.x, infraredAmount))
        }

        if let colorGrade {
            color = colorGrade.apply(to: clamp01(color))
        }

        return clamp01(color)
    }

    // MARK: - Infrared

    /// Colour infrared film, laid over the grade by `amount`.
    ///
    /// The film's three layers each see one band further down the spectrum
    /// than their dye shows: red shows infrared, green shows red, blue shows
    /// green, and blue light is filtered out altogether. So the graded red
    /// moves to green, the graded green to blue, and red is given the
    /// infrared record.
    ///
    /// There is no infrared record to give it — the sensor sits behind a
    /// filter that stops it — so one is estimated from the scene. What
    /// reflects infrared brightly is mostly what is green: leaves and grass,
    /// whose chlorophyll is transparent to it. What reflects almost none is
    /// what is blue: sky and water. So the estimate is the scene's brightness,
    /// leaning on green, raised by how much greener than blue a colour is and
    /// lowered by how much bluer. Its weights sum to one over a neutral, so a
    /// grey wall stays grey and white stays white.
    ///
    /// Foliage comes out red to magenta, sky deep blue, skin pale cream, and a
    /// red flower yellow-green — the four things the film is recognised by.
    private static func infrared(_ graded: RGB, scene: RGB, amount: Float) -> RGB {
        let record = clamp01(0.25 * scene.x + 0.75 * scene.y + (scene.y - scene.z))
        let shifted = RGB(record, graded.x, graded.y)
        return clamp01(graded + (shifted - graded) * amount)
    }

    // MARK: - HSL colour mixer

    /// A band with its sliders already converted to degrees and multipliers.
    private struct ResolvedBand {
        var center: Float
        var hueShift: Float
        var saturationScale: Float
        /// In stops of the band's brightness.
        var luminanceShift: Float
    }

    /// How many stops a band's Luminance slider moves it at full deflection.
    private static let stopsPerLuminance: Float = 0.75

    private static func resolvedBands(for profile: PositiveFilmProfile) -> [ResolvedBand] {
        let sorted = profile.bands.sorted { $0.center < $1.center }
        var resolved = sorted.map {
            ResolvedBand(center: $0.center,
                         hueShift: $0.hue * PositiveFilmProfile.degreesPerHueUnit,
                         saturationScale: PositiveFilmProfile.saturationMultiplier($0.saturation),
                         luminanceShift: $0.luminance / 100 * stopsPerLuminance)
        }
        // Repeat the first band at 360° so hue interpolation wraps cleanly
        // through magenta and back into red.
        if var wrapped = resolved.first {
            wrapped.center += 360
            resolved.append(wrapped)
        }
        return resolved
    }

    private func applyColorMixer(_ color: RGB) -> RGB {
        guard bands.count > 1 else { return color }

        var hsv = rgbToHSV(color)

        // Near-neutral pixels have a meaningless hue, so shifting them would
        // just add noise. Fade the mixer in as saturation rises.
        let influence = smoothstep(0.03, 0.18, hsv.y)
        guard influence > 0 else { return color }

        // Linearly blend between the two bands bracketing this hue. Adjacent
        // weights always sum to 1, so the transitions stay smooth and no hue
        // is left ungoverned.
        var hueShift: Float = 0
        var saturationScale: Float = 1
        var luminanceShift: Float = 0
        for index in 0..<(bands.count - 1) {
            let lower = bands[index]
            let upper = bands[index + 1]
            guard hsv.x >= lower.center, hsv.x <= upper.center else { continue }

            let span = upper.center - lower.center
            let t = span > 0 ? (hsv.x - lower.center) / span : 0
            hueShift = lerp(lower.hueShift, upper.hueShift, t)
            saturationScale = lerp(lower.saturationScale, upper.saturationScale, t)
            luminanceShift = lerp(lower.luminanceShift, upper.luminanceShift, t)
            break
        }

        hsv.x += hueShift * influence
        hsv.y = clamp01(hsv.y * lerp(1, saturationScale, influence))
        if luminanceShift != 0 {
            hsv.z = clamp01(hsv.z * pow(2, luminanceShift * influence))
        }
        return hsvToRGB(hsv)
    }

    // MARK: - Camera calibration

    /// Builds a 3×3 matrix whose columns are the rotated, saturation-adjusted
    /// primaries. The rows are then normalised so that white maps to white,
    /// which keeps neutrals neutral — the whole point of a calibration pass is
    /// to move colours without introducing a global cast.
    private static func calibrationMatrix(for profile: PositiveFilmProfile) -> simd_float3x3 {
        let columns = [
            adjustedPrimary(RGB(1, 0, 0), profile.redPrimary),
            adjustedPrimary(RGB(0, 1, 0), profile.greenPrimary),
            adjustedPrimary(RGB(0, 0, 1), profile.bluePrimary),
        ]

        var matrix = simd_float3x3(columns: (columns[0], columns[1], columns[2]))

        // Row i sums to whatever white currently maps to on channel i.
        let white = matrix * RGB(repeating: 1)
        for row in 0..<3 {
            let scale = white[row] != 0 ? 1 / white[row] : 1
            matrix[0][row] *= scale
            matrix[1][row] *= scale
            matrix[2][row] *= scale
        }
        return matrix
    }

    /// Rotates a primary's hue and scales its saturation *around its own
    /// luminance*, so desaturating a primary greys it down rather than
    /// contaminating the other two channels with white.
    ///
    /// The result is deliberately not clamped — small negative coefficients are
    /// normal in a colour matrix and are what let a primary gain saturation.
    private static func adjustedPrimary(_ primary: RGB, _ settings: PositiveFilmProfile.Primary) -> RGB {
        var hsv = rgbToHSV(primary)
        hsv.x += settings.hue * PositiveFilmProfile.degreesPerCalibrationUnit
        let rotated = hsvToRGB(hsv)

        let scale = PositiveFilmProfile.saturationMultiplier(settings.saturation)
        let grey = RGB(repeating: luma(rotated))
        return grey + (rotated - grey) * scale
    }
}

// MARK: - Colour grading

/// The four wheels turned into colour offsets, and the two sliders into the
/// edges of the three tonal ranges.
private struct ResolvedColorGrade {

    /// The furthest a wheel at full saturation pushes a colour, and the
    /// furthest its Luminance moves it, in output units.
    private static let tintReach: Float = 0.25
    private static let luminanceReach: Float = 0.15

    let shadows: RGB
    let midtones: RGB
    let highlights: RGB
    let global: RGB

    /// Where the shadows give way to the highlights, as a luma.
    let pivot: Float
    /// How far either side of the pivot the ranges blend into each other.
    let width: Float

    init(_ grade: ColorGrade) {
        shadows = ResolvedColorGrade.offset(for: grade.shadows)
        midtones = ResolvedColorGrade.offset(for: grade.midtones)
        highlights = ResolvedColorGrade.offset(for: grade.highlights)
        global = ResolvedColorGrade.offset(for: grade.global)

        // Positive Balance moves the pivot down, giving the highlights wheel
        // more of the frame — the way Lightroom's does.
        pivot = 0.5 - min(max(grade.balance, -100), 100) / 100 * 0.3
        width = 0.15 + min(max(grade.blending, 0), 100) / 100 * 0.7
    }

    /// A wheel as one offset: the hue's chroma with its luma taken out, so
    /// tinting moves colour and not brightness, plus the Luminance shift.
    private static func offset(for wheel: GradeWheel) -> RGB {
        let tint = hsvToRGB(RGB(wheel.hue, 1, 1))
        let chroma = tint - RGB(repeating: luma(tint))
        let saturation = min(max(wheel.saturation, 0), 100) / 100
        let luminance = min(max(wheel.luminance, -100), 100) / 100
        return chroma * saturation * tintReach + RGB(repeating: luminance * luminanceReach)
    }

    func apply(to color: RGB) -> RGB {
        let tone = clamp01(luma(color))
        let shadowWeight = 1 - smoothstep(pivot - width, pivot, tone)
        let highlightWeight = smoothstep(pivot, pivot + width, tone)
        let midtoneWeight = max(0, 1 - shadowWeight - highlightWeight)

        return clamp01(color
                       + shadows * shadowWeight
                       + midtones * midtoneWeight
                       + highlights * highlightWeight
                       + global)
    }
}
