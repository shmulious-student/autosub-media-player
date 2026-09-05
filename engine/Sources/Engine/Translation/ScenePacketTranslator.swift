import Foundation

public struct ScenePacket: Sendable {
    public var cueIndices: [Int]
    public var lines: [String]
    /// Deterministically resolved speaker/addressee per line (AddresseeResolver),
    /// parallel to `lines`. Empty when the ladder was not run — the prompt then
    /// falls back to plain numbered lines exactly as before.
    public var bindings: [DialogueBinding]
    /// 1–2 sentence situational summary of the scene this packet belongs to
    /// (SceneSynopsis), injected so ambiguous lines are read in context.
    public var synopsis: String?

    public init(cueIndices: [Int], lines: [String],
                bindings: [DialogueBinding] = [], synopsis: String? = nil) {
        self.cueIndices = cueIndices
        self.lines = lines
        self.bindings = bindings
        self.synopsis = synopsis
    }

    public var isEmpty: Bool { lines.isEmpty }

    /// The binding for a local (0-based) line, or nil when none was resolved.
    public func binding(at local0: Int) -> DialogueBinding? {
        local0 >= 0 && local0 < bindings.count ? bindings[local0] : nil
    }

    /// A sub-packet over a local index range, carrying the matching bindings.
    public func slice(_ range: Range<Int>) -> ScenePacket {
        ScenePacket(
            cueIndices: Array(cueIndices[range]),
            lines: Array(lines[range]),
            bindings: bindings.isEmpty ? [] : Array(bindings[range]),
            synopsis: synopsis)
    }
}

public enum ScenePacketer {
    /// Build packet-sized scenes from timed cues.
    ///
    /// Packets split on large timing gaps and on conservative context limits.
    /// Defaults fit the current 4096-token llama context better than the larger
    /// scene packets we should test once the server runs at 8k/16k context.
    /// - `bindingsByCueIndex`: AddresseeResolver output, keyed by `SubtitleCue.index`.
    /// - `sceneIdByCueIndex` / `synopsisBySceneId`: SceneSegmenter output. When given,
    ///   a packet NEVER spans two narrative scenes (a packet carries exactly one
    ///   synopsis, so it must describe every line in it) and inherits its synopsis.
    public static func packets(
        cues: [SubtitleCue],
        maxLines: Int = 24,
        maxSourceChars: Int = 2_400,
        sceneGapMs: Int = 2_500,
        bindingsByCueIndex: [Int: DialogueBinding] = [:],
        sceneIdByCueIndex: [Int: Int] = [:],
        synopsisBySceneId: [Int: String] = [:]
    ) -> [ScenePacket] {
        var out: [ScenePacket] = []
        var indices: [Int] = []
        var lines: [String] = []
        var bindings: [DialogueBinding] = []
        var chars = 0
        var previousEnd: Int?
        var currentScene: Int?

        func flush() {
            guard !lines.isEmpty else { return }
            out.append(ScenePacket(
                cueIndices: indices, lines: lines,
                bindings: bindings.count == lines.count ? bindings : [],
                synopsis: currentScene.flatMap { synopsisBySceneId[$0] }))
            indices.removeAll(keepingCapacity: true)
            lines.removeAll(keepingCapacity: true)
            bindings.removeAll(keepingCapacity: true)
            chars = 0
        }

        for cue in PromptTextSanitizer.sanitizedCues(cues) {
            let gap = previousEnd.map { cue.startMs - $0 } ?? 0
            let scene = sceneIdByCueIndex[cue.index]
            let leftScene = !lines.isEmpty && scene != nil && scene != currentScene
            let wouldOverflow = !lines.isEmpty
                && (lines.count >= maxLines || chars + cue.text.count > maxSourceChars)
            if gap >= sceneGapMs || wouldOverflow || leftScene { flush() }
            if lines.isEmpty { currentScene = scene }
            indices.append(cue.index)
            lines.append(cue.text)
            if let b = bindingsByCueIndex[cue.index] { bindings.append(b) }
            chars += cue.text.count
            previousEnd = cue.endMs
        }
        flush()
        return out
    }
}

public enum ScenePacketTranslationError: Error, CustomStringConvertible {
    case invalidPacket(String)

