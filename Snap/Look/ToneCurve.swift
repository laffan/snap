//
//  ToneCurve.swift
//  Snap
//
//  The two tone curves Lightroom offers, in the shape it offers them: a
//  parametric curve moved by four region sliders, and a point curve drawn by
//  hand, once for all three channels and once for each of them.
//
//  Both are pure functions of a value, so both are baked into the lookup table
//  with everything else per-pixel — see `Grade`. Nothing in here knows about
//  Core Image, which is what lets the maths be checked anywhere Swift runs.
//

import Foundation

// MARK: - Point curve

/// One control point on a point curve, both axes 0...1.
struct CurvePoint: Codable, Equatable, Hashable {
    var x: Float
    var y: Float
}

/// A curve drawn through control points, the way Lightroom's point curve is.
///
/// Interpolated with a monotone cubic rather than a natural spline: a natural
/// spline overshoots between two points that are close together, which on a
/// tone curve is a tone that goes the wrong way. A monotone one never does,
/// and between points that already rise it is just as smooth.
struct PointCurve: Codable, Equatable {

    /// Sorted by x, endpoints included. Two points is a straight line.
    var points: [CurvePoint] = PointCurve.identityPoints

    static let identityPoints = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]

    /// The most points a curve holds — the same sixteen Lightroom allows.
    static let maximumPoints = 16

    /// True when the curve leaves every value where it found it.
    var isIdentity: Bool {
        points.allSatisfy { abs($0.x - $0.y) < 0.0005 }
    }

    /// The curve at `x`.
    func value(at x: Float) -> Float {
        PointCurve.evaluate(sortedPoints, at: x)
    }

    /// The curve sampled evenly across 0...1, for the lookup table.
    func sampled(count: Int) -> [Float] {
        let sorted = sortedPoints
        let last = Float(max(count - 1, 1))
        return (0..<count).map { PointCurve.evaluate(sorted, at: Float($0) / last) }
    }

    private var sortedPoints: [CurvePoint] {
        points.sorted { $0.x < $1.x }
    }

    /// Fritsch–Carlson monotone cubic interpolation, flat beyond the ends.
    private static func evaluate(_ points: [CurvePoint], at x: Float) -> Float {
        guard let first = points.first, let last = points.last else { return x }
        guard points.count > 1 else { return clamp01(first.y) }
        if x <= first.x { return clamp01(first.y) }
        if x >= last.x { return clamp01(last.y) }

        let count = points.count
        var secants = [Float](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            secants[index] = dx > 0 ? (points[index + 1].y - points[index].y) / dx : 0
        }

        var tangents = [Float](repeating: 0, count: count)
        tangents[0] = secants[0]
        tangents[count - 1] = secants[count - 2]
        for index in 1..<(count - 1) {
            let before = secants[index - 1]
            let after = secants[index]
            tangents[index] = before * after <= 0 ? 0 : (before + after) / 2
        }
        for index in 0..<(count - 1) where secants[index] != 0 {
            let a = tangents[index] / secants[index]
            let b = tangents[index + 1] / secants[index]
            let length = a * a + b * b
            if length > 9 {
                let scale = 3 / length.squareRoot()
                tangents[index] = scale * a * secants[index]
                tangents[index + 1] = scale * b * secants[index]
            }
        }

        var segment = 0
        while segment < count - 2 && x > points[segment + 1].x { segment += 1 }

        let p0 = points[segment]
        let p1 = points[segment + 1]
        let h = p1.x - p0.x
        guard h > 0 else { return clamp01(p0.y) }

        let t = (x - p0.x) / h
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2

        let y = h00 * p0.y + h10 * h * tangents[segment]
            + h01 * p1.y + h11 * h * tangents[segment + 1]
        return clamp01(y)
    }
}

/// The point curve's four channels: the one that moves all three together,
/// and one each for red, green and blue.
struct PointCurves: Codable, Equatable {
    var master = PointCurve()
    var red = PointCurve()
    var green = PointCurve()
    var blue = PointCurve()

    var isIdentity: Bool {
        master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }
}

// MARK: - Parametric curve

/// Lightroom's region curve: four sliders, each lifting or lowering one
/// quarter of the tonal range, −100...100.
///
/// The regions overlap the way Lightroom's do, so moving Darks also moves the
/// edges of Shadows and Lights a little and the curve never kinks at a
/// boundary. Both ends are held where they are — this is a curve for shaping
/// the tones between black and white, and Whites and Blacks are the sliders
/// that move the ends.
struct ParametricCurve: Codable, Equatable {
    var highlights: Float = 0
    var lights: Float = 0
    var darks: Float = 0
    var shadows: Float = 0

    var isIdentity: Bool {
        highlights == 0 && lights == 0 && darks == 0 && shadows == 0
    }

    /// The furthest a region moves at full deflection, in output units.
    static let reach: Float = 0.12

    /// Centres of the four regions, darkest first.
    private static let centers: [Float] = [0.125, 0.375, 0.625, 0.875]
    private static let radius: Float = 0.25

    func value(at x: Float) -> Float {
        guard !isIdentity else { return x }
        let amounts = [shadows, darks, lights, highlights]
        var offset: Float = 0
        for (center, amount) in zip(ParametricCurve.centers, amounts) where amount != 0 {
            let distance = (x - center) / ParametricCurve.radius
            guard abs(distance) < 1 else { continue }
            let bump = (1 - distance * distance)
            offset += amount / 100 * bump * bump
        }
        // Pinned at both ends, gently enough that the curve stays rising even
        // with Shadows or Highlights all the way down.
        let envelope = smoothstep(0, 0.25, x) * smoothstep(0, 0.25, 1 - x)
        return clamp01(x + ParametricCurve.reach * offset * envelope)
    }

    func sampled(count: Int) -> [Float] {
        let last = Float(max(count - 1, 1))
        return (0..<count).map { value(at: Float($0) / last) }
    }
}

// MARK: - Colour grading

/// One of Lightroom's colour-grading wheels: a hue, how much of it, and a
/// luminance shift for the tones it governs.
struct GradeWheel: Codable, Equatable {
    /// Degrees, 0..<360.
    var hue: Float = 0
    /// 0...100. Zero is no tint whatever the hue says.
    var saturation: Float = 0
    /// −100...100.
    var luminance: Float = 0

    var isNeutral: Bool { saturation == 0 && luminance == 0 }
}

/// Lightroom's Color Grading panel: three wheels for shadows, midtones and
/// highlights, a fourth over everything, and the two sliders that say where
/// one range ends and the next begins.
struct ColorGrade: Codable, Equatable {
    var shadows = GradeWheel()
    var midtones = GradeWheel()
    var highlights = GradeWheel()
    var global = GradeWheel()

    /// How much the three ranges overlap, 0...100. Lightroom's default is 50.
    var blending: Float = 50
    /// Where shadows give way to highlights, −100...100. Positive gives more
    /// of the frame to the highlights wheel.
    var balance: Float = 0

    var isNeutral: Bool {
        shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral
    }
}

// MARK: - Sampling

/// A curve sampled for the lookup table, read back with linear interpolation.
struct CurveTable {
    let values: [Float]

    init(_ values: [Float]) {
        self.values = values
    }

    /// Samples per table. Fine enough that the interpolation between two of
    /// them is far inside what the 64³ lookup table can resolve.
    static let samples = 1024

    @inline(__always)
    func callAsFunction(_ x: Float) -> Float {
        let scaled = clamp01(x) * Float(values.count - 1)
        let index = min(Int(scaled), values.count - 2)
        let fraction = scaled - Float(index)
        return values[index] + (values[index + 1] - values[index]) * fraction
    }
}
