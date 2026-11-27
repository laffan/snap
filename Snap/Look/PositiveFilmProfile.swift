//
//  PositiveFilmProfile.swift
//  Snap
//
//  Every knob the look exposes, written in Lightroom slider units so the
//  values can be compared directly against a reference profile.
//
//  This is `Codable` because it is also the document format: saving a look
//  writes this struct straight to JSON alongside the frame it produced.
//

import Foundation

struct PositiveFilmProfile: Codable, Equatable {

    // MARK: - Basic

    /// Lightroom's relative Temperature, −100...100. Negative is cooler, the
    /// way the blue end of the slider is.
    ///
    /// A white balance rather than a tint: it pulls the red and blue channels
    /// apart and leaves green where it is, which is the axis the slider names.
    /// Zero by default — the look is built against daylight, and a profile
    /// should not carry a correction for a room it wasn't shot in.
    var temperature: Float = 0

    /// Lightroom's relative Tint, −100...100. Negative is greener, positive
    /// more magenta.
    ///
    /// The other axis of a white balance: green against red and blue together,
    /// for the cast a fluorescent tube or a canopy of leaves puts on a frame
    /// that Temperature can't reach. Zero by default, for the same reason
    /// Temperature is.
    var tint: Float = 0

    /// Exposure in stops, −5...5.
    ///
    /// A develop setting rather than a camera one, so it re-applies when a
    /// stored negative is re-filtered and travels to Lightroom as
    /// `crs:Exposure2012`. The panel's slider moves it. The wheel beside the
    /// shutter does not: that is the camera's own compensation, which is the
    /// only one of the two that can bring a clipped highlight back.
    var exposure: Float = 0

    /// Lightroom Contrast, −100...100.
    var contrast: Float = 35

    /// Lightroom Highlights, −100...100. Negative recovers bright areas.
    var highlights: Float = -12

    /// Lightroom Shadows, −100...100. Positive opens deep shadow detail.
    var shadows: Float = -20

    /// Lightroom Blacks, −100...100. Negative crushes the black point.
    /// A small negative value gives the toe a bit of bite without closing
    /// up the shadow detail that `shadows` just opened.
    var blacks: Float = -5

    /// Lightroom Whites, −100...100. The other end of the curve from Blacks:
    /// positive pushes the brightest tones toward clipping, negative pulls
    /// them back under it, and the midtones are left alone either way.
    var whites: Float = 0

    /// Lightroom Texture, −100...100. Detail at the scale of skin and bark —
    /// finer than Clarity, coarser than Sharpening. Negative smooths it.
    var texture: Float = 0

    /// Lightroom Clarity, −100...100. Midtone local contrast.
    var clarity: Float = 0

    /// Sharpening, 0...100. Where clarity is a wide, low-amplitude unsharp
    /// mask read as midtone local contrast, this is the narrow one read as
    /// detail.
    var sharpness: Float = 20

    /// Lightroom Vibrance, −100...100.
    var vibrance: Float = 25

    /// Lightroom Saturation, −100...100. Every colour by the same amount,
    /// where Vibrance holds back on the ones that are already strong.
    var saturation: Float = 0

    /// Lightroom Dehaze, −100...100. Positive takes the veil a haze lays over
    /// distance out of the frame; negative lays one on.
    var dehaze: Float = 0

    /// Renders the frame monochrome.
    ///
    /// The conversion happens at the end of the grade, so the colour mixer
    /// still shapes it: desaturating a band changes that band's luminance, the
    /// way a black-and-white mixer does. The negative keeps its colour data —
    /// this is how the frame is rendered, not what was recorded.
    var blackAndWhite = false

    // MARK: - Tone curve

    /// A gentle extra S on top of Contrast, on the same −100...100 scale.
    var toneCurveS: Float = 60

    /// How far the bottom of the curve is lifted off the floor, in output
    /// units. This is the matte foot; 0 gives a true black.
    var blackLift: Float = 0.086

