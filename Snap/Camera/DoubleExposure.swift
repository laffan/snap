//
//  DoubleExposure.swift
//  Snap
//
//  Two photographs on one frame, added the way film adds them.
//
//  A frame of film exposed twice holds both lots of light, and a Bayer negative
//  can be made to do exactly the same: before demosaicing, each photosite is a
//  number for how much light reached it, so two negatives added photosite by
//  photosite are the one the sensor would have made had it been open for both.
//  That is a sum rather than an average — a highlight in either exposure stays
//  as bright as it was — which is why each exposure is taken a stop under what
//  the wheel says, the way two exposures on film are: the two stops' worth of
//  light add up to the one.
//
//  The sum is written into the first exposure's DNG by `DNGRaw`, the way a long
//  exposure's is, and from there it is a negative like any other. It keeps the
//  first exposure's colour matrices and white balance, which is what film does
//  too: a frame shot under a lamp on top of one shot in daylight is rendered as
//  one roll of film would render both.
//

import Foundation

enum DoubleExposure {

    /// How far under the wheel each exposure is taken, so that two of them add
    /// up to it.
    static let stopsUnder: Float = 1

    enum Failure: LocalizedError {
        case differentSensors

        var errorDescription: String? {
            switch self {
            case .differentSensors: return "The two exposures came off different sensors."
            }
        }
    }

    /// The two negatives added, written into the first's DNG.
    ///
    /// Only negatives off the same sensor can be added: each of the phone's
    /// lenses has a sensor of its own, with its own size, levels and colour,
    /// and the merge is described by the first one's.
    static func merge(_ first: Data, _ second: Data) throws -> Data {
        let base = try DNGRaw(first)
        let added = try DNGRaw(second)
        guard base.width == added.width, base.height == added.height,
              base.cameraModel == added.cameraModel else {
            throw Failure.differentSensors
        }

        let stack = BayerStack(raw: base)
        try stack.add(base, exposure: 1)
        try stack.add(added, exposure: 1)
        // Two frames' worth of read noise, and the shot noise of the light both
        // brought.
        return try base.replacingImage(with: stack.summed(),
                                       exposureTime: nil,
                                       noise: (signal: 1, floor: 2))
    }

    /// A first exposure that never got its second, brought back up the stops
    /// it was taken under so it stands as a photograph of its own.
    static func alone(_ first: Data, stopsUnder: Float) throws -> Data {
        guard stopsUnder > 0 else { return first }
        let raw = try DNGRaw(first)
        let stack = BayerStack(raw: raw)
        try stack.add(raw, exposure: 1)
        let gain = Double(pow(2, stopsUnder))
        return try raw.replacingImage(with: stack.merged(scale: gain),
                                      exposureTime: nil,
                                      noise: (signal: gain, floor: gain * gain))
    }
}
