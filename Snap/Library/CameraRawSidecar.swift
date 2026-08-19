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
//  Two stages don't translate as single numbers. The tone curve is sampled
//  into crs:ToneCurvePV2012 control points, and the crop becomes the
//  crs:Crop* fractions.
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

    static func xmp(for profile: PositiveFilmProfile, crop: RAWCropper.CropFractions?) -> String {
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
            attribute("Blacks2012", profile.blacks),
            attribute("Clarity2012", profile.clarity),
            attribute("Sharpness", profile.sharpness),
            attribute("Vibrance", profile.vibrance),
        ]

        // Colour mixer. Sorted by centre so the bands line up with Lightroom's
        // fixed order regardless of how they're stored.
        for (name, band) in zip(bandNames, profile.bands.sorted(by: { $0.center < $1.center })) {
            attributes.append(attribute("HueAdjustment\(name)", band.hue))
            attributes.append(attribute("SaturationAdjustment\(name)", band.saturation))
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
                "crs:CropAngle=\"0\"",
                "crs:CropConstrainToWarp=\"0\"",
            ]
        }

        let indentedAttributes = attributes
            .map { "    \($0)" }
            .joined(separator: "\n")

        let curvePoints = toneCurve(for: profile)
            .map { "     <rdf:li>\($0)</rdf:li>" }
            .joined(separator: "\n")

        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Snap 1.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        \(indentedAttributes)>
           <crs:ToneCurvePV2012>
            <rdf:Seq>
        \(curvePoints)
            </rdf:Seq>
           </crs:ToneCurvePV2012>
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

    /// Samples the profile's tone curve — the extra S plus the matte black
    /// lift — into control points on Lightroom's 0...255 grid.
    private static func toneCurve(for profile: PositiveFilmProfile) -> [String] {
        let inputs = [0, 32, 64, 96, 128, 160, 192, 224, 255]
        return inputs.map { input in
            let x = Float(input) / 255
            let shaped = sCurve(x, amount: profile.toneCurveAmount)
            let lifted = profile.blackLift + shaped * (1 - profile.blackLift)
            return "\(input), \(Int((clamp01(lifted) * 255).rounded()))"
        }
    }
}
