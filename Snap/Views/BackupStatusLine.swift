//
//  BackupStatusLine.swift
//  Snap
//
//  What the backup folder has of one frame, under that frame's caption.
//
//  It sits below the caption rather than beside the date, because the two
//  halves of a row say different things: the lines above are what the
//  photograph *is* — when, where, what was written about it — and this is what
//  has happened to it since. It is also the only line in the row with anything
//  to do, and things to do belong at the end of what you were reading.
//
//  Quiet in the ordinary cases and yellow in the one that isn't. A frame that
//  is safely in the folder should be readable at a glance and ignorable at the
//  same glance; a file that has gone missing is the only thing here worth
//  interrupting for.
//

import SwiftUI

struct BackupStatusLine: View {

    let state: BackupState

    /// Sends the files again, for a frame the folder has lost.
    var onResend: () -> Void
    /// The other answer to the same question: stop keeping this one, and the
    /// warning goes with it.
    var onRemove: () -> Void

    @ViewBuilder
    var body: some View {
        switch state {
        case .unknown:
            EmptyView()
        case .copying:
            quiet("Backing up…", glyph: "arrow.up.circle")
        case .done(let kinds):
            quiet("Backed up · \(BackupStatusLine.list(kinds))", glyph: "checkmark.circle")
        case .missing(let kinds):
            warning("\(BackupStatusLine.list(kinds)) missing from the folder")
        case .failed(let reason):
            warning(reason)
        }
    }

    /// The two states that are working as intended, said as small as they can
    /// be said.
    private func quiet(_ text: String, glyph: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.38))
        .padding(.top, 2)
    }

    /// The one that isn't.
    ///
    /// Yellow, which in this interface is already the colour of a reading that
    /// wants looking at — the EV number past a stop and a half wears the same
    /// one. The two answers sit under it rather than beside the text, so a long
    /// folder name can't push either of them off the row.
    private func warning(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(2)
            }
            .foregroundStyle(Color.snapAccent)

            HStack(spacing: 14) {
                Button("Resend", action: onResend)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.snapAccent)

                Button("Remove from Favorites", action: onRemove)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 3)
    }

    /// JPEG, RAW, or both — in that order, since that is the order they were
    /// written in.
    private static func list(_ kinds: [BackupKind]) -> String {
        kinds.map(\.label).joined(separator: " + ")
    }
}