    /// The region curve: Highlights, Lights, Darks and Shadows.
    var parametricCurve = ParametricCurve()

    /// The point curve, drawn by hand, for all three channels and for each.
    var pointCurve = PointCurves()

    // MARK: - Colour mixer (HSL)

    struct HSLBand: Codable, Equatable {
        var name: String
        /// Hue this band is centred on, in degrees.
        var center: Float
        /// Lightroom Hue slider for the band, −100...100.
        var hue: Float
        /// Lightroom Saturation slider for the band, −100...100.
        var saturation: Float
        /// Lightroom Luminance slider for the band, −100...100.
        var luminance: Float = 0
    }

    /// The Positive Film look isolates reds and blues while crushing and
    /// shifting greens and yellows.
    ///
    /// One deliberate deviation from a literal reading of the reference: it
    /// lists Green as Hue −35 but annotates it "shift toward aqua/blue", and
    /// in Lightroom a negative green hue moves toward *yellow*. The teal-shifted
    /// foliage is the defining half of this look, so the stated intent wins and
    /// the band is stored as a positive shift.
    var bands: [HSLBand] = [
        HSLBand(name: "Red",     center:   0, hue:  +5, saturation: +15),
        HSLBand(name: "Orange",  center:  30, hue:  +5, saturation:  +5),
        HSLBand(name: "Yellow",  center:  60, hue: -20, saturation: -30),
        HSLBand(name: "Green",   center: 120, hue: +35, saturation: -40),
        HSLBand(name: "Aqua",    center: 180, hue: +10, saturation: +10),
        HSLBand(name: "Blue",    center: 240, hue: +10, saturation: -15),
        HSLBand(name: "Purple",  center: 285, hue:   0, saturation: -50),
        HSLBand(name: "Magenta", center: 315, hue:   0, saturation: -50),
    ]

    // MARK: - Camera calibration

    struct Primary: Codable, Equatable {
        /// Lightroom calibration Hue slider, −100...100.
        var hue: Float
        /// Lightroom calibration Saturation slider, −100...100.
        var saturation: Float
    }

    var redPrimary   = Primary(hue:  -5, saturation:  +5)
    var greenPrimary = Primary(hue: -10, saturation:   0)
    var bluePrimary  = Primary(hue: +10, saturation: -10)

    /// How far the frame is taken towards colour infrared film, 0...100.
    ///
    /// Infrared film records three layers shifted one place down the
    /// spectrum: the red layer sees infrared, the green sees red, the blue
    /// sees green. Foliage reflects infrared strongly and comes out red; a sky
    /// has almost none and stays blue; skin goes pale. A phone's sensor sits
    /// behind a filter that stops infrared, so the infrared record here is an
    /// estimate made from the colour of the scene — see
    /// `Grade.infrared` — and the other two are the real thing,
    /// moved along.
    ///
    /// Zero by default, and set by the Infrared sub-profile rather than kept
    /// in the base look.
    var infrared: Float = 0

    // MARK: - Colour grading

    /// Shadows, midtones, highlights and global wheels, with blending and
    /// balance. Neutral by default.
    var colorGrade = ColorGrade()

    // MARK: - Detail

    /// Lightroom Sharpening Radius, 0.5...3. One is where the sharpening pass
    /// has always sat; the amount is `sharpness`, above.
    var sharpenRadius: Float = 1

    /// Lightroom Noise Reduction, Luminance, 0...100.
    var luminanceNoiseReduction: Float = 0

    /// Lightroom Noise Reduction, Color, 0...100: the coloured speckle in a
    /// dark frame, smoothed without touching how light or dark anything is.
    var colorNoiseReduction: Float = 0

    // MARK: - Effects

