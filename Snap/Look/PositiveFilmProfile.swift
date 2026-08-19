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

    /// Exposure in stops, −5...5.
    ///
    /// A develop setting rather than a camera one, so it re-applies when a
    /// stored negative is re-filtered and travels to Lightroom as
    /// `crs:Exposure2012`. The stepper beside the shutter and the slider in the
    /// panel move this same value.
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

    /// Lightroom Clarity, −100...100. Midtone local contrast.
    var clarity: Float = 0

    /// Sharpening, 0...100. Where clarity is a wide, low-amplitude unsharp
    /// mask read as midtone local contrast, this is the narrow one read as
    /// detail.
    var sharpness: Float = 20

    /// Lightroom Vibrance, −100...100.
    var vibrance: Float = 25

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

    // MARK: - Colour mixer (HSL)

    struct HSLBand: Codable, Equatable {
        var name: String
        /// Hue this band is centred on, in degrees.
        var center: Float
        /// Lightroom Hue slider for the band, −100...100.
        var hue: Float
        /// Lightroom Saturation slider for the band, −100...100.
        var saturation: Float
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

    // MARK: - RAW

    /// How much of Apple's global tone curve to keep when developing a RAW
    /// capture, 0...100, mapped onto `CIRAWFilter.boostAmount`.
    ///
    /// 0 is the most complete bypass and gives a linear response to the scene;
    /// 100 is Apple's own rendering. Only used on the RAW path.
    var rawBoost: Float = 10

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
    var sharpnessRadiusFraction: Float { 0.0012 }

    /// `CIRAWFilter.boostAmount`, 0...1.
    var rawBoostAmount: Float { rawBoost / 100 }
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
        case exposure, contrast, highlights, shadows, blacks, clarity, sharpness, vibrance
        case blackAndWhite
        case toneCurveS, blackLift
        case bands
        case redPrimary, greenPrimary, bluePrimary
        case rawBoost
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

        exposure   = float(.exposure, exposure)
        contrast   = float(.contrast, contrast)
        highlights = float(.highlights, highlights)
        shadows    = float(.shadows, shadows)
        blacks     = float(.blacks, blacks)
        clarity    = float(.clarity, clarity)
        sharpness  = float(.sharpness, sharpness)
        vibrance   = float(.vibrance, vibrance)
        blackAndWhite = bool(.blackAndWhite, blackAndWhite)
        toneCurveS = float(.toneCurveS, toneCurveS)
        blackLift  = float(.blackLift, blackLift)

        rawBoost    = float(.rawBoost, rawBoost)

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
