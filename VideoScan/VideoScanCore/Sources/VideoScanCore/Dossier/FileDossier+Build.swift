// FileDossier+Build.swift (VideoScanCore/Dossier) — the pure builder: one
// stored record and its content's provenance assertions → the three layers.
// Every line names its source; a reading that is not there says why in
// words ("not transcribed yet", "no audio track"), never a blank — and a
// blank is never read as absence: an unprobed record's lines say "not
// probed yet", never "no audio track" (Codex 11/05).
//
// Floor (Rick's brief): nothing InspectorDossierView showed is lost — the
// inferred date (its range, confidence and written reason, or "none —
// reason"), the transcript (with its model), the scene captions per frame
// (with their model), the usable OCR dates (GH #402: degenerate reads are
// not evidence), the OCR text, and the dossier run's date and stack.
//
// Which reader ran (review 11/05): every channel is keyed on its OWN
// evidence, never the shared dossier footer (`dossierProcessedAt` is also
// stamped by the transcript-only and captions-only passes). See `Ran`.
//
// Rulings honoured here: a machine era is never a date and `era.none` is
// never an era (DECISIONS 2026-11-01); a machine claim is an `.observation`
// with its signer, never a `.fact`; the assertions' `confidence` column is
// never read (events_design rule 9).

import Foundation

extension FileDossier {

    /// The dossier of `record` (as the loader rebuilt it from catalog.sqlite)
    /// and its content's assertion rows. `unreadable` = why the stored
    /// analysis values could not be decoded (the record was rebuilt without them).
    /// `rickRole`: the content's current Provenance ▸ Set Role (Unknown when
    /// there is none) — an estimated provenance yields to it.
    public static func build(record r: VideoRecord, digest: String?, assertions: [CatalogRow.ProvenanceAssertionReading],
                             rickRole: ProvenanceRole = .unknown, unreadable: String? = nil, now: Date) -> FileDossier {
        let technical = technicalSection(r, now: now)
        let patterns = patternsSection(r, assertions: assertions, rickRole: rickRole, unreadable: unreadable)
        return FileDossier(fileID: r.id.uuidString, filename: r.filename, path: r.fullPath, digest: digest,
                           removed: r.removal != nil, technical: technical, patterns: patterns,
                           collection: Section(layer: .collection, summary: collectionComingNext, lines: []))
    }

    // MARK: Layer 1 — Technical

    static func technicalSection(_ r: VideoRecord, now: Date) -> Section {
        let facts = TechnicalFacts(record: r)
        if let why = notProbed(r) {
            var lines = [Line(label: "Probe", value: why, source: "ffprobe", standing: .missing)]
            if let m = r.dateModifiedRaw {
                lines.append(Line(label: "File modified", value: TechnicalReading.day(m),
                                  reading: "file-system date: the transfer/copy history only, never the shoot",
                                  source: "file system", standing: .fact))
            }
            return Section(layer: .technical, summary: why, lines: lines)
        }
        var lines = TechnicalReading.interpret(facts, now: now).map {
            Line(label: $0.label, value: $0.value, reading: $0.suggests, source: $0.source,
                 standing: $0.isInference ? .observation : .fact)
        }
        if facts.codec == "dvvideo" {
            let at = (lines.firstIndex { $0.label == "Audio" }).map { $0 + 1 } ?? lines.count
            lines.insert(dvClockLine, at: at)
        }
        var summary = TechnicalReading.oneLiner(facts)
        if let d = facts.duration { summary += " · " + TechnicalReading.durationWords(d) }
        return Section(layer: .technical, summary: summary, lines: lines)
    }

    /// Why there are no probe facts, or nil when there are.
    static func notProbed(_ r: VideoRecord) -> String? {
        switch r.streamTypeRaw {
        case "": return "not probed yet"
        case "ffprobe failed":
            let why = r.isPlayable.trimmingCharacters(in: .whitespaces)
            return "ffprobe could not read this file" + (why.isEmpty || why == "Yes" ? "" : " (\(why))")
        default: return nil
        }
    }

