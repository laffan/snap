//
//  HistogramView.swift
//  Snap
//
//  The histogram at the top of the develop panel: red, green and blue laid
//  over each other, with a clipping warning at each end.
//
//  Read off whatever the viewer is actually showing — the frame the renderer
//  last drew — so it describes the photograph as graded, the live camera and a
//  negative under the sliders alike, and never a guess at either.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Bins for each channel and for luminance, as fractions of the frame.
struct HistogramBins: Equatable {
    static let count = 64

    var red: [Float]
    var green: [Float]
    var blue: [Float]
    var luminance: [Float]

    /// Share of the frame sitting in the bottom or top bin of any channel past
    /// which the end is called clipped. Half a percent: a few specular
    /// highlights aren't a problem, a blown sky is.
    private static let clipThreshold: Float = 0.005

    var clipsShadows: Bool {
        max(red.first ?? 0, green.first ?? 0, blue.first ?? 0) > HistogramBins.clipThreshold
    }

    var clipsHighlights: Bool {
        max(red.last ?? 0, green.last ?? 0, blue.last ?? 0) > HistogramBins.clipThreshold
    }
}

/// Samples the renderer a few times a second while the panel is open.
final class HistogramModel: ObservableObject {

    @Published private(set) var bins: HistogramBins?

    private let context = CIContext(options: [
        .cacheIntermediates: false,
        .name: "SnapHistogram",
    ])
    private let queue = DispatchQueue(label: "com.snap.histogram", qos: .utility)
    private weak var lastImage: CIImage?
    private var isBusy = false

    /// Called on a timer from the panel. Skips the work when the image hasn't
    /// changed since last time, or when the last one is still being counted.
    func sample(_ image: CIImage?) {
        guard let image, !isBusy, image !== lastImage else { return }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return }
        lastImage = image
        isBusy = true

        queue.async { [weak self] in
            guard let self else { return }
            let bins = self.count(image)
            DispatchQueue.main.async {
                self.isBusy = false
                if let bins, bins != self.bins { self.bins = bins }
            }
        }
    }

    private func count(_ image: CIImage) -> HistogramBins? {
        // Small: a histogram is a shape, and 160 pixels a side has all of it.
        let extent = image.extent
        let scale = min(1, 160 / max(extent.width, extent.height))
        let small = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let smallExtent = small.extent.integral

        // Binned the way it reads, in display values rather than in the
        // linear light Core Image works in — the same as Lightroom's.
        let encoded = small.applyingFilter("CILinearToSRGBToneCurve")

        guard let channels = histogram(of: encoded, extent: smallExtent) else { return nil }

        let lumaImage = encoded.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
        ])
        guard let luma = histogram(of: lumaImage, extent: smallExtent) else { return nil }

        return HistogramBins(red: channels.0, green: channels.1, blue: channels.2,
                             luminance: luma.0)
    }

    /// Red, green and blue bins, each normalised to sum to one.
    private func histogram(of image: CIImage, extent: CGRect) -> ([Float], [Float], [Float])? {
        let filter = CIFilter.areaHistogram()
        filter.inputImage = image
        filter.extent = extent
        filter.count = HistogramBins.count
        filter.scale = 1
        guard let output = filter.outputImage else { return nil }

        var pixels = [Float](repeating: 0, count: HistogramBins.count * 4)
        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(output,
                           toBitmap: base,
                           rowBytes: HistogramBins.count * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: HistogramBins.count, height: 1),
                           format: .RGBAf,
                           colorSpace: nil)
        }

        func channel(_ offset: Int) -> [Float] {
            let values = (0..<HistogramBins.count).map { max(0, pixels[$0 * 4 + offset]) }
            let total = values.reduce(0, +)
            return total > 0 ? values.map { $0 / total } : values
        }
        return (channel(0), channel(1), channel(2))
    }
}

struct HistogramView: View {

    let bins: HistogramBins?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.04))

            if let bins {
                Canvas { context, size in
                    // Scaled to the tallest bin away from the two ends, so a
                    // frame with a lot of pure black doesn't flatten the rest.
                    let interior = [bins.red, bins.green, bins.blue].flatMap { $0.dropFirst().dropLast() }
                    let peak = max(interior.max() ?? 0, 0.0001)

                    func path(_ values: [Float]) -> Path {
                        var path = Path()
                        let step = size.width / CGFloat(values.count - 1)
                        path.move(to: CGPoint(x: 0, y: size.height))
                        for (index, value) in values.enumerated() {
                            let height = min(CGFloat(value / peak), 1) * (size.height - 2)
                            path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
                        }
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.closeSubpath()
                        return path
                    }

                    context.blendMode = .plusLighter
                    context.fill(path(bins.red), with: .color(Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.6)))
                    context.fill(path(bins.green), with: .color(Color(red: 0.2, green: 0.8, blue: 0.3).opacity(0.6)))
                    context.fill(path(bins.blue), with: .color(Color(red: 0.25, green: 0.4, blue: 1).opacity(0.6)))
                }
                .padding(.horizontal, 10)

                HStack {
                    clipMark(isOn: bins.clipsShadows, color: Color(red: 0.4, green: 0.6, blue: 1))
                    Spacer()
                    clipMark(isOn: bins.clipsHighlights, color: .white)
                }
                .padding(4)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(accessibilityValue)
    }

    /// The two corner triangles Lightroom lights when an end clips.
    private func clipMark(isOn: Bool, color: Color) -> some View {
        Image(systemName: "triangle.fill")
            .font(.system(size: 6))
            .foregroundStyle(isOn ? color : .white.opacity(0.18))
    }

    private var accessibilityValue: String {
        guard let bins else { return "Waiting for a frame" }
        switch (bins.clipsShadows, bins.clipsHighlights) {
        case (true, true): return "Clipping shadows and highlights"
        case (true, false): return "Clipping shadows"
        case (false, true): return "Clipping highlights"
        case (false, false): return "No clipping"
        }
    }
}
