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
//  The adjustments that are *not* per-pixel — geometry, exposure,
//  highlight/shadow recovery, noise reduction, texture, clarity, sharpening,
//  the vignette and grain — stay as real filters around the LUT. The maths of
//  the LUT itself is in `Grade`.
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

        // 0. Geometry, before anything else, the way Lightroom does it: every
        //    stage after this one is working on the frame as it will be framed.
        let framed = profile.hasGeometry ? transformed(image) : image

        // Sampling past the edges keeps the blur-based stages from darkening
        // the border; we crop back to the original extent at the end.
        var output = framed.clampedToExtent()

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

        let shortEdge = Float(min(extent.width, extent.height))

        // 3. Noise reduction, before anything sharpens the noise it is there
        //    to remove.
        output = denoised(output, shortEdge: shortEdge)

        // 4. Texture, clarity and sharpening are the same operation at three
        //    scales: a wide, gentle unsharp mask reads as midtone local
        //    contrast, a middling one as texture, a narrow one as detail. All
        //    three radii scale with the image so preview and capture match,
        //    and each softens instead when it is taken below zero.
        output = locallyContrasted(output,
                                   amount: profile.textureAmount * 0.6,
                                   radius: shortEdge * profile.textureRadiusFraction)
        output = locallyContrasted(output,
                                   amount: profile.clarityIntensity,
                                   radius: shortEdge * profile.clarityRadiusFraction)

        if profile.sharpnessIntensity > 0 {
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = output
            sharpen.radius = max(0.5, shortEdge * profile.sharpnessRadiusFraction)
            sharpen.intensity = profile.sharpnessIntensity
            output = sharpen.outputImage ?? output
        }

        // 5. The grade itself.
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = output
        cube.cubeDimension = Float(resolution.rawValue)
        cube.cubeData = cubeData
        cube.colorSpace = workingColorSpace
        output = cube.outputImage ?? output

        // 6. The effects, over the finished picture: a vignette is a thing
        //    done to a print, and grain is the print's own.
        output = vignetted(output, extent: extent)
        output = grained(output, shortEdge: shortEdge)

        return output.cropped(to: extent)
    }

    // MARK: - Local contrast

    /// An unsharp mask for positive amounts, and a blend toward the blur for
    /// negative ones — which is what taking clarity or texture below zero is:
    /// the same band of detail, turned down instead of up.
    private func locallyContrasted(_ image: CIImage, amount: Float, radius: Float) -> CIImage {
        guard amount != 0 else { return image }
        let radius = max(1, radius)

        if amount > 0 {
            let mask = CIFilter.unsharpMask()
            mask.inputImage = image
            mask.radius = radius
            mask.intensity = amount
            return mask.outputImage ?? image
        }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image
        blur.radius = radius
        guard let blurred = blur.outputImage else { return image }

        let blend = CIFilter.dissolveTransition()
        blend.inputImage = image
        blend.targetImage = blurred
        blend.time = min(-amount * 0.6, 1)
        return blend.outputImage ?? image
    }

    // MARK: - Noise reduction

    private func denoised(_ image: CIImage, shortEdge: Float) -> CIImage {
        var output = image

        let level = profile.luminanceNoiseLevel
        if level > 0 {
            let reduction = CIFilter.noiseReduction()
            reduction.inputImage = output
            reduction.noiseLevel = level
            reduction.sharpness = 0.4
            output = reduction.outputImage ?? output
        }

        // Colour noise is speckle in hue, not in brightness. So the colour of
        // a blurred copy is laid under the brightness of the frame itself:
        // the speckle averages out and every edge stays exactly where it was.
        let colorAmount = profile.colorNoiseAmount
        if colorAmount > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = output
            blur.radius = max(1, shortEdge * 0.004)

            let luminosity = CIFilter.luminosityBlendMode()
            luminosity.inputImage = output
            luminosity.backgroundImage = blur.outputImage

            if let smoothed = luminosity.outputImage {
                let blend = CIFilter.dissolveTransition()
                blend.inputImage = output
                blend.targetImage = smoothed
                blend.time = colorAmount
                output = blend.outputImage ?? output
            }
        }

        return output
    }

    // MARK: - Vignette

    /// Lightroom's post-crop vignette: the corners darkened or lightened by
    /// Amount, from a ring set by Midpoint, faded in over Feather.
    ///
    /// Round, because the frame is square, and a vignette that follows a
    /// square frame's own shape is the round one.
    private func vignetted(_ image: CIImage, extent: CGRect) -> CIImage {
        let amount = min(max(profile.vignetteAmount, -100), 100) / 100
        guard amount != 0 else { return image }

        let halfDiagonal = Float(hypot(extent.width, extent.height) / 2)
        let midpoint = min(max(profile.vignetteMidpoint, 0), 100) / 100
        let feather = min(max(profile.vignetteFeather, 0), 100) / 100

        let ring = halfDiagonal * (0.35 + 0.6 * midpoint)
        let inner = max(0, ring * (1 - 0.7 * feather) - halfDiagonal * 0.02)
        let outer = max(inner + 1, ring * (1 + 0.5 * feather) + halfDiagonal * 0.02)

        let gradient = CIFilter.radialGradient()
        gradient.center = CGPoint(x: extent.midX, y: extent.midY)
        gradient.radius0 = inner
        gradient.radius1 = outer

        if amount < 0 {
            // Multiplied: white inside the ring changes nothing, the grey
            // beyond it takes the corners down.
            let edge = CGFloat(1 + amount)
            gradient.color0 = CIColor(red: 1, green: 1, blue: 1)
            gradient.color1 = CIColor(red: edge, green: edge, blue: edge)
            guard let mask = gradient.outputImage else { return image }

            let multiply = CIFilter.multiplyCompositing()
            multiply.inputImage = mask
            multiply.backgroundImage = image
            return multiply.outputImage ?? image
        }

        // Screened: black inside the ring changes nothing, the grey beyond it
        // lifts the corners toward white.
        let edge = CGFloat(amount)
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: edge, green: edge, blue: edge)
        guard let mask = gradient.outputImage else { return image }

        let screen = CIFilter.screenBlendMode()
        screen.inputImage = mask
        screen.backgroundImage = image
        return screen.outputImage ?? image
    }

    // MARK: - Grain

    /// Film grain, soft-lit over the finished picture.
    ///
    /// Monochrome noise from Core Image's generator, blown up to the grain's
    /// size — which, like every other radius here, is a fraction of the
    /// frame's short edge, so the preview and the capture carry the same grain
    /// at their own resolutions. Roughness mixes in a second, finer layer from
    /// another channel of the same noise, so the clumps stop being even.
    /// Soft light leaves a grey of one half exactly where it was, which is
    /// what makes the noise a texture rather than a change of exposure.
    private func grained(_ image: CIImage, shortEdge: Float) -> CIImage {
        let amount = min(max(profile.grainAmount, 0), 100) / 100
        guard amount > 0, let noise = CIFilter.randomGenerator().outputImage else { return image }

        let size = min(max(profile.grainSize, 0), 100) / 100
        let roughness = min(max(profile.grainRoughness, 0), 100) / 100
        let cell = CGFloat(max(0.5, shortEdge * (0.0006 + size * 0.0025)))

        func channel(_ vector: CIVector) -> CIImage {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = noise
            matrix.rVector = vector
            matrix.gVector = vector
            matrix.bVector = vector
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
            matrix.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            return matrix.outputImage ?? noise
        }

        let coarse = channel(CIVector(x: 1, y: 0, z: 0, w: 0))
            .transformed(by: CGAffineTransform(scaleX: cell, y: cell))
        let fine = channel(CIVector(x: 0, y: 1, z: 0, w: 0))
            .transformed(by: CGAffineTransform(scaleX: cell * 0.5, y: cell * 0.5))

        let mix = CIFilter.dissolveTransition()
        mix.inputImage = coarse
        mix.targetImage = fine
        mix.time = roughness * 0.5
        let grain = mix.outputImage ?? coarse

        // Contrast around the middle grey: Amount is how far the grain
        // reaches either side of it.
        let strength = CGFloat(amount * 0.55)
        let contrast = CIFilter.colorMatrix()
        contrast.inputImage = grain
        contrast.rVector = CIVector(x: strength, y: 0, z: 0, w: 0)
        contrast.gVector = CIVector(x: 0, y: strength, z: 0, w: 0)
        contrast.bVector = CIVector(x: 0, y: 0, z: strength, w: 0)
        contrast.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        contrast.biasVector = CIVector(x: 0.5 - strength / 2, y: 0.5 - strength / 2,
                                       z: 0.5 - strength / 2, w: 0)
        guard let shaped = contrast.outputImage else { return image }

        let softLight = CIFilter.softLightBlendMode()
        softLight.inputImage = shaped
        softLight.backgroundImage = image
        return softLight.outputImage ?? image
    }

    // MARK: - Geometry

    /// Straighten and the two perspective sliders, as one move of the frame's
    /// four corners, scaled up just far enough that the square stays filled.
    ///
    /// Vertical widens the top edge and narrows the bottom — what pulls a
    /// building that leans back upright — and Horizontal does the same across.
    /// Then the whole is turned by Straighten, and the smallest scale found at
    /// which the original square fits inside what came out. The frame loses
    /// exactly what turning it costs and nothing more, and never shows an edge.
    private func transformed(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let corners = PositiveFilmFilter.geometryCorners(for: profile)

        let halfWidth = extent.width / 2
        let halfHeight = extent.height / 2
        func placed(_ point: SIMD2<Float>) -> CGPoint {
            CGPoint(x: extent.midX + CGFloat(point.x) * halfWidth,
                    y: extent.midY + CGFloat(point.y) * halfHeight)
        }

        // A couple of pixels of the frame's own edge carried past it, so the
        // resampled border is the photograph rather than a fade to nothing.
        let padded = image.clampedToExtent().cropped(to: extent.insetBy(dx: -2, dy: -2))

        let perspective = CIFilter.perspectiveTransform()
        perspective.inputImage = padded
        perspective.topLeft = placed(corners[0])
        perspective.topRight = placed(corners[1])
        perspective.bottomRight = placed(corners[2])
        perspective.bottomLeft = placed(corners[3])
        guard let output = perspective.outputImage else { return image }
        return output.cropped(to: extent)
    }

    /// Where the frame's corners go, in a square of side two centred on the
    /// origin, y up: top-left, top-right, bottom-right, bottom-left.
    static func geometryCorners(for profile: PositiveFilmProfile) -> [SIMD2<Float>] {
        let vertical = min(max(profile.perspectiveVertical, -100), 100) / 100 * 0.3
        let horizontal = min(max(profile.perspectiveHorizontal, -100), 100) / 100 * 0.3
        let angle = min(max(profile.straighten, -45), 45) * .pi / 180

        var corners: [SIMD2<Float>] = [
            SIMD2(-(1 + vertical), 1 - horizontal),
            SIMD2(1 + vertical, 1 + horizontal),
            SIMD2(1 - vertical, -(1 + horizontal)),
            SIMD2(-(1 - vertical), -(1 - horizontal)),
        ]

        let cosine = cos(angle)
        let sine = sin(angle)
        corners = corners.map { SIMD2($0.x * cosine - $0.y * sine, $0.x * sine + $0.y * cosine) }

        // The smallest scale at which the square [−1, 1]² sits inside the
        // quad. It is convex whatever the sliders say, so the square's four
        // corners being inside is the whole test.
        let square: [SIMD2<Float>] = [SIMD2(-1, 1), SIMD2(1, 1), SIMD2(1, -1), SIMD2(-1, -1)]
        func covers(_ scale: Float) -> Bool {
            let quad = corners.map { $0 * scale }
            return square.allSatisfy { contains(quad, $0) }
        }

        var low: Float = 0.25
        var high: Float = 8
        if covers(1) { high = 1 }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if covers(middle) { high = middle } else { low = middle }
        }
        let scale = high * 1.002
        return corners.map { $0 * scale }
    }

    /// Whether `point` is inside the convex quad, edges included.
    private static func contains(_ quad: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
        var sign: Float = 0
        for index in 0..<quad.count {
            let a = quad[index]
            let b = quad[(index + 1) % quad.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-6 { continue }
            if sign == 0 {
                sign = cross > 0 ? 1 : -1
            } else if (cross > 0 ? 1 : -1) != sign {
                return false
            }
        }
        return true
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
        let grade = Grade(profile: profile)

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

                    let graded = grade(RGB(red, green, blue))

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
}
