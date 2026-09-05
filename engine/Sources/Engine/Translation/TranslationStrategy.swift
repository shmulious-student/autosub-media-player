// TranslationStrategy — the user-selectable speed/quality tier for translation.
//
// Proven on the real episode (benchmark + gender gate, SPEC §4):
//   .quality   single lean pass on the 12B   → 88% gender, ~8.5 min / 30 min. DEFAULT.
//   .fast      single lean pass on the 7B    → 75% gender, ~4.9 min / 30 min.
//   .progressive  7B draft FIRST (watchable in ~4.9 min) → the 12B then re-resolves
//                 gender on the flagged (1st/2nd-person) lines IN THE BACKGROUND,
//                 upgrading the sidecar in place. Best of both: fast to watch, ends
//                 at ~12B gender quality. Total compute is higher, but time-to-
//                 watchable is the 7B's.
//
// All three share ONE translation path (lean ScenePacketTranslator); they differ
// only in which model(s) run and whether a background gender pass follows.

import Foundation

public enum TranslationStrategy: String, Codable, Sendable, CaseIterable {
    case quality      // single-pass, 12B (default)
    case fast         // single-pass, 7B
    case progressive  // 7B draft now, 12B gender-fix in background

    public static let `default`: TranslationStrategy = .quality

    public init(wire: String?) {
        self = TranslationStrategy(rawValue: wire ?? "") ?? .quality
    }

    /// Does this strategy run the slow 12B at all? (Used to decide which models warm.)
    public var usesQualityModel: Bool { self != .fast }
    /// Does this strategy run the fast 7B at all?
    public var usesFastModel: Bool { self != .quality }
}