    /// Until the DV datecode analyzer lands (design §7 step 3).
    static let dvClockLine = Line(label: "DV clock", value: "not read yet",
                                  reading: "the DV clock reader is not built yet; until it is, a DV file's creation time is when it was copied, not shot",
                                  source: "DV clock", standing: .missing)

    // MARK: Layer 2 — Patterns & events

    /// What the stored stamps PROVE ran on this file, per reader.
    struct Ran {
        /// Why the streams are not known (never probed / the probe failed), in
        /// the Patterns lines' words; nil = probed. Codex 11/05: an unprobed
        /// record read as "no audio, no video" and its lines said "no audio
        /// track" / "no picture" with no evidence. Unknown reads as unknown.
        var streamsUnknown: String?
        var hasVideo: Bool
        var hasAudio: Bool
        /// The scene captioner: `caption_runs` (sceneCaptionModel / Date) — the full pass and Captions-only both write it.
        var captions: Bool
        /// The on-screen (OCR) reader runs only inside the FULL dossier pass
        /// (applyDossier), which stamps the run and the captions with ONE
        /// instant. The captions-only and transcript-only passes stamp the
        /// footer too (stampDossierProvenance), so the footer alone proves
        /// nothing; only a "vlm+whisper" footer at the captions' own instant
        /// can come from the full pass. A VLM-only full pass cannot be told
        /// apart from Captions-only, so it is "not known", never "none found".
        var ocr: Bool
        /// Words for "nothing stored" when the reader is not proven to have run.
        var ocrUnknownReason: String?

        init(_ r: VideoRecord) {
            streamsUnknown = FileDossier.streamsUnknown(r)
            hasVideo = r.streamTypeRaw == "Video+Audio" || r.streamTypeRaw == "Video only"
            hasAudio = r.streamTypeRaw == "Video+Audio" || r.streamTypeRaw == "Audio only"
            captions = r.sceneCaptionDate != nil || r.sceneCaptionModel != nil
            var full = false
            if let at = r.dossierProcessedAt, let captioned = r.sceneCaptionDate, let model = r.sceneCaptionModel,
               Int64(at.timeIntervalSince1970) == Int64(captioned.timeIntervalSince1970),
               r.dossierProcessedBy?.hasPrefix(model + "+") == true {
                full = true
            }
            ocr = full
            ocrUnknownReason = !full && captions
                ? "the scene captions ran, but no stamp shows the on-screen reader ran on this file (it stores nothing when it finds nothing)"
                : nil
        }

        /// The words for a channel that needs a picture (the probe's words when it did not tell).
        var noPicture: String {
            streamsUnknown ?? (hasAudio ? "no picture (audio only)" : "no picture (no audio or video stream)")
        }
        /// The words for a channel that needs sound.
        var noSound: String { streamsUnknown ?? "no audio track" }
    }

    static func patternsSection(_ r: VideoRecord, assertions: [CatalogRow.ProvenanceAssertionReading],
                                rickRole: ProvenanceRole = .unknown, unreadable: String?) -> Section {
        let ran = Ran(r)
        let verdict = EraVerdict(assertions)
        var lines: [Line] = [eraLine(verdict, userDate: r.userDate, ran: ran)]
        if let mine = userDateLine(r) { lines.append(mine) }
        lines.append(inferredDateLine(r))
        if let provenance = provenanceLine(r, assertions: assertions, rickRole: rickRole) { lines.append(provenance) }
        lines.append(sceneLine(r, ran: ran))
        lines.append(speechLine(r, ran: ran))
        lines.append(peopleLine(r))
        if let machine = recognizedLine(r) { lines.append(machine) }
        lines.append(ocrLine("On-screen dates", r.usableOCRDates, r, ran: ran, source: "burn-in reader"))
        if let burned = burnedInLine(assertions) { lines.append(burned) }
        lines.append(ocrLine("On-screen text", r.ocrText, r, ran: ran, source: "on-screen text reader"))
        lines.append(dossierRunLine(r))
        if let unreadable {
            lines.append(Line(label: "Stored analysis", value: "could not be read", reading: unreadable,
                              source: "catalog.sqlite", standing: .missing))
        }
        return Section(layer: .patterns, summary: patternsSummary(r, era: verdict), lines: lines)
    }

