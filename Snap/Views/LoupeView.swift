//
//  LoupeView.swift
//  Snap
//
//  The frame at 100%, under a finger.
//
//  A phone-sized square is a poor place to answer the one question a
//  photograph has to answer before it is worth keeping: is it sharp. Twelve
//  megapixels drawn into four hundred points is a frame that always looks
//  sharp. So the loupe stops fitting the frame to the screen and starts
//  showing it at its own size — one image pixel per screen pixel — with the
//  finger as the cursor over it.
//
//  It is a way of looking rather than a way of changing, which is why it wears
//  a colour of its own: the accent means a setting is switched on, and nothing
//  in here is.
//

import CoreImage
import SwiftUI
import UIKit

/// What the loupe has to show, and how to make it.
///
/// Both of the frame's renderings, the way the viewer and the sliders both
/// already offer both: the graded photograph, and the negative underneath it
/// with no look on it.
struct LoupeSource: Equatable {

    var id: UUID
    /// The finished frame on disk. What the graded side *is* in the viewer,
    /// and the fallback under the sliders for a frame whose negative won't
    /// develop.
    var jpegURL: URL
    /// The negative, when the capture was RAW. Without one there is only the
    /// JPEG, and the swipe between the two has nowhere to go.
    var rawURL: URL?
    /// The look the frame was taken with, which is what develops its negative
    /// in the viewer. Under the sliders the live one is used instead — see
    /// `LoupeView.profile`.
    var profile: PositiveFilmProfile
    /// True while the sliders are open, where the graded side is made rather
    /// than read: the JPEG on disk is the frame as it was taken, and what is
    /// being looked at there is the frame as it is being developed.
    var isDeveloping: Bool
}

struct LoupeView: View {

    let source: LoupeSource
    /// Watched, so a slider moved under the loupe reaches it. The still is
    /// remade off this — after a pause, since a drag would otherwise ask for a
    /// full-resolution development on every tick. Only read while the sliders
    /// are open; in the viewer the frame wears its own look and this never
    /// comes into it.
    @ObservedObject var look: LookModel
    let edge: CGFloat
    /// Which of the two renderings is up, shared with the row under the frame
    /// so the JPEG/RAW label goes on answering the same question it answers
    /// everywhere else.
    @Binding var showsRAW: Bool

    @State private var image: UIImage? = nil
    @State private var isLoading = false
    /// Where the finger is, in the square's own points. Nil while nothing is
    /// touching it, which is when the frame is shown whole.
    @State private var cursor: CGPoint? = nil

    @Environment(\.displayScale) private var displayScale

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of CameraView.
    init(source: LoupeSource, look: LookModel, edge: CGFloat, showsRAW: Binding<Bool>) {
        self.source = source
        self.look = look
        self.edge = edge
        _showsRAW = showsRAW
    }

    /// The look to develop and grade this frame with.
    ///
    /// In the viewer that is the frame's own, and it never moves. Under the
    /// sliders it is whatever the sliders say now: the JPEG on disk is the
    /// frame as it was taken, and what is on screen there is the frame as it is
    /// being developed.
    private var profile: PositiveFilmProfile {
        source.isDeveloping ? look.profile : source.profile
    }

    /// How much of the frame the loupe asks for.
    ///
    /// A 12MP square is a little over 3000 pixels a side, so this is the whole
    /// of one and no more than the sensor has to give. The viewer's own copy is
    /// decoded to about a thousand, which is exactly the detail this mode
    /// exists to get past — so the loupe reads its own.
    private static let pixels: CGFloat = 3200

    /// Everything a still has to be remade for: which frame, which of its two
    /// renderings, and — under the sliders — what the sliders are set to.
    private struct Request: Equatable {
        var id: UUID
        var showsRAW: Bool
        var profile: PositiveFilmProfile
    }

    private var request: Request {
        // The profile is the shot's own in the viewer and never moves there, so
        // this only ever changes under the sliders.
        Request(id: source.id,
                showsRAW: showsRAW && source.rawURL != nil,
                profile: profile)
    }

