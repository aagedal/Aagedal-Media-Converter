// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class TranscriptionPipelineTests: XCTestCase {

    // MARK: - Whisper JSON

    func testWhisperWordParserReadsFilterLinesInSeconds() {
        let data = Data("""
        {"start":330,"end":900,"text":" there,","p":0.8057,"language":"no"}
        {"start":50,"end":330,"text":" Hello","p":0.91,"language":"no"}
        not json
        {"start":900,"end":1000,"text":"","p":null,"language":"no"}
        {"start":1000,"end":1500,"text":" say \\"quoted\\" c\\\\d","p":0.5,"language":"en"}
        {"start":1500,"end":1600,"text":"broken "quote""}
        """.utf8)

        let transcript = WhisperWordJSONParser.parse(data)

        XCTAssertEqual(transcript.words.map(\.text), ["Hello", "there,", #"say "quoted" c\d"#])
        XCTAssertEqual(transcript.words[0].start, 0.05, accuracy: 1e-9)
        XCTAssertEqual(transcript.words[0].end, 0.33, accuracy: 1e-9)
        XCTAssertEqual(transcript.words[2].end, 1.5, accuracy: 1e-9)
        XCTAssertEqual(transcript.language, "no")
    }

    func testWhisperWordParserDropsNonSpeechMarkers() {
        let data = Data("""
        {"start":0,"end":100,"text":" [BLANK_AUDIO]"}
        {"start":100,"end":200,"text":" Hei"}
        {"start":200,"end":300,"text":" ["}
        {"start":300,"end":400,"text":"BLANK_AUDIO"}
        {"start":400,"end":500,"text":"]"}
        {"start":500,"end":600,"text":" igjen."}
        """.utf8)
        XCTAssertEqual(WhisperWordJSONParser.parse(data).words.map(\.text), ["Hei", "igjen."])
    }

    func testWhisperFilterRequestsWordJSONAndOptionalVAD() {
        let plain = WhisperFFmpegTranscriber.filter(modelPath: "/m.bin", outputPath: "/w.json", language: "no")
        XCTAssertTrue(plain.contains(":format=json:max_len=1:"))
        XCTAssertFalse(plain.contains("vad_model"))
        XCTAssertTrue(plain.hasSuffix(":queue=20"))

        let vad = WhisperFFmpegTranscriber.filter(
            modelPath: "/m.bin", outputPath: "/w.json", language: "no",
            fasterTranscription: true, vadModelPath: "/models/vad: v6.bin"
        )
        XCTAssertTrue(vad.contains(#":vad_model=/models/vad\\: v6.bin:"#), vad)
        XCTAssertTrue(vad.hasSuffix(":queue=30"))
    }

    func testWhisperFilterPassesNamesAsInitialPrompt() {
        let empty = WhisperFFmpegTranscriber.filter(
            modelPath: "/m.bin", outputPath: "/w.json", language: "no", initialPrompt: "  \n "
        )
        XCTAssertFalse(empty.contains("initial_prompt"))

        let named = WhisperFFmpegTranscriber.filter(
            modelPath: "/m.bin", outputPath: "/w.json", language: "no",
            initialPrompt: "Mette Qvigstad, Kvæfjord\nNRK: Nordlys"
        )
        XCTAssertTrue(named.contains(#":initial_prompt=Mette Qvigstad\, Kvæfjord NRK\\: Nordlys:"#), named)
    }

    // MARK: - Cue builder

    private func words(_ text: String, start: Double = 0, step: Double = 0.3, speaker: Int? = nil) -> [TranscriptWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TranscriptWord(
                text: String(word), start: start + Double(index) * step,
                end: start + Double(index) * step + step * 0.8, speaker: speaker
            )
        }
    }

    func testCueBuilderKeepsShortSentenceOnOneLine() {
        let cues = SubtitleCueBuilder().cues(for: words("Hello there, this is a test."))
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].lines, ["Hello there, this is a test."])
        XCTAssertEqual(cues[0].start, 0)
    }

    func testCueBuilderRespectsLineLengthAndLineCount() {
        let text = """
        Dette er en ganske lang setning som ikke får plass på én linje og derfor må deles opp i flere \
        undertekster slik at seeren rekker å lese alt sammen uten problemer i det hele tatt
        """
        let builder = SubtitleCueBuilder(maxLineLength: 32)
        let cues = builder.cues(for: words(text))
        XCTAssertGreaterThan(cues.count, 1)
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.lines.count, 2, "\(cue.lines)")
            for line in cue.lines { XCTAssertLessThanOrEqual(line.count, 32, line) }
        }
        XCTAssertEqual(cues.flatMap(\.lines).joined(separator: " "), text)
    }

    func testCueBuilderBalancesTwoLinesAndPrefersPunctuation() {
        let lines = SubtitleCueBuilder(maxLineLength: 30).layoutLines(
            ["Først", "dette,", "og", "så", "kommer", "resten", "av", "teksten"], width: 30
        )
        XCTAssertEqual(lines, ["Først dette,", "og så kommer resten av teksten"])
    }

    func testCueBuilderSplitsOnLongPause() {
        let first = words("One two three.")
        let second = words("Four five six.", start: 5)
        let cues = SubtitleCueBuilder().cues(for: first + second)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].start, 5)
    }

    func testCueBuilderPutsShortDialogueOnDashedLines() {
        let question = words("Er du klar?", speaker: 0)
        let answer = words("Ja.", start: 1.0, speaker: 1)
        let cues = SubtitleCueBuilder(speakerStyle: .dashes).cues(for: question + answer)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].lines, ["– Er du klar?", "– Ja."])
    }

    func testCueBuilderPairsAQuestionAndItsReplyAsDialogue() {
        let question = words("Hei, er du klar for opptaket i dag?", speaker: 0)
        let answer = words("Ja, jeg er klar.", start: 3, speaker: 1)
        let later = words("Flott.", start: 8, speaker: 0)
        let cues = SubtitleCueBuilder(speakerStyle: .dashes).cues(for: question + answer + later)
        XCTAssertEqual(cues.map(\.lines), [
            ["– Hei, er du klar for opptaket i dag?", "– Ja, jeg er klar."],
            ["Flott."],
        ])
    }

    func testCueBuilderMovesTrailingWordsAfterAClauseIntoTheNextCue() {
        let text = "Flott, da begynner vi med en kort presentasjon av prosjektet, og så tar vi spørsmålene etterpå."
        let cues = SubtitleCueBuilder().cues(for: words(text, step: 0.25))
        XCTAssertEqual(cues.map(\.lines), [
            ["Flott, da begynner vi med en", "kort presentasjon av prosjektet,"],
            ["og så tar vi spørsmålene etterpå."],
        ])
    }

    func testCueBuilderDoesNotSplitAReplyAcrossCues() {
        let question = words("Er du klar?", speaker: 0)
        let reply = words("Det høres bra ut, jeg har forberedt noen notater om budsjettet.", start: 1.2, speaker: 1)
        let cues = SubtitleCueBuilder(speakerStyle: .dashes).cues(for: question + reply)
        XCTAssertEqual(cues.first?.lines, ["Er du klar?"])
        XCTAssertFalse(cues.flatMap(\.lines).contains { $0.hasPrefix("–") })
    }

    func testCueBuilderStartsNewCueWhenDialogueTurnIsTooLong() {
        let first = words("Dette er en lang replikk som fyller hele linjen alene", speaker: 0)
        let second = words("Ja.", start: 4, speaker: 1)
        let cues = SubtitleCueBuilder(speakerStyle: .dashes).cues(for: first + second)
        XCTAssertEqual(cues.last?.lines, ["Ja."])
        XCTAssertFalse(cues.flatMap(\.lines).contains { $0.hasPrefix("–") })
    }

    func testCueBuilderIgnoresSpeakersWhenStyleIsOff() {
        let cues = SubtitleCueBuilder().cues(for: words("Er du klar?", speaker: 0) + words("Ja.", start: 1.0, speaker: 1))
        XCTAssertEqual(cues.map(\.lines), [["Er du klar? Ja."]])
    }

    func testCueBuilderNamesSpeakerOnlyWhenTheVoiceChanges() {
        let builder = SubtitleCueBuilder(speakerStyle: .names, speakerName: { "Speaker \($0 + 1)" })
        let cues = builder.cues(for:
            words("Hei.", speaker: 0) + words("Hvordan går det?", start: 2.5, speaker: 0)
            + words("Bra.", start: 5, speaker: 1)
        )
        XCTAssertEqual(cues.map { $0.lines[0] }, ["Speaker 1: Hei.", "Hvordan går det?", "Speaker 2: Bra."])
    }

    func testCueBuilderExtendsShortCuesWithoutOverlappingTheNext() {
        let cues = SubtitleCueBuilder().cues(for: [
            // 33 characters need about two seconds of reading time.
            TranscriptWord(text: "Uttrykksfulle-ordsammensetninger.", start: 1, end: 1.2),
            TranscriptWord(text: "Nei.", start: 2.45, end: 2.6),
            TranscriptWord(text: "Kanskje.", start: 5, end: 5.3),
        ])
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].end, 2.37, accuracy: 1e-9)
        XCTAssertEqual(cues[1].end, 3.45, accuracy: 1e-9)
        XCTAssertEqual(cues[2].end, 6.0, accuracy: 1e-9)
    }

    func testSRTRendering() {
        let srt = SubtitleCueBuilder.srt([
            SubtitleCue(start: 0, end: 1.5, lines: ["A"]),
            SubtitleCue(start: 3661.001, end: 3662, lines: ["B", "C"]),
        ])
        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:01,500\nA\n\n2\n01:01:01,001 --> 01:01:02,000\nB\nC\n")
    }

    // MARK: - CTC forced alignment

    private let vocabulary = ["|": 0, "a": 1, "b": 2, "[PAD]": 3]

    /// Log probabilities where `labels[frame]` is likely and the rest unlikely.
    private func emissions(_ labels: [Int], vocabularySize: Int = 4) -> [Float] {
        labels.flatMap { label in
            (0..<vocabularySize).map { $0 == label ? log(0.9) : log(0.1 / Float(vocabularySize - 1)) }
        }
    }

    func testCTCAlignerFindsWordsInEmissions() throws {
        let aligner = CTCForcedAligner(vocabulary: vocabulary, blankTokenID: 3, wordDelimiter: "|", lowercase: true)
        //            0  1  2  3  4  5  6  7  8  9 10 11 12 13
        let labels = [3, 3, 1, 1, 2, 3, 0, 3, 3, 3, 2, 1, 1, 3]
        let ranges = try XCTUnwrap(aligner.align(
            words: ["AB", "ba"], logProbabilities: emissions(labels),
            frameCount: labels.count, vocabularySize: 4, secondsPerFrame: 0.02
        ))
        XCTAssertEqual(ranges[0]?.lowerBound ?? -1, 0.04, accuracy: 1e-9)
        XCTAssertEqual(ranges[0]?.upperBound ?? -1, 0.10, accuracy: 1e-9)
        XCTAssertEqual(ranges[1]?.lowerBound ?? -1, 0.20, accuracy: 1e-9)
        XCTAssertEqual(ranges[1]?.upperBound ?? -1, 0.26, accuracy: 1e-9)
    }

    func testCTCAlignerNeedsBlankBetweenRepeatedLetters() {
        let aligner = CTCForcedAligner(vocabulary: vocabulary, blankTokenID: 3, wordDelimiter: "|", lowercase: true)
        XCTAssertNil(aligner.align(
            words: ["aa"], logProbabilities: emissions([1]), frameCount: 1, vocabularySize: 4, secondsPerFrame: 0.02
        ))
        XCTAssertNotNil(aligner.align(
            words: ["aa"], logProbabilities: emissions([1, 3, 1]), frameCount: 3, vocabularySize: 4, secondsPerFrame: 0.02
        ))
    }

    func testCTCAlignerSkipsUnknownCharactersAndFoldsDiacritics() {
        let aligner = CTCForcedAligner(vocabulary: vocabulary, blankTokenID: 3, wordDelimiter: "|", lowercase: true)
        XCTAssertEqual(aligner.tokens(for: "Á-b!"), [1, 2])
        XCTAssertEqual(aligner.tokens(for: "2026"), [])
    }

    func testCTCMergeSpreadsUnalignedWordsBetweenNeighbours() {
        let original = [
            TranscriptWord(text: "a", start: 9, end: 9.1),
            TranscriptWord(text: "12", start: 9, end: 9.1),
            TranscriptWord(text: "34", start: 9, end: 9.1),
            TranscriptWord(text: "b", start: 9, end: 9.1),
        ]
        let merged = CTCForcedAligner.merge([0...0.5, nil, nil, 1.5...2.0], into: original, offset: 10)
        XCTAssertEqual(merged.map(\.start), [10, 10.5, 11, 11.5])
        XCTAssertEqual(merged.map(\.end), [10.5, 11, 11.5, 12])
    }

    func testAlignmentWindowsSplitAtPausesWithoutOverlapping() {
        let input = words("a b c d", step: 0.4) + words("e f", start: 4, step: 0.4)
        let windows = WordAlignmentPlanner.windows(for: input, duration: 10)
        XCTAssertEqual(windows.map(\.words), [0..<4, 4..<6])
        XCTAssertEqual(windows[0].start, 0)
        XCTAssertLessThanOrEqual(windows[0].end, windows[1].start)
        XCTAssertEqual(windows[1].start, 3, accuracy: 1e-9)
        XCTAssertEqual(windows[1].end, 5.72, accuracy: 1e-9)
    }

    func testAlignmentWindowsStayWithinMaximumLength() {
        let input = words(Array(repeating: "ord", count: 200).joined(separator: " "), step: 0.3)
        let windows = WordAlignmentPlanner.windows(for: input, duration: 100, maximumWindow: 10)
        XCTAssertGreaterThan(windows.count, 5)
        for window in windows {
            let span = input[window.words.upperBound - 1].end - input[window.words.lowerBound].start
            XCTAssertLessThanOrEqual(span, 10)
        }
    }

    // MARK: - Speech regions and speakers

    func testSpeechRegionsPadMergeAndMapBack() {
        let map = SpeechRegionMap(speech: [1...2, 2.5...3, 10...11], duration: 10.5)
        XCTAssertEqual(map.regions.map(\.start), [0.75, 9.75])
        XCTAssertEqual(map.regions.map(\.end), [3.25, 10.5])
        XCTAssertEqual(map.speechDuration, 3.25, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(1.0), 1.75, accuracy: 1e-9)
        XCTAssertEqual(map.sourceTime(2.6), 9.85, accuracy: 1e-9)

        let mapped = map.sourceWords([TranscriptWord(text: "x", start: 2.4, end: 2.7)])
        XCTAssertEqual(mapped[0].start, 3.15, accuracy: 1e-9)
        // The end stays in the start's region instead of jumping over the pause.
        XCTAssertEqual(mapped[0].end, 3.25, accuracy: 1e-9)
    }

    func testSpeechAudioConcatenatesRegions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechAudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.wav")
        let samples = (0..<16_000 * 4).map { Int16(truncatingIfNeeded: $0 / 16_000 * 1000) }
        try PCMWaveFile.write(
            [samples.withUnsafeBufferPointer { Data(buffer: $0) }], byteCount: samples.count * 2,
            sampleRate: 16_000, to: source
        )

        let audio = try PCMWaveFile(url: source)
        XCTAssertEqual(audio.sampleCount, 64_000)
        XCTAssertEqual(audio.duration, 4)

        let map = SpeechRegionMap(speech: [0.5...0.75, 3.0...3.5], duration: 4, padding: 0, mergeGap: 0)
        let speech = directory.appendingPathComponent("speech.wav")
        try map.writeSpeechAudio(from: audio, to: speech)
        let written = try PCMWaveFile(url: speech)
        XCTAssertEqual(written.sampleCount, 4_000 + 8_000)
        XCTAssertEqual(written.floatSamples(0..<1)[0], 0)
        XCTAssertEqual(written.floatSamples(4_000..<4_001)[0], 3000 / 32768)
    }

    func testDiarizationParsingAndSpeakerAssignment() throws {
        let segments = try SpeakerDiarizer.parse(Data("""
        {"file":"a.wav","segments":[
          {"start": 7.0, "end": 11.0, "speaker": 2},
          {"start": 0.0, "end": 3.6, "speaker": 1},
          {"start": 3.0, "end": 3.0, "speaker": 3}
        ]}
        """.utf8))
        XCTAssertEqual(segments.map(\.speaker), [1, 2])

        let assigned = SpeakerDiarizer.assignSpeakers(to: [
            TranscriptWord(text: "first", start: 7.5, end: 8),
            TranscriptWord(text: "edge", start: 3.8, end: 4.0),
            TranscriptWord(text: "lost", start: 5, end: 5.2),
            TranscriptWord(text: "early", start: 1, end: 1.2),
        ], segments: segments)
        // Renumbered in order of first appearance.
        XCTAssertEqual(assigned.map(\.speaker), [0, 1, nil, 1])
    }

    func testSpeakerAssignmentPrefersLargestOverlap() {
        let assigned = SpeakerDiarizer.assignSpeakers(
            to: [TranscriptWord(text: "x", start: 1, end: 2)],
            segments: [
                SpeakerSegment(start: 0, end: 1.2, speaker: 5),
                SpeakerSegment(start: 1.1, end: 3, speaker: 6),
            ]
        )
        XCTAssertEqual(assigned[0].speaker, 0)
    }

    // MARK: - Language and options

    func testTranscriptLanguageResolution() {
        let norwegian = words("Dette er en test av norsk tale, og vi håper at språket blir gjenkjent riktig.")
        XCTAssertEqual(TranscriptLanguage.resolve(setting: "sv", model: .base, words: []), "sv")
        XCTAssertEqual(TranscriptLanguage.resolve(setting: "auto", model: .norwegianLarge, words: []), "no")
        XCTAssertEqual(TranscriptLanguage.resolve(setting: "auto", model: .base, words: norwegian), "no")
        XCTAssertEqual(TranscriptLanguage.resolve(setting: "auto", model: .base, words: norwegian, detected: "sv"), "sv")
        XCTAssertEqual(TranscriptLanguage.resolve(setting: "en", model: .base, words: [], detected: "sv"), "en")
        XCTAssertEqual(WordAlignerModel.model(forLanguage: "nb")?.id, "nb-bokmaal-300m")
    }

    func testPipelineOptionsReadDefaults() throws {
        let suite = "TranscriptionPipelineTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = WhisperPipelineOptions(defaults: defaults)
        XCTAssertTrue(fresh.speechOnly)
        XCTAssertTrue(fresh.refineWordTiming)
        XCTAssertEqual(fresh.speakerStyle, .dashes)
        XCTAssertEqual(fresh.maxLineLength, 42)

        defaults.set(false, forKey: AppConstants.whisperSpeechOnlyKey)
        defaults.set("names", forKey: AppConstants.whisperSpeakerStyleKey)
        defaults.set(37, forKey: AppConstants.whisperMaxLineLengthKey)
        let changed = WhisperPipelineOptions(defaults: defaults)
        XCTAssertFalse(changed.speechOnly)
        XCTAssertEqual(changed.speakerStyle, .names)
        XCTAssertEqual(changed.maxLineLength, 37)
        XCTAssertTrue(changed.needsExtractedAudio)
        XCTAssertFalse(WhisperPipelineOptions.plain.needsExtractedAudio)
    }

    // MARK: - Silero VAD

    func testBundledSileroModelMatchesChecksum() throws {
        let url = try XCTUnwrap(AppConstants.whisperVADModelURL, "Silero VAD is not in the app bundle")
        let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, AppConstants.whisperVADModelSHA256)
        XCTAssertNoThrow(try SileroVoiceActivityDetector(modelURL: url))
    }

    func testSileroSegmentsFollowWhisperCpp() {
        // 512-sample windows: a short dip stays inside speech, a 0.16 s burst
        // is dropped, and speech still running at the end is kept.
        let probabilities: [Float] = Array(repeating: 0, count: 10) + Array(repeating: 0.9, count: 30)
            + Array(repeating: 0.1, count: 2) + Array(repeating: 0.9, count: 18)
            + Array(repeating: 0, count: 20) + Array(repeating: 0.9, count: 5)
            + Array(repeating: 0, count: 15) + Array(repeating: 0.9, count: 10)
        let segments = SileroVoiceActivityDetector.segments(probabilities: probabilities, window: 512, duration: 3.52)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].lowerBound, 0.29, accuracy: 1e-9)
        XCTAssertEqual(segments[0].upperBound, 1.95, accuracy: 1e-9)
        XCTAssertEqual(segments[1].lowerBound, 3.17, accuracy: 1e-9)
        XCTAssertEqual(segments[1].upperBound, 3.52, accuracy: 1e-9)
    }

    func testSileroFindsSpeechBetweenSilences() async throws {
        let model = try XCTUnwrap(AppConstants.whisperVADModelURL)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("SileroTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let speech = work.appendingPathComponent("speech.aiff")
        let say = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/say"),
            arguments: ["-o", speech.path, "This is a short test of speech detection."],
            timeout: .seconds(60), standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 4096
        ))
        guard say.succeeded else { throw XCTSkip("Speech synthesis is unavailable") }
        let wave = work.appendingPathComponent("audio.wav")
        let ffmpeg = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: ffmpegURL,
            arguments: ["-nostdin", "-f", "lavfi", "-t", "2", "-i", "anullsrc=r=16000:cl=mono", "-i", speech.path,
                        "-f", "lavfi", "-t", "3", "-i", "anullsrc=r=16000:cl=mono",
                        "-filter_complex", "[1]aresample=16000[s];[0][s][2]concat=n=3:v=0:a=1", "-ac", "1",
                        "-c:a", "pcm_s16le", wave.path],
            timeout: .seconds(60), standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 64 * 1024
        ))
        XCTAssertTrue(ffmpeg.succeeded, ffmpeg.standardErrorText)

        let audio = try PCMWaveFile(url: wave)
        let segments = try SileroVoiceActivityDetector(modelURL: model).speech(in: audio)
        let first = try XCTUnwrap(segments.first, "No speech found")
        let last = try XCTUnwrap(segments.last)
        XCTAssertGreaterThan(first.lowerBound, 1.7, "\(segments)")
        XCTAssertLessThan(first.lowerBound, 2.3, "\(segments)")
        XCTAssertLessThan(last.upperBound, audio.duration - 2.5, "\(segments)")
        XCTAssertGreaterThan(last.upperBound, audio.duration - 3.5, "\(segments)")
    }

    // MARK: - Installed aligner (skipped unless present)

    /// Runs the Norwegian Core ML aligner on synthetic speech after two seconds
    /// of silence. Whisper-like times that start too early must move into the
    /// speech. Skipped when the aligner or the Norwegian voice is missing.
    func testInstalledNorwegianAlignerMovesWordsIntoSpeech() async throws {
        guard let directory = WordAlignerModelManager.shared.installedDirectory(forLanguage: "no") else {
            throw XCTSkip("Norwegian word aligner is not installed")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AlignerTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let speech = work.appendingPathComponent("speech.aiff")
        let say = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/say"),
            arguments: ["-v", "Nora", "-o", speech.path, "Hei, jeg heter Nora og dette er en test."],
            timeout: .seconds(60), standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 4096
        ))
        guard say.succeeded else { throw XCTSkip("The Norwegian voice Nora is not installed") }
        let wave = work.appendingPathComponent("audio.wav")
        let ffmpeg = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: ffmpegURL,
            arguments: ["-nostdin", "-f", "lavfi", "-t", "2", "-i", "anullsrc=r=16000:cl=mono", "-i", speech.path,
                        "-filter_complex", "[0][1]concat=n=2:v=0:a=1,aresample=16000", "-ac", "1",
                        "-c:a", "pcm_s16le", wave.path],
            timeout: .seconds(60), standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 64 * 1024
        ))
        XCTAssertTrue(ffmpeg.succeeded, ffmpeg.standardErrorText)

        let audio = try PCMWaveFile(url: wave)
        let text = ["Hei,", "jeg", "heter", "Nora", "og", "dette", "er", "en", "test."]
        // Pretend Whisper put the words 1.2 s early and evenly spaced.
        let rough = text.enumerated().map { index, word in
            TranscriptWord(text: word, start: 0.8 + Double(index) * 0.3, end: 1.05 + Double(index) * 0.3)
        }
        let aligned = try await Wav2Vec2WordAligner(directory: directory).align(rough, audio: audio)

        XCTAssertGreaterThan(aligned[0].start, 1.9, "\(aligned)")
        XCTAssertLessThan(aligned[0].start, 2.4, "\(aligned)")
        for (previous, next) in zip(aligned, aligned.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.start, next.start)
            XCTAssertLessThanOrEqual(previous.end, next.start + 0.05)
        }
        XCTAssertLessThanOrEqual(aligned.last?.end ?? .infinity, audio.duration + 0.05)
    }

    private var ffmpegURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Aagedal Media Converter/Binaries/ffmpeg")
    }
}

/// Writes a fake engine result where a subprocess fake would. The Whisper
/// filter writes word JSON (its destination ends in `.json`), so an SRT
/// fixture becomes one JSON line per cue; other engines get the SRT as is.
func writeFakeTranscriptionOutput(_ srt: String, to url: URL) throws {
    guard url.pathExtension == "json" else {
        try srt.write(to: url, atomically: true, encoding: .utf8)
        return
    }
    func milliseconds(_ timestamp: String) -> Int {
        let parts = timestamp.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == ":" || $0 == "," }).compactMap { Int($0) }
        return ((parts[0] * 60 + parts[1]) * 60 + parts[2]) * 1000 + parts[3]
    }
    var lines: [String] = []
    for block in srt.components(separatedBy: "\n\n") {
        let rows = block.components(separatedBy: "\n")
        guard let timing = rows.firstIndex(where: { $0.contains(" --> ") }) else { continue }
        let times = rows[timing].components(separatedBy: " --> ").map(milliseconds)
        let text = rows[(timing + 1)...].filter { !$0.isEmpty }.joined(separator: " ")
        let object: [String: Any] = ["start": times[0], "end": times[1], "text": text]
        lines.append(String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}
