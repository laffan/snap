//
//  DNGRaw.swift
//  Snap
//
//  The sensor image inside a DNG: found, read back, and replaced.
//
//  A long exposure is many negatives added together, and what comes out of
//  that has to be a negative again — something `RAWDeveloper`, the square
//  crop, the sidecar and Lightroom already know what to do with. ImageIO will
//  read a DNG and rewrite the metadata around one, but it will not take new
//  sensor data. So this does the one thing needed and nothing more: it opens
//  the first frame's own DNG, finds the CFA image in it, and puts the merged
//  one in its place. Every other byte — the colour matrices, the lens
//  corrections Apple keeps in its opcode lists, the maker notes, the preview —
//  is the first frame's, untouched, because all of it is still true of the
//  merge.
//
//  Apple writes the sensor image as tiles of lossless JPEG. Writing that back
//  would need an encoder, so the merged image goes in uncompressed instead:
//  the same tiles, in the same order, appended to the end of the file, with the
//  tile table pointed at them and Compression set to none. The old tiles stay
//  where they were, referenced by nothing. That costs the file the size of an
//  uncompressed frame, and buys leaving everything else exactly where Apple put
//  it — which is the part nobody can be sure of rewriting correctly.
//
//  What does change, besides the pixels:
//    · the raw-image digests are made unreadable rather than left wrong, so a
//      converter that checks them doesn't call the file damaged
//    · RawDataUniqueID is new, so a converter's cache doesn't take the merge
//      for the first frame
//    · ExposureTime is the time the stack spans
//    · the noise profile is divided by how many frames went in, since that is
//      what averaging them did to the noise
//

import Foundation

struct DNGRaw {