    var body: some View {
        ZStack {
            Color.black

            if let image {
                let zoom = magnification(for: image)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: edge * zoom, height: edge * zoom)
                    .offset(offset(zoom: zoom))
            }

            if isLoading {
                ProgressView()
                    .tint(Color.snapLoupe)
            }
        }
        .frame(width: edge, height: edge)
        .clipped()
        .contentShape(Rectangle())
        // One gesture, and it says both of the things the loupe can be told.
        // Touching down magnifies at once — a loupe is put down on a print,
        // not waited for — and the finger carries the magnified point with it
        // from there. Lifting off after a decisive sideways drag is the other
        // thing: the two renderings, swapped the way a swipe swaps anything
        // else in this app.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if cursor == nil {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    cursor = value.location
                }
                .onEnded { value in
                    cursor = nil
                    guard source.rawURL != nil else { return }
                    let width = value.translation.width
                    guard abs(width) > 44, abs(width) > abs(value.translation.height) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showsRAW.toggle()
                }
        )
        // Light blue, and thick enough to read as a state rather than as an
        // edge the frame happens to have.
        .overlay {
            Rectangle()
                .strokeBorder(Color.snapLoupe, lineWidth: 2)
                .allowsHitTesting(false)
        }
        .task(id: request) { await load() }
    }

    /// How far the frame has to be blown up for one of its pixels to land on
    /// one of the screen's.
    ///
    /// One while nothing is touching it: with no finger down the loupe is the
    /// frame, whole and fitted, and putting one down is what magnifies it.
    ///
    /// And never below one: a frame with fewer pixels than the square has — a
    /// preview frame, or a negative that wouldn't develop — is already at 100%,
    /// and stretching it further would only make a soft image bigger.
    private func magnification(for image: UIImage) -> CGFloat {
        guard cursor != nil, edge > 0, displayScale > 0 else { return 1 }
        return max(1, image.size.width * image.scale / (edge * displayScale))
    }

    /// Brings the point under the finger to the middle of the square.
    ///
    /// The magnified frame is centred by the layout, so the offset is how far
    /// the cursor sits from its centre, at the magnified scale. With no finger
    /// down there is no cursor and the frame sits whole and centred.
    private func offset(zoom: CGFloat) -> CGSize {
        guard let cursor, edge > 0 else { return .zero }
        let x = min(max(cursor.x / edge, 0), 1)
        let y = min(max(cursor.y / edge, 0), 1)
        return CGSize(width: edge * zoom * (0.5 - x),
                      height: edge * zoom * (0.5 - y))
    }

    /// Reads or makes whichever rendering is up, at loupe size.
    ///
    /// A slider moved under the loupe changes what the frame is, so the still
    /// is remade — but not on every tick of a drag, which would ask for a
    /// full-resolution development forty times a second. The pause is what says
    /// the hand has settled; the first load doesn't wait for one.
    private func load() async {
        if image != nil {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
        }

        isLoading = true

        let source = self.source
        let profile = self.profile
        let wantsRAW = showsRAW && source.rawURL != nil
        let pixels = LoupeView.pixels

        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let context = CIContext(options: [.cacheIntermediates: false])

            // The negative as it stands, which is the same peek the viewer and
            // the sliders both offer — just read at a size worth magnifying.
            if wantsRAW, let rawURL = source.rawURL {
                return RAWDeveloper.previewImage(at: rawURL,
                                                 profile: profile,
                                                 maxPixelSize: pixels,
                                                 context: context)
            }

            // In the viewer the graded frame is a file: it is the photograph
            // that was saved, and re-making it would only be a second opinion
            // about it.
            if !source.isDeveloping {
                return ShotStore.image(at: source.jpegURL, maxPixelSize: pixels)
            }

            // Under the sliders it isn't a file yet. What is on screen is this
            // negative under these settings, so that is what the loupe has to
            // magnify — the JPEG on disk is the frame as it was taken.
            guard let rawURL = source.rawURL,
                  let developed = RAWDeveloper.developedImage(at: rawURL,
                                                              profile: profile,
                                                              maxPixelSize: pixels) else {
                return ShotStore.image(at: source.jpegURL, maxPixelSize: pixels)
            }

            let filter = PositiveFilmFilter(profile: profile.resolved, resolution: .final)
            let graded = filter.apply(to: developed)
            guard let cgImage = context.createCGImage(graded, from: graded.extent) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value

        // A slider moved while this was working started a newer one, and a
        // still of the settings before it is not the frame being looked at.
        guard !Task.isCancelled else { return }
        image = loaded
        isLoading = false
    }
}

/// The way out, directly under the frame it is about.
///
/// Said in words rather than as an X, because the loupe is a mode rather than
/// a screen: there is nothing over the top of anything, and a photograph that
/// has stopped fitting the square needs to say why and how to stop it.
struct ExitLoupeButton: View {

    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("EXIT LOUPE MODE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Color.snapLoupe)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.snapLoupe.opacity(0.6), lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel("Exit loupe mode")
    }
}
