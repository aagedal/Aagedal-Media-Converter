// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// What the Whisper pipeline does around transcription. Each step is optional
/// and falls back quietly when its model or tool is missing, so a run always
/// produces subtitles even if it cannot refine them.
struct WhisperPipelineOptions: Sendable, Equatable {
    /// Transcribe only the speech Silero VAD finds (step 1 in WhisperX terms).
    var speechOnly: Bool
    /// Re-time words with a wav2vec2 aligner for the language.
    var refineWordTiming: Bool
    var speakerStyle: SubtitleSpeakerStyle
    var maxLineLength: Int

    /// Whisper's own word times laid out by the cue builder, with no extra tools.
    static let plain = WhisperPipelineOptions(
        speechOnly: false, refineWordTiming: false, speakerStyle: .off,
        maxLineLength: AppConstants.defaultWhisperMaxLineLength
    )

    init(speechOnly: Bool, refineWordTiming: Bool, speakerStyle: SubtitleSpeakerStyle, maxLineLength: Int) {
        self.speechOnly = speechOnly
        self.refineWordTiming = refineWordTiming
        self.speakerStyle = speakerStyle
        self.maxLineLength = maxLineLength
    }

    init(defaults: UserDefaults) {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        let lineLength = defaults.integer(forKey: AppConstants.whisperMaxLineLengthKey)
        self.init(
            speechOnly: bool(AppConstants.whisperSpeechOnlyKey, AppConstants.defaultWhisperSpeechOnly),
            refineWordTiming: bool(AppConstants.whisperRefineWordTimingKey, AppConstants.defaultWhisperRefineWordTiming),
            speakerStyle: SubtitleSpeakerStyle(rawValue: defaults.string(forKey: AppConstants.whisperSpeakerStyleKey)
                ?? AppConstants.defaultWhisperSpeakerStyle) ?? .dashes,
            maxLineLength: (20...80).contains(lineLength) ? lineLength : AppConstants.defaultWhisperMaxLineLength
        )
    }

    var needsDiarization: Bool { speakerStyle != .off }
    var needsExtractedAudio: Bool { speechOnly || needsDiarization || refineWordTiming }
}

/// Tools the pipeline may use. Each returns nil when unavailable.
struct WhisperPipelineTools: Sendable {
    var diarizerPath: @Sendable () -> String? = { BinaryPathResolver.nemotronPath }
    var vadModel: @Sendable () -> URL? = { AppConstants.whisperVADModelURL }
    var alignerDirectory: @Sendable (String) -> URL? = {
        WordAlignerModelManager.shared.installedDirectory(forLanguage: $0)
    }

    /// No diarization, VAD or alignment; used by tests and the plain pipeline.
    static let none = WhisperPipelineTools(diarizerPath: { nil }, vadModel: { nil }, alignerDirectory: { _ in nil })
}

/// Runs Silero VAD, Whisper, wav2vec2 alignment and speaker assignment, and
/// returns the finished SRT text.
struct WhisperTranscriptionPipeline: Sendable {
    let transcriber: WhisperFFmpegTranscriber
    let subprocessRunner: any SubprocessRunning
    let tools: WhisperPipelineTools
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WhisperPipeline")

    init(transcriber: WhisperFFmpegTranscriber, subprocessRunner: any SubprocessRunning, tools: WhisperPipelineTools) {
        self.transcriber = transcriber
        self.subprocessRunner = subprocessRunner
        self.tools = tools
    }

    struct Request: Sendable {
        var inputFile: URL
        var modelPath: URL
        var model: WhisperModel
        var language: String
        var audioStreamIndex: Int?
        var fasterTranscription: Bool
        var ffmpegPath: String
        var options: WhisperPipelineOptions
        /// Where the filter writes its word JSON.
        var wordsFile: URL
        var workDirectory: URL
    }

