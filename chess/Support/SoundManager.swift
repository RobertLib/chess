//
//  SoundManager.swift
//  chess
//
//  All sounds are synthesized at startup (no audio assets): short wooden
//  clicks for moves, deeper thuds for captures and small musical stingers
//  for game events.
//

import AVFoundation

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    nonisolated enum Effect: CaseIterable {
        case select
        case move
        case capture
        case castle
        case check
        case promote
        case illegal
        case gameStart
        case win
        case lose
        case draw
    }

    var isEnabled = true

    private var players: [Effect: [AVAudioPlayer]] = [:]
    private var isPreparing = false
    /// Effects asked for before the players were ready. Preparation starts at
    /// launch and takes a moment; without this, a game begun in that moment
    /// would open in silence. It is a short list rather than a single slot
    /// because the opening of a game asks for more than one — the start chime
    /// and a first move can both land inside the same warm-up — and keeping
    /// only the last of them swallowed the rest.
    private var pendingEffects: [Effect] = []
    /// Enough to cover a warm-up, few enough that a silent stretch cannot turn
    /// into a burst of stale sounds when the players finally arrive.
    private static let maxPendingEffects = 4

    /// `AVAudioPlayer` is not `Sendable`, but one that has just been built and
    /// never touched can be handed over safely — from here on only the main
    /// actor uses it.
    nonisolated private struct PreparedPlayers: @unchecked Sendable {
        let pools: [Effect: [AVAudioPlayer]]
    }

    private init() {}

    /// Renders every effect and builds its player pool, off the main thread.
    /// Eleven synthesized WAVs and twenty-two players are enough work to be
    /// felt as a stutter, so none of it happens while the board is waiting.
    /// Safe to call more than once; only the first call does anything.
    func prepare() {
        guard players.isEmpty, !isPreparing else { return }
        isPreparing = true

        Task { [weak self] in
            let prepared = await Task.detached(priority: .utility) {
                // A small pool per effect allows two of the same sound to overlap.
                var pools: [Effect: [AVAudioPlayer]] = [:]
                for effect in Effect.allCases {
                    let data = Self.render(effect)
                    let pool = (0..<2).compactMap { _ in try? AVAudioPlayer(data: data) }
                    pool.forEach { $0.prepareToPlay() }
                    pools[effect] = pool
                }
                return PreparedPlayers(pools: pools)
            }.value

            guard let self else { return }
            // The category is set here rather than in `init` so that touching
            // the singleton costs nothing at all.
            try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
            self.players = prepared.pools
            self.isPreparing = false
            let pending = self.pendingEffects
            self.pendingEffects = []
            for effect in pending { self.play(effect) }
        }
    }

    func play(_ effect: Effect) {
        guard isEnabled else { return }
        guard let pool = players[effect] else {
            // Still warming up: queue this one and play it when ready.
            prepare()
            if pendingEffects.count < Self.maxPendingEffects {
                pendingEffects.append(effect)
            }
            return
        }
        if let free = pool.first(where: { !$0.isPlaying }) ?? pool.first {
            free.currentTime = 0
            free.play()
        }
    }

    /// Convenience: pick the right sound for a move.
    func play(for move: Move, isCheck: Bool) {
        if isCheck {
            play(.check)
        } else if move.isCastle {
            play(.castle)
        } else if move.promotion != nil {
            play(.promote)
        } else if move.isCapture {
            play(.capture)
        } else {
            play(.move)
        }
    }

    // MARK: - Synthesis

    nonisolated private static let sampleRate = 44_100.0

    nonisolated private static func render(_ effect: Effect) -> Data {
        let samples: [Float]
        switch effect {
        case .select:
            samples = click(frequency: 1_500, duration: 0.03, volume: 0.18)
        case .move:
            samples = woodClick(startFrequency: 950, endFrequency: 620, duration: 0.075, volume: 0.5)
        case .capture:
            samples = mix(
                woodClick(startFrequency: 340, endFrequency: 150, duration: 0.13, volume: 0.75),
                noiseBurst(duration: 0.03, volume: 0.25)
            )
        case .castle:
            samples = sequence(
                woodClick(startFrequency: 950, endFrequency: 620, duration: 0.07, volume: 0.45),
                silence(0.07),
                woodClick(startFrequency: 800, endFrequency: 520, duration: 0.08, volume: 0.5)
            )
        case .check:
            samples = sequence(
                tone(frequency: 740, duration: 0.09, volume: 0.4),
                tone(frequency: 988, duration: 0.14, volume: 0.4)
            )
        case .promote:
            samples = sequence(
                tone(frequency: 523, duration: 0.07, volume: 0.35),
                tone(frequency: 659, duration: 0.07, volume: 0.35),
                tone(frequency: 784, duration: 0.12, volume: 0.4)
            )
        case .illegal:
            samples = tone(frequency: 130, duration: 0.09, volume: 0.35, harmonic: 0.6)
        case .gameStart:
            samples = mix(
                tone(frequency: 262, duration: 0.4, volume: 0.20, attack: 0.02),
                tone(frequency: 330, duration: 0.4, volume: 0.16, attack: 0.02),
                tone(frequency: 392, duration: 0.4, volume: 0.16, attack: 0.02)
            )
        case .win:
            samples = sequence(
                tone(frequency: 523, duration: 0.11, volume: 0.4),
                tone(frequency: 659, duration: 0.11, volume: 0.4),
                tone(frequency: 784, duration: 0.11, volume: 0.4),
                tone(frequency: 1_047, duration: 0.28, volume: 0.45)
            )
        case .lose:
            samples = sequence(
                tone(frequency: 392, duration: 0.18, volume: 0.35),
                tone(frequency: 311, duration: 0.30, volume: 0.35)
            )
        case .draw:
            samples = sequence(
                tone(frequency: 440, duration: 0.14, volume: 0.3),
                tone(frequency: 440, duration: 0.20, volume: 0.25)
            )
        }
        return wavData(from: samples)
    }

    /// Damped sine sweep with a touch of second harmonic — a wooden "tock".
    nonisolated private static func woodClick(
        startFrequency: Double, endFrequency: Double, duration: Double, volume: Double
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        var phase = 0.0
        return (0..<count).map { index in
            let t = Double(index) / Double(count)
            let frequency = startFrequency + (endFrequency - startFrequency) * t
            phase += 2 * .pi * frequency / sampleRate
            let envelope = exp(-t * 9)
            let sample = sin(phase) + 0.35 * sin(2 * phase)
            return Float(sample * envelope * volume)
        }
    }

    nonisolated private static func tone(
        frequency: Double, duration: Double, volume: Double,
        harmonic: Double = 0.25, attack: Double = 0.008
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let t = Double(index) / Double(count)
            let attackEnvelope = min(1, time / attack)
            let release = exp(-t * 5)
            let sample = sin(2 * .pi * frequency * time)
                + harmonic * sin(4 * .pi * frequency * time)
            return Float(sample * attackEnvelope * release * volume)
        }
    }

    nonisolated private static func click(frequency: Double, duration: Double, volume: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let t = Double(index) / Double(count)
            let envelope = exp(-t * 22)
            return Float(sin(2 * .pi * frequency * time) * envelope * volume)
        }
    }

    nonisolated private static func noiseBurst(duration: Double, volume: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        var state: UInt64 = 0x12345678
        return (0..<count).map { index in
            let t = Double(index) / Double(count)
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let random = Double(state >> 33) / Double(UInt32.max) * 2 - 1
            return Float(random * exp(-t * 14) * volume)
        }
    }

    nonisolated private static func silence(_ duration: Double) -> [Float] {
        [Float](repeating: 0, count: Int(duration * sampleRate))
    }

    nonisolated private static func sequence(_ parts: [Float]...) -> [Float] {
        parts.flatMap { $0 }
    }

    nonisolated private static func mix(_ parts: [Float]...) -> [Float] {
        let length = parts.map(\.count).max() ?? 0
        var result = [Float](repeating: 0, count: length)
        for part in parts {
            for (index, sample) in part.enumerated() {
                result[index] += sample
            }
        }
        return result
    }

    /// Wraps mono float samples into a 16-bit PCM WAV container.
    nonisolated private static func wavData(from samples: [Float]) -> Data {
        var data = Data()
        let sampleCount = samples.count
        let byteRate = Int(sampleRate) * 2
        let dataSize = sampleCount * 2

        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(16)
        append16(1)                      // PCM
        append16(1)                      // mono
        append(UInt32(sampleRate))
        append(UInt32(byteRate))
        append16(2)                      // block align
        append16(16)                     // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(clamped * 32_766)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
