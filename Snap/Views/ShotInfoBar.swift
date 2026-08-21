//
//  ShotInfoBar.swift
//  Snap
//
//  What the frame under the sliders is: when it was taken and where, on the
//  left; what it was taken on, on the right.
//
//  Two lines a side, quiet enough to sit above forty sliders without competing
//  with them. Everything comes out of the file itself, so a frame taken before
//  any of this existed still describes as much of itself as it recorded.
//

import CoreLocation
import SwiftUI

/// What the bar needs in order to describe a frame: the file to read, and the
/// shot's own timestamp for a capture that carried no EXIF date of its own.
struct ShotInfoSource: Equatable {
    var id: UUID
    var url: URL
    var date: Date
}

struct ShotInfoBar: View {

    let source: ShotInfoSource

    @State private var info = ShotInfo()
    /// The name of somewhere, once the geocoder answers. The coordinate stands
    /// in until it does, and stays if it never does.
    @State private var place: String? = nil

    @Environment(\.openURL) private var openURL

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of the panel.
    init(source: ShotInfoSource) {
        self.source = source
    }

    private var placeLabel: String? {
        place ?? info.coordinateLabel
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                if let date = info.dateLabel {
                    line(date, emphasis: true)
                        .padding(.vertical, 1)
                }
                // A place is somewhere you can go, so the line that names it
                // is the one thing in here that does something.
                if let coordinate = info.coordinate, let placeLabel {
                    Button {
                        openMaps(at: coordinate)
                    } label: {
                        line(placeLabel, emphasis: false)
                            .padding(.vertical, 1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens this place in Google Maps")
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                if let shutter = info.shutterLabel {
                    line(shutter, emphasis: true)
                }
                if let iso = info.isoLabel {
                    line(iso, emphasis: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: placeLabel)
        .task(id: source.id) { await load() }
    }

    /// The first line of each column carries the reading; the second qualifies
    /// it. Dimming the second is what keeps four short lines from reading as a
    /// paragraph.
    private func line(_ text: String, emphasis: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: emphasis ? .medium : .regular))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(emphasis ? 0.6 : 0.4))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Google Maps by ordinary https rather than by its own URL scheme. The app
    /// claims these links, so the tap lands in it when it is installed and in a
    /// browser showing the same map when it isn't — and nothing has to be
    /// declared in the Info.plist to ask whether it is there.
    private func openMaps(at coordinate: CLLocationCoordinate2D) {
        let query = String(format: "%.6f,%.6f", coordinate.latitude, coordinate.longitude)
        guard let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(query)") else {
            return
        }
        openURL(url)
    }

    /// Reading the file is quick but it is still a file, so it happens off the
    /// main thread; the place name is a network round trip and arrives whenever
    /// it arrives.
    private func load() async {
        place = nil

        let url = source.url
        let date = source.date
        let read = await Task.detached(priority: .userInitiated) {
            ShotInfo.read(at: url, fallbackDate: date)
        }.value

        info = read

        guard let coordinate = read.coordinate else { return }
        place = await PlaceNames.shared.name(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude)
    }
}
