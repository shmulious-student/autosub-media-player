// LanguageName — map a BCP-47-ish language CODE to its English NAME for prompts.
//
// Prompts must say "translate into Hebrew", not "translate into he". The 12B is
// Hebrew-saturated enough to tolerate the bare code, but smaller models (DictaLM
// 2.0 7B) read "into he" as noise and silently default to another language
// (observed: Spanish). Always feed the model the spelled-out language name.

import Foundation

public enum LanguageName {
    public static func of(_ code: String) -> String {
        switch code.lowercased().prefix(2) {
        case "he", "iw": return "Hebrew"
        case "en": return "English"
        case "ar": return "Arabic"
        case "ru": return "Russian"
        case "es": return "Spanish"
        case "fr": return "French"
        case "de": return "German"
        case "it": return "Italian"
        case "pt": return "Portuguese"
        case "nl": return "Dutch"
        case "pl": return "Polish"
        case "tr": return "Turkish"
        case "fa": return "Persian"
        case "uk": return "Ukrainian"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "zh": return "Chinese"
        case "hi": return "Hindi"
        default: return code
        }
    }
}