    /// Lightroom Post-Crop Vignetting Amount, −100...100. Negative darkens the
    /// corners, positive lightens them.
    var vignetteAmount: Float = 0
    /// How far in the vignette begins, 0...100. Lightroom's default is 50.
    var vignetteMidpoint: Float = 50
    /// How softly it fades in, 0...100. Lightroom's default is 50.
    var vignetteFeather: Float = 50

    /// Lightroom Grain Amount, 0...100.
    var grainAmount: Float = 0
    /// Lightroom Grain Size, 0...100. Lightroom's default is 25.
    var grainSize: Float = 25
    /// Lightroom Grain Roughness, 0...100: how uneven the grain is from one
    /// clump to the next. Lightroom's default is 50.
    var grainRoughness: Float = 50

    // MARK: - Geometry

    /// Straighten, in degrees, −45...45. The frame is rotated and scaled up
    /// just far enough that the square stays filled.
    var straighten: Float = 0
    /// Lightroom Transform Vertical, −100...100: converging verticals pulled
    /// upright, or pushed further apart.
    var perspectiveVertical: Float = 0
    /// Lightroom Transform Horizontal, −100...100.
    var perspectiveHorizontal: Float = 0

    // MARK: - RAW

    /// How much of Apple's global tone curve to keep when developing a RAW
    /// capture, 0...100, mapped onto `CIRAWFilter.boostAmount`.
    ///
    /// 0 is the most complete bypass and gives a linear response to the scene;
    /// 100 is Apple's own rendering. Only used on the RAW path.
    var rawBoost: Float = 10

    // MARK: - Sub-profiles

    /// Which sub-profiles are lit. They are laid over the top of everything
    /// above at the moment of rendering — see `resolved` — so nothing in here
    /// is edited by them and the sliders go on showing the base.
    var subProfiles: Set<SubProfile> = []

    /// The settings the photographer has moved by hand, which no sub-profile
    /// gets to set over the top of.
    ///
    /// A sub-profile *sets* the settings it names, which is what makes a toggle
    /// mean the same thing wherever the base is sitting — and what used to make
    /// three of the develop panel's sliders do nothing at all while one was
    /// lit. Exposure moved, and Night put it back to −0.6 on the way to the
    /// renderer, every time. So the hand wins: taking hold of a slider records
    /// it here and the sub-profile leaves it alone from then on, which is what
    /// makes every slider in the panel change the photograph.
    ///
    /// Switching a sub-profile off and on again clears the ones it names — see
    /// `toggle` — so a fresh light is a fresh correction rather than a
    /// correction with holes in it.
    var overrides: Set<SubProfile.Setting> = []

    /// The lit sub-profiles in a fixed order, for anything that shows them.
    var activeSubProfiles: [SubProfile] {
        SubProfile.allCases.filter { subProfiles.contains($0) }
    }

    /// The profile as it is actually rendered: the base with whatever
    /// sub-profiles are lit laid over it, less whatever has been taken back by
    /// hand.
    ///
    /// Everything that bakes, grades or describes a rendering goes through
    /// this; everything that is *stored* keeps the base and the flags apart, so
    /// a shot can be reopened with the sub-profile still switchable.
    var resolved: PositiveFilmProfile {
        var result = self
        for subProfile in activeSubProfiles {
            result = subProfile.applied(to: result, skipping: overrides)
        }
        // Already applied: a resolved profile resolves to itself, which is what
        // keeps a second pass from laying them on twice. Both are cleared
        // whether or not anything was lit, so two profiles that render the same
        // photograph compare equal — which is what the bake cache is asking.
        result.subProfiles = []
        result.overrides = []
        return result
    }

    mutating func toggle(_ subProfile: SubProfile) {
        if subProfiles.contains(subProfile) {
            subProfiles.remove(subProfile)
        } else {
            subProfiles.insert(subProfile)
        }
        // Either way this sub-profile starts again from nothing: a toggle means
        // the same thing every time it is pressed, and a correction that
        // remembered which of its settings had been argued with last time
        // would not.
        overrides.subtract(subProfile.settings.keys)
    }

