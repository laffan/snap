//
//  ActionBar.swift
//  Snap
//
//  The one row of buttons the app has, with the roll attached under it.
//
//  Develop and the favourites used to sit in two places — centred under the
//  shutter on the camera screen, left-aligned in the panel's header once it
//  opened — which made the same two buttons look like two different pairs. They
//  are one bar now, in one arrangement, and it is the bar that moves rather
//  than the buttons: opening Develop lifts it and the roll it carries to just
//  under the frame, and the sliders fill in beneath.
//
//  What the bar gains in develop mode — the handle, Reset and Done — fades in
//  at the right, around buttons that were already there and don't move.
//

import SwiftUI

struct ActionBar: View {

    /// For the heart, which lights only when there is something kept.
    @ObservedObject var store: ShotStore
    /// For the starburst, which lights only when the app has left something
    /// behind.
    @ObservedObject var snapshots: SnapshotStore

    var isDeveloping: Bool
    /// False when the frame in the viewer has no negative to develop.
    var canDevelop: Bool
    var isStripVisible: Bool
    /// How far the panel has been pulled up over the preview, and how far it
    /// may go. The handle owns the first and the camera screen decides the
    /// second.
    @Binding var lift: CGFloat
    var liftLimit: CGFloat

    var onToggleDevelop: () -> Void
    var onFavorites: () -> Void
    var onSnapshots: () -> Void
    var onToggleStrip: () -> Void
    var onReset: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // What the app is: a develop screen and the frames you kept.
                develop
                FavoritesButton(store: store, action: onFavorites)

                Spacer()

                // What is on screen: the roll under the bar, and the frames the
                // app left behind. Both are ways of showing something rather
                // than ways of changing something, so they keep to their own
                // end of the bar.
                stripToggle
                snapshotsButton

                if isDeveloping {
                    Button("Reset", action: onReset)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.leading, 8)
                        .transition(.opacity)

                    Button("Done", action: onClose)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 16)
                        .transition(.opacity)
                }
            }

            // Above the row rather than in it, so it sits at the centre of the
            // bar and not at the centre of whatever is left over.
            if isDeveloping {
                PanelHandle(lift: $lift, limit: liftLimit)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    /// The switch the whole panel hangs off. It opens the sliders and it closes
    /// them again — the same tap either way, which is what a word that stays in
    /// one place ought to mean. Lit while they are open, so the bar says which
    /// screen you are on without a second control to read.
    private var develop: some View {
        Button(action: onToggleDevelop) {
            Text("Develop")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isDeveloping ? 1 : 0.75))
                .padding(.vertical, 8)
                // Ten here and ten inside each of the two round targets beside
                // it puts an even gap between all three.
                .padding(.trailing, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canDevelop)
        .opacity(canDevelop ? 1 : 0.35)
        .accessibilityLabel("Develop")
        .accessibilityValue(isDeveloping ? "on" : "off")
    }

    /// The way into the frames the app left behind while it was away.
    ///
    /// A starburst, because that is what one of these is: not a photograph
    /// anybody took, but the flash of wherever the phone was pointing when it
    /// went into a pocket.
    private var snapshotsButton: some View {
        Button(action: onSnapshots) {
            Image(systemName: "sparkle")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(snapshots.snapshots.isEmpty)
        .opacity(snapshots.snapshots.isEmpty ? 0.35 : 1)
        .accessibilityLabel("Snapshots")
    }

    /// Shows and hides the roll under the bar.
    ///
    /// Dimmed rather than accented while the roll is down: the one colour this
    /// interface has is spent on settings that change the photograph, and
    /// whether the roll is showing is not one of them.
    private var stripToggle: some View {
        Button(action: onToggleStrip) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(isStripVisible ? 0.75 : 0.3))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show the roll")
        .accessibilityValue(isStripVisible ? "on" : "off")
    }
}

// MARK: - Handle

/// The grab handle at the centre of the bar, while the panel is open.
///
/// Dragging it up pulls the panel over the preview square, which gives the
/// sliders room without ever hiding what the camera is looking at. The camera
/// screen puts it back when the panel closes.
struct PanelHandle: View {

    @Binding var lift: CGFloat
    let limit: CGFloat

    /// Where the lift stood when this drag started. A drag reports its
    /// translation from where the finger went down, so without this every
    /// change would be measured from zero again.
    @State private var start: CGFloat? = nil

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of the bar.
    init(lift: Binding<CGFloat>, limit: CGFloat) {
        _lift = lift
        self.limit = limit
    }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 22, height: 1.5)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        // Measured globally: the handle is being carried by the panel it is
        // resizing, so a local translation would feed back into itself.
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = start ?? lift
                    if start == nil { start = base }
                    lift = min(max(base - value.translation.height, 0), limit)
                }
                .onEnded { _ in start = nil }
        )
        .accessibilityLabel("Resize the develop panel")
    }
}
