//
//  LosslessJPEG.swift
//  Snap
//
//  Reads the lossless JPEG that DNG tiles are written in.
//
//  This is the old lossless mode of JPEG — ITU T.81's process 14, usually
//  called LJ92 — rather than the JPEG everybody knows: each sample is
//  predicted from its neighbours and only the difference is Huffman-coded, so
//  the numbers come back exactly. Apple writes a Bayer negative's sensor image
//  as tiles of it.
//
//  Snap reads every frame of a long exposure back out of its DNG through
//  this, all of its tiles at once, so it is written to be quick in a debug
//  build as well as a release one — see `decodeScan`. Checked against LibRaw,
//  photosite for photosite, on the Bayer negatives of five iPhones from the 6s
//  Plus to the XS, which Apple wrote the same way throughout: twelve-bit
//  samples, two interleaved components a row, predictor 1.
//
//  What a DNG uses is all that is supported: one frame, every component in one
//  scan, any of the seven predictors, any precision up to 16 bits. Restart
//  intervals and the hierarchical modes are refused rather than guessed at.
//

import Foundation

enum LosslessJPEG {

    enum Failure: LocalizedError {
        case malformed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let what):   return "A lossless JPEG is damaged: \(what)."
            case .unsupported(let what): return "A lossless JPEG uses something Snap can't read: \(what)."
            }
        }
    }

    /// The shape the JPEG itself declares. DNG usually codes a tile as half
    /// as many columns of two interleaved components, so `width × components`
    /// is the tile's width.
    struct Frame {
        let width: Int
        let height: Int
        let components: Int
        let precision: Int
    }

    /// Decodes a whole lossless JPEG. Samples come back in the order they were
    /// coded — row by row, and within a row each column's components in turn —
    /// which is the tile's own order, photosite by photosite.
    static func decode(_ bytes: UnsafeBufferPointer<UInt8>) throws -> (frame: Frame, samples: [UInt16]) {
        let count = bytes.count
        guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw Failure.malformed("no start of image")
        }

        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }

        var tables: [Int: Huffman] = [:]
        var frame: Frame?
        var componentIDs: [Int] = []
        var position = 2

        while position + 4 <= count {
            guard bytes[position] == 0xFF else { throw Failure.malformed("lost its place between segments") }
            let marker = bytes[position + 1]
            // Fill bytes, and the markers that stand alone.
            if marker == 0xFF { position += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { position += 2; continue }
            if marker == 0xD9 { break }

            let length = u16(position + 2)
            let body = position + 4
            let end = position + 2 + length
            guard length >= 2, end <= count else { throw Failure.malformed("a segment runs past the end") }

            switch marker {
            case 0xC4:
                var at = body
                while at + 17 <= end {
                    let id = Int(bytes[at] & 0x0F)
                    var lengths = [Int](repeating: 0, count: 16)
                    for index in 0..<16 { lengths[index] = Int(bytes[at + 1 + index]) }
                    let total = lengths.reduce(0, +)
                    guard at + 17 + total <= end else { throw Failure.malformed("a Huffman table is short") }
                    let symbols = (0..<total).map { bytes[at + 17 + $0] }
                    tables[id] = try Huffman(lengths: lengths, symbols: symbols)
                    at += 17 + total
                }

            case 0xC3:
                guard length >= 8 else { throw Failure.malformed("the frame header is short") }
                let components = Int(bytes[body + 5])
                guard components > 0, length >= 8 + components * 3 else {
                    throw Failure.malformed("the frame header is short")
                }
                frame = Frame(width: u16(body + 3), height: u16(body + 1),
                              components: components, precision: Int(bytes[body]))
                componentIDs = (0..<components).map { Int(bytes[body + 6 + $0 * 3]) }

            case 0xC0, 0xC1, 0xC2, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF:
                throw Failure.unsupported("it isn't the lossless process")

            case 0xDD:
                if u16(body) != 0 { throw Failure.unsupported("restart intervals") }

            case 0xDA:
                guard let frame else { throw Failure.malformed("a scan before the frame") }
                let scanComponents = Int(bytes[body])
                guard scanComponents == frame.components, length >= 6 + scanComponents * 2 else {
                    throw Failure.unsupported("components in separate scans")
                }
                var order: [Huffman] = []
                for index in 0..<scanComponents {
                    let selector = Int(bytes[body + 1 + index * 2])
                    let table = Int(bytes[body + 2 + index * 2] >> 4)
                    guard componentIDs.firstIndex(of: selector) == index else {
                        throw Failure.unsupported("components out of order")
                    }
                    guard let huffman = tables[table] else { throw Failure.malformed("a missing Huffman table") }
                    order.append(huffman)
                }
                let predictor = Int(bytes[body + 1 + scanComponents * 2])
                let pointTransform = Int(bytes[body + 3 + scanComponents * 2] & 0x0F)
                guard (1...7).contains(predictor) else { throw Failure.unsupported("predictor \(predictor)") }
                guard (2...16).contains(frame.precision), pointTransform < frame.precision else {
                    throw Failure.unsupported("\(frame.precision)-bit samples")
                }

                let samples = try decodeScan(UnsafeBufferPointer(rebasing: bytes[end...]),
                                             frame: frame,
                                             tables: order,
                                             predictor: predictor,
                                             pointTransform: pointTransform)
                return (frame, samples)

            default:
                break
            }
            position = end
        }
        throw Failure.malformed("no scan")
    }

    // MARK: - The scan

    /// The entropy-coded data, sample by sample.
    ///
    /// Written with plain pointers and the bit reading inlined, because this
    /// runs over every photosite of every frame of a long exposure, and a debug
    /// build — which is what runs from Xcode — checks every array subscript
    /// and calls every small method rather than folding it in. That made a
    /// frame take longer to read than to take. The shifts are the masking kind
    /// for the same reason: the ordinary ones are generic, and unoptimised a
    /// generic call is what each of them becomes.
    private static func decodeScan(_ data: UnsafeBufferPointer<UInt8>,
                                   frame: Frame,
                                   tables: [Huffman],
                                   predictor: Int,
                                   pointTransform: Int) throws -> [UInt16] {
        let components = frame.components
        let rowLength = frame.width * components
        var samples = [UInt16](repeating: 0, count: rowLength * frame.height)
        // The first sample of the first row is predicted from the middle of the
        // range, since there is nothing before it to predict from.
        let initial = 1 << (frame.precision - pointTransform - 1)

        // Every component's table end to end, so one pointer reaches them all.
        var lookups = [UInt16]()
        lookups.reserveCapacity(components << 16)
        for table in tables { lookups.append(contentsOf: table.lookup) }

        guard let input = data.baseAddress else { throw Failure.malformed("no scan data") }
        let end = data.count

        try samples.withUnsafeMutableBufferPointer { buffer in
            try lookups.withUnsafeBufferPointer { lookupBuffer in
                guard let out = buffer.baseAddress, let lookup = lookupBuffer.baseAddress else { return }

                var position = 0
                /// The next bits, from the top down, and how many of them are real.
                var bits: UInt64 = 0
                var available = 0
                var index = 0

                for row in 0..<frame.height {
                    for column in 0..<frame.width {
                        for component in 0..<components {
                            // Enough for a code and its bits — sixteen and
                            // fifteen at most — with one refill. JPEG stuffs a
                            // zero after every 0xFF; any other byte after one is
                            // a marker, which ends the data and reads as zeros.
                            while available <= 56 {
                                var byte: UInt8 = 0
                                if position < end {
                                    byte = input[position]
                                    if byte == 0xFF {
                                        if position + 1 < end, input[position + 1] == 0 {
                                            position += 2
                                        } else {
                                            byte = 0
                                        }
                                    } else {
                                        position += 1
                                    }
                                }
                                bits |= UInt64(truncatingIfNeeded: byte) &<< UInt64(truncatingIfNeeded: 56 - available)
                                available &+= 8
                            }

                            let entry = lookup[(component &<< 16) | Int(truncatingIfNeeded: bits &>> 48)]
                            guard entry != 0 else { throw Failure.malformed("a code that isn't in its table") }
                            let length = Int(truncatingIfNeeded: entry &>> 8)
                            bits = bits &<< UInt64(truncatingIfNeeded: length)
                            available &-= length

                            // How many bits the difference has, then those bits.
                            // Sixteen is the one size with none after it.
                            let size = Int(truncatingIfNeeded: entry & 0xFF)
                            var difference = 0
                            if size == 16 {
                                difference = 32768
                            } else if size > 0 {
                                guard size < 16 else { throw Failure.malformed("a difference of \(size) bits") }
                                let value = Int(truncatingIfNeeded: bits &>> UInt64(truncatingIfNeeded: 64 &- size))
                                bits = bits &<< UInt64(truncatingIfNeeded: size)
                                available &-= size
                                difference = value < (1 &<< (size &- 1)) ? value &- (1 &<< size) &+ 1 : value
                            }

                            let prediction: Int
                            if row == 0 {
                                prediction = column == 0 ? initial : Int(out[index - components])
                            } else if column == 0 {
                                prediction = Int(out[index - rowLength])
                            } else if predictor == 1 {
                                // What Apple writes, so the one worth not branching past.
                                prediction = Int(out[index - components])
                            } else {
                                let left = Int(out[index - components])
                                let above = Int(out[index - rowLength])
                                let corner = Int(out[index - rowLength - components])
                                switch predictor {
                                case 2: prediction = above
                                case 3: prediction = corner
                                case 4: prediction = left + above - corner
                                case 5: prediction = left + ((above - corner) >> 1)
                                case 6: prediction = above + ((left - corner) >> 1)
                                default: prediction = (left + above) >> 1
                                }
                            }
                            // Arithmetic is modulo 2¹⁶, which is how a difference
                            // of 32768 wraps round to anything.
                            out[index] = UInt16(truncatingIfNeeded: prediction &+ difference)
                            index &+= 1
                        }
                    }
                }

                if pointTransform > 0 {
                    let shift = UInt16(pointTransform)
                    for at in 0..<index { out[at] <<= shift }
                }
            }
        }
        return samples
    }

    // MARK: - Huffman

    /// A table looked up sixteen bits at a time: every code is at most sixteen
    /// long, so the next sixteen bits always name exactly one.
    private struct Huffman {
        /// Length in the high byte, symbol in the low; zero for no code.
        let lookup: [UInt16]

        /// Every tile brings tables of its own, so this is built 128 times a
        /// frame — each code's run of entries is filled in one go rather than
        /// one subscript at a time.
        init(lengths: [Int], symbols: [UInt8]) throws {
            var lookup = [UInt16](repeating: 0, count: 1 << 16)
            try lookup.withUnsafeMutableBufferPointer { buffer in
                guard let table = buffer.baseAddress else { return }
                var code = 0
                var next = 0
                for length in 1...16 {
                    for _ in 0..<lengths[length - 1] {
                        let shift = 16 - length
                        let start = code << shift
                        let end = (code + 1) << shift
                        guard end <= buffer.count, next < symbols.count else {
                            throw Failure.malformed("a Huffman table with too many codes")
                        }
                        let entry = UInt16(length << 8 | Int(symbols[next]))
                        (table + start).update(repeating: entry, count: end - start)
                        code += 1
                        next += 1
                    }
                    code <<= 1
                }
            }
            self.lookup = lookup
        }
    }
}
