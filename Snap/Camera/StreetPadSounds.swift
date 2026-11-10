//
//  StreetPadSounds.swift
//  Snap
//
//  The quiet tones StreetPad talks in, through the earpiece.
//
//  A phone held up as if about to make a call has its earpiece at the top,
//  and the earpiece is quiet enough to be heard by the person holding it and
//  by nobody else. So that is where these go: a tick for each second of the
//  lead-in, a thud as each frame is taken, and the level guide's Geiger
//  clicks.
//  With headphones in, they go to the headphones instead, which is better
//  still.
//
//  They used to be haptics alone, and haptics turned out not to arrive on
//  every phone the camera runs on. Sound does.
//
//  The sounds are made here rather than shipped as files: a few milliseconds
//  to a tenth of a second of sine wave or noise each, written into WAV data
//  once and handed to an `AVAudioPlayer` apiece, so the same sound asked for
//  twice restarts rather than queueing behind itself.
//

import AVFoundation

@MainActor
final class StreetPadSounds {

    enum Sound: CaseIterable {
        /// One second of the lead-in going by: a short, dry click.
        case tick
        /// A frame being taken: a low, dull thud, the sound of something
        /// closing rather than of anything electronic.
        case shutter
        /// The level guide: one very quiet Geiger-counter click, a few
        /// milliseconds of noise. The guide decides how often.
        case click
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
    /// a click — or, struck, left to die away from full, which is what makes
    /// a tick a tick and a thud a thud.
    ///
    /// A struck tone can fall in pitch as it goes, which is most of what a
    /// thud is, and carry an octave above for the small speakers that can't
    /// play the fundamental. `noise` mixes in white noise, all the way to a
    /// Geiger click that is nothing else.
    private static func tone(_ tone: Tone) -> [Float] {
        let count = Int(tone.duration * sampleRate)
        let attack = max(1, Int(0.004 * sampleRate))
        var samples = [Float](repeating: 0, count: count + Int(tone.gap * sampleRate))

        // The same noise every launch: a fixed seed, so a sound is the same
        // sound each time it is made.
        var seed: UInt32 = 0x2545_F491
        func noise() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max) * 2 - 1
        }

        let endFrequency = tone.endFrequency ?? tone.frequency
        var phase = 0.0
        let level = 1 / (1 + tone.overtone)

        for index in 0..<count {
            let time = Double(index) / sampleRate
            let progress = Double(index) / Double(max(count - 1, 1))
            let envelope: Double
            if tone.isStruck {
                envelope = exp(-time / (tone.duration / 5))
            } else {
                let rise = min(1, Double(index) / Double(attack))
                let fall = min(1, Double(count - index) / Double(attack * 3))
                envelope = min(rise, fall)
            }

            // Falling exponentially, the way a struck body settles.
            let frequency = tone.frequency * pow(endFrequency / tone.frequency, progress)
            phase += 2 * .pi * frequency / sampleRate
            let pitched = (sin(phase) + tone.overtone * sin(2 * phase)) * level
            let value = pitched * (1 - tone.noise) + noise() * tone.noise
            samples[index] = Float(value * envelope)
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
    /// Where the pitch has fallen (or risen) to by the end. Nil holds it.
    var endFrequency: Double? = nil
    var duration: Double
    /// Silence after it, before the next tone of the same sound.
    var gap: Double = 0
    var isStruck = false
    /// How loud the octave above is against the fundamental, 0...1.
    var overtone: Double = 0
    /// How much of it is white noise rather than tone, 0...1.
    var noise: Double = 0
}

private extension StreetPadSounds.Sound {

    var tones: [Tone] {
        switch self {
        case .tick:
            return [Tone(frequency: 2_400, duration: 0.02, isStruck: true)]
        case .shutter:
            // From 150 Hz down to 55 over a tenth of a second, with a little
            // noise for the knock at the front. The octave above is for the
            // earpiece, which barely plays below a couple of hundred hertz:
            // it carries the thud where the fundamental can't.
            return [Tone(frequency: 150, endFrequency: 55, duration: 0.11,
                         isStruck: true, overtone: 0.6, noise: 0.12)]
        case .click:
            // A few milliseconds of noise, struck and gone — the sound a
            // Geiger counter makes, and a sound with no pitch to be noticed by.
            return [Tone(frequency: 1_000, duration: 0.004, isStruck: true, noise: 1)]
        }
    }

    /// Quiet, on top of what is already a quiet speaker. The click quietest
    /// of all, since there can be twenty-five of it a second; the thud loudest,
    /// since low sounds come out of a small speaker quietest.
    var volume: Float {
        switch self {
        case .tick:    return 0.45
        case .shutter: return 0.8
        case .click:   return 0.15
        }
    }
}
