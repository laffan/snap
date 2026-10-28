//
//  StreetPadSounds.swift
//  Snap
//
//  The quiet tones StreetPad talks in, through the earpiece.
//
//  A phone held up as if about to make a call has its earpiece at the top,
//  and the earpiece is quiet enough to be heard by the person holding it and
//  by nobody else. So that is where these go: a tick for each second of the
//  lead-in, a soft beep as each frame is taken, and the level guide's pips.
//  With headphones in, they go to the headphones instead, which is better
//  still.
//
//  They used to be haptics alone, and haptics turned out not to arrive on
//  every phone the camera runs on. Sound does.
//
//  The tones are made here rather than shipped as files: a few hundred
//  milliseconds of sine wave each, written into WAV data once and handed to
//  an `AVAudioPlayer` apiece, so the same sound asked for twice restarts
//  rather than queueing behind itself.
//

import AVFoundation

@MainActor
final class StreetPadSounds {

    enum Sound: CaseIterable {
        /// One second of the lead-in going by: a short, dry click.
        case tick
        /// A frame being taken: a soft, short beep, higher than anything
        /// else here.
        case shutter
        /// The level guide, horizon off: one pip, high when the phone leans
        /// to the right, low when it leans to the left.
        case horizonHigh, horizonLow
        /// The level guide, pointing off: two pips, high when the camera
        /// points up, low when it points down.
        case pointingHigh, pointingLow
    }

    private var players: [Sound: AVAudioPlayer] = [:]
    private var isActive = false
    /// Turning the audio session off is held back a moment after a run ends,
    /// so the last frame's beep isn't cut off in the middle; a run that
    /// starts in the meantime cancels it.
    private var pendingDeactivation: Task<Void, Never>? = nil

    /// Takes the audio session for the length of a run.
    ///
    /// The earpiece is reachable only from a session that can also record,
    /// which is why the category is play-and-record — nothing is recorded,
    /// and no input is ever opened. Other audio keeps playing alongside, and
    /// haptics are asked to keep working too, since a recording-capable
    /// session mutes them unless told otherwise.
    func activate() {
        pendingDeactivation?.cancel()
        pendingDeactivation = nil
        guard !isActive else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .default,
                                    options: [.mixWithOthers, .allowBluetoothA2DP])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            // The receiver rather than the loudspeaker, which is where
            // play-and-record sends sound unless told otherwise; said anyway,
            // in case something before this said otherwise.
            try session.overrideOutputAudioPort(.none)
            try session.setActive(true)
        } catch {
            // No session, no tones. The haptics are still tried.
            return
        }

        if players.isEmpty { makePlayers() }
        players.values.forEach { _ = $0.prepareToPlay() }
        isActive = true
    }

    /// Gives the audio session back, after a moment — see
    /// `pendingDeactivation`.
    func deactivate() {
        guard isActive, pendingDeactivation == nil else { return }
        pendingDeactivation = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            self.players.values.forEach { $0.stop() }
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            self.isActive = false
            self.pendingDeactivation = nil
        }
    }

    func play(_ sound: Sound) {
        guard isActive, let player = players[sound] else { return }
        player.currentTime = 0
        player.play()
    }

    // MARK: - Making the tones

    private func makePlayers() {
        for sound in Sound.allCases {
            guard let player = try? AVAudioPlayer(data: StreetPadSounds.wav(for: sound)) else { continue }
            player.volume = sound.volume
            players[sound] = player
        }
    }

    private static let sampleRate = 44_100.0

    /// A sound as one or more tones in a row, each with its own pitch,
    /// length and the silence after it.
    private static func wav(for sound: Sound) -> Data {
        var samples: [Float] = []
        for tone in sound.tones {
            samples += Self.tone(tone)
        }
        return wavData(samples)
    }

    /// A sine at `frequency`, eased in and out so it starts and stops without
    /// a click — or, for a tick, struck and left to die away, which is what
    /// makes it a click.
    private static func tone(_ tone: Tone) -> [Float] {
        let count = Int(tone.duration * sampleRate)
        let attack = max(1, Int(0.004 * sampleRate))
        var samples = [Float](repeating: 0, count: count + Int(tone.gap * sampleRate))

        for index in 0..<count {
            let time = Double(index) / sampleRate
            let envelope: Double
            if tone.isStruck {
                envelope = exp(-time / (tone.duration / 5))
            } else {
                let rise = min(1, Double(index) / Double(attack))
                let fall = min(1, Double(count - index) / Double(attack * 3))
                envelope = min(rise, fall)
            }
            samples[index] = Float(sin(2 * .pi * tone.frequency * time) * envelope)
        }
        return samples
    }

    /// 16-bit mono PCM in a WAV header, which is what `AVAudioPlayer` reads
    /// straight out of memory.
    private static func wavData(_ samples: [Float]) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        let rate = UInt32(sampleRate)
        let byteCount = UInt32(samples.count * 2)

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))          // the size of this chunk
        append(UInt16(1))           // PCM
        append(UInt16(1))           // mono
        append(rate)
        append(rate * 2)            // bytes per second
        append(UInt16(2))           // bytes per frame
        append(UInt16(16))          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(byteCount)
        for sample in samples {
            append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
        }
        return data
    }
}

/// One tone of a sound.
private struct Tone {
    var frequency: Double
    var duration: Double
    /// Silence after it, before the next tone of the same sound.
    var gap: Double = 0
    var isStruck = false
}

private extension StreetPadSounds.Sound {

    /// Pitches are kept apart by a fifth or more, so which one is playing is
    /// never in doubt: the level guide's two at G5 and C5, the frame's beep
    /// well above both at E6, and the tick a click rather than a note.
    var tones: [Tone] {
        switch self {
        case .tick:
            return [Tone(frequency: 2_400, duration: 0.02, isStruck: true)]
        case .shutter:
            return [Tone(frequency: 1_318.5, duration: 0.07)]
        case .horizonHigh:
            return [Tone(frequency: 784, duration: 0.045)]
        case .horizonLow:
            return [Tone(frequency: 523.25, duration: 0.045)]
        case .pointingHigh:
            return [Tone(frequency: 784, duration: 0.035, gap: 0.045),
                    Tone(frequency: 784, duration: 0.035)]
        case .pointingLow:
            return [Tone(frequency: 523.25, duration: 0.035, gap: 0.045),
                    Tone(frequency: 523.25, duration: 0.035)]
        }
    }

    /// Quiet, on top of what is already a quiet speaker. The beep is the
    /// quietest of all: it is a confirmation, not an alarm.
    var volume: Float {
        switch self {
        case .tick:    return 0.45
        case .shutter: return 0.3
        default:       return 0.35
        }
    }
}