    enum Failure: LocalizedError {
        case notDNG
        case noSensorImage
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .notDNG:               return "The negative isn't a DNG."
            case .noSensorImage:        return "The negative has no sensor image in it."
            case .unsupported(let why): return "The negative can't be rewritten: \(why)."
            }
        }
    }

    /// The sensor image's size, in photosites.
    let width: Int
    let height: Int
    /// The black level, one value per cell of its repeating pattern, row by row.
    let blackLevels: [Float]
    let blackRepeatRows: Int
    let blackRepeatColumns: Int
    /// Where that pattern starts: the top left of the active area.
    let blackOriginRow: Int
    let blackOriginColumn: Int
    let whiteLevel: Float

    /// How many strips or tiles the image is stored in.
    var segmentCount: Int { offsets.count }

    private let file: TIFFFile
    private let directories: [TIFFFile.Directory]
    private let exif: TIFFFile.Directory?
    private let image: TIFFFile.Directory
    private let layout: Layout
    private let offsets: [Int]
    private let byteCounts: [Int]
    private let compression: Int
    private let bitsPerSample: Int

    private enum Layout {
        case strips(rowsPerStrip: Int)
        case tiles(width: Int, length: Int)
    }

    // MARK: - Reading

    init(_ dng: Data) throws {
        let file: TIFFFile
        do {
            file = try TIFFFile(dng)
        } catch {
            throw Failure.notDNG
        }
        let directories = try file.directories()

        func first(_ tag: UInt16, in directory: TIFFFile.Directory) -> Int? {
            directory[tag].map { file.integer($0, at: 0) }
        }

        // The full-size CFA image: not a preview (subfile type 0) and
        // photometric 32803, which is DNG's colour filter array.
        guard let image = directories.first(where: {
            (first(254, in: $0) ?? 0) == 0 && first(262, in: $0) == 32803
        }) else {
            throw Failure.noSensorImage
        }

        guard let width = first(256, in: image), let height = first(257, in: image),
              width > 0, height > 0 else {
            throw Failure.unsupported("its sensor image has no size")
        }
        guard (first(277, in: image) ?? 1) == 1 else {
            throw Failure.unsupported("its sensor image has more than one sample per photosite")
        }
        guard (first(339, in: image) ?? 1) == 1 else {
            throw Failure.unsupported("its sensor values aren't whole numbers")
        }
        // A linearisation table means the stored numbers are indices into it
        // rather than light, and the average of two indices means nothing.
        guard image[50712] == nil else {
            throw Failure.unsupported("its sensor values go through a linearisation table")
        }

        let bitsPerSample = first(258, in: image) ?? 1
        let compression = first(259, in: image) ?? 1

        let layout: Layout
        let offsets: [Int]
        let byteCounts: [Int]
        if let tileWidth = first(322, in: image), let tileLength = first(323, in: image),
           let tileOffsets = image[324], let tileCounts = image[325],
           tileWidth > 0, tileLength > 0 {
            layout = .tiles(width: tileWidth, length: tileLength)
            offsets = file.integers(tileOffsets)
            byteCounts = file.integers(tileCounts)
            let across = (width + tileWidth - 1) / tileWidth
            let down = (height + tileLength - 1) / tileLength
            guard offsets.count == across * down, byteCounts.count == offsets.count else {
                throw Failure.unsupported("its tile table doesn't match its size")
            }
        } else if let stripOffsets = image[273], let stripCounts = image[279] {
            let rows = max(1, min(first(278, in: image) ?? height, height))
            layout = .strips(rowsPerStrip: rows)
            offsets = file.integers(stripOffsets)
            byteCounts = file.integers(stripCounts)
            guard offsets.count == (height + rows - 1) / rows, byteCounts.count == offsets.count else {
                throw Failure.unsupported("its strip table doesn't match its size")
            }
        } else {
            throw Failure.unsupported("it doesn't say where its sensor image is")
        }
        for (offset, count) in zip(offsets, byteCounts) where offset < 0 || offset + count > file.count {
            throw Failure.unsupported("its sensor image runs past the end of the file")
        }

        // The black level repeats over a small pattern, usually 1×1 or the
        // 2×2 of the colour filter, anchored at the active area's corner.
        var repeatRows = 1
        var repeatColumns = 1
        if let dimensions = image[50713].map({ file.integers($0) }), dimensions.count >= 2,
           dimensions[0] > 0, dimensions[1] > 0 {
            repeatRows = dimensions[0]
            repeatColumns = dimensions[1]
        }
        let cells = repeatRows * repeatColumns
        var black = image[50714].map { file.numbers($0).map(Float.init) } ?? [0]
        if black.isEmpty { black = [0] }
        if black.count < cells {
            black = Array(repeating: black[0], count: cells)
        } else if black.count > cells {
            black = Array(black.prefix(cells))
        }

        var originRow = 0
        var originColumn = 0
        if let area = image[50829].map({ file.integers($0) }), area.count >= 4 {
            originRow = area[0]
            originColumn = area[1]
        }

        let white = image[50717].map { Float(file.number($0, at: 0)) }
            ?? Float((1 << min(bitsPerSample, 16)) - 1)

        var exif: TIFFFile.Directory?
        if let pointer = directories.first.flatMap({ first(34665, in: $0) }) {
            exif = try? file.directory(at: pointer).directory
        }

        self.file = file
        self.directories = directories
        self.exif = exif
        self.image = image
        self.layout = layout
        self.offsets = offsets
        self.byteCounts = byteCounts
        self.compression = compression
        self.bitsPerSample = bitsPerSample
        self.width = width
        self.height = height
        self.blackLevels = black
        self.blackRepeatRows = repeatRows
        self.blackRepeatColumns = repeatColumns
        self.blackOriginRow = originRow
        self.blackOriginColumn = originColumn
        self.whiteLevel = white
    }

    /// The part of the image a strip or tile holds, as stored — a tile at the
    /// right or bottom edge runs past the image, and its stored size says so.
    func segmentRect(_ index: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        switch layout {
        case .strips(let rows):
            let y = index * rows
            return (0, y, width, min(rows, height - y))
        case .tiles(let tileWidth, let tileLength):
            let across = (width + tileWidth - 1) / tileWidth
            return ((index % across) * tileWidth, (index / across) * tileLength, tileWidth, tileLength)
        }
    }

    /// One strip or tile's samples, row by row within it, decoded.
    func segmentSamples(_ index: Int) throws -> [UInt16] {
        let rect = segmentRect(index)
        let range = offsets[index] ..< offsets[index] + byteCounts[index]

        switch compression {
        case 1:
            guard bitsPerSample == 16 else {
                throw Failure.unsupported("its sensor image is packed at \(bitsPerSample) bits")
            }
            let count = rect.width * rect.height
            guard range.count >= count * 2 else {
                throw Failure.unsupported("a piece of its sensor image is short")
            }
            return (0..<count).map { file.read16(range.lowerBound + $0 * 2) }

        case 7:
            let decoded = try file.bytes(in: range) { try LosslessJPEG.decode($0) }
            guard decoded.samples.count == rect.width * rect.height else {
                throw Failure.unsupported("a tile's JPEG doesn't match the tile")
            }
            return decoded.samples

        default:
            throw Failure.unsupported("its sensor image uses compression \(compression)")
        }
    }

    /// The whole sensor image, decoded, row by row with no padding.
    ///
    /// Every strip or tile is its own lossless JPEG, so they are read on every
    /// core at once, each into its own part of the image.
    func decodedImage() throws -> [UInt16] {
        var image = [UInt16](repeating: 0, count: width * height)
        let lock = NSLock()
        var failure: Error?
        let width = self.width
        let height = self.height

        image.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: segmentCount) { index in
                do {
                    let rect = segmentRect(index)
                    let rows = min(rect.height, height - rect.y)
                    let columns = min(rect.width, width - rect.x)
                    guard rows > 0, columns > 0 else { return }
                    let samples = try segmentSamples(index)
                    samples.withUnsafeBufferPointer { tile in
                        guard let source = tile.baseAddress else { return }
                        for row in 0..<rows {
                            (base + (rect.y + row) * width + rect.x)
                                .update(from: source + row * rect.width, count: columns)
                        }
                    }
                } catch {
                    lock.lock()
                    if failure == nil { failure = error }
                    lock.unlock()
                }
            }
        }

        if let failure { throw failure }
        return image
    }

    // MARK: - Replacing

    /// The same DNG with `samples` — `width × height` of them, row by row —
    /// as its sensor image.
    ///
    /// `exposureTime` replaces the EXIF exposure, in seconds. `noiseScale`
    /// multiplies the noise profile: averaging N frames divides the noise
    /// variance by N, so the merge passes 1/N.
    func replacingImage(with samples: [UInt16],
                        exposureTime: Double?,
                        noiseScale: Double) throws -> Data {
        guard samples.count == width * height else {
            throw Failure.unsupported("the merged image is the wrong size")
        }

        var out = file
        let sizes = (0..<segmentCount).map { index -> Int in
            let rect = segmentRect(index)
            return rect.width * rect.height * 2
        }

        // Already uncompressed 16-bit, and every piece has room: the new
        // samples go where the old ones were.
        let inPlace = compression == 1 && bitsPerSample == 16
            && zip(byteCounts, sizes).allSatisfy { $0 >= $1 }

        var positions = offsets
        if !inPlace {
            guard let offsetsEntry = image[324] ?? image[273],
                  let countsEntry = image[325] ?? image[279] else {
                throw Failure.unsupported("it doesn't say where its sensor image is")
            }
            // A table of SHORTs can't point past 64 KB, which is where the end
            // of the file is.
            guard offsetsEntry.type == TIFFFile.long else {
                throw Failure.unsupported("its image table can't point that far")
            }
            guard countsEntry.type == TIFFFile.long || sizes.allSatisfy({ $0 <= 0xFFFF }) else {
                throw Failure.unsupported("its image table can't hold an uncompressed size")
            }

            var next = out.appendZeros(sizes.reduce(0, +), alignment: 4)
            for index in positions.indices {
                positions[index] = next
                next += sizes[index]
            }

            try out.set(offsetsEntry, to: positions)
            try out.set(countsEntry, to: sizes)
            if let entry = image[259] {
                try out.set(entry, to: Array(repeating: 1, count: entry.count))
            }
            if let entry = image[258] {
                try out.set(entry, to: Array(repeating: 16, count: entry.count))
            }
            if let entry = image[317] {
                try out.set(entry, to: Array(repeating: 1, count: entry.count))
            }
        }

        let bigEndian = out.isBigEndian
        samples.withUnsafeBufferPointer { source in
            out.withMutableBytes { bytes in
                guard let from = source.baseAddress, let to = bytes.baseAddress else { return }
                for index in positions.indices {
                    write(segment: index, of: from, into: UnsafeMutableRawPointer(to),
                          at: positions[index], bigEndian: bigEndian)
                }
            }
        }

        // RawImageDigest and NewRawImageDigest are MD5s of the image just
        // replaced. Left as they are, a converter that checks them calls the
        // file damaged; a count of zero is a tag a reader skips.
        for directory in directories {
            for tag: UInt16 in [50972, 51111] {
                if let entry = directory[tag] { out.setCount(entry, to: 0) }
            }
            if let entry = directory[50781], entry.size == 16 {
                var identifier = [UInt8](repeating: 0, count: 16)
                for index in identifier.indices { identifier[index] = UInt8.random(in: 0...255) }
                out.overwrite(entry, with: identifier)
            }
        }

        if let exposureTime, exposureTime > 0 {
            let fraction = DNGRaw.exposureRational(exposureTime)
            for directory in [directories.first, exif].compactMap({ $0 }) {
                if let entry = directory[33434], entry.type == TIFFFile.rational {
                    out.setRational(entry, numerator: fraction.numerator, denominator: fraction.denominator)
                }
            }
        }

        if noiseScale > 0, noiseScale != 1 {
            for directory in directories {
                if let entry = directory[51041], entry.type == TIFFFile.double {
                    out.setDoubles(entry, to: out.numbers(entry).map { $0 * noiseScale })
                }
                // Relative to the camera's own, as a multiplier on its standard
                // deviation rather than its variance.
                if let entry = directory[50731], entry.type == TIFFFile.rational {
                    let value = out.number(entry, at: 0) * noiseScale.squareRoot()
                    let fraction = DNGRaw.rational(value, precision: 10_000)
                    out.setRational(entry, numerator: fraction.numerator, denominator: fraction.denominator)
                }
            }
        }

        return out.data
    }

    /// One strip or tile, in the file's byte order, with the parts of an edge
    /// tile that lie past the image left at zero.
    ///
    /// A row at a time rather than a sample at a time: a debug build checks
    /// every subscript, and twelve million of them is seconds the shutter
    /// would spend waiting. Rows that need their bytes swapped go through a
    /// scratch row, so nothing is ever stored at an address that might not be
    /// aligned for it.
    private func write(segment index: Int,
                       of samples: UnsafePointer<UInt16>,
                       into bytes: UnsafeMutableRawPointer,
                       at position: Int,
                       bigEndian: Bool) {
        let rect = segmentRect(index)
        let rowBytes = rect.width * 2
        let valid = max(0, min(rect.width, width - rect.x))
        let swaps = bigEndian != (UInt16(1).bigEndian == 1)
        var scratch = [UInt16](repeating: 0, count: swaps ? valid : 0)

        for row in 0..<rect.height {
            let destination = bytes + position + row * rowBytes
            let y = rect.y + row
            guard y < height, valid > 0 else {
                destination.initializeMemory(as: UInt8.self, repeating: 0, count: rowBytes)
                continue
            }
            let source = samples + y * width + rect.x
            if swaps {
                scratch.withUnsafeMutableBufferPointer { row in
                    guard let target = row.baseAddress else { return }
                    for x in 0..<valid { target[x] = source[x].byteSwapped }
                    destination.copyMemory(from: target, byteCount: valid * 2)
                }
            } else {
                destination.copyMemory(from: source, byteCount: valid * 2)
            }
            if valid < rect.width {
                (destination + valid * 2).initializeMemory(as: UInt8.self, repeating: 0,
                                                           count: (rect.width - valid) * 2)
            }
        }
    }

    /// A duration as EXIF writes one: a fraction of a second below a second,
    /// tenths above.
    static func exposureRational(_ seconds: Double) -> (numerator: UInt32, denominator: UInt32) {
        if seconds >= 1 { return rational(seconds, precision: 10) }
        return (1, UInt32(clamping: Int((1 / seconds).rounded())))
    }

    /// Any other positive number, to `precision` parts in one.
    static func rational(_ value: Double, precision: Int) -> (numerator: UInt32, denominator: UInt32) {
        (UInt32(clamping: Int((value * Double(precision)).rounded())), UInt32(precision))
    }
}

