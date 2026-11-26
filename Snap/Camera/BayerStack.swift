//
//  BayerStack.swift
//  Snap
//
//  Sensor frames added up, photosite by photosite.
//
//  Before the colour filter is undone, a negative is one number per photosite:
//  how much light reached it, plus the sensor's black level. Adding frames
//  there is adding light, which is the whole of what a long exposure is, and
//  it happens before anything — demosaicing, white balance, a tone curve — has
//  made a decision that adding afterwards would have to undo.
//
//  What comes out is the average, put back on the scale the frames were on, so
//  it drops into the first frame's DNG as if the sensor had produced it. An
//  average rather than a sum because the sum would be N times too bright and
//  clip; the light the extra frames brought shows up instead as noise that has
//  gone down, by the square root of how many there were.
//
//  Frames of different exposures are weighted by it. Each one is the light it
//  collected — black taken off — and the merge is all of that light divided by
//  all of the exposure, so a frame that got twice the light counts for twice as
//  much, which is what it is worth. With every frame alike that is the plain
//  average.
//
//  The running total is one float per photosite: 48 MB for twelve megapixels,
//  whatever the number of frames. Each frame is added and let go as it arrives,
//  so a thirty-second stack holds no more than a two-second one.
//

import Foundation

final class BayerStack {

    let width: Int
    let height: Int

    /// How many frames have gone in.
    private(set) var frames = 0
    /// The frames' exposures added up, each as a multiple of the first's.
    private(set) var exposure: Double = 0

    private let white: Float
    /// The black level put back on the merge: the first frame's.
    private let black: BlackPattern
    private var sum: [Float]

    /// The black level laid out along a whole row, one row per row of its
    /// repeating pattern, so taking it off a frame is one subtraction per
    /// photosite.
    struct BlackPattern {
        let rows: [[Float]]
        let originRow: Int

        init(width: Int, levels: [Float], repeatRows: Int, repeatColumns: Int,
             originRow: Int, originColumn: Int) {
            let rowCount = max(1, repeatRows)
            let columns = max(1, repeatColumns)
            func level(_ row: Int, _ column: Int) -> Float {
                let index = row * columns + column
                return index < levels.count ? levels[index] : (levels.first ?? 0)
            }
            rows = (0..<rowCount).map { row in
                (0..<width).map { x in
                    level(row, ((x - originColumn) % columns + columns) % columns)
                }
            }
            self.originRow = originRow
        }

        init(width: Int, raw: DNGRaw) {
            self.init(width: width,
                      levels: raw.blackLevels,
                      repeatRows: raw.blackRepeatRows,
                      repeatColumns: raw.blackRepeatColumns,
                      originRow: raw.blackOriginRow,
                      originColumn: raw.blackOriginColumn)
        }

        func row(for y: Int) -> [Float] {
            let count = rows.count
            return rows[((y - originRow) % count + count) % count]
        }
    }

    enum Failure: LocalizedError {
        case wrongSize(width: Int, height: Int)

        var errorDescription: String? {
            switch self {
            case .wrongSize(let width, let height):
                return "A frame came out \(width)×\(height), unlike the first."
            }
        }
    }

    init(width: Int,
         height: Int,
         blackLevels: [Float],
         repeatRows: Int,
         repeatColumns: Int,
         originRow: Int = 0,
         originColumn: Int = 0,
         whiteLevel: Float) {
        self.width = width
        self.height = height
        self.white = whiteLevel
        self.black = BlackPattern(width: width, levels: blackLevels,
                                  repeatRows: repeatRows, repeatColumns: repeatColumns,
                                  originRow: originRow, originColumn: originColumn)
        sum = [Float](repeating: 0, count: width * height)
    }

    convenience init(raw: DNGRaw) {
        self.init(width: raw.width,
                  height: raw.height,
                  blackLevels: raw.blackLevels,
                  repeatRows: raw.blackRepeatRows,
                  repeatColumns: raw.blackRepeatColumns,
                  originRow: raw.blackOriginRow,
                  originColumn: raw.blackOriginColumn,
                  whiteLevel: raw.whiteLevel)
    }

    /// Adds one frame straight out of its own DNG, with its own black level
    /// taken off — so a sensor whose black drifts from frame to frame still
    /// adds up to light and nothing else.
    ///
    /// `exposure` is the frame's shutter times its ISO, relative to the first
    /// frame's. Nothing is added unless the whole frame decodes, so a damaged
    /// one leaves the total as it was.
    func add(_ raw: DNGRaw, exposure relative: Double) throws {
        guard raw.width == width, raw.height == height else {
            throw Failure.wrongSize(width: raw.width, height: raw.height)
        }
        let samples = try raw.decodedImage()
        samples.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            accumulate(base, bytesPerRow: width * 2, black: BlackPattern(width: width, raw: raw))
        }
        frames += 1
        exposure += relative
    }

    /// Adds one frame held as an array, row by row with no padding, whose
    /// black level is the first frame's.
    func add(_ samples: [UInt16], exposure relative: Double) {
        precondition(samples.count == width * height)
        samples.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            accumulate(base, bytesPerRow: width * 2, black: black)
        }
        frames += 1
        exposure += relative
    }

    /// Plain pointers throughout, since a debug build checks every buffer
    /// subscript and a frame is twelve million of them.
    private func accumulate(_ base: UnsafeRawPointer, bytesPerRow: Int, black: BlackPattern) {
        let width = self.width
        sum.withUnsafeMutableBufferPointer { all in
            guard let total = all.baseAddress else { return }
            for y in 0..<height {
                let source = (base + y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                let row = total + y * width
                black.row(for: y).withUnsafeBufferPointer { levels in
                    guard let level = levels.baseAddress else { return }
                    for x in 0..<width {
                        row[x] += Float(source[x]) - level[x]
                    }
                }
            }
        }
    }

    /// The average, on the frames' own scale: all the light divided by all the
    /// exposure, with the black level put back.
    ///
    /// Rounded to whole numbers, which is finer than anything a frame could
    /// show on its own — a single frame's noise is many of these steps across.
    func merged() -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height)
        guard exposure > 0 else { return out }
        let divisor = Float(1 / exposure)
        let white = self.white
        let width = self.width

        sum.withUnsafeBufferPointer { all in
            out.withUnsafeMutableBufferPointer { merged in
                guard let total = all.baseAddress, let result = merged.baseAddress else { return }
                for y in 0..<height {
                    let row = total + y * width
                    let target = result + y * width
                    black.row(for: y).withUnsafeBufferPointer { levels in
                        guard let level = levels.baseAddress else { return }
                        for x in 0..<width {
                            let value = row[x] * divisor + level[x]
                            target[x] = UInt16(min(max(value, 0), white).rounded())
                        }
                    }
                }
            }
        }
        return out
    }
}
