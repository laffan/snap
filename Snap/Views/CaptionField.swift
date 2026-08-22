//
//  CaptionField.swift
//  Snap
//
//  A line or two of text under a frame being reviewed, which becomes that
//  frame's caption — in the app's own sidecar and in the file's EXIF.
//
//  A rule under the words and nothing else: a box would be the loudest thing
//  on a screen that is otherwise a photograph and a shutter.
//

import SwiftUI

struct CaptionField: View {

    let shot: Shot
    /// Raised while the keyboard is up, so the screen above can make room for
    /// it. The focus itself stays in here — it is nobody else's business which
    /// field has it.
    @Binding var isEditing: Bool
    /// Called with the trimmed caption when the field lets go of the keyboard,
    /// and again on the way out if anything is still unsaved.
    var onCommit: (String) -> Void

    @State private var text: String
    @FocusState private var isFocused: Bool

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private, putting this out of reach of the camera
    // screen. It also seeds the draft, since the field is rebuilt per frame.
    init(shot: Shot, isEditing: Binding<Bool>, onCommit: @escaping (String) -> Void) {
        self.shot = shot
        _isEditing = isEditing
        self.onCommit = onCommit
        _text = State(initialValue: shot.caption)
    }

    var body: some View {
        TextField("Caption",
                  text: $text,
                  prompt: Text("Add a caption").foregroundStyle(.white.opacity(0.28)),
                  axis: .vertical)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.85))
            .tint(Color.snapAccent)
            // Room for a sentence or two before it starts scrolling, which is
            // as much as a caption should be and as much as the space under the
            // frame can lend it.
            .lineLimit(1...3)
            .textInputAutocapitalization(.sentences)
            .focused($isFocused)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(isFocused ? 0.28 : 0.12))
                    .frame(height: 0.5)
            }
            .animation(.easeOut(duration: 0.15), value: isFocused)
            // A caption can run to a second line, so Return has to make one.
            // Done above the keyboard is what puts it away, and putting it away
            // is what saves.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isFocused = false }
                }
            }
            .onChange(of: isFocused) { _, focused in
                withAnimation(.easeOut(duration: 0.25)) { isEditing = focused }
                if !focused { commit() }
            }
            // The frame can be swiped away or put down with the keyboard still
            // up, and this view goes with it.
            .onDisappear {
                commit()
                if isEditing { isEditing = false }
            }
            .accessibilityLabel("Caption")
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != shot.caption else { return }
        onCommit(trimmed)
    }
}
