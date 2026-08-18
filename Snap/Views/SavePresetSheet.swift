//
//  SavePresetSheet.swift
//  Snap
//
//  Names the frame that was just captured, together with the look that made it.
//

import SwiftUI
import UIKit

struct SavePresetSheet: View {

    let image: UIImage?
    var onCancel: () -> Void
    var onSave: (_ title: String, _ notes: String) -> Void

    @State private var title: String
    @State private var notes: String
    @FocusState private var notesFocused: Bool

    // Explicit because the private state above would otherwise make the
    // memberwise initializer private.
    init(image: UIImage?,
         onCancel: @escaping () -> Void,
         onSave: @escaping (String, String) -> Void) {
        self.image = image
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: Preset.defaultTitle())
        _notes = State(initialValue: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let image {
                    Section {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                    }
                }

                Section("Title") {
                    TextField("Title", text: $title)
                        .submitLabel(.next)
                        .onSubmit { notesFocused = true }
                }

                Section("Notes") {
                    TextField("What were you shooting?", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($notesFocused)
                }
            }
            .navigationTitle("Save Look")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? Preset.defaultTitle() : trimmed, notes)
                    }
                }
            }
        }
    }
}
