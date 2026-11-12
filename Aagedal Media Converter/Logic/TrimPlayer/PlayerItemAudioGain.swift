// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Applies a decibel gain to AVPlayer audio, which AVPlayer.volume cannot raise above unity.

import Accelerate
import AVFoundation
import MediaToolbox
import Synchronization

/// State shared with the real-time tap callback, which reads it once per buffer.
private final class AudioGainTapStorage: Sendable {
    let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    /// The tap only scales 32-bit float PCM; other formats pass through unchanged.
    let processesFloat = Atomic<Bool>(false)
}

/// Previews an export volume on an AVPlayerItem through an audio processing tap.
/// The tap is installed only once a gain other than 0 dB is needed, and later
/// changes apply to the playing audio straight away.
@MainActor
final class PlayerItemAudioGain {
    private let storage = AudioGainTapStorage()
    private weak var installedItem: AVPlayerItem?
    private var installTask: Task<Void, Never>?

    var decibels: Double = 0 {
        didSet {
            let gain = decibels.isFinite ? Float(pow(10, decibels / 20)) : 1
            storage.gainBits.store(gain.bitPattern, ordering: .relaxed)
        }
    }

    func apply(to item: AVPlayerItem?) {
        guard let item, abs(decibels) >= 0.05, installedItem !== item else { return }
        installedItem = item
        installTask?.cancel()
        installTask = Task { [weak item] in
            guard let asset = item?.asset,
                  let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty,
                  !Task.isCancelled, let item else { return }
            item.audioMix = audioMix(for: tracks)
        }
    }

    /// A mix that taps every track with this gain.
    func audioMix(for tracks: [AVAssetTrack]) -> AVMutableAudioMix {
        let storage = storage
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.compactMap { track in
            guard let tap = Self.makeTap(storage) else { return nil }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            return parameters
        }
        return mix
    }

    private nonisolated static func makeTap(_ storage: AudioGainTapStorage) -> MTAudioProcessingTap? {
        // Each tap holds the storage until its finalize callback releases it.
        let clientInfo = Unmanaged.passRetained(storage).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<AudioGainTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let storage = Unmanaged<AudioGainTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                let description = format.pointee
                storage.processesFloat.store(
                    description.mFormatID == kAudioFormatLinearPCM
                        && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                        && description.mBitsPerChannel == 32,
                    ordering: .relaxed)
            },
            unprepare: nil,
            process: { tap, frameCount, _, buffers, frameCountOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, buffers, flagsOut, nil, frameCountOut) == noErr
                else { return }
                let storage = Unmanaged<AudioGainTapStorage>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                var gain = Float(bitPattern: storage.gainBits.load(ordering: .relaxed))
                guard gain != 1, storage.processesFloat.load(ordering: .relaxed) else { return }
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
                    vDSP_vsmul(samples, 1, &gain, samples, 1, count)
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<AudioGainTapStorage>.fromOpaque(clientInfo).release()
            return nil
        }
        return tap
    }
}
