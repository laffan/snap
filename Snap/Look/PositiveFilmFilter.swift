//
//  PositiveFilmFilter.swift
//  Snap
//
//  Turns a PositiveFilmProfile into something Core Image can run, and applies
//  it identically to the live preview and to the captured frame.
//
//  Everything that is a pure per-pixel function of colour — white balance,
//  calibration, contrast, vibrance, the HSL mixer, the tone curve — is baked
//  once into a single 3D lookup table. That keeps the per-frame cost to one
//  texture fetch no matter how elaborate the grade gets, and guarantees the
//  preview and the saved file go through the exact same maths.
//
//  The adjustments that are *not* per-pixel — highlight/shadow recovery,
//  exposure, clarity and sharpening — stay as real filters around the LUT.
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

    /// The exposure as a curve over linear light, or nil at zero.
    private let exposureCurve: Data?
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    init(profile: PositiveFilmProfile = PositiveFilmProfile(),
         resolution: Resolution = .final) {
        self.profile = profile
        self.resolution = resolution
        self.cubeData = PositiveFilmFilter.makeCubeData(profile: profile,
                                                        dimension: resolution.rawValue)
        self.exposureCurve = PositiveFilmFilter.makeExposureCurve(stops: profile.exposure)
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

        // 1. Exposure, first, so everything downstream sees the tones the
        //    photograph is actually meant to have. Moved along a shoulder
        //    rather than multiplied — see `makeExposureCurve`.
        if let exposureCurve {
            let curve = CIFilter.colorCurves()
            curve.inputImage = output
            curve.curvesData = exposureCurve
            curve.curvesDomain = CIVector(x: 0, y: 1)
            curve.colorSpace = linearColorSpace
            output = curve.outputImage ?? output
        }

        // 2. Highlight recovery and shadow lift, before anything steepens the
        //    curve, so there is still headroom to recover.
        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = output
        highlightShadow.highlightAmount = profile.highlightAmount
        highlightShadow.shadowAmount = profile.shadowAmount
        output = highlightShadow.outputImage ?? output

        // 3. Clarity and sharpening are the same operation at two scales: a
        //    wide, gentle unsharp mask reads as midtone local contrast, a
        //    narrow one reads as detail. Both radii scale with the image so
        //    preview and capture match.
        let shortEdge = Float(min(extent.width, extent.height))

        if profile.clarityIntensity > 0 {
            let clarity = CIFilter.unsharpMask()
            clarity.inputImage = output
            clarity.radius = max(1, shortEdge * profile.clarityRadiusFraction)
            clarity.intensity = profile.clarityIntensity
            output = clarity.outputImage ?? output
        }

        if profile.sharpnessIntensity > 0 {
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = output
            sharpen.radius = max(0.5, shortEdge * profile.sharpnessRadiusFraction)
            sharpen.intensity = profile.sharpnessIntensity
            output = sharpen.outputImage ?? output
        }

        // 4. The grade itself.
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = output
        cube.cubeDimension = Float(resolution.rawValue)
        cube.cubeData = cubeData
        cube.colorSpace = workingColorSpace
        output = cube.outputImage ?? output

        return output.cropped(to: extent)
    }

    // MARK: - Exposure

    /// How hard the highlights are assumed to have been rolled off already.
    ///
    /// At 4, white in the frame is taken to sit at 80% of the brightest thing
    /// the scene could hold — a strong shoulder, which is what Apple's own
    /// rendering of the video frames has.
    private static let exposureShoulder: Float = 4

    /// Samples in the exposure curve. It is close to a straight line through
    /// the shadows, where linear light crowds its values, so 1024 is plenty.
    private static let exposureCurveSamples = 1024

    /// Exposure as a move along a film-like shoulder, sampled for
    /// `CIColorCurves`.
    ///
    /// What the preview reaches this with is a frame that has already been
    /// rendered — the video stream is Apple's finished picture — so its white
    /// is the top of a shoulder rather than a measurement of the light. A
    /// plain gain treats it as the light: one stop down drags white to 188/255, everything in the
    /// frame goes down by the same ratio, and the frame reads as the same
    /// picture under a grey veil.
    ///
    /// So the shoulder is unrolled, the stops applied to that, and the
    /// shoulder rolled back on. The shadows move by the full amount, where a
    /// stop is a stop; the midtones by most of it; the highlights by much
    /// less, since they were the part already compressed. One stop down
    /// leaves white at 235/255 and the shadows a full stop deeper, which is
    /// contrast kept rather than lost. Up, the highlights roll into white
    /// instead of piling up against it.
    ///
    /// `shoulder(s) = (1 + k)s / (1 + ks)` maps 0→0 and 1→1, and moving by
    /// `g = 2^stops` is `shoulder(g · shoulder⁻¹(x))`. Moves compose — +1
    /// then −1 is where you started — and the curve is never more than about
    /// 1.6× steeper than the input, so 8-bit skies don't band at −5.
    ///
    /// The curve's domain stops at white. Anything a RAW development carries
    /// above 1 is held there on the way in, which costs only what a stop
    /// down used to pull back from above white before the lookup table
    /// clamped it.
    private static func makeExposureCurve(stops: Float) -> Data? {
        guard stops != 0 else { return nil }

        let k = exposureShoulder
        let gain = pow(2, stops)
        let last = Float(exposureCurveSamples - 1)

        var values = [Float]()
        values.reserveCapacity(exposureCurveSamples * 3)
        for index in 0..<exposureCurveSamples {
            let x = Float(index) / last
            let scene = x / ((1 + k) - k * x)
            let moved = gain * scene
            let y = min((1 + k) * moved / (1 + k * moved), 1)
            values.append(contentsOf: [y, y, y])
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
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

    /// The per-pixel grade, in the order Lightroom applies it: white balance,
    /// camera calibration, then the basic panel (blacks, contrast, vibrance),
    /// then the colour mixer, then the point curve.
    private static func grade(_ input: RGB,
                              profile: PositiveFilmProfile,
                              calibration: simd_float3x3,
                              bands: [ResolvedBand]) -> RGB {
        // First, as white balance always is: everything downstream is built on
        // an assumption about what colour the light was.
        var color = clamp01(whiteBalanced(input, amount: profile.temperatureAmount))
        color = clamp01(calibration * color)
        // The scene as the sensor saw it, before the look has had its say
        // about greens — which is the only thing the infrared estimate can be
        // made from, and the look would otherwise have crushed half of it.
        let scene = color
        color = clamp01(shiftBlacks(color, by: profile.blacksShift))
        color = sCurve(color, amount: profile.contrastAmount)
        color = clamp01(applyVibrance(color, amount: profile.vibranceAmount))
        color = applyColorMixer(color, bands: bands)

        // After the mixer rather than before it: the look takes Purple and
        // Magenta almost out, and those are exactly the colours infrared
        // foliage comes out as.
        let infraredAmount = profile.infraredAmount
        if infraredAmount > 0 {
            color = infrared(color, scene: scene, amount: infraredAmount)
        }

        color = sCurve(color, amount: profile.toneCurveAmount)
        color = liftBlacks(color, by: profile.blackLift)

        // Last, so the colour mixer still shapes the result: a band that was
        // desaturated arrives here darker or lighter than one that wasn't,
        // which is exactly how a black-and-white mixer works.
        if profile.blackAndWhite {
            let graded = clamp01(color)
            // Black-and-white infrared is the infrared record on its own:
            // white trees under a black sky. After the mapping above, that
            // record is the red channel.
            color = RGB(repeating: lerp(luma(graded), graded.x, infraredAmount))
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