    public var description: String {
        switch self {
        case .invalidPacket(let reason): return "Invalid scene-packet translation: \(reason)"
        }
    }
}

public struct ScenePacketTranslationStats: Sendable {
    public var requests: Int = 0
    public var splits: Int = 0
    public var numberedFallbacks: Int = 0
    /// Lines served from CueTranslationCache — the work this run did NOT have to do.
    public var cachedLines: Int = 0
    public var fallbackFailures: Int = 0
    /// `"unverified@<cueIndex>"` for lines that still failed fidelity validation after
    /// a repair re-ask (kept as best candidate, surfaced for QA).
    public var qaFlags: [String] = []

    public init() {}
}

public struct ScenePacketTranslationOutput: Sendable {
    public var translationsByCueIndex: [Int: String]
    public var stats: ScenePacketTranslationStats

    public init(translationsByCueIndex: [Int: String], stats: ScenePacketTranslationStats) {
        self.translationsByCueIndex = translationsByCueIndex
        self.stats = stats
    }
}

/// Output schema the scene-packet translator asks the model to emit.
///
/// The model decodes one of these per packet. Because decode (token generation) is
/// the memory-bandwidth wall (~22 tok/s on the 12B; prefill is ~8x faster), the
/// schema's per-line token overhead is a FIRST-ORDER cost, not a formatting detail:
///   - `.json`  emits `{"i":1,"sg":"m","ag":"u","t":"…"}` per line — the gender
///              bookkeeping (sg/ag) and JSON punctuation roughly DOUBLE the output
///              tokens vs the translation alone (measured 1.95x on a 24-line scene).
///   - `.lean`  emits only `<n>. <translation>` — gender/speaker context is pushed
///              entirely into the (cheap, cached) PROMPT, so the model decodes ONLY
///              the Hebrew. Same per-line scene context, ~half the output tokens.
/// Both give the model the full continuous scene + known character genders as
/// input, so gendered grammar / pronouns / cross-line consistency are unchanged.
public enum ScenePacketFormat: String, Sendable, Codable {
    case json
    case lean
}

/// Fuses attribution and translation into one validated scene-packet request.
///
/// The target LLM remains the authority. We only accept packets that produce one
/// translated entry per source line. Bad packets are recursively split; callers
/// can fall back to the legacy path if this still fails.
public struct ScenePacketTranslator: Sendable {
    private let chat: LlamaChat
    private let format: ScenePacketFormat
    /// Spoken/source language code (e.g. "en"), declared in the prompt so the model
    /// translates FROM the right language and never "re-translates" already-target text.
    /// Nil ⇒ the model infers it from the text.
    private let sourceLang: String?
    /// User-forced/locked name translations (SOURCE name → TARGET name). Injected as a
    /// glossary so the model renders these names EXACTLY and identically everywhere.
    private let nameGlossary: [String: String]

    public init(chat: LlamaChat, format: ScenePacketFormat = .json,
                sourceLang: String? = nil, nameGlossary: [String: String] = [:]) {
        self.chat = chat
        self.format = format
        self.sourceLang = sourceLang
        self.nameGlossary = nameGlossary
    }

