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
    /// The black level laid out along a whole row, one row per row of its
    /// repeating pattern, so adding a frame is one subtraction per photosite.
    private let blackRows: [[Float]]
    private let blackOriginRow: Int
    private var sum: [Float]

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
        self.blackOriginRow = originRow

        let rows = max(1, repeatRows)
        let columns = max(1, repeatColumns)
        func level(_ row: Int, _ column: Int) -> Float {
            let index = row * columns + column
            return index < blackLevels.count ? blackLevels[index] : (blackLevels.first ?? 0)
        }
        blackRows = (0..<rows).map { row in
            (0..<width).map { x in
                level(row, ((x - originColumn) % columns + columns) % columns)
            }
        }
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

    private func blackRow(for y: Int) -> Int {
        let rows = blackRows.count
        return ((y - blackOriginRow) % rows + rows) % rows
    }

    /// Adds one frame, read as 16-bit samples `bytesPerRow` apart.
    ///
    /// `exposure` is the frame's shutter times its ISO, relative to the first
    /// frame's. `scale` undoes a pixel buffer that holds the numbers the DNG
    /// does shifted up by some bits — 1 when they are the same numbers.
    ///
    /// Plain pointers throughout, since a debug build checks every buffer
    /// subscript and a frame is twelve million of them.
    func add(_ base: UnsafeRawPointer, bytesPerRow: Int, exposure relative: Double, scale: Float = 1) {
        let width = self.width
        sum.withUnsafeMutableBufferPointer { all in
            guard let total = all.baseAddress else { return }
            for y in 0..<height {
                let source = (base + y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                let row = total + y * width
                blackRows[blackRow(for: y)].withUnsafeBufferPointer { levels in
                    guard let black = levels.baseAddress else { return }
                    if scale == 1 {
                        for x in 0..<width {
                            row[x] += Float(source[x]) - black[x]
                        }
                    } else {
                        for x in 0..<width {
                            row[x] += Float(source[x]) * scale - black[x]
                        }
                    }
                }
            }
        }
        frames += 1
        exposure += relative
    }

    /// Adds one frame held as an array, row by row with no padding.
    func add(_ samples: [UInt16], exposure relative: Double) {
        precondition(samples.count == width * height)
        samples.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            add(base, bytesPerRow: width * 2, exposure: relative)
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
                    blackRows[blackRow(for: y)].withUnsafeBufferPointer { levels in
                        guard let black = levels.baseAddress else { return }
                        for x in 0..<width {
                            let value = row[x] * divisor + black[x]
                            target[x] = UInt16(min(max(value, 0), white).rounded())
                        }
                    }
                }
            }
        }
        return out
    }
}