    /// Why the streams are unknown, in words ("not probed yet", "probe failed: <why>"); nil = probed.
    /// Which records are unprobed is `notProbed`'s rule; these are the short words.
    static func streamsUnknown(_ r: VideoRecord) -> String? {
        guard notProbed(r) != nil else { return nil }
        if r.streamTypeRaw.isEmpty { return "not probed yet" }
        let why = r.isPlayable.trimmingCharacters(in: .whitespaces)
        return "probe failed" + (why.isEmpty || why == "Yes" ? "" : ": \(why)")
    }

    /// "1990–1995 (8B, unconfirmed) · 12 scenes described · speech · 2 people", or "nothing analyzed yet".
    /// The era part says what the analyzer concluded even when it found no era
    /// (Codex 11/05: "nothing analyzed yet" was said over an era.none or a give-up).
    static func patternsSummary(_ r: VideoRecord, era: EraVerdict) -> String {
        var parts: [String] = []
        switch era {
        case .era(let e, _): parts.append("\(e.rangeText) (\(e.modelShortName), unconfirmed)")
        case .rejected: parts.append("era rejected by you")
        case .none(_, let gaveUp): parts.append(gaveUp ? "era: given up after \(EraAttemptStore.maxTries) tries" : "no usable era")
        case .unreadable: parts.append("era unreadable")
        case .notYet: break
        }
        if !r.sceneCaptions.isEmpty { parts.append(count(r.sceneCaptions.count, "scene") + " described") }
        if let t = r.audioTranscript { parts.append(t.isEmpty ? "no speech" : "speech") }
        let people = r.confirmedByUserPeople.count
        if people > 0 { parts.append(count(people, "person", plural: "people")) }
        return parts.isEmpty ? "nothing analyzed yet" : parts.joined(separator: " · ")
    }

    // MARK: Era

    /// What the era analyzers' rows say about this content — ONE classification,
    /// read by the Era line and the summary (they cannot disagree). Order: an
    /// era stands; else Rick rejected one; else `era.none` (given up or not);
    /// else an unreadable fused value; else nothing yet.
    enum EraVerdict {
        case era(MachineEra, others: [MachineEra])
        case rejected(CatalogRow.ProvenanceAssertionReading)
        case none(CatalogRow.ProvenanceAssertionReading, gaveUp: Bool)
        case unreadable(CatalogRow.ProvenanceAssertionReading)
        case notYet

        init(_ assertions: [CatalogRow.ProvenanceAssertionReading]) {
            let eras = MachineEraResolver.eras(fromRowsOfOneSubject: assertions)
            if let first = eras.first {
                self = .era(first, others: Array(eras.dropFirst()))
            } else if let rejected = FileDossier.rejectedEra(assertions) {
                self = .rejected(rejected)
            } else if let none = FileDossier.newest(assertions, field: "era.none") {
                self = .none(none, gaveUp: MachineEraResolver.object(none.evidenceJSON)["gaveUp"] as? Bool ?? false)
            } else if let bad = FileDossier.live(assertions, field: MachineEraResolver.fusedField).max(by: { $0.seq < $1.seq }) {
                self = .unreadable(bad)
            } else {
                self = .notYet
            }
        }
    }

