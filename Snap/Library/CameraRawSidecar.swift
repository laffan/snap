//
//  CameraRawSidecar.swift
//  Snap
//
//  Writes the look as Camera Raw settings, so a negative opens in Lightroom
//  already cropped square and already graded.
//
//  This is why the profile has been kept in Lightroom slider units since the
//  beginning: `crs:` properties take those numbers directly. Contrast 28 is
//  crs:Contrast2012="28"; the Green band's +35 hue is
//  crs:HueAdjustmentGreen="35"; the blue primary is crs:BlueHue / crs:BlueSaturation.
//  Almost nothing needs converting.
//
//  A few stages don't translate as single numbers. The look's curve and the
//  RGB point curve are sampled together into crs:ToneCurvePV2012 control
//  points, each channel's point curve goes into its own ToneCurvePV2012Red,
//  Green or Blue, and the crop becomes the crs:Crop* fractions.
//
//  The names follow Lightroom's panels, but the arithmetic behind each one is
//  this app's own: a negative opens close to the JPEG, not identical to it.
//
//  These are XMP property names, not a compiled API — a name that turns out to
//  be wrong is ignored by Camera Raw rather than failing the file, so the rest
//  of the look still lands.
//

import Foundation

enum CameraRawSidecar {

    /// Lightroom's HSL bands, in the order our profile stores them.
    private static let bandNames = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]

    /// Process version 2012, which is the one all the `*2012` sliders belong to.
    private static let processVersion = "11.0"

    /// A neutral starting point. Adobe Color carries its own tone curve, which
    /// would stack with ours; Adobe Standard is the flatter base the profile
    /// was built against.
    private static let cameraProfile = "Adobe Standard"

    static func xmp(for baseProfile: PositiveFilmProfile, crop: RAWCropper.CropFractions?) -> String {
        // The negative should open wearing what the JPEG is wearing, and what
        // the JPEG is wearing is the profile with its sub-profiles laid on.
        let profile = baseProfile.resolved

        var attributes: [String] = [
            "crs:Version=\"\(processVersion)\"",
            "crs:ProcessVersion=\"\(processVersion)\"",
            "crs:WhiteBalance=\"As Shot\"",
            "crs:CameraProfile=\"\(cameraProfile)\"",
            "crs:HasSettings=\"True\"",
            "crs:ConvertToGrayscale=\"\(profile.blackAndWhite ? "True" : "False")\"",
        ]

        // Basic panel. Exposure is the one slider Lightroom keeps in stops
        // rather than in its own −100...100 units.
        attributes += [
            "crs:Exposure2012=\"\(String(format: "%+.2f", profile.exposure))\"",
            attribute("Contrast2012", profile.contrast),
            attribute("Highlights2012", profile.highlights),
            attribute("Shadows2012", profile.shadows),
            attribute("Whites2012", profile.whites),
            attribute("Blacks2012", profile.blacks),
            attribute("Texture", profile.texture),
            attribute("Clarity2012", profile.clarity),
            attribute("Dehaze", profile.dehaze),
            attribute("Vibrance", profile.vibrance),
            attribute("Saturation", profile.saturation),
        ]

        // Detail.
        attributes += [
            attribute("Sharpness", profile.sharpness),
            "crs:SharpenRadius=\"\(String(format: "%+.1f", profile.sharpenRadius))\"",
            attribute("LuminanceSmoothing", profile.luminanceNoiseReduction),
            attribute("ColorNoiseReduction", profile.colorNoiseReduction),
        ]

        // Effects. Highlight-priority vignetting is the style that darkens
        // without greying the brightest tones, which is the closest of the
        // three to the multiply this app uses.
        attributes += [
            attribute("PostCropVignetteAmount", profile.vignetteAmount),
            attribute("PostCropVignetteMidpoint", profile.vignetteMidpoint),
            attribute("PostCropVignetteFeather", profile.vignetteFeather),
            "crs:PostCropVignetteRoundness=\"0\"",
            "crs:PostCropVignetteStyle=\"1\"",
            attribute("GrainAmount", profile.grainAmount),
            attribute("GrainSize", profile.grainSize),
            attribute("GrainFrequency", profile.grainRoughness),
        ]

        // Camera Raw keeps a raw file's white balance in Kelvin and reserves
        // the incremental pair for relative edits, which it may well ignore on
        // a DNG — in which case the negative opens at the temperature it was
        // shot at, which is the honest fallback. Written only when it says
        // something, so a frame with no temperature on it doesn't claim one.
        if profile.temperature != 0 {
            attributes.append(attribute("IncrementalTemperature", profile.temperature))
        }
        if profile.tint != 0 {
            attributes.append(attribute("IncrementalTint", profile.tint))
        }

        // Colour mixer. Sorted by centre so the bands line up with Lightroom's
        // fixed order regardless of how they're stored.
        for (name, band) in zip(bandNames, profile.bands.sorted(by: { $0.center < $1.center })) {
            attributes.append(attribute("HueAdjustment\(name)", band.hue))
            attributes.append(attribute("SaturationAdjustment\(name)", band.saturation))
            attributes.append(attribute("LuminanceAdjustment\(name)", band.luminance))
        }

        // Colour grading. Lightroom kept the split-toning names for the
        // shadow and highlight wheels' hue and saturation, and for the
        // balance, when it grew the third wheel; the rest are new.
        let grade = profile.colorGrade
        attributes += [
            attribute("SplitToningShadowHue", grade.shadows.hue),
            attribute("SplitToningShadowSaturation", grade.shadows.saturation),
            attribute("ColorGradeShadowLum", grade.shadows.luminance),
            attribute("ColorGradeMidtoneHue", grade.midtones.hue),
            attribute("ColorGradeMidtoneSat", grade.midtones.saturation),
            attribute("ColorGradeMidtoneLum", grade.midtones.luminance),
            attribute("SplitToningHighlightHue", grade.highlights.hue),
            attribute("SplitToningHighlightSaturation", grade.highlights.saturation),
            attribute("ColorGradeHighlightLum", grade.highlights.luminance),
            attribute("ColorGradeGlobalHue", grade.global.hue),
            attribute("ColorGradeGlobalSat", grade.global.saturation),
            attribute("ColorGradeGlobalLum", grade.global.luminance),
            attribute("ColorGradeBlending", grade.blending),
            attribute("SplitToningBalance", grade.balance),
        ]

        // The region curve, with Lightroom's default split points, the
        // quarters this app's regions sit between.
        attributes += [
            attribute("ParametricShadows", profile.parametricCurve.shadows),
            attribute("ParametricDarks", profile.parametricCurve.darks),
            attribute("ParametricLights", profile.parametricCurve.lights),
            attribute("ParametricHighlights", profile.parametricCurve.highlights),
            "crs:ParametricShadowSplit=\"25\"",
            "crs:ParametricMidtoneSplit=\"50\"",
            "crs:ParametricHighlightSplit=\"75\"",
        ]

        // Transform. Lightroom's own Rotate only reaches ten degrees either
        // way, so Straighten goes in as the crop's angle below, which is what
        // Lightroom's Straighten tool writes.
        if profile.hasGeometry {
            attributes += [
                attribute("PerspectiveVertical", profile.perspectiveVertical),
                attribute("PerspectiveHorizontal", profile.perspectiveHorizontal),
            ]
        }

        // Calibration.
        attributes += [
            attribute("RedHue", profile.redPrimary.hue),
            attribute("RedSaturation", profile.redPrimary.saturation),
            attribute("GreenHue", profile.greenPrimary.hue),
            attribute("GreenSaturation", profile.greenPrimary.saturation),
            attribute("BlueHue", profile.bluePrimary.hue),
            attribute("BlueSaturation", profile.bluePrimary.saturation),
        ]

        attributes.append("crs:ToneCurveName2012=\"Custom\"")

        if let crop {
            attributes += [
                "crs:HasCrop=\"True\"",
                "crs:CropTop=\"\(fraction(crop.top))\"",
                "crs:CropLeft=\"\(fraction(crop.left))\"",
                "crs:CropBottom=\"\(fraction(crop.bottom))\"",
                "crs:CropRight=\"\(fraction(crop.right))\"",
                "crs:CropAngle=\"\(String(format: "%.2f", profile.straighten))\"",
                // Keeps the crop inside the picture once the perspective has
                // pulled its edges in, the way this app scales to fill.
                "crs:CropConstrainToWarp=\"\(profile.hasGeometry ? 1 : 0)\"",
            ]
        }

        let indentedAttributes = attributes
            .map { "    \($0)" }
            .joined(separator: "\n")

        let curves = [
            curveElement("ToneCurvePV2012", toneCurve(for: profile)),
            channelElement("ToneCurvePV2012Red", profile.pointCurve.red),
            channelElement("ToneCurvePV2012Green", profile.pointCurve.green),
            channelElement("ToneCurvePV2012Blue", profile.pointCurve.blue),
        ].joined(separator: "\n")

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Snap 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        \(indentedAttributes)>
        \(curves)
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    // MARK: - Pieces

    private static func attribute(_ name: String, _ value: Float) -> String {
        "crs:\(name)=\"\(Int(value.rounded()))\""
    }

    private static func fraction(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// One curve as an XMP sequence of "input, output" points, at the
    /// indent the packet above puts its children.
    private static func curveElement(_ name: String, _ points: [String]) -> String {
        var lines = ["   <crs:\(name)>", "    <rdf:Seq>"]
        lines += points.map { "     <rdf:li>\($0)</rdf:li>" }
        lines += ["    </rdf:Seq>", "   </crs:\(name)>"]
        return lines.joined(separator: "\n")
    }

    /// A channel's point curve as its own points on Lightroom's 0...255 grid.
    private static func channelElement(_ name: String, _ curve: PointCurve) -> String {
        let points = curve.points
            .sorted { $0.x < $1.x }
            .map { "\(Int((clamp01($0.x) * 255).rounded())), \(Int((clamp01($0.y) * 255).rounded()))" }
        return curveElement(name, points)
    }

    /// Samples the stages of the grade that sit in Lightroom's one composite
    /// curve — the look's S, the RGB point curve, then the matte black lift —
    /// into control points on Lightroom's 0...255 grid. The region curve goes
    /// in as its own four sliders instead.
    ///
    /// Seventeen points rather than nine, since a hand-drawn curve can bend
    /// between any two of them.
    private static func toneCurve(for profile: PositiveFilmProfile) -> [String] {
        let inputs = stride(from: 0, through: 256, by: 16).map { min($0, 255) }
        let master = profile.pointCurve.master
        return inputs.map { input in
            let x = Float(input) / 255
            let shaped = master.value(at: sCurve(x, amount: profile.toneCurveAmount))
            let lifted = profile.blackLift + shaped * (1 - profile.blackLift)
            return "\(input), \(Int((clamp01(lifted) * 255).rounded()))"
        }
    }
}