    func run(_ request: Request, progress: @escaping @Sendable (WhisperProgress) -> Void) async throws -> String {
        let options = request.options
        var transcriptionInput = request.inputFile
        var transcriptionStream = request.audioStreamIndex
        var audio: PCMWaveFile?
        var speakers: [SpeakerSegment] = []
        var diarized = false
        var speechMap: SpeechRegionMap?
        // Share of the progress bar spent before and after Whisper itself.
        let preparation = options.needsExtractedAudio ? 0.08 : 0
        let refinement = options.refineWordTiming ? 0.1 : 0

        if options.needsExtractedAudio {
            progress(WhisperProgress(stage: .extractingAudio, percentage: 0, message: nil))
            let wave = request.workDirectory.appendingPathComponent("audio.wav")
            try await NemotronAudioExtractor(subprocessRunner: subprocessRunner).extract(
                inputFile: request.inputFile, outputFile: wave,
                ffmpegPath: request.ffmpegPath, audioStreamIndex: request.audioStreamIndex
            )
            let extracted = try PCMWaveFile(url: wave)
            audio = extracted
            transcriptionInput = wave
            transcriptionStream = nil
            progress(WhisperProgress(stage: .transcribing, percentage: preparation / 2, message: nil))

            if options.needsDiarization, let diarizerPath = tools.diarizerPath() {
                do {
                    speakers = try await SpeakerDiarizer(subprocessRunner: subprocessRunner, executablePath: diarizerPath)
                        .diarize(audio: wave, outputFile: request.workDirectory.appendingPathComponent("speakers.json"))
                    diarized = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.warning("Speaker detection failed; continuing without it: \(error.localizedDescription, privacy: .public)")
                }
            }

            // Whisper invents text for silence and music; with no speech at
            // all there is nothing to transcribe.
            let speech = options.speechOnly ? try detectSpeech(in: extracted, diarized: diarized ? speakers : nil) : nil
            if let speech, speech.isEmpty {
                logger.info("No speech detected; writing empty subtitles")
                return ""
            }
            if let speech {
                let map = SpeechRegionMap(speech: speech, duration: extracted.duration)
                let speechFile = request.workDirectory.appendingPathComponent("speech.wav")
                try map.writeSpeechAudio(from: extracted, to: speechFile)
                speechMap = map
                transcriptionInput = speechFile
                logger.info("Transcribing \(map.speechDuration, privacy: .public)s of speech from \(extracted.duration, privacy: .public)s")
            }
        }
        try Task.checkCancellation()

        let vadModel = options.speechOnly ? tools.vadModel() : nil
        let span = 1 - preparation - refinement
        try await transcriber.transcribe(
            inputFile: transcriptionInput,
            modelPath: request.modelPath,
            outputFile: request.wordsFile,
            ffmpegPath: request.ffmpegPath,
            language: request.language,
            audioStreamIndex: transcriptionStream,
            fasterTranscription: request.fasterTranscription,
            vadModelPath: vadModel?.path
        ) { update in
            var scaled = update
            scaled.percentage = preparation + update.percentage * span
            progress(scaled)
        }
        guard FileManager.default.fileExists(atPath: request.wordsFile.path) else {
            throw WhisperServiceError.srtGenerationFailed
        }
        var words = WhisperWordJSONParser.parse(try Data(contentsOf: request.wordsFile))
        if let speechMap { words = speechMap.sourceWords(words) }

        if options.refineWordTiming, let audio, !words.isEmpty,
           let language = TranscriptLanguage.resolve(setting: request.language, model: request.model, words: words),
           let directory = tools.alignerDirectory(language) {
            do {
                let aligner = try Wav2Vec2WordAligner(directory: directory)
                words = try await aligner.align(words, audio: audio) { fraction in
                    progress(WhisperProgress(stage: .transcribing, percentage: 1 - refinement + fraction * refinement, message: nil))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Word alignment failed; keeping Whisper timing: \(error.localizedDescription, privacy: .public)")
            }
        }

        var speakerStyle = SubtitleSpeakerStyle.off
        if options.speakerStyle != .off, !speakers.isEmpty {
            words = SpeakerDiarizer.assignSpeakers(to: words, segments: speakers)
            speakerStyle = options.speakerStyle
        }
        progress(WhisperProgress(stage: .writingSRT, percentage: 0.99, message: nil))
        return SubtitleCueBuilder(
            maxLineLength: options.maxLineLength,
            speakerStyle: speakerStyle,
            speakerName: { String(localized: "Speaker \($0 + 1)") }
        ).srt(for: words)
    }

    /// Where the speech is, from the bundled Silero model, or from speaker
    /// detection if Silero cannot run. Nil when neither is available.
    private func detectSpeech(in audio: PCMWaveFile, diarized: [SpeakerSegment]?) throws -> [ClosedRange<Double>]? {
        if let model = tools.vadModel() {
            do {
                return try SileroVoiceActivityDetector(modelURL: model).speech(in: audio)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.warning("Silero VAD failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return diarized?.map { $0.start...$0.end }
    }
}