    /// Moves one setting by hand, and takes it off any sub-profile that names
    /// it. Every control that writes one of these goes through here.
    mutating func setByHand(_ setting: SubProfile.Setting, to value: Float) {
        self[keyPath: setting.keyPath] = value
        overrides.insert(setting)
    }

    // MARK: - Slider → renderer conversions

    /// Lightroom's hue sliders run a band roughly a third of the way to its
    /// neighbour at full deflection, so ±100 maps to ±30°.
    static let degreesPerHueUnit: Float = 0.30

    /// Calibration hue sliders rotate a whole primary and bite harder per unit,
    /// so they get a shorter lever.
    static let degreesPerCalibrationUnit: Float = 0.20

    /// −100 removes all saturation, +100 doubles it.
    static func saturationMultiplier(_ slider: Float) -> Float {
        max(0, 1 + slider / 100)
    }

    /// How far the red and blue channels are pulled apart, ±0.25 at full
    /// deflection — firm enough to take a lamp off a white wall, short of the
    /// theatrical.
    var temperatureAmount: Float { temperature / 100 * 0.25 }

    /// How far green is pulled against red and blue, ±0.2 at full deflection.
    var tintAmount: Float { tint / 100 * 0.2 }

    /// How far the white point moves, in output units, at full deflection.
    var whitesShift: Float { whites / 100 * 0.15 }

    /// Multiplier for the global Saturation slider.
    var saturationScale: Float { PositiveFilmProfile.saturationMultiplier(saturation) }

    /// Dehaze, −1...1.
    var dehazeAmount: Float { min(max(dehaze, -100), 100) / 100 }

    /// Blend amount for the contrast S-curve (see `sCurve(_:amount:)`).
    var contrastAmount: Float { contrast / 100 }

    /// Blend amount for the additional tone-curve S.
    var toneCurveAmount: Float { toneCurveS / 100 }

    /// `CIVibrance`-style amount, 0...1.
    var vibranceAmount: Float { vibrance / 100 }

    /// How far the black point moves, in output units, at full deflection.
    var blacksShift: Float { blacks / 100 * 0.15 }

    /// `CIHighlightShadowAdjust.highlightAmount`, where 1.0 is unchanged and
    /// lower values recover blown highlights.
    var highlightAmount: Float { 1 + highlights / 100 }

    /// `CIHighlightShadowAdjust.shadowAmount`, −1...1.
    var shadowAmount: Float { shadows / 100 }

    /// `CIUnsharpMask.intensity` for the clarity pass. Clarity is a wide-radius,
    /// low-amplitude unsharp mask, so the slider gets scaled well down.
    var clarityIntensity: Float { clarity / 100 * 1.5 }

    /// Unsharp radius as a fraction of the image's short edge. Keeping it
    /// relative rather than absolute is what makes the 1080px preview and the
    /// full-resolution capture look like the same photograph.
    var clarityRadiusFraction: Float { 0.018 }

    /// `CIUnsharpMask.intensity` for the sharpening pass.
    var sharpnessIntensity: Float { sharpness / 100 }

    /// A much narrower radius than clarity's — detail rather than local
    /// contrast — and relative for the same reason.
    var sharpnessRadiusFraction: Float { 0.0012 * min(max(sharpenRadius, 0.5), 3) }

    /// Texture as an unsharp mask between the two: wider than sharpening's,
    /// far narrower than clarity's.
    var textureRadiusFraction: Float { 0.0045 }
    var textureAmount: Float { min(max(texture, -100), 100) / 100 }

    /// `CINoiseReduction.noiseLevel`, 0...0.08.
    var luminanceNoiseLevel: Float { min(max(luminanceNoiseReduction, 0), 100) / 100 * 0.08 }
    var colorNoiseAmount: Float { min(max(colorNoiseReduction, 0), 100) / 100 }