    /// The "NAME GLOSSARY" prompt block (or empty when there are no locked names).
    private func glossaryBlock() -> String? {
        guard !nameGlossary.isEmpty else { return nil }
        let list = nameGlossary.sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value)" }
            .joined(separator: "; ")
        return "NAME GLOSSARY (translate these names EXACTLY as shown, identically every "
            + "time, never vary or re-spell them): \(list)"
    }

    /// "from English into Hebrew" / "into Hebrew" — the translation direction clause.
    /// Drops the FROM half when the source is unknown or equals the target.
    static func direction(source: String?, target: String) -> String {
        let into = "into \(LanguageName.of(target))"
        guard let s = source, !s.isEmpty,
              LanguageName.of(s) != LanguageName.of(target) else { return into }
        return "from \(LanguageName.of(s)) \(into)"
    }

    /// - `cached`: cueIndex → an already-correct translation (CueTranslationCache).
    ///   A packet whose lines are ALL cached costs nothing at all; a packet with
    ///   some cached lines asks the model only for the rest, handing it the whole
    ///   scene as (prompt-cached) context. This is what makes correcting one
    ///   character's gender a seconds-long re-translation instead of a full rerun.
    public func translate(
        packets: [ScenePacket],
        targetLang: String,
        knownCharacters: [String: String] = [:],
        cached: [Int: String] = [:],
        onProgress: @Sendable (Double) -> Void = { _ in },
        onPacketTranslated: (@Sendable ([Int: String]) -> Void)? = nil
    ) async throws -> ScenePacketTranslationOutput {
        var translations: [Int: String] = [:]
        var stats = ScenePacketTranslationStats()
        let total = max(packets.count, 1)

        for (i, packet) in packets.enumerated() where !packet.isEmpty {
            // Whole packet already translated under the same inputs — no request.
            let hits = packet.cueIndices.compactMap { cached[$0] }
            if hits.count == packet.cueIndices.count {
                stats.cachedLines += hits.count
                for (k, cueIndex) in packet.cueIndices.enumerated() {
                    translations[cueIndex] = hits[k]
                }
                onProgress(Double(i + 1) / Double(total))
                continue
            }
            stats.cachedLines += hits.count
            let result = try await translatePacket(
                packet,
                targetLang: targetLang,
                knownCharacters: knownCharacters,
                cached: cached,
                stats: &stats
            )
            translations.merge(result) { current, _ in current }
            onPacketTranslated?(result)
            onProgress(Double(i + 1) / Double(total))
        }
        return ScenePacketTranslationOutput(translationsByCueIndex: translations, stats: stats)
    }

    private func translatePacket(
        _ packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String],
        cached: [Int: String] = [:],
        stats: inout ScenePacketTranslationStats
    ) async throws -> [Int: String] {
        // LEAN: ask for `<n>. <translation>` only — no JSON, no sg/ag echo. The
        // model decodes ~half the tokens of the JSON schema for the same scene.
        if format == .lean {
            return try await translateLeanPacket(
                packet, targetLang: targetLang, knownCharacters: knownCharacters,
                cached: cached, stats: &stats)
        }

        stats.requests += 1
        let prompt = buildPrompt(packet: packet, targetLang: targetLang, knownCharacters: knownCharacters)
        let sourceChars = packet.lines.reduce(0) { $0 + $1.count }
        let maxTokens = max(500, min(1_100, sourceChars + packet.lines.count * 20 + 280))
        let raw = try await chat.complete(
            system: nil,
            user: prompt,
            maxTokens: maxTokens,
            temperature: 0.2
        )

        if let parsed = Self.parseTranslations(raw, cueIndices: packet.cueIndices) {
            return parsed
        }

        guard packet.lines.count > 6 else {
            return try await translateNumberedFallback(
                packet,
                targetLang: targetLang,
                knownCharacters: knownCharacters,
                stats: &stats,
                invalidRaw: raw
            )
        }

        return try await splitAndTranslate(
            packet, targetLang: targetLang, knownCharacters: knownCharacters, stats: &stats)
    }

    /// Lean translation of one packet with TARGETED REPAIR.
    ///
    /// The model occasionally drops a line (usually the last, after emitting its END
    /// marker early) or merges two. Splitting the packet to recover would re-decode
    /// every already-good line — the dominant cost. Instead we keep what parsed and
    /// re-ask ONLY for the missing line numbers, handing the whole scene back as
    /// context (its prefix is prompt-cached, so the re-ask is almost pure decode of
    /// just the missing lines). Splitting is the last resort for a fully garbled packet.
    private func translateLeanPacket(
        _ packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String],
        cached: [Int: String] = [:],
        stats: inout ScenePacketTranslationStats
    ) async throws -> [Int: String] {
        // Lines already translated under identical inputs are seeded straight in;
        // only the rest are asked for. A partially-cached packet therefore takes the
        // targeted-repair path below rather than a full re-decode of the scene.
        let seeded = packet.cueIndices.map { cached[$0] ?? "" }
        var parsed: [String]
        if seeded.contains(where: { !$0.isEmpty }) {
            parsed = seeded
        } else {
            stats.requests += 1
            let prompt = buildNumberedFallbackPrompt(
                packet: packet, targetLang: targetLang, knownCharacters: knownCharacters)
            let raw = try await chat.complete(
                system: nil, user: prompt,
                maxTokens: Self.leanMaxTokens(packet), temperature: 0.2)
            parsed = DictaLMTranslator.parseNumbered(raw, expected: packet.lines.count)
        }
        var missing = Self.missingLocals(parsed)

        // Pass 1: re-ask only the dropped lines, full scene as (cached) context.
        if !missing.isEmpty {
            stats.numberedFallbacks += 1
            stats.requests += 1
            let repairPrompt = buildLeanRepairPrompt(
                packet: packet, missingLocal0: missing,
                targetLang: targetLang, knownCharacters: knownCharacters)
            let repairRaw = try await chat.complete(
                system: nil, user: repairPrompt,
                maxTokens: max(120, missing.count * 40 + 60), temperature: 0.2)
            let repaired = DictaLMTranslator.parseNumbered(repairRaw, expected: packet.lines.count)
            for local0 in missing where !repaired[local0].isEmpty { parsed[local0] = repaired[local0] }
            missing = Self.missingLocals(parsed)
        }

        // Still missing (rare) and the packet is large → split that remainder. A tiny
        // packet that still won't parse is a genuine failure callers can fall back on.
        if !missing.isEmpty {
            guard packet.lines.count > 4 else {
                throw ScenePacketTranslationError.invalidPacket(
                    "lean packet (\(packet.lines.count) lines) left \(missing.count) unresolved after repair")
            }
            stats.fallbackFailures += missing.count
            let split = try await splitAndTranslate(
                packet, targetLang: targetLang, knownCharacters: knownCharacters, stats: &stats)
            // splitAndTranslate returns by cueIndex; fill only what's still missing.
            for local0 in missing {
                if let t = split[packet.cueIndices[local0]] { parsed[local0] = t }
            }
            missing = Self.missingLocals(parsed)
            guard missing.isEmpty else {
                throw ScenePacketTranslationError.invalidPacket(
                    "lean packet: \(missing.count) lines unresolved after split")
            }
        }

        // FIDELITY VALIDATION: re-ask lines whose translation looks unfaithful
        // (untranslated, dropped/added content, looped, lost a number). Conservative
        // checks → rare re-asks. Residual failures are kept and flagged for QA.
        try await validateAndRepair(
            &parsed, packet: packet, targetLang: targetLang,
            knownCharacters: knownCharacters, stats: &stats)

        var out: [Int: String] = [:]
        for (i, text) in parsed.enumerated() { out[packet.cueIndices[i]] = text }
        return out
    }

    /// Deterministically check each translated line against its source and re-ask the
    /// ones that look unfaithful, using the same cheap scene-context repair as dropped
    /// lines. Only a repair that itself PASSES validation replaces the original (never
    /// swap a suspect line for another bad one). Residual failures are flagged in qaFlags.
    private func validateAndRepair(
        _ parsed: inout [String],
        packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String],
        stats: inout ScenePacketTranslationStats
    ) async throws {
        func suspects(_ lines: [String]) -> [Int] {
            lines.enumerated().compactMap { i, t in
                t.isEmpty ? nil
                    : (TranslationOutputValidator.isValid(
                        source: packet.lines[i], translation: t, targetLang: targetLang) ? nil : i)
            }
        }
        let suspect = suspects(parsed)
        guard !suspect.isEmpty else { return }

        stats.numberedFallbacks += 1
        stats.requests += 1
        let prompt = buildLeanRepairPrompt(
            packet: packet, missingLocal0: suspect,
            targetLang: targetLang, knownCharacters: knownCharacters)
        let raw = try await chat.complete(
            system: nil, user: prompt,
            maxTokens: max(120, suspect.count * 40 + 60), temperature: 0.2)
        let repaired = DictaLMTranslator.parseNumbered(raw, expected: packet.lines.count)
        for local0 in suspect where !repaired[local0].isEmpty
            && TranslationOutputValidator.isValid(
                source: packet.lines[local0], translation: repaired[local0], targetLang: targetLang) {
            parsed[local0] = repaired[local0]
        }

        // Residual: keep the best candidate we have, but surface it for QA.
        for local0 in suspects(parsed) {
            stats.qaFlags.append("unverified@\(packet.cueIndices[local0])")
        }
    }

    private static func leanMaxTokens(_ packet: ScenePacket) -> Int {
        let sourceChars = packet.lines.reduce(0) { $0 + $1.count }
        // ~20 output tokens/line of Hebrew measured; give headroom but cap for safety.
        return max(220, min(1_600, sourceChars + packet.lines.count * 14 + 160))
    }

    private static func missingLocals(_ parsed: [String]) -> [Int] {
        parsed.enumerated().filter { $0.element.isEmpty }.map { $0.offset }
    }

    /// Re-ask prompt: same scene, but emit Hebrew ONLY for the still-missing line
    /// numbers. Output is just those lines, so the re-ask is cheap decode.
    private func buildLeanRepairPrompt(
        packet: ScenePacket,
        missingLocal0: [Int],
        targetLang: String,
        knownCharacters: [String: String]
    ) -> String {
        let wanted = missingLocal0.map { String($0 + 1) }.joined(separator: ", ")
        var parts: [String] = []
        parts.append("""
        You are an expert subtitle translator. Below is a continuous scene. Translate \
        \(Self.direction(source: sourceLang, target: targetLang)) ONLY the lines numbered: \(wanted), staying FAITHFUL to exactly \
        what each line says — convey its full meaning, add nothing, omit nothing, do not paraphrase. \
        Use the whole scene only to resolve speaker/addressee gender and ambiguous pronouns. \
        Output one numbered translation per requested line, in the form "<number>. <translation>". \
        No other lines, no notes.
        """)
        if !packet.bindings.isEmpty { parts.append(Self.bindingRules) }
        parts.append(Self.noHedgeRule)
        parts.append(contentsOf: contextBlocks(packet: packet, knownCharacters: knownCharacters))
        parts.append("--- SOURCE LINES ---")
        parts.append(contentsOf: sourceLineBlock(packet))
        parts.append("--- TRANSLATIONS (only \(wanted)) ---")
        return parts.joined(separator: "\n")
    }

    /// Halve a packet and translate each half independently, then merge. Shared by
    /// both formats: smaller scenes are easier for the model to keep aligned.
    private func splitAndTranslate(
        _ packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String],
        stats: inout ScenePacketTranslationStats
    ) async throws -> [Int: String] {
        stats.splits += 1
        let mid = packet.lines.count / 2
        let left = packet.slice(0 ..< mid)
        let right = packet.slice(mid ..< packet.lines.count)
        var out = try await translatePacket(
            left,
            targetLang: targetLang,
            knownCharacters: knownCharacters,
            stats: &stats
        )
        let rightOut = try await translatePacket(
            right,
            targetLang: targetLang,
            knownCharacters: knownCharacters,
            stats: &stats
        )
        out.merge(rightOut) { current, _ in current }
        return out
    }

    private func translateNumberedFallback(
        _ packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String],
        stats: inout ScenePacketTranslationStats,
        invalidRaw: String
    ) async throws -> [Int: String] {
        stats.numberedFallbacks += 1
        stats.requests += 1
        let prompt = buildNumberedFallbackPrompt(
            packet: packet,
            targetLang: targetLang,
            knownCharacters: knownCharacters
        )
        let sourceChars = packet.lines.reduce(0) { $0 + $1.count }
        let raw = try await chat.complete(
            system: nil,
            user: prompt,
            maxTokens: max(220, min(620, sourceChars + 140)),
            temperature: 0.2
        )
        let parsed = DictaLMTranslator.parseNumbered(raw, expected: packet.lines.count)
        guard parsed.count == packet.lines.count, !parsed.contains(where: { $0.isEmpty }) else {
            stats.fallbackFailures += 1
            let sample = invalidRaw.prefix(180).replacingOccurrences(of: "\n", with: " ")
            throw ScenePacketTranslationError.invalidPacket(
                "packet with \(packet.lines.count) lines failed JSON and numbered fallback; raw=\(sample)"
            )
        }
        var out: [Int: String] = [:]
        for (i, text) in parsed.enumerated() {
            out[packet.cueIndices[i]] = text
        }
        return out
    }


    // MARK: - Deterministic bindings in the prompt

    /// `"[SPEAKER: Maya (F)] [TO: Danny (M)] "` — the resolved facts for one line.
    ///
    /// We hand the model the ANSWER rather than asking it to infer who is talking to
    /// whom, because the ladder (AddresseeResolver) resolves it deterministically
    /// from the dialogue and the model does not. Returns "" when nothing was
    /// resolved, so an unbound packet reads exactly as it did before.
    static func bindingTag(_ b: DialogueBinding) -> String {
        var tags: [String] = []
        if let speaker = b.speaker {
            tags.append("[SPEAKER: \(speaker) (\(mark(b.speakerGender)))]")
        }
        switch b.method {
        case .groupAddress:
            tags.append("[TO: a group (\(mark(b.addresseeGender)) plural)]")
        case .unknown:
            tags.append("[TO: unknown - use gender-neutral phrasing]")
        default:
            if let name = b.addressee {
                tags.append("[TO: \(name) (\(mark(b.addresseeGender)))]")
            } else {
                tags.append("[TO: unknown - use gender-neutral phrasing]")
            }
        }
        return tags.isEmpty ? "" : tags.joined(separator: " ") + " "
    }

    private static func mark(_ g: Gender) -> String {
        switch g {
        case .m: return "M"
        case .f: return "F"
        case .nb, .unknown: return "?"
        }
    }

    /// The rules that make the tags binding — only emitted when a packet has them.
    static let bindingRules = """
    - Each line is prefixed with [SPEAKER: name (M/F)] and [TO: ...]. These are \
    RESOLVED FACTS about the scene, not guesses: inflect 1st-person forms for the \
    SPEAKER and 2nd-person forms (verbs, "you", imperatives) for the addressee in [TO], \
    by both gender and number. Use plural 2nd-person forms ONLY for [TO: a group ...].
    - NEVER copy the tags into your output. Translate only the text after them.
    - [TO: unknown] means the dialogue does not determine the addressee. Rephrase the \
    line so NO gendered second-person form appears at all (use an infinitive, an \
    impersonal construction, or a noun phrase). Do not guess a gender.
    """

    /// Applies to every packet, bound or not: a hedge is never acceptable output.
    static let noHedgeRule = """
    - NEVER write two gendered forms together as a hedge - not with a slash \
    (\u{05D0}\u{05EA}/\u{05D0}\u{05EA}\u{05D4}) and not with brackets \
    (\u{05D9}\u{05D5}\u{05D3}\u{05E2}(\u{05EA})). Choose one form, or rephrase so \
    the distinction never arises.
    """

    /// Scene synopsis + character genders + glossary, in the order the model reads them.
    private func contextBlocks(packet: ScenePacket, knownCharacters: [String: String]) -> [String] {
        var parts: [String] = []
        if let synopsis = packet.synopsis, !synopsis.isEmpty {
            parts.append("SCENE: \(synopsis)")
        }
        if !knownCharacters.isEmpty {
            let list = knownCharacters.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("KNOWN CHARACTER GENDERS: \(list)")
        }
        if let g = glossaryBlock() { parts.append(g) }
        return parts
    }

    /// Numbered source lines, each prefixed with its resolved bindings.
    private func sourceLineBlock(_ packet: ScenePacket) -> [String] {
        packet.lines.enumerated().map { i, line in
            let tag = packet.binding(at: i).map(Self.bindingTag) ?? ""
            return "\(i + 1). \(tag)\(line)"
        }
    }

    func buildPrompt(
        packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String] = [:]
    ) -> String {
        var parts: [String] = []
        parts.append("""
        You are an expert subtitle translator. Translate this continuous scene \
        \(Self.direction(source: sourceLang, target: targetLang)), staying FAITHFUL to exactly what is said. Infer speaker and \
        addressee gender AND number from names, pronouns, turn-taking, and context — a vocative \
        name (the person addressed, e.g. "…, Mel Brooks!") fixes the addressee to that single \
        person's gender and SINGULAR forms; a recognizable real person keeps their real-world \
        gender. Apply gendered grammar correctly. Output ONLY compact JSON, no markdown.

        JSON schema:
        {"lines":[{"i":1,"sg":"m|f|u","ag":"m|f|u","t":"translation"}]}

        Rules:
        - Return exactly one object for each input line, same numeric i values.
        - "t" must contain only the translated subtitle text.
        - Translate the full meaning of each line: omit nothing, add nothing, do not paraphrase or soften.
        - Translate each line on its own; use the scene only for gender and ambiguous pronouns.
        - Write natural, idiomatic spoken \(LanguageName.of(targetLang)) (not word-for-word).
        - Do not copy timing, tags, notes, or explanations.
        - Keep glossary names consistent when known.
        - After the JSON object, output a newline followed by END.
        """)
        if !packet.bindings.isEmpty { parts.append(Self.bindingRules) }
        parts.append(Self.noHedgeRule)
        parts.append(contentsOf: contextBlocks(packet: packet, knownCharacters: knownCharacters))
        parts.append("--- SOURCE LINES ---")
        parts.append(contentsOf: sourceLineBlock(packet))
        parts.append("--- JSON ---")
        return parts.joined(separator: "\n")
    }

    private func buildNumberedFallbackPrompt(
        packet: ScenePacket,
        targetLang: String,
        knownCharacters: [String: String]
    ) -> String {
        var parts: [String] = []
        parts.append("""
        You are an expert subtitle translator. Translate each numbered line of this \
        continuous scene \(Self.direction(source: sourceLang, target: targetLang)), staying FAITHFUL to exactly what is said.

        Faithfulness rules:
        - Convey the full meaning of each line — never omit, shorten, soften, or censor it.
        - Add nothing that is not in the source — no explanations, filler, or invented words.
        - Do not paraphrase into a different statement; keep the speaker's actual words, tone, and intent.
        - Translate each line on its own. Use the surrounding lines ONLY to resolve speaker/addressee \
        gender, number, and ambiguous pronouns — never to move meaning between lines.
        - Gendered grammar: inflect 1st-person forms for the SPEAKER and 2nd-person forms \
        (verbs, "you", imperatives) for the ADDRESSEE, by both GENDER and NUMBER. A name used as \
        the one being addressed (a vocative, e.g. "…, Mel Brooks!") fixes the addressee: use that \
        single person's gender and SINGULAR forms — and a recognizable real person keeps their \
        real-world gender. Use plural "you" only when more than one person is actually addressed.
        - Keep proper names, numbers, and quoted text exact.
        - Write natural, idiomatic spoken \(LanguageName.of(targetLang)) (not word-for-word).

        Output exactly one numbered translation per input line, same order, in the form \
        "<number>. <translation>". No JSON, no notes.
        After the final numbered translation, output a newline followed by END.
        """)
        if !packet.bindings.isEmpty { parts.append(Self.bindingRules) }
        parts.append(Self.noHedgeRule)
        parts.append(contentsOf: contextBlocks(packet: packet, knownCharacters: knownCharacters))
        parts.append("--- SOURCE LINES ---")
        parts.append(contentsOf: sourceLineBlock(packet))
        parts.append("--- TRANSLATIONS ---")
        return parts.joined(separator: "\n")
    }

    static func parseTranslations(_ raw: String, cueIndices: [Int]) -> [Int: String]? {
        guard let data = extractJSONObject(raw)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = obj["lines"] as? [[String: Any]]
        else { return nil }

        guard lines.count == cueIndices.count else { return nil }
        var byLocalIndex: [Int: String] = [:]
        for item in lines {
            guard let i = intValue(item["i"]), i >= 1, i <= cueIndices.count else { return nil }
            guard let rawText = item["t"] as? String else { return nil }
            let text = DictaLMTranslator.cleanLine(rawText)
            guard !text.isEmpty else { return nil }
            byLocalIndex[i] = text
        }
        guard byLocalIndex.count == cueIndices.count else { return nil }

        var out: [Int: String] = [:]
        for local in 1 ... cueIndices.count {
            guard let text = byLocalIndex[local] else { return nil }
            out[cueIndices[local - 1]] = text
        }
        return out
    }

    private static func extractJSONObject(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              start <= end
        else { return nil }
        return String(raw[start ... end])
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