    static func eraLine(_ verdict: EraVerdict, userDate: String?, ran: Ran) -> Line {
        switch verdict {
        case .era(let era, let others):
            var reading: String?
            if let year = MachineEraResolver.rickYear(userDate) {
                reading = MachineEraResolver.closeEnough(era: era, rickYear: year) ? "agrees with your date (\(year))"
                    : "disagrees with your date (\(year))"
            }
            return Line(label: "Era", value: era.rangeText, reading: reading, source: "\(era.modelShortName) era, unconfirmed",
                        evidence: MachineEraResolver.inspectorHelp(era: era, others: others), standing: .observation)
        case .rejected(let rejected):
            // Rick's veto: the analyzer DID reach the file; he refused what it said.
            return Line(label: "Era", value: "rejected by you",
                        reading: "the \(MachineEraResolver.modelShortName(by: rejected.by)) analyzer said \(rejected.value.replacingOccurrences(of: "-", with: "–")); you rejected it",
                        source: "Rick", evidence: "Era \(rejected.value) by \(rejected.by), \(eventDay(rejected.at)); rejected by you.", standing: .fact)
        case .none(let none, let gaveUp):
            // `era.none` is the analyzer's "looked, nothing usable" — words, never an era.
            let reason = MachineEraResolver.object(none.evidenceJSON)["reason"] as? String
            return Line(label: "Era", value: gaveUp ? "no era: the analyzer gave up" : "no usable era", reading: reason,
                        source: "\(MachineEraResolver.modelShortName(by: none.by)) era",
                        evidence: "By \(none.by), \(eventDay(none.at))." + (reason.map { " \($0)" } ?? ""),
                        standing: gaveUp ? .missing : .nothingFound)
        case .unreadable(let bad):
            // A fused row whose value is not a year range: stored, but unreadable.
            return Line(label: "Era", value: "unreadable", reading: "the stored era value \"\(bad.value)\" is not a year range",
                        source: "\(MachineEraResolver.modelShortName(by: bad.by)) era", standing: .missing)
        case .notYet:
            if let unknown = ran.streamsUnknown {
                return Line(label: "Era", value: unknown, reading: "the era analyzer reads only files probed as video",
                            source: "era analyzer", standing: .missing)
            }
            return Line(label: "Era", value: ran.hasVideo ? "not analyzed yet" : "no picture to read",
                        reading: ran.hasVideo ? "VideoScan Background has not reached this file" : nil,
                        source: "era analyzer", standing: .missing)
        }
    }

    /// The newest machine `era.fused` row (a readable range) that Rick rejected afterwards.
    static func rejectedEra(_ rows: [CatalogRow.ProvenanceAssertionReading]) -> CatalogRow.ProvenanceAssertionReading? {
        let field = MachineEraResolver.fusedField
        return rows.filter { f in
            f.field == field && f.state == "inferred" && MachineEraResolver.isMachine(f.by) && MachineEraResolver.range(f.value) != nil
                && MachineEraResolver.isRejected(f, among: rows)
        }.max { $0.seq < $1.seq }
    }

    static func userDateLine(_ r: VideoRecord) -> Line? {
        guard let date = r.userDate else { return nil }
        return Line(label: "Your date", value: date, reading: r.userDateConfidence, source: "Rick", standing: .fact)
    }

    // MARK: Inferred date (the triangulated answer; GH #201)

    static func inferredDateLine(_ r: VideoRecord) -> Line {
        let source = "date triangulator" + (r.inferredDateSource.map { " · \($0)" } ?? "")
        if let date = r.inferredRecordDate {
            let value = r.effectiveInferredDateRange?.displayString ?? TechnicalReading.day(date)
            return Line(label: "Inferred date", value: value, reading: r.inferredDateConfidence.map(confidenceWords),
                        source: source, evidence: nonEmpty(r.inferredDateReason), standing: .observation)
        }
        if let reason = nonEmpty(r.inferredDateReason) {
            return Line(label: "Inferred date", value: "none", reading: reason, source: source, standing: .nothingFound)
        }
        return Line(label: "Inferred date", value: "not inferred yet", source: "date triangulator", standing: .missing)
    }

    /// "62 % confidence (fair)" — the old badge's buckets, in words (no colour).
    static func confidenceWords(_ value: Float) -> String {
        let label = value >= 0.85 ? "strong" : (value >= 0.5 ? "fair" : "weak")
        return String(format: "%.0f %% confidence (%@)", value * 100, label)
    }

    // MARK: Provenance (estimated or confirmed; DECISIONS 2026-11-10)

