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
//  What the bar gains in develop mode — the menu's chevron, the handle, Reset
//  and Done — fades in around the buttons that were already there, so nothing
//  that was on screen has to be found again.
//

import SwiftUI

struct ActionBar: View {

    /// For the heart, which lights only when there is something kept.
    @ObservedObject var store: ShotStore

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

    var onDevelop: () -> Void
    var onFavorites: () -> Void
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

                if isDeveloping {
                    Button("Reset", action: onReset)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
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

    /// The button that opens the panel, and the menu it becomes once the panel
    /// is open. Same word in the same place either way — what changes is what
    /// pressing it does, which is what the chevron appearing says.
    @ViewBuilder
    private var develop: some View {
        if isDeveloping {
            Menu {
                actions
            } label: {
                developLabel
            }
            .disabled(isBusy)
            .opacity(isBusy ? 0.4 : 1)
            .accessibilityLabel("Develop actions")
        } else {
            Button(action: onDevelop) { developLabel }
                .buttonStyle(.plain)
                .disabled(!canDevelop)
                .opacity(canDevelop ? 1 : 0.35)
                .accessibilityLabel("Develop")
        }
    }

    private var developLabel: some View {
        HStack(spacing: 6) {
            Text("Develop")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                // Held in place on the camera screen rather than left out, so
                // the heart beside it doesn't shuffle sideways when the panel
                // opens.
                .opacity(isDeveloping ? 1 : 0)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 6)
        .contentShape(Rectangle())
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

    /// Shows and hides the roll under the bar.
    ///
    /// Dimmed rather than accented while the roll is down: the one colour this
    /// interface has is spent on settings that change the photograph, and
    /// whether the roll is showing is not one of them.
    private var stripToggle: some View {
        Button(action: onToggleStrip) {
            Image(systemName: "square.grid.3x3")
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
