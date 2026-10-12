import AppKit
import AVFAudio
import Combine
import Foundation

struct BackupSoundPreferences: Equatable {
    static let enabledKey = "backupSoundEnabled"
    static let volumeKey = "backupSoundVolume"
    static let defaultVolume = 0.45

    var enabled: Bool
    var volume: Double

    init(defaults: UserDefaults) {
        enabled = defaults.bool(forKey: Self.enabledKey)
        volume = Self.normalizedVolume(
            defaults.object(forKey: Self.volumeKey) as? Double ?? Self.defaultVolume
        )
    }

    static func normalizedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return defaultVolume }
        return (min(max(value, 0), 1) * 20).rounded() / 20
    }
}

enum BackupSoundCue: String, CaseIterable {
    case success, failure

    init?(status: BackupStatus) {
        switch status {
        case .success: self = .success
        case .failure: self = .failure
        case .cancelled: return nil
        }
    }
}

// Sound provenance, version 1 (2026-09): created specifically for BackupCron
// using the oscillator parameters below. No recordings, sample libraries,
// system sound files, third-party melodies, or downloaded assets are used.
// Success is a soft rising pair; failure is a lower, gently descending pair.
// This records the production method, not a guarantee of exclusive rights in
// simple tones or a claim that generated material is copyrightable everywhere.
enum BackupSoundSynthesis {
    static let sampleRate = 44_100

    private struct Tone {
        let start: Double
        let duration: Double
        let frequency: Double
        let glide: Double
    }

    static func samples(for cue: BackupSoundCue, volume: Double = 1) -> [Int16] {
        let tones: [Tone]
        switch cue {
        case .success:
            tones = [Tone(start: 0.015, duration: 0.19, frequency: 586, glide: 16),
                     Tone(start: 0.17, duration: 0.29, frequency: 879, glide: 9)]
        case .failure:
            tones = [Tone(start: 0.015, duration: 0.16, frequency: 349, glide: -12),
                     Tone(start: 0.23, duration: 0.23, frequency: 293, glide: -8)]
        }
        let gain = BackupSoundPreferences.normalizedVolume(volume)
        return (0..<Int(0.50 * Double(sampleRate))).map { index in
            let time = Double(index) / Double(sampleRate)
            var sample = 0.0
            for tone in tones {
                let local = time - tone.start
                guard local >= 0, local < tone.duration else { continue }
                // Smooth attack/release and a quiet overtone avoid clicks and
                // harsh alert timbres; the 40 ms silent tail ends at zero.
                let attack = min(local / 0.018, 1)
                let release = min((tone.duration - local) / 0.055, 1)
                let envelope = pow(sin(attack * .pi / 2), 2)
                    * pow(sin(release * .pi / 2), 2) * exp(-4 * local)
                let phase = 2 * Double.pi * (tone.frequency * local
                    + tone.glide * local * local / (2 * tone.duration))
                sample += 0.27 * envelope * (sin(phase) + 0.12 * sin(2 * phase))
            }
            return Int16((min(max(sample * gain, -0.95), 0.95) * Double(Int16.max)).rounded())
        }
    }

    static func wav(for cue: BackupSoundCue, volume: Double = 1) -> Data {
        let pcm = samples(for: cue, volume: volume)
        let byteCount = UInt32(pcm.count * 2)
        var data = Data()
        data.reserveCapacity(44 + Int(byteCount))
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1)) // Linear PCM.
        append(UInt16(1)) // Mono.
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(byteCount)
        for sample in pcm { append(sample) }
        return data
    }

    static func notificationFile(
        for status: BackupStatus,
        preferences: BackupSoundPreferences,
        suppressSound: Bool,
        directory: URL
    ) throws -> URL? {
        guard !suppressSound, preferences.enabled, preferences.volume > 0,
              let cue = BackupSoundCue(status: status) else { return nil }
        let volume = BackupSoundPreferences.normalizedVolume(preferences.volume)
        // Immutable names avoid system audio-cache collisions between volume
        // changes. Only two cues × 20 nonzero levels (< 2 MB) can be produced.
        let file = directory.appendingPathComponent(
            "BackupCron-feedback-v1-\(cue.rawValue)-\(Int(volume * 20)).wav"
        )
        let data = wav(for: cue, volume: volume)
        if (try? Data(contentsOf: file)) != data {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        return file
    }
}