    /// What this content is, as ProvenanceResolver reads its rows: an
    /// `.observation` ("estimated, unconfirmed") until Rick confirms, then his
    /// `.fact`. No estimate, or one he rejected → no line; and Rick's own
    /// Set Role wins here as on every surface (`ProvenanceResolver.visible`):
    /// another role → no line, Unknown → provisional again. The year is the
    /// year folder the archive filed THIS row's file under (a row outside
    /// the archive has none) and the capture month its embedded creation
    /// date — each omitted when unknown, never invented. An alternate
    /// capture does not name its master here: this builder reads one file.
    static func provenanceLine(_ r: VideoRecord, assertions: [CatalogRow.ProvenanceAssertionReading],
                               rickRole: ProvenanceRole = .unknown) -> Line? {
        guard let stands = ProvenanceResolver.estimate(fromRowsOfOneSubject: assertions),
              let estimate = ProvenanceResolver.visible(stands, rickRole: rickRole),
              let sentence = ProvenanceResolver.sentence(
                estimate, year: ProvenanceResolver.tapeYear(archivePath: r.fullPath, captured: r.embeddedCreationDate),
                captured: r.embeddedCreationDate,
                technical: .init(videoCodec: r.videoCodec, resolution: r.resolution, bitDepth: r.bitDepth)) else { return nil }
        return Line(label: "Provenance", value: sentence,
                    reading: estimate.isConfirmed ? "confirmed by you" : "estimated, unconfirmed",
                    source: estimate.isConfirmed ? "Rick" : "catalog rule, unconfirmed",
                    evidence: ProvenanceResolver.evidenceWords(fromRowsOfOneSubject: assertions),
                    standing: estimate.isConfirmed ? .fact : .observation)
    }

    // MARK: Captions, OCR, transcript

    static func sceneLine(_ r: VideoRecord, ran: Ran) -> Line {
        let model = r.sceneCaptionModel ?? "VLM"
        let evidence = r.sceneCaptionDate.map { "Captioned by \(model) on \(TechnicalReading.dayAndTime($0))." }
        guard !r.sceneCaptions.isEmpty else {
            if ran.captions {
                return Line(label: "Scene", value: "no scenes described", source: model, evidence: evidence, standing: .nothingFound)
            }
            return Line(label: "Scene", value: ran.hasVideo ? "not described yet" : ran.noPicture,
                        source: "scene captions", standing: .missing)
        }
        return Line(label: "Scene", value: count(r.sceneCaptions.count, "frame") + " described",
                    reading: r.sceneCaptions.first.map { String($0.text.prefix(120)) }, source: model,
                    evidence: evidence, standing: .observation, body: r.sceneCaptions.map { TimedText(at: $0.timestamp, text: $0.text) })
    }

    static func speechLine(_ r: VideoRecord, ran: Ran) -> Line {
        let model = r.audioTranscriptModel ?? "Whisper"
        guard let text = r.audioTranscript else {
            return Line(label: "Speech", value: ran.hasAudio ? "not transcribed yet" : ran.noSound, source: "transcript", standing: .missing)
        }
        let evidence = r.audioTranscriptDate.map { "Transcribed by \(model) on \(TechnicalReading.dayAndTime($0))." }
        if text.isEmpty {     // '' = Whisper ran and heard no speech (transcripts table)
            return Line(label: "Speech", value: "no speech found", source: model, evidence: evidence, standing: .nothingFound)
        }
        return Line(label: "Speech", value: "“" + String(text.prefix(80)) + (text.count > 80 ? "…”" : "”"),
                    reading: "\(text.count) characters", source: model, evidence: evidence, standing: .observation,
                    body: [TimedText(at: nil, text: text)])
    }

