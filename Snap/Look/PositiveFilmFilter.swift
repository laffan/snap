//
//  PositiveFilmFilter.swift
//  Snap
//
//  Turns a PositiveFilmProfile into something Core Image can run, and applies
//  it identically to the live preview and to the captured frame.
//
//  Everything that is a pure per-pixel function of colour — calibration,
//  contrast, vibrance, the HSL mixer, the tone curve — is baked once into a
//  single 3D lookup table. That keeps the per-frame cost to one texture fetch
//  no matter how elaborate the grade gets, and guarantees the preview and the
//  saved file go through the exact same maths.
//
//  The adjustments that are *not* per-pixel — highlight/shadow recovery,
//  clarity — stay as real filters around the LUT.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import simd

final class PositiveFilmFilter {

    /// Samples per axis in the lookup table.
    ///
    /// Measured against the exact per-pixel grade, 64³ holds worst-case error
    /// to ~1.8/255 (mean 0.1/255) and keeps a neutral ramp inside 0.3/255, so
    /// smooth walls and skies don't band. 32³ roughly triples that error —
    /// fine for a preview that is being dragged, not for a committed look.
    enum Resolution: Int {
        /// Used while a slider is in motion, where responsiveness wins.
        case draft = 32
        /// Used for everything that is kept: settled edits, and every capture.
        case final = 64
    }

    /// The look Snap ships with.
    ///
    /// Baking the lookup table takes a moment, so this is a `static let`: Swift
    /// initialises it lazily and exactly once, whichever thread asks first. In
    /// practice that is the capture queue reaching for the first frame, which
    /// keeps the cost off the main thread at launch.
    static let standard = PositiveFilmFilter()

    let profile: PositiveFilmProfile
    let resolution: Resolution

    private let cubeData: Data
    private let workingColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(profile: PositiveFilmProfile = PositiveFilmProfile(),
         resolution: Resolution = .final) {
        self.profile = profile
        self.resolution = resolution
        self.cubeData = PositiveFilmFilter.makeCubeData(profile: profile,
                                                        dimension: resolution.rawValue)
    }

    // MARK: - Applying the look

    /// Applies the full look. The result has the same extent as the input, so
    /// callers can treat this as an in-place transformation.
    func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }

        // Sampling past the edges keeps the blur-based stages from darkening
        // the border; we crop back to the original extent at the end.
        var output = image.clampedToExtent()

        // 1. Highlight recovery and shadow lift, before anything steepens the
        //    curve, so there is still headroom to recover.
        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = output
        highlightShadow.highlightAmount = profile.highlightAmount
        highlightShadow.shadowAmount = profile.shadowAmount
        output = highlightShadow.outputImage ?? output

        // 2. Clarity: a wide, gentle unsharp mask reads as midtone local
        //    contrast rather than as sharpening. The radius scales with the
        //    image so preview and capture match.
        if profile.clarityIntensity > 0 {
            let shortEdge = Float(min(extent.width, extent.height))
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = output
            unsharp.radius = max(1, shortEdge * profile.clarityRadiusFraction)
            unsharp.intensity = profile.clarityIntensity
            output = unsharp.outputImage ?? output
        }

        // 3. The grade itself.
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = output
        cube.cubeDimension = Float(resolution.rawValue)
        cube.cubeData = cubeData
        cube.colorSpace = workingColorSpace
        output = cube.outputImage ?? output

        return output.cropped(to: extent)
    }

    // MARK: - Baking the lookup table

    private static func makeCubeData(profile: PositiveFilmProfile, dimension: Int) -> Data {
        let calibration = calibrationMatrix(for: profile)
        let bands = resolvedBands(for: profile)

        let entryCount = dimension * dimension * dimension
        var values = [Float](repeating: 0, count: entryCount * 4)
        let step = Float(dimension - 1)

        var offset = 0
        for blueIndex in 0..<dimension {
            let blue = Float(blueIndex) / step
            for greenIndex in 0..<dimension {
                let green = Float(greenIndex) / step
                for redIndex in 0..<dimension {
                    let red = Float(redIndex) / step

                    let graded = grade(RGB(red, green, blue),
                                       profile: profile,
                                       calibration: calibration,
                                       bands: bands)

                    values[offset + 0] = graded.x
                    values[offset + 1] = graded.y
                    values[offset + 2] = graded.z
                    values[offset + 3] = 1
                    offset += 4
                }
            }
        }

        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The per-pixel grade, in the order Lightroom applies it: camera
    /// calibration, then the basic panel (blacks, contrast, vibrance), then
    /// the colour mixer, then the point curve.
    private static func grade(_ input: RGB,
                              profile: PositiveFilmProfile,
                              calibration: simd_float3x3,
                              bands: [ResolvedBand]) -> RGB {
        var color = clamp01(calibration * input)
        color = clamp01(shiftBlacks(color, by: profile.blacksShift))
        color = sCurve(color, amount: profile.contrastAmount)
        color = clamp01(applyVibrance(color, amount: profile.vibranceAmount))
        color = applyColorMixer(color, bands: bands)
        color = sCurve(color, amount: profile.toneCurveAmount)
        color = liftBlacks(color, by: profile.blackLift)
        return clamp01(color)
    }

    // MARK: - HSL colour mixer

    /// A band with its sliders already converted to degrees and a multiplier.
    private struct ResolvedBand {
        var center: Float
        var hueShift: Float
        var saturationScale: Float
    }

    private static func resolvedBands(for profile: PositiveFilmProfile) -> [ResolvedBand] {
        let sorted = profile.bands.sorted { $0.center < $1.center }
        var resolved = sorted.map {
            ResolvedBand(center: $0.center,
                         hueShift: $0.hue * PositiveFilmProfile.degreesPerHueUnit,
                         saturationScale: PositiveFilmProfile.saturationMultiplier($0.saturation))
        }
        // Repeat the first band at 360° so hue interpolation wraps cleanly
        // through magenta and back into red.
        if var wrapped = resolved.first {
            wrapped.center += 360
            resolved.append(wrapped)
        }
        return resolved
    }

    private static func applyColorMixer(_ color: RGB, bands: [ResolvedBand]) -> RGB {
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
        for index in 0..<(bands.count - 1) {
            let lower = bands[index]
            let upper = bands[index + 1]
            guard hsv.x >= lower.center, hsv.x <= upper.center else { continue }

            let span = upper.center - lower.center
            let t = span > 0 ? (hsv.x - lower.center) / span : 0
            hueShift = lerp(lower.hueShift, upper.hueShift, t)
            saturationScale = lerp(lower.saturationScale, upper.saturationScale, t)
            break
        }

        hsv.x += hueShift * influence
        hsv.y = clamp01(hsv.y * lerp(1, saturationScale, influence))
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