@MainActor
protocol BackupCuePlaying: AnyObject {
    var isPlaying: Bool { get }
    func play(_ cue: BackupSoundCue, volume: Float) -> Bool
    func setVolume(_ volume: Float)
    func stop()
}

@MainActor
private final class SynthesizedCuePlayer: BackupCuePlaying {
    private var player: AVAudioPlayer?
    private var buffers: [BackupSoundCue: Data] = [:]
    var isPlaying: Bool { player?.isPlaying == true }

    func play(_ cue: BackupSoundCue, volume: Float) -> Bool {
        stop()
        let data = buffers[cue] ?? BackupSoundSynthesis.wav(for: cue)
        buffers[cue] = data
        do {
            let next = try AVAudioPlayer(data: data)
            next.volume = volume
            player = next // Retain until the short cue has finished.
            return next.play()
        } catch {
            return false
        }
    }

    func setVolume(_ volume: Float) { player?.volume = volume }
    func stop() { player?.stop(); player = nil }
}

@MainActor
final class BackupAudioFeedback: ObservableObject {
    static let shared = BackupAudioFeedback()

    @Published private(set) var enabled: Bool
    @Published private(set) var volume: Double
    @Published private(set) var previewFailed = false
    private let defaults: UserDefaults
    private let player: BackupCuePlaying
    private let isActive: @MainActor () -> Bool
    private let uptime: () -> TimeInterval
    private var lastCueAt: TimeInterval?
    private var lastCue: BackupSoundCue?

    init(
        defaults: UserDefaults = .standard,
        player: BackupCuePlaying? = nil,
        isActive: @escaping @MainActor () -> Bool = { NSApp?.isActive == true },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.defaults = defaults
        self.player = player ?? SynthesizedCuePlayer()
        self.isActive = isActive
        self.uptime = uptime
        let preferences = BackupSoundPreferences(defaults: defaults)
        enabled = preferences.enabled
        volume = preferences.volume
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: BackupSoundPreferences.enabledKey)
        previewFailed = false
        if !value { player.stop() }
    }

    func setVolume(_ value: Double) {
        volume = BackupSoundPreferences.normalizedVolume(value)
        defaults.set(volume, forKey: BackupSoundPreferences.volumeKey)
        player.setVolume(Float(volume))
        previewFailed = false
        if volume == 0 { player.stop() }
    }

    // Return whether this result belongs to the foreground audio path, even
    // when muted/throttled. The notification must not replay it after an app
    // switch. Background results use UserNotifications, never AVAudioPlayer,
    // so they don't bypass notification permissions or Focus.
    @discardableResult
    func handleResult(_ status: BackupStatus) -> Bool {
        guard isActive() else { return false }
        guard enabled, volume > 0, let cue = BackupSoundCue(status: status) else { return true }
        let now = uptime()
        let isBurst = lastCueAt.map { now - $0 < 1 } ?? false
        // Coalesce simultaneous completions; an error may replace a success.
        if (isBurst || player.isPlaying) && !(cue == .failure && lastCue == .success) { return true }
        if player.play(cue, volume: Float(volume)) {
            lastCueAt = now
            lastCue = cue
        }
        return true
    }

    func preview(_ cue: BackupSoundCue) {
        previewFailed = false
        guard enabled, volume > 0 else { return }
        previewFailed = !player.play(cue, volume: Float(volume))
        lastCueAt = uptime()
        lastCue = cue
    }
}
