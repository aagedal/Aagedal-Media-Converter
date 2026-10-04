// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Locales supported out of the box by the bundled Nemotron 3.5 base model.
/// Adaptation-only locales such as Nynorsk require different model weights.
struct NemotronLanguage: Identifiable, Sendable {
    let id: String
    let name: String

    static let supported: [Self] = [
        .init(id: "auto", name: "Automatic detection"),
        .init(id: "nb-NO", name: "Norwegian Bokmål"),
        .init(id: "ar-AR", name: "Arabic"),
        .init(id: "bg-BG", name: "Bulgarian"),
        .init(id: "zh-CN", name: "Chinese (Mandarin)"),
        .init(id: "hr-HR", name: "Croatian"),
        .init(id: "cs-CZ", name: "Czech"),
        .init(id: "da-DK", name: "Danish"),
        .init(id: "nl-NL", name: "Dutch"),
        .init(id: "en-GB", name: "English (United Kingdom)"),
        .init(id: "en-US", name: "English (United States)"),
        .init(id: "et-EE", name: "Estonian"),
        .init(id: "fi-FI", name: "Finnish"),
        .init(id: "fr-CA", name: "French (Canada)"),
        .init(id: "fr-FR", name: "French (France)"),
        .init(id: "de-DE", name: "German"),
        .init(id: "hi-IN", name: "Hindi"),
        .init(id: "hu-HU", name: "Hungarian"),
        .init(id: "it-IT", name: "Italian"),
        .init(id: "ja-JP", name: "Japanese"),
        .init(id: "ko-KR", name: "Korean"),
        .init(id: "pl-PL", name: "Polish"),
        .init(id: "pt-BR", name: "Portuguese (Brazil)"),
        .init(id: "pt-PT", name: "Portuguese (Portugal)"),
        .init(id: "ro-RO", name: "Romanian"),
        .init(id: "ru-RU", name: "Russian"),
        .init(id: "sk-SK", name: "Slovak"),
        .init(id: "es-ES", name: "Spanish (Spain)"),
        .init(id: "es-US", name: "Spanish (United States)"),
        .init(id: "sv-SE", name: "Swedish"),
        .init(id: "tr-TR", name: "Turkish"),
        .init(id: "uk-UA", name: "Ukrainian"),
        .init(id: "vi-VN", name: "Vietnamese")
    ]
}
