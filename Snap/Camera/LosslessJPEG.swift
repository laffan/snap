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
//  Snap needs it for one thing: reading a tile of the first frame of a long
//  exposure back out of its DNG, to check that the pixel buffer AVFoundation
//  handed over holds the same numbers the file does. Everything after that
//  works on the pixel buffers and never decodes anything, so this is written to
//  be plain rather than fast.
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

    private static func decodeScan(_ data: UnsafeBufferPointer<UInt8>,
                                   frame: Frame,
                                   tables: [Huffman],
                                   predictor: Int,
                                   pointTransform: Int) throws -> [UInt16] {
        let components = frame.components
        let rowLength = frame.width * components
        var samples = [UInt16](repeating: 0, count: rowLength * frame.height)
        var reader = BitReader(data)
        // The first sample of the first row is predicted from the middle of the
        // range, since there is nothing before it to predict from.
        let initial = 1 << (frame.precision - pointTransform - 1)

        try samples.withUnsafeMutableBufferPointer { out in
            for row in 0..<frame.height {
                let rowStart = row * rowLength
                for column in 0..<frame.width {
                    for component in 0..<components {
                        let index = rowStart + column * components + component
                        let difference = try reader.difference(using: tables[component])

                        let prediction: Int
                        if row == 0 && column == 0 {
                            prediction = initial
                        } else if row == 0 {
                            prediction = Int(out[index - components])
                        } else if column == 0 {
                            prediction = Int(out[index - rowLength])
                        } else {
                            let left = Int(out[index - components])
                            let above = Int(out[index - rowLength])
                            let corner = Int(out[index - rowLength - components])
                            switch predictor {
                            case 1: prediction = left
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
                        out[index] = UInt16(truncatingIfNeeded: prediction + difference)
                    }
                }
            }
            if pointTransform > 0 {
                for index in out.indices { out[index] <<= UInt16(pointTransform) }
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

        init(lengths: [Int], symbols: [UInt8]) throws {
            var lookup = [UInt16](repeating: 0, count: 1 << 16)
            var code = 0
            var next = 0
            for length in 1...16 {
                for _ in 0..<lengths[length - 1] {
                    let shift = 16 - length
                    let start = code << shift
                    let end = (code + 1) << shift
                    guard end <= lookup.count, next < symbols.count else {
                        throw Failure.malformed("a Huffman table with too many codes")
                    }
                    let entry = UInt16(length << 8 | Int(symbols[next]))
                    for index in start..<end { lookup[index] = entry }
                    code += 1
                    next += 1
                }
                code <<= 1
            }
            self.lookup = lookup
        }
    }

    // MARK: - Bits

    /// The entropy-coded data, a bit at a time, with JPEG's stuffed zero after
    /// every 0xFF taken back out. A marker ends it, after which it reads zeros.
    private struct BitReader {
        private let data: UnsafeBufferPointer<UInt8>
        private var position = 0
        /// The next bits, from the top down.
        private var buffer: UInt64 = 0
        private var available = 0

        init(_ data: UnsafeBufferPointer<UInt8>) {
            self.data = data
        }

        private mutating func refill() {
            while available <= 56 {
                var byte: UInt8 = 0
                if position < data.count {
                    byte = data[position]
                    if byte == 0xFF {
                        let following: UInt8 = position + 1 < data.count ? data[position + 1] : 0xD9
                        if following == 0x00 {
                            position += 2
                        } else {
                            // A marker: the data is over. Stay put and read zeros.
                            byte = 0
                        }
                    } else {
                        position += 1
                    }
                }
                buffer |= UInt64(byte) << UInt64(56 - available)
                available += 8
            }
        }

        private mutating func take(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            refill()
            let value = Int(buffer >> UInt64(64 - count))
            buffer <<= UInt64(count)
            available -= count
            return value
        }

        /// One coded difference: a Huffman code for how many bits it has, then
        /// those bits.
        mutating func difference(using table: Huffman) throws -> Int {
            refill()
            let entry = table.lookup[Int(buffer >> 48)]
            guard entry != 0 else { throw Failure.malformed("a code that isn't in its table") }
            let length = Int(entry >> 8)
            buffer <<= UInt64(length)
            available -= length

            let size = Int(entry & 0xFF)
            switch size {
            case 0:
                return 0
            case 16:
                // The one size with no bits after it.
                return 32768
            case 1...15:
                let bits = take(size)
                return bits < (1 << (size - 1)) ? bits - (1 << size) + 1 : bits
            default:
                throw Failure.malformed("a difference of \(size) bits")
            }
        }
    }
}
