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
//  What the bar gains in develop mode — the handle, Reset, the menu of things
//  the panel can do, and Done — fades in around the buttons that were already
//  there, so nothing that was on screen has to be found again. The three on the
//  left never move.
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
    var isBusy: Bool
    var isStripVisible: Bool
    /// "Snap" for a live capture, "Capture Version" when a stored negative is
    /// loaded.
    var primaryTitle: String
    /// How far the panel has been pulled up over the preview, and how far it
    /// may go. The handle owns the first and the camera screen decides the
    /// second.
    @Binding var lift: CGFloat
    var liftLimit: CGFloat

    var onToggleDevelop: () -> Void
    var onFavorites: () -> Void
    var onSnapshots: () -> Void
    var onToggleStrip: () -> Void
    var onLoad: () -> Void
    var onSave: () -> Void
    var onSnap: () -> Void
    var onReset: () -> Void
    var onClose: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                develop
                FavoritesButton(store: store, action: onFavorites)
                stripToggle

                Spacer()

                // Right-aligned, and stays there: the develop chrome arrives
                // to its left rather than pushing it off the end.
                snapshotsButton

                if isDeveloping {
                    Button("Reset", action: onReset)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)

                    // Between the two words rather than beside the title: what
                    // is in here — load a look, save one, take the frame — is
                    // of a piece with Reset and Done, and none of it is what
                    // the word Develop means.
                    actionMenu
                        .transition(.opacity)

                    Button("Done", action: onClose)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.leading, 8)
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

    private var actionMenu: some View {
        Menu {
            actions
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.4 : 1)
        .accessibilityLabel("Develop actions")
    }

    /// Everything the panel can do that isn't a slider, ordered so the capture —
    /// the one that ends a session at the panel — sits nearest the thumb.
    @ViewBuilder
    private var actions: some View {
        Button {
            onLoad()
        } label: {
            Label("Load Develop Settings", systemImage: "tray.and.arrow.down")
        }

        Button {
            onSave()
        } label: {
            Label("Save Develop Settings", systemImage: "square.and.pencil")
        }

        Button {
            onSnap()
        } label: {
            Label(primaryTitle, systemImage: "camera")
        }
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