    /// Whether any of the geometry sliders has moved.
    var hasGeometry: Bool {
        straighten != 0 || perspectiveVertical != 0 || perspectiveHorizontal != 0
    }

    /// `CIRAWFilter.boostAmount`, 0...1.
    var rawBoostAmount: Float { rawBoost / 100 }

    /// How much of the infrared mapping is laid over the grade, 0...1.
    var infraredAmount: Float { min(max(infrared, 0), 100) / 100 }
}

// MARK: - Lenient decoding

/// Hand-written so that a profile saved by an older build still loads after
/// new knobs are added: any key that isn't in the JSON keeps its default
/// rather than failing the whole decode. Synthesised `Codable` would throw on
/// the first missing key and take every previously saved shot with it.
///
/// This lives in an extension on purpose — declaring an initialiser in the
/// type body would suppress the memberwise initialiser the defaults rely on.
extension PositiveFilmProfile {

    enum CodingKeys: String, CodingKey {
        case temperature, tint
        case exposure, contrast, highlights, shadows, whites, blacks
        case texture, clarity, dehaze, sharpness, vibrance, saturation
        case blackAndWhite
        case toneCurveS, blackLift, parametricCurve, pointCurve
        case bands
        case redPrimary, greenPrimary, bluePrimary
        case infrared
        case colorGrade
        case sharpenRadius, luminanceNoiseReduction, colorNoiseReduction
        case vignetteAmount, vignetteMidpoint, vignetteFeather
        case grainAmount, grainSize, grainRoughness
        case straighten, perspectiveVertical, perspectiveHorizontal
        case rawBoost
        case subProfiles, overrides
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // `try?` on a throwing optional decode gives Float??, so both layers
        // have to be unwrapped: a malformed value falls back just like a
        // missing one.
        func float(_ key: CodingKeys, _ fallback: Float) -> Float {
            ((try? container.decodeIfPresent(Float.self, forKey: key)) ?? nil) ?? fallback
        }

        func bool(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? container.decodeIfPresent(Bool.self, forKey: key)) ?? nil) ?? fallback
        }

        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys, _ fallback: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }

        temperature = float(.temperature, temperature)
        tint       = float(.tint, tint)
        exposure   = float(.exposure, exposure)
        contrast   = float(.contrast, contrast)
        highlights = float(.highlights, highlights)
        shadows    = float(.shadows, shadows)
        whites     = float(.whites, whites)
        blacks     = float(.blacks, blacks)
        texture    = float(.texture, texture)
        clarity    = float(.clarity, clarity)
        dehaze     = float(.dehaze, dehaze)
        sharpness  = float(.sharpness, sharpness)
        vibrance   = float(.vibrance, vibrance)
        saturation = float(.saturation, saturation)
        blackAndWhite = bool(.blackAndWhite, blackAndWhite)
        toneCurveS = float(.toneCurveS, toneCurveS)
        blackLift  = float(.blackLift, blackLift)
        parametricCurve = value(ParametricCurve.self, .parametricCurve, parametricCurve)
        pointCurve = value(PointCurves.self, .pointCurve, pointCurve)

        colorGrade = value(ColorGrade.self, .colorGrade, colorGrade)

        sharpenRadius = float(.sharpenRadius, sharpenRadius)
        luminanceNoiseReduction = float(.luminanceNoiseReduction, luminanceNoiseReduction)
        colorNoiseReduction = float(.colorNoiseReduction, colorNoiseReduction)

        vignetteAmount   = float(.vignetteAmount, vignetteAmount)
        vignetteMidpoint = float(.vignetteMidpoint, vignetteMidpoint)
        vignetteFeather  = float(.vignetteFeather, vignetteFeather)
        grainAmount      = float(.grainAmount, grainAmount)
        grainSize        = float(.grainSize, grainSize)
        grainRoughness   = float(.grainRoughness, grainRoughness)

        straighten            = float(.straighten, straighten)
        perspectiveVertical   = float(.perspectiveVertical, perspectiveVertical)
        perspectiveHorizontal = float(.perspectiveHorizontal, perspectiveHorizontal)

        infrared    = float(.infrared, infrared)
        rawBoost    = float(.rawBoost, rawBoost)

        // A raw value this build doesn't know throws, and the whole set falls
        // back to empty rather than the shot failing to load.
        if let decoded = ((try? container.decodeIfPresent(Set<SubProfile>.self, forKey: .subProfiles)) ?? nil) {
            subProfiles = decoded
        }

        // Same treatment, and for the same reason: a setting name this build
        // doesn't know throws, and the set falls back to empty rather than the
        // shot failing to load.
        if let decoded = ((try? container.decodeIfPresent(Set<SubProfile.Setting>.self, forKey: .overrides)) ?? nil) {
            overrides = decoded
        }

        if let decoded = ((try? container.decodeIfPresent([HSLBand].self, forKey: .bands)) ?? nil),
           !decoded.isEmpty {
            bands = decoded
        }
        if let decoded = ((try? container.decodeIfPresent(Primary.self, forKey: .redPrimary)) ?? nil) {
            redPrimary = decoded
        }
        if let decoded = ((try? container.decodeIfPresent(Primary.self, forKey: .greenPrimary)) ?? nil) {
            greenPrimary = decoded
        }
        if let decoded = ((try? container.decodeIfPresent(Primary.self, forKey: .bluePrimary)) ?? nil) {
            bluePrimary = decoded
        }
    }
}

