// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The method used to convert a video's subtitle track to SRT
enum SubtitleConversionMethod: String, Sendable, Equatable {
    /// AI audio transcription via whisper.cpp (speech → text)
    case whisper
    /// Optical character recognition via Tesseract (bitmap images → text)
    case ocr
    /// AI audio transcription via parakeet-mlx (NeMo ASR on Apple Silicon)
    case nemotron
    case parakeet
    var isTranscription: Bool { self != .ocr }

    var displayName: String {
        switch self {
        case .whisper: return "Whisper"
        case .parakeet: return "Parakeet"
        case .nemotron: return "Nemotron"
        case .ocr: return "OCR"
        }
    }

    static var defaultTranscription: Self {
        let method = Self(rawValue: UserDefaults.standard.string(forKey: AppConstants.defaultTranscriptionEngineKey) ?? "whisper") ?? .whisper
        return method.isTranscription ? method : .whisper
    }
}