// MARK: - TIFF

/// Just enough TIFF to read a directory and change values where they lie.
///
/// Nothing is ever moved: a value is overwritten in place, or new data is
/// appended at the end and pointed to. Classic TIFF only, which is what DNG is.
struct TIFFFile {

    enum Failure: Error {
        case malformed
    }

    static let byte: UInt16 = 1
    static let short: UInt16 = 3
    static let long: UInt16 = 4
    static let rational: UInt16 = 5
    static let double: UInt16 = 12

    private var storage: [UInt8]
    let isBigEndian: Bool

    var count: Int { storage.count }
    var data: Data { Data(storage) }

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: Int
        /// Where the twelve-byte entry itself is.
        let position: Int
        /// Where its value is: inside the entry when four bytes hold it,
        /// wherever the entry points when they don't.
        let valuePosition: Int

        var size: Int { count * TIFFFile.width(of: type) }
    }

    struct Directory {
        let offset: Int
        let entries: [UInt16: Entry]

        subscript(tag: UInt16) -> Entry? { entries[tag] }
    }

    init(_ data: Data) throws {
        storage = [UInt8](data)
        guard storage.count >= 8 else { throw Failure.malformed }
        switch (storage[0], storage[1]) {
        case (0x49, 0x49): isBigEndian = false
        case (0x4D, 0x4D): isBigEndian = true
        default: throw Failure.malformed
        }
        guard read16(2) == 42 else { throw Failure.malformed }
    }

    static func width(of type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1
        case 3, 8: return 2
        case 4, 9, 11, 13: return 4
        case 5, 10, 12: return 8
        default: return 0
        }
    }

    // MARK: Directories

    /// Every image directory in the file: the chain from the header, and every
    /// SubIFD hanging off any of them. IFD0 comes first.
    func directories() throws -> [Directory] {
        var found: [Directory] = []
        var pending = [Int(read32(4))]
        var seen = Set<Int>()

        while !pending.isEmpty {
            let offset = pending.removeFirst()
            guard offset > 0, offset < storage.count, seen.insert(offset).inserted else { continue }
            let (directory, next) = try self.directory(at: offset)
            found.append(directory)
            if let subIFDs = directory[330] {
                pending.append(contentsOf: integers(subIFDs))
            }
            if next > 0 { pending.append(next) }
        }

        guard !found.isEmpty else { throw Failure.malformed }
        return found
    }

    /// The directory at `offset`, and the offset of the one after it.
    func directory(at offset: Int) throws -> (directory: Directory, next: Int) {
        guard offset >= 0, offset + 2 <= storage.count else { throw Failure.malformed }
        let entryCount = Int(read16(offset))
        let end = offset + 2 + entryCount * 12
        guard end + 4 <= storage.count else { throw Failure.malformed }

        var entries: [UInt16: Entry] = [:]
        for index in 0..<entryCount {
            let position = offset + 2 + index * 12
            let type = read16(position + 2)
            let width = TIFFFile.width(of: type)
            guard width > 0 else { continue }
            let count = Int(read32(position + 4))
            let size = count * width
            let valuePosition = size <= 4 ? position + 8 : Int(read32(position + 8))
            // A broken entry is skipped rather than allowed to sink the file.
            guard valuePosition >= 0, valuePosition + size <= storage.count else { continue }
            let tag = read16(position)
            entries[tag] = Entry(tag: tag, type: type, count: count,
                                 position: position, valuePosition: valuePosition)
        }
        return (Directory(offset: offset, entries: entries), Int(read32(end)))
    }

    // MARK: Reading values

    func read16(_ at: Int) -> UInt16 {
        isBigEndian
            ? UInt16(storage[at]) << 8 | UInt16(storage[at + 1])
            : UInt16(storage[at]) | UInt16(storage[at + 1]) << 8
    }

    func read32(_ at: Int) -> UInt32 {
        isBigEndian
            ? UInt32(read16(at)) << 16 | UInt32(read16(at + 2))
            : UInt32(read16(at)) | UInt32(read16(at + 2)) << 16
    }

    func read64(_ at: Int) -> UInt64 {
        isBigEndian
            ? UInt64(read32(at)) << 32 | UInt64(read32(at + 4))
            : UInt64(read32(at)) | UInt64(read32(at + 4)) << 32
    }

    func integers(_ entry: Entry) -> [Int] {
        (0..<entry.count).map { integer(entry, at: $0) }
    }

    func integer(_ entry: Entry, at index: Int) -> Int {
        let at = entry.valuePosition + index * TIFFFile.width(of: entry.type)
        switch entry.type {
        case 1, 2, 7: return Int(storage[at])
        case 6:       return Int(Int8(bitPattern: storage[at]))
        case 3:       return Int(read16(at))
        case 8:       return Int(Int16(bitPattern: read16(at)))
        case 4, 13:   return Int(read32(at))
        case 9:       return Int(Int32(bitPattern: read32(at)))
        default:      return Int(number(entry, at: index))
        }
    }

    func numbers(_ entry: Entry) -> [Double] {
        (0..<entry.count).map { number(entry, at: $0) }
    }

    func number(_ entry: Entry, at index: Int) -> Double {
        let at = entry.valuePosition + index * TIFFFile.width(of: entry.type)
        switch entry.type {
        case 5:
            let denominator = read32(at + 4)
            return denominator == 0 ? 0 : Double(read32(at)) / Double(denominator)
        case 10:
            let denominator = Int32(bitPattern: read32(at + 4))
            return denominator == 0 ? 0 : Double(Int32(bitPattern: read32(at))) / Double(denominator)
        case 11:
            return Double(Float(bitPattern: read32(at)))
        case 12:
            return Double(bitPattern: read64(at))
        default:
            return Double(integer(entry, at: index))
        }
    }

    /// A run of the file's bytes, without copying them.
    func bytes<R>(in range: Range<Int>, _ body: (UnsafeBufferPointer<UInt8>) throws -> R) throws -> R {
        guard range.lowerBound >= 0, range.upperBound <= storage.count else { throw Failure.malformed }
        return try storage.withUnsafeBufferPointer { all in
            try body(UnsafeBufferPointer(rebasing: all[range]))
        }
    }

    // MARK: Writing

    mutating func write16(_ value: UInt16, at: Int) {
        if isBigEndian {
            storage[at] = UInt8(truncatingIfNeeded: value >> 8)
            storage[at + 1] = UInt8(truncatingIfNeeded: value)
        } else {
            storage[at] = UInt8(truncatingIfNeeded: value)
            storage[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
    }

    mutating func write32(_ value: UInt32, at: Int) {
        if isBigEndian {
            write16(UInt16(truncatingIfNeeded: value >> 16), at: at)
            write16(UInt16(truncatingIfNeeded: value), at: at + 2)
        } else {
            write16(UInt16(truncatingIfNeeded: value), at: at)
            write16(UInt16(truncatingIfNeeded: value >> 16), at: at + 2)
        }
    }

    mutating func write64(_ value: UInt64, at: Int) {
        if isBigEndian {
            write32(UInt32(truncatingIfNeeded: value >> 32), at: at)
            write32(UInt32(truncatingIfNeeded: value), at: at + 4)
        } else {
            write32(UInt32(truncatingIfNeeded: value), at: at)
            write32(UInt32(truncatingIfNeeded: value >> 32), at: at + 4)
        }
    }

    /// Overwrites an integer entry's values. There must be exactly as many as
    /// it already holds, since nothing here makes room.
    mutating func set(_ entry: Entry, to values: [Int]) throws {
        guard values.count == entry.count else { throw Failure.malformed }
        let width = TIFFFile.width(of: entry.type)
        for (index, value) in values.enumerated() {
            let at = entry.valuePosition + index * width
            switch entry.type {
            case 1, 7:
                guard (0...0xFF).contains(value) else { throw Failure.malformed }
                storage[at] = UInt8(value)
            case 3:
                guard (0...0xFFFF).contains(value) else { throw Failure.malformed }
                write16(UInt16(value), at: at)
            case 4:
                guard (0...0xFFFF_FFFF).contains(value) else { throw Failure.malformed }
                write32(UInt32(value), at: at)
            default:
                throw Failure.malformed
            }
        }
    }

    mutating func setRational(_ entry: Entry, numerator: UInt32, denominator: UInt32) {
        guard entry.type == TIFFFile.rational, entry.count >= 1 else { return }
        write32(numerator, at: entry.valuePosition)
        write32(denominator, at: entry.valuePosition + 4)
    }

    mutating func setDoubles(_ entry: Entry, to values: [Double]) {
        guard entry.type == TIFFFile.double else { return }
        for (index, value) in values.prefix(entry.count).enumerated() {
            write64(value.bitPattern, at: entry.valuePosition + index * 8)
        }
    }

    /// Rewrites how many values an entry claims to hold — which, set to zero,
    /// is a way of switching an entry off without moving anything.
    mutating func setCount(_ entry: Entry, to count: UInt32) {
        write32(count, at: entry.position + 4)
    }

    mutating func overwrite(_ entry: Entry, with bytes: [UInt8]) {
        for (index, byte) in bytes.prefix(entry.size).enumerated() {
            storage[entry.valuePosition + index] = byte
        }
    }

    /// Room at the end of the file, returning where it starts.
    ///
    /// Appended as an array rather than a `repeatElement`: a debug build walks
    /// the latter a byte at a time, which for a frame's worth is seconds.
    mutating func appendZeros(_ count: Int, alignment: Int) -> Int {
        let padding = (alignment - storage.count % alignment) % alignment
        storage.reserveCapacity(storage.count + padding + count)
        storage.append(contentsOf: [UInt8](repeating: 0, count: padding))
        let start = storage.count
        storage.append(contentsOf: [UInt8](repeating: 0, count: count))
        return start
    }

    mutating func withMutableBytes<R>(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> R) rethrows -> R {
        try storage.withUnsafeMutableBufferPointer { try body($0) }
    }
}
