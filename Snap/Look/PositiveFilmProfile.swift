//
//  PositiveFilmProfile.swift
//  Snap
//
//  A Core Image approximation of the Ricoh GR II "Positive Film" image
//  control. The numbers below are written in Lightroom slider units so they
//  can be compared directly against the reference profile; the conversion into
//  the units the renderer actually wants happens in the computed properties at
//  the bottom.
//
//  This is the one file to edit when dialling the look in.
//

import Foundation

struct PositiveFilmProfile {

    // MARK: - Basic adjustments

    /// Lightroom Contrast, −100...100. The reference calls for +35 to +50;
    /// we sit in the middle of that range.
    var contrast: Float = 42

    /// Lightroom Highlights, −100...100. Negative pulls bright areas back.
    var highlights: Float = -20

    /// Lightroom Shadows, −100...100. Positive opens up deep shadow detail.
    var shadows: Float = 18

    /// Lightroom Clarity, −100...100. Midtone local contrast.
    var clarity: Float = 22

    /// Lightroom Vibrance, −100...100.
    var vibrance: Float = 10

    // MARK: - Tone curve

    /// A gentle extra S on top of the Contrast slider: shadows pulled down,
    /// highlights pushed up. Expressed on the same −100...100 scale.
    var toneCurveS: Float = 15

    /// How far the bottom-left of the point curve is lifted off the floor,
    /// in output units. 0.042 puts the deepest black at roughly 4% grey,
    /// which reads as a faded, matte shadow without looking washed out.
    var blackLift: Float = 0.042

    // MARK: - Colour mixer (HSL)

    /// One band of the eight-way HSL mixer.
    struct HSLBand {
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
        HSLBand(center:   0, hue:  +5, saturation: +15),  // Red
        HSLBand(center:  30, hue:  +5, saturation:  +5),  // Orange
        HSLBand(center:  60, hue: -20, saturation: -30),  // Yellow  → toward orange
        HSLBand(center: 120, hue: +35, saturation: -40),  // Green   → toward aqua
        HSLBand(center: 180, hue: +10, saturation: +10),  // Aqua
        HSLBand(center: 240, hue: +10, saturation: +10),  // Blue
        HSLBand(center: 285, hue:   0, saturation: -50),  // Purple
        HSLBand(center: 315, hue:   0, saturation: -50),  // Magenta
    ]

    // MARK: - Camera calibration

    struct Primary {
        /// Lightroom calibration Hue slider, −100...100.
        var hue: Float
        /// Lightroom calibration Saturation slider, −100...100.
        var saturation: Float
    }

    var redPrimary   = Primary(hue:  +5, saturation:  +5)
    var greenPrimary = Primary(hue: -10, saturation:   0)
    var bluePrimary  = Primary(hue: +10, saturation: -10)

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
}