    /// The on-screen dates / text line. "none found" only when the reader is
    /// PROVEN to have run (Ran.ocr); otherwise it says what is known.
    static func ocrLine(_ label: String, _ reads: [SceneCaption], _ r: VideoRecord, ran: Ran, source: String) -> Line {
        guard reads.isEmpty else {
            return Line(label: label, value: count(reads.count, "read"), reading: reads.first?.text,
                        source: r.sceneCaptionModel ?? "VLM", standing: .observation,
                        body: reads.map { TimedText(at: $0.timestamp, text: $0.text) })
        }
        if !ran.hasVideo { return Line(label: label, value: ran.noPicture, source: source, standing: .missing) }
        if ran.ocr { return Line(label: label, value: "none found", source: r.sceneCaptionModel ?? "VLM", standing: .nothingFound) }
        if let why = ran.ocrUnknownReason { return Line(label: label, value: "not known", reading: why, source: source, standing: .missing) }
        return Line(label: label, value: "not read yet", source: source, standing: .missing)
    }

    /// The era job's `ocr.date` observations (8B burn-in reads), newest first.
    static func burnedInLine(_ assertions: [CatalogRow.ProvenanceAssertionReading]) -> Line? {
        let rows = live(assertions, field: "ocr.date").sorted { $0.seq > $1.seq }
        guard let first = rows.first else { return nil }
        var values: [String] = []
        for row in rows where !values.contains(row.value) { values.append(row.value) }
        let body = rows.map { row -> TimedText in
            TimedText(at: MachineEraResolver.object(row.evidenceJSON)["atS"] as? Double, text: "\(row.value) — \(row.by), \(eventDay(row.at))")
        }
        return Line(label: "Burned-in date", value: values.joined(separator: ", "),
                    source: "\(MachineEraResolver.modelShortName(by: first.by)) date reader, unconfirmed",
                    evidence: "Dates the model read off the picture. A reading, never a date of the file.",
                    standing: .observation, body: body)
    }

    // MARK: People

    static func peopleLine(_ r: VideoRecord) -> Line {
        let names = r.confirmedByUserPeople.map(\.name)
        guard !names.isEmpty else { return Line(label: "People", value: "none confirmed", source: "Rick", standing: .missing) }
        return Line(label: "People", value: "\(names.count) confirmed: " + names.joined(separator: ", "), source: "Rick", standing: .fact)
    }

    static func recognizedLine(_ r: VideoRecord) -> Line? {
        let detected = r.detectedPeople, suspected = r.suspectedPeople
        guard !detected.isEmpty || !suspected.isEmpty else { return nil }
        return Line(label: "Recognized", value: detected.isEmpty ? "none" : detected.joined(separator: ", "),
                    reading: suspected.isEmpty ? nil : "suspected: " + suspected.joined(separator: ", "),
                    source: "face recognition, unconfirmed", standing: .observation)
    }

    // MARK: The dossier run (the old provenance footer)

    static func dossierRunLine(_ r: VideoRecord) -> Line {
        guard let at = r.dossierProcessedAt else {
            return Line(label: "Dossier run", value: "not run yet", source: "dossier pipeline", standing: .missing)
        }
        // The old footer's date AND time of day, in the local zone (a wall-clock event on this Mac).
        let when = TechnicalReading.dayAndTime(at)
        return Line(label: "Dossier run", value: when, source: r.dossierProcessedBy ?? "dossier pipeline",
                    evidence: r.dossierProcessedBy.map { "Processed \(when) by \($0)." }, standing: .fact)
    }

    // MARK: Helpers

    /// Machine `inferred` rows of `field` that Rick has not rejected since (same value).
    static func live(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> [CatalogRow.ProvenanceAssertionReading] {
        rows.filter { row in
            row.field == field && row.state == "inferred" && MachineEraResolver.isMachine(row.by)
                && !MachineEraResolver.isRejected(row, among: rows)
        }
    }

    static func newest(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> CatalogRow.ProvenanceAssertionReading? {
        live(rows, field: field).max { $0.seq < $1.seq }
    }

    /// A row's `at` (when the helper observed it, on this Mac) as a local day.
    static func eventDay(_ at: Int64) -> String { TechnicalReading.day(Date(timeIntervalSince1970: TimeInterval(at))) }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? noun : (plural ?? noun + "s"))
    }
}
