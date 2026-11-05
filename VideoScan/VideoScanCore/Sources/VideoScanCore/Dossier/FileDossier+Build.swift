// FileDossier+Build.swift (VideoScanCore/Dossier) — the pure builder: one
// stored record and its content's provenance assertions → the three layers.
// Every line names its source; a reading that is not there says why in
// words ("not transcribed yet", "no audio track"), never a blank.
//
// Floor (Rick's brief): nothing InspectorDossierView showed is lost — the
// inferred date (its range, confidence and written reason, or "none —
// reason"), the transcript (with its model), the scene captions per frame
// (with their model), the usable OCR dates (GH #402: degenerate reads are
// not evidence), the OCR text, and the dossier run's date and stack.
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
    public static func build(record r: VideoRecord, digest: String?, assertions: [CatalogRow.ProvenanceAssertionReading],
                             unreadable: String? = nil, now: Date) -> FileDossier {
        let technical = technicalSection(r, now: now)
        let patterns = patternsSection(r, assertions: assertions, unreadable: unreadable)
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
            Line(label: $0.label, value: $0.value, reading: $0.suggests, source: $0.source, standing: .fact)
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

    static func patternsSection(_ r: VideoRecord, assertions: [CatalogRow.ProvenanceAssertionReading], unreadable: String?) -> Section {
        let hasVideo = r.streamTypeRaw == "Video+Audio" || r.streamTypeRaw == "Video only"
        let hasAudio = r.streamTypeRaw == "Video+Audio" || r.streamTypeRaw == "Audio only"
        let eras = MachineEraResolver.eras(fromRowsOfOneSubject: assertions)
        var lines: [Line] = [eraLine(eras.first, others: Array(eras.dropFirst()), assertions: assertions, userDate: r.userDate, hasVideo: hasVideo)]
        if let mine = userDateLine(r) { lines.append(mine) }
        lines.append(inferredDateLine(r))
        lines.append(sceneLine(r, hasVideo: hasVideo))
        lines.append(speechLine(r, hasAudio: hasAudio))
        lines.append(peopleLine(r))
        if let machine = recognizedLine(r) { lines.append(machine) }
        lines.append(ocrDatesLine(r, hasVideo: hasVideo))
        if let burned = burnedInLine(assertions) { lines.append(burned) }
        lines.append(ocrTextLine(r, hasVideo: hasVideo))
        lines.append(dossierRunLine(r))
        if let unreadable {
            lines.append(Line(label: "Stored analysis", value: "could not be read", reading: unreadable,
                              source: "catalog.sqlite", standing: .missing))
        }
        return Section(layer: .patterns, summary: patternsSummary(r, era: eras.first), lines: lines)
    }

    /// "1990–1995 (8B, unconfirmed) · 12 scenes described · speech · 2 people", or "nothing analyzed yet".
    static func patternsSummary(_ r: VideoRecord, era: MachineEra?) -> String {
        var parts: [String] = []
        if let era { parts.append("\(era.rangeText) (\(era.modelShortName), unconfirmed)") }
        if !r.sceneCaptions.isEmpty { parts.append(count(r.sceneCaptions.count, "scene") + " described") }
        if let t = r.audioTranscript { parts.append(t.isEmpty ? "no speech" : "speech") }
        let people = r.confirmedByUserPeople.count
        if people > 0 { parts.append(count(people, "person", plural: "people")) }
        return parts.isEmpty ? "nothing analyzed yet" : parts.joined(separator: " · ")
    }

    // MARK: Era

    static func eraLine(_ era: MachineEra?, others: [MachineEra], assertions: [CatalogRow.ProvenanceAssertionReading],
                        userDate: String?, hasVideo: Bool) -> Line {
        if let era {
            var reading: String?
            if let year = MachineEraResolver.rickYear(userDate) {
                reading = MachineEraResolver.closeEnough(era: era, rickYear: year) ? "agrees with your date (\(year))"
                    : "disagrees with your date (\(year))"
            }
            return Line(label: "Era", value: era.rangeText, reading: reading, source: "\(era.modelShortName) era, unconfirmed",
                        evidence: MachineEraResolver.inspectorHelp(era: era, others: others), standing: .observation)
        }
        // `era.none` is the analyzer's "looked, nothing usable" — words, never an era.
        if let none = newest(assertions, field: "era.none") {
            let evidence = object(none.evidenceJSON)
            let reason = evidence["reason"] as? String
            let gaveUp = evidence["gaveUp"] as? Bool ?? false
            return Line(label: "Era", value: gaveUp ? "no era: the analyzer gave up" : "no usable era", reading: reason,
                        source: "\(MachineEraResolver.modelShortName(by: none.by)) era",
                        evidence: "By \(none.by), \(TechnicalReading.day(Date(timeIntervalSince1970: TimeInterval(none.at))))."
                            + (reason.map { " \($0)" } ?? ""),
                        standing: .missing)
        }
        return Line(label: "Era", value: hasVideo ? "not analyzed yet" : "no picture to read",
                    reading: hasVideo ? "VideoScan Background has not reached this file" : nil,
                    source: "era analyzer", standing: .missing)
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
            return Line(label: "Inferred date", value: "none", reading: reason, source: source, standing: .missing)
        }
        return Line(label: "Inferred date", value: "not inferred yet", source: "date triangulator", standing: .missing)
    }

    /// "62 % confidence (fair)" — the old badge's buckets, in words (no colour).
    static func confidenceWords(_ value: Float) -> String {
        let label = value >= 0.85 ? "strong" : (value >= 0.5 ? "fair" : "weak")
        return String(format: "%.0f %% confidence (%@)", value * 100, label)
    }

    // MARK: Captions, OCR, transcript

    static func sceneLine(_ r: VideoRecord, hasVideo: Bool) -> Line {
        let model = r.sceneCaptionModel ?? "VLM"
        guard !r.sceneCaptions.isEmpty else {
            return Line(label: "Scene", value: hasVideo ? "not described yet" : "no picture (audio only)",
                        source: "scene captions", standing: .missing)
        }
        return Line(label: "Scene", value: count(r.sceneCaptions.count, "frame") + " described",
                    reading: r.sceneCaptions.first.map { String($0.text.prefix(120)) }, source: model,
                    evidence: r.sceneCaptionDate.map { "Captioned by \(model) on \(TechnicalReading.day($0))." },
                    standing: .observation, body: r.sceneCaptions.map { TimedText(at: $0.timestamp, text: $0.text) })
    }

    static func speechLine(_ r: VideoRecord, hasAudio: Bool) -> Line {
        let model = r.audioTranscriptModel ?? "Whisper"
        guard let text = r.audioTranscript else {
            return Line(label: "Speech", value: hasAudio ? "not transcribed yet" : "no audio track", source: "transcript", standing: .missing)
        }
        let evidence = r.audioTranscriptDate.map { "Transcribed by \(model) on \(TechnicalReading.day($0))." }
        if text.isEmpty {
            return Line(label: "Speech", value: "no speech found", source: model, evidence: evidence, standing: .observation)
        }
        return Line(label: "Speech", value: "“" + String(text.prefix(80)) + (text.count > 80 ? "…”" : "”"),
                    reading: "\(text.count) characters", source: model, evidence: evidence, standing: .observation,
                    body: [TimedText(at: nil, text: text)])
    }

    static func ocrDatesLine(_ r: VideoRecord, hasVideo: Bool) -> Line {
        let usable = r.usableOCRDates
        guard !usable.isEmpty else {
            return Line(label: "On-screen dates", value: r.dossierProcessedAt != nil ? "none read" : (hasVideo ? "not read yet" : "no picture"),
                        source: "burn-in reader", standing: .missing)
        }
        return Line(label: "On-screen dates", value: count(usable.count, "read"), reading: usable.first?.text,
                    source: r.sceneCaptionModel ?? "VLM", standing: .observation,
                    body: usable.map { TimedText(at: $0.timestamp, text: $0.text) })
    }

    static func ocrTextLine(_ r: VideoRecord, hasVideo: Bool) -> Line {
        guard !r.ocrText.isEmpty else {
            return Line(label: "On-screen text", value: r.dossierProcessedAt != nil ? "none read" : (hasVideo ? "not read yet" : "no picture"),
                        source: "on-screen text reader", standing: .missing)
        }
        return Line(label: "On-screen text", value: count(r.ocrText.count, "read"), reading: r.ocrText.first?.text,
                    source: r.sceneCaptionModel ?? "VLM", standing: .observation,
                    body: r.ocrText.map { TimedText(at: $0.timestamp, text: $0.text) })
    }

    /// The era job's `ocr.date` observations (8B burn-in reads), newest first.
    static func burnedInLine(_ assertions: [CatalogRow.ProvenanceAssertionReading]) -> Line? {
        let rows = live(assertions, field: "ocr.date").sorted { $0.seq > $1.seq }
        guard let first = rows.first else { return nil }
        var values: [String] = []
        for row in rows where !values.contains(row.value) { values.append(row.value) }
        let body = rows.map { row -> TimedText in
            TimedText(at: object(row.evidenceJSON)["atS"] as? Double,
                      text: "\(row.value) — \(row.by), \(TechnicalReading.day(Date(timeIntervalSince1970: TimeInterval(row.at))))")
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
        return Line(label: "Dossier run", value: TechnicalReading.day(at), source: r.dossierProcessedBy ?? "dossier pipeline",
                    evidence: r.dossierProcessedBy.map { "Processed \(TechnicalReading.day(at)) by \($0)." }, standing: .fact)
    }

    // MARK: Helpers

    /// Machine `inferred` rows of `field` that Rick has not rejected since (same value).
    static func live(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> [CatalogRow.ProvenanceAssertionReading] {
        let rejected = rows.filter { $0.field == field && $0.state == "rejected" }
        return rows.filter { row in
            row.field == field && row.state == "inferred" && MachineEraResolver.isMachine(row.by)
                && !rejected.contains { $0.value == row.value && $0.seq > row.seq }
        }
    }

    static func newest(_ rows: [CatalogRow.ProvenanceAssertionReading], field: String) -> CatalogRow.ProvenanceAssertionReading? {
        live(rows, field: field).max { $0.seq < $1.seq }
    }

    static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func count(_ n: Int, _ noun: String, plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? noun : (plural ?? noun + "s"))
    }
}
