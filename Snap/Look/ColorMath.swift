//
//  ColorMath.swift
//  Snap
//
//  Small, dependency-free colour helpers used to bake the film look into a
//  3D lookup table. Everything here operates on display-referred (gamma
//  encoded) sRGB values in the 0...1 range, which is the space Lightroom's
//  sliders effectively work in — that is what lets us translate the published
//  slider values into something recognisable.
//

import simd

typealias RGB = SIMD3<Float>

/// Rec. 709 luma weights, used wherever we need a perceptual brightness.
let lumaWeights = RGB(0.2126, 0.7152, 0.0722)

@inline(__always)
func clamp01(_ x: Float) -> Float {
    min(max(x, 0), 1)
}

@inline(__always)
func clamp01(_ c: RGB) -> RGB {
    RGB(clamp01(c.x), clamp01(c.y), clamp01(c.z))
}

@inline(__always)
func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t
}

@inline(__always)
func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = clamp01((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
}

@inline(__always)
func luma(_ c: RGB) -> Float {
    simd_dot(c, lumaWeights)
}

// MARK: - White balance

/// Warms or cools a colour by pulling the red and blue channels apart, and
/// tints it by moving green against the other two.
///
/// `amount` is the temperature axis of a white balance: red one way, blue the
/// other, green left alone — the fraction each channel is pushed by, positive
/// for warmer. `tint` is the other axis: green down and red and blue up
/// together for magenta, the reverse for green.
///
/// The gains are divided through by what they do to white, so the frame keeps
/// its brightness and only its colour moves. White itself doesn't stay white —
/// that is the whole point of a white balance — but it doesn't get lighter
/// or darker on the way.
@inline(__always)
func whiteBalanced(_ c: RGB, amount: Float, tint: Float = 0) -> RGB {
    guard amount != 0 || tint != 0 else { return c }
    let gain = RGB(1 + amount + tint / 2, 1 - tint, 1 - amount + tint / 2)
    let brightness = simd_dot(gain, lumaWeights)
    guard brightness > 0 else { return c }
    return c * (gain / brightness)
}

// MARK: - HSV

/// Returns `(hue in 0..<360, saturation 0...1, value 0...1)`.
func rgbToHSV(_ c: RGB) -> RGB {
    let maxC = max(c.x, max(c.y, c.z))
    let minC = min(c.x, min(c.y, c.z))
    let delta = maxC - minC

    var hue: Float = 0
    if delta > 0 {
        if maxC == c.x {
            hue = 60 * ((c.y - c.z) / delta)
        } else if maxC == c.y {
            hue = 60 * (2 + (c.z - c.x) / delta)
        } else {
            hue = 60 * (4 + (c.x - c.y) / delta)
        }
        if hue < 0 { hue += 360 }
    }

    let saturation = maxC > 0 ? delta / maxC : 0
    return RGB(hue, saturation, maxC)
}

func hsvToRGB(_ hsv: RGB) -> RGB {
    var hue = hsv.x.truncatingRemainder(dividingBy: 360)
    if hue < 0 { hue += 360 }

    let saturation = clamp01(hsv.y)
    let value = hsv.z

    let sector = hue / 60
    let index = sector.rounded(.down)
    let fraction = sector - index

    let p = value * (1 - saturation)
    let q = value * (1 - saturation * fraction)
    let t = value * (1 - saturation * (1 - fraction))

    switch Int(index) % 6 {
    case 0:  return RGB(value, t, p)
    case 1:  return RGB(q, value, p)
    case 2:  return RGB(p, value, t)
    case 3:  return RGB(p, q, value)
    case 4:  return RGB(t, p, value)
    default: return RGB(value, p, q)
    }
}

// MARK: - Tone shaping

/// Blends `x` toward a smoothstep S-curve. `amount` of 0 is a no-op; an amount
/// of 1 gives the full 3x² − 2x³ curve, whose slope through the midtones is
/// 1.5. So the resulting midtone contrast multiplier is `1 + amount / 2`,
/// which is how the Lightroom-style contrast values get translated.
@inline(__always)
func sCurve(_ x: Float, amount: Float) -> Float {
    guard amount != 0 else { return x }
    let s = x * x * (3 - 2 * x)
    return x + (s - x) * amount
}

@inline(__always)
func sCurve(_ c: RGB, amount: Float) -> RGB {
    RGB(sCurve(c.x, amount: amount),
        sCurve(c.y, amount: amount),
        sCurve(c.z, amount: amount))
}

/// Raises the black point so the darkest tone in the frame is a soft charcoal
/// rather than true black — the "matte" foot of the Positive Film curve.
@inline(__always)
func liftBlacks(_ c: RGB, by lift: Float) -> RGB {
    RGB(repeating: lift) + c * (1 - lift)
}

/// Moves the black point without disturbing the midtones: full effect at the
/// floor, faded out by roughly 35% grey. Negative crushes, positive opens.
@inline(__always)
func shiftBlacks(_ x: Float, by amount: Float) -> Float {
    x + amount * (1 - smoothstep(0, 0.35, x))
}

@inline(__always)
func shiftBlacks(_ c: RGB, by amount: Float) -> RGB {
    guard amount != 0 else { return c }
    return RGB(shiftBlacks(c.x, by: amount),
               shiftBlacks(c.y, by: amount),
               shiftBlacks(c.z, by: amount))
}

/// Moves the white point without disturbing the midtones: full effect at the
/// top, faded out by roughly 65% grey. The mirror of `shiftBlacks`.
@inline(__always)
func shiftWhites(_ c: RGB, by amount: Float) -> RGB {
    guard amount != 0 else { return c }
    func shift(_ x: Float) -> Float { x + amount * smoothstep(0.65, 1, x) }
    return RGB(shift(c.x), shift(c.y), shift(c.z))
}

/// Scales every colour's distance from its own grey by the same amount.
@inline(__always)
func applySaturation(_ c: RGB, scale: Float) -> RGB {
    guard scale != 1 else { return c }
    let grey = RGB(repeating: luma(c))
    return grey + (c - grey) * scale
}

/// Takes a haze out, or lays one on.
///
/// Haze is light scattered toward the camera on the way, which adds a veil of
/// near-white to everything in proportion to how far off it is. The darkest
/// channel of a colour is the best single guess at how much veil it carries —
/// nothing in a clear scene is lit evenly in all three — so positive amounts
/// subtract that much of white and stretch what is left back out, which is the
/// dark-channel prior worked one pixel at a time. Half the brightness that
/// costs is given back, since a dehazed frame should read clearer, not darker.
///
/// Negative amounts lay a cool, pale veil over the frame.
@inline(__always)
func dehazed(_ c: RGB, amount: Float) -> RGB {
    guard amount != 0 else { return c }
    let white = RGB(repeating: 1)
    if amount < 0 {
        let veil = RGB(0.82, 0.84, 0.87)
        return c + (veil - c) * (-amount * 0.5)
    }
    let dark = min(c.x, min(c.y, c.z))
    let transmission = max(1 - 0.45 * amount * dark, 0.2)
    let cleared = clamp01((c - white) / transmission + white)
    let before = luma(c)
    let after = luma(cleared)
    guard after > 0.0001 else { return cleared }
    let restored = clamp01(cleared * (before / after))
    return cleared + (restored - cleared) * 0.5
}

/// Saturation boost that backs off on colours that are already saturated, so
/// skin tones and skies gain life without the reds going neon.
@inline(__always)
func applyVibrance(_ c: RGB, amount: Float) -> RGB {
    guard amount != 0 else { return c }
    let maxC = max(c.x, max(c.y, c.z))
    let minC = min(c.x, min(c.y, c.z))
    let saturation = maxC > 0 ? (maxC - minC) / maxC : 0

    let gain = 1 + amount * (1 - saturation) * 2
    let grey = luma(c)
    return RGB(repeating: grey) + (c - RGB(repeating: grey)) * gain
}