/// Bands saved before the mixer had a Luminance row still load, with
/// Luminance at zero — synthesised decoding would throw on the missing key and
/// take the whole mixer back to the built-in one.
extension PositiveFilmProfile.HSLBand {

    enum CodingKeys: String, CodingKey {
        case name, center, hue, saturation, luminance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        center = try container.decode(Float.self, forKey: .center)
        hue = try container.decode(Float.self, forKey: .hue)
        saturation = try container.decode(Float.self, forKey: .saturation)
        luminance = ((try? container.decodeIfPresent(Float.self, forKey: .luminance)) ?? nil) ?? 0
    }
}

// MARK: - What has been changed

extension PositiveFilmProfile {

    /// Every setting that has moved off the built-in look, one line each, in
    /// the order the panel lists them. Empty when nothing has moved.
    ///
    /// Labels match the sliders and the numbers are formatted the way the
    /// sliders format them, so a copied line reads as the row it came from.
    /// The two groups that share colour names are spelled out — Calibration
    /// Red is not the mixer's Red.
    var adjustments: [String] {
        let base = PositiveFilmProfile()
        var lines: [String] = []

        func compare(_ label: String, _ value: Float, _ reference: Float, decimals: Int = 0) {
            guard value != reference else { return }
            let formatted = String(format: "%.\(decimals)f", value)
            lines.append("\(label): \(formatted)")
        }

        // Light
        compare("Exposure", exposure, base.exposure, decimals: 2)
        compare("Contrast", contrast, base.contrast)
        compare("Highlights", highlights, base.highlights)
        compare("Shadows", shadows, base.shadows)
        compare("Whites", whites, base.whites)
        compare("Blacks", blacks, base.blacks)

        // Curve
        compare("Curve Highlights", parametricCurve.highlights, base.parametricCurve.highlights)
        compare("Curve Lights", parametricCurve.lights, base.parametricCurve.lights)
        compare("Curve Darks", parametricCurve.darks, base.parametricCurve.darks)
        compare("Curve Shadows", parametricCurve.shadows, base.parametricCurve.shadows)
        for (name, curve) in [("RGB", pointCurve.master), ("Red", pointCurve.red),
                              ("Green", pointCurve.green), ("Blue", pointCurve.blue)]
        where !curve.isIdentity {
            let points = curve.points
                .sorted { $0.x < $1.x }
                .map { "\(Int(($0.x * 255).rounded())),\(Int(($0.y * 255).rounded()))" }
                .joined(separator: " ")
            lines.append("\(name) Curve: \(points)")
        }
        compare("S-Curve", toneCurveS, base.toneCurveS)
        compare("Black Lift", blackLift, base.blackLift, decimals: 3)

        // Color
        compare("Temperature", temperature, base.temperature)
        compare("Tint", tint, base.tint)
        compare("Vibrance", vibrance, base.vibrance)
        compare("Saturation", saturation, base.saturation)
        if blackAndWhite != base.blackAndWhite {
            lines.append("Black & White: \(blackAndWhite ? "on" : "off")")
        }

        for band in bands {
            guard let reference = base.bands.first(where: { $0.name == band.name }) else { continue }
            compare("\(band.name) Hue", band.hue, reference.hue)
            compare("\(band.name) Saturation", band.saturation, reference.saturation)
            compare("\(band.name) Luminance", band.luminance, reference.luminance)
        }

        // Grading
        for (name, wheel, reference) in [("Shadows", colorGrade.shadows, base.colorGrade.shadows),
                                         ("Midtones", colorGrade.midtones, base.colorGrade.midtones),
                                         ("Highlights", colorGrade.highlights, base.colorGrade.highlights),
                                         ("Global", colorGrade.global, base.colorGrade.global)]
        where wheel != reference {
            lines.append("Grading \(name): hue \(Int(wheel.hue.rounded())), saturation \(Int(wheel.saturation.rounded())), luminance \(Int(wheel.luminance.rounded()))")
        }
        compare("Grading Blending", colorGrade.blending, base.colorGrade.blending)
        compare("Grading Balance", colorGrade.balance, base.colorGrade.balance)

        // Effects
        compare("Texture", texture, base.texture)
        compare("Clarity", clarity, base.clarity)
        compare("Dehaze", dehaze, base.dehaze)
        compare("Vignette", vignetteAmount, base.vignetteAmount)
        compare("Vignette Midpoint", vignetteMidpoint, base.vignetteMidpoint)
        compare("Vignette Feather", vignetteFeather, base.vignetteFeather)
        compare("Grain", grainAmount, base.grainAmount)
        compare("Grain Size", grainSize, base.grainSize)
        compare("Grain Roughness", grainRoughness, base.grainRoughness)

        // Detail
        compare("Sharpness", sharpness, base.sharpness)
        compare("Sharpen Radius", sharpenRadius, base.sharpenRadius, decimals: 1)
        compare("Noise Reduction", luminanceNoiseReduction, base.luminanceNoiseReduction)
        compare("Color Noise Reduction", colorNoiseReduction, base.colorNoiseReduction)

        // Geometry
        compare("Straighten", straighten, base.straighten, decimals: 1)
        compare("Vertical", perspectiveVertical, base.perspectiveVertical)
        compare("Horizontal", perspectiveHorizontal, base.perspectiveHorizontal)

        for (name, primary, reference) in [("Red", redPrimary, base.redPrimary),
                                           ("Green", greenPrimary, base.greenPrimary),
                                           ("Blue", bluePrimary, base.bluePrimary)] {
            compare("Calibration \(name) Hue", primary.hue, reference.hue)
            compare("Calibration \(name) Saturation", primary.saturation, reference.saturation)
        }
        compare("Infrared", infrared, base.infrared)

        compare("Apple Tone Curve", rawBoost, base.rawBoost)

        // Not a slider and not pasteable, but it is part of what makes this
        // frame different from the built-in look, which is what the list is.
        if !subProfiles.isEmpty {
            lines.append("Sub-profiles: \(activeSubProfiles.map(\.label).joined(separator: ", "))")
        }

        return lines
    }
}
