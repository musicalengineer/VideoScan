// ObservationsReport.swift (VideoScanCore/Observations) — what the machine
// found across MANY files, in the dossier's three layers
// (docs/design/file_dossier_view.md Part II; Rick 2026-11-06: "where can I
// query the observations and see what the models have learned?").
//
// One sentence: a PURE value, built from stored rows only, inside one read
// snapshot — three tiers of groups of rows, each row a count with its
// source in words and the rule behind it for the ⓘ. Machine observations
// only (§II.0): the one human value read, Rick's date, appears as the
// "agrees with your date" COMPARISON and nowhere else.
//
// Rulings honoured: a machine era is words, never a date; `era.none` is
// never an era; an era Rick rejected is never "found" (the Results sheet's
// classification, shared SQL); a reader that did not run says "not … yet",
// never "none".
//
// Memory: the groups hold a few hundred rows; the two word histograms keep
// at most `wordKeyCap` distinct keys while counting (new keys are dropped
// once the cap is reached) and `topWords` rows after.
//
// (For Rick: a report struct filled by one static `build(reader:)`, like a
// C++ `Report::build(const Reader&)`; nothing here has state or I/O.)

import Foundation

public struct ObservationsReport: Sendable, Equatable {

    public typealias Layer = FileDossier.Layer
    public typealias Standing = FileDossier.Standing

    /// One row: a label, its words, the count behind them, who said it, the rule.
    public struct Row: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        /// The number the words come from; nil for a row that is words only ("not analyzed yet: 0" still carries 0).
        public var count: Int?
        public var source: String
        public var evidence: String?
        public var standing: Standing

        public var id: String { label + "·" + value }

        public init(label: String, value: String, count: Int? = nil, source: String, evidence: String? = nil, standing: Standing) {
            self.label = label
            self.value = value
            self.count = count
            self.source = source
            self.evidence = evidence
            self.standing = standing
        }

        /// A counted row in files: "12 files".
        static func files(_ label: String, _ n: Int, source: String, evidence: String? = nil, standing: Standing = .observation) -> Row {
            Row(label: label, value: ObservationsReport.files(n), count: n, source: source, evidence: evidence, standing: standing)
        }

        /// The row's words for a tier filter (label, value, source).
        public var searchText: String { (label + " " + value + " " + source).lowercased() }
    }

    public struct Group: Sendable, Equatable, Identifiable {
        public var title: String
        public var rows: [Row]
        public var id: String { title }
        public init(title: String, rows: [Row]) {
            self.title = title
            self.rows = rows
        }
    }

    public struct Tier: Sendable, Equatable, Identifiable {
        public var layer: Layer
        /// The collapsed chevron's one line.
        public var summary: String
        public var groups: [Group]
        public var id: Layer { layer }
        public init(layer: Layer, summary: String, groups: [Group]) {
            self.layer = layer
            self.summary = summary
            self.groups = groups
        }

        public func group(_ title: String) -> Group? { groups.first { $0.title == title } }
        public func row(_ group: String, _ label: String) -> Row? { self.group(group)?.rows.first { $0.label == label } }
    }

    public var scope: ObservationsScope
    public var files: Int
    public var contents: Int
    public var analyzed: Int
    public var technical: Tier
    public var patterns: Tier
    public var collection: Tier
    /// Unix seconds the report was built.
    public var builtAt: Int64

    public var tiers: [Tier] { [technical, patterns, collection] }

    public init(scope: ObservationsScope, files: Int, contents: Int, analyzed: Int, technical: Tier, patterns: Tier, collection: Tier, builtAt: Int64) {
        self.scope = scope
        self.files = files
        self.contents = contents
        self.analyzed = analyzed
        self.technical = technical
        self.patterns = patterns
        self.collection = collection
        self.builtAt = builtAt
    }

    // MARK: Knobs

    /// Distinct keys the word histograms hold while counting (worst case ≈ 20k × ~40 B).
    public static let wordKeyCap = 20_000
    public static let topWords = 25
    public static let topNames = 25
    public static let topEvents = 25
    public static let topBurnedIn = 15

    // MARK: Build

    /// The whole report from one read snapshot. Throws only what the reader throws.
    public static func build(reader: any CatalogObservationsReading, scope: ObservationsScope, now: Date) throws -> ObservationsReport {
        let at = Int64(now.timeIntervalSince1970)
        let totals = try reader.observationTotals(scope)
        let coverage = try reader.observationCoverage(scope, now: at)
        let technical = try technicalTier(reader: reader, scope: scope, totals: totals, now: now)
        let eras = try reader.observationEraVerdicts(scope)
        let agreement = try agreement(reader: reader, scope: scope)
        let captions = try reader.observationCaptions(scope)
        let speech = try reader.observationSpeech(scope)
        let patterns = try patternsTier(reader: reader, scope: scope, totals: totals, coverage: coverage, eras: eras,
                                        captions: captions, speech: speech, agreement: agreement)
        let collection = collectionTier(totals: totals, coverage: coverage, eras: eras, captions: captions, speech: speech, agreement: agreement)
        return ObservationsReport(scope: scope, files: totals.files, contents: totals.contents, analyzed: coverage.analyzedAny,
                                  technical: technical, patterns: patterns, collection: collection, builtAt: at)
    }

    // MARK: Tier 1 — Technical (what the probe read, and what it suggests)

    static let probe = "ffprobe"

    static func technicalTier(reader: any CatalogObservationsReading, scope: ObservationsScope, totals: CatalogRow.ObservationTotals,
                              now: Date) throws -> Tier {
        let tuples = try reader.observationTechnicalTuples(scope)
        var readings: [String: Int] = [:]
        var containers: [String: Int] = [:], vcodecs: [String: Int] = [:], acodecs: [String: Int] = [:]
        var sizes: [String: Int] = [:], rates: [String: Int] = [:], scans: [String: Int] = [:]
        var cameras: [String: Int] = [:], encoders: [String: Int] = [:]
        var suggests: [String: String] = [:]
        for t in tuples where !t.streamType.isEmpty && t.streamType != "ffprobe failed" {
            let facts = t.facts
            readings[TechnicalReading.oneLiner(facts), default: 0] += t.contents
            for line in TechnicalReading.interpret(facts, now: now) {
                let key: String
                switch line.label {
                case "Container": key = line.value; containers[key, default: 0] += t.contents
                case "Video codec": key = line.value; vcodecs[key, default: 0] += t.contents
                case "Audio": key = line.value.replacingOccurrences(of: "first audio stream: ", with: ""); acodecs[key, default: 0] += t.contents
                case "Frame size": key = line.value; sizes[key, default: 0] += t.contents
                case "Frame rate": key = line.value + " fps"; rates[key, default: 0] += t.contents
                case "Scan": key = line.value; scans[key, default: 0] += t.contents
                case "Make / model": key = line.value; cameras[key, default: 0] += t.contents
                case "Encoder / muxer": key = line.value; encoders[key, default: 0] += t.contents
                default: continue
                }
                if suggests[line.label + key] == nil { suggests[line.label + key] = line.suggests }
            }
        }
        func group(_ title: String, _ label: String, _ counts: [String: Int], source: String) -> Group {
            Group(title: title, rows: counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map {
                Row.files($0.key, $0.value, source: source, evidence: suggests[label + $0.key], standing: .fact)
            })
        }
        var groups: [Group] = []
        groups.append(Group(title: "Format readings", rows: readings.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map {
            Row.files($0.key, $0.value, source: "TechnicalReading over the probe facts",
                      evidence: "The dossier's one-line reading of each distinct probe tuple (container, codecs, frame size, rate, scan, audio, device tags), "
                        + "counted over the files that share it. A reading, not a stored fact.", standing: .observation)
        }))
        groups.append(group("Containers", "Container", containers, source: probe))
        groups.append(group("Video codecs", "Video codec", vcodecs, source: TechnicalReading.firstVideoStream))
        groups.append(group("Audio", "Audio", acodecs, source: TechnicalReading.firstAudioStream))
        groups.append(group("Frame sizes", "Frame size", sizes, source: TechnicalReading.firstVideoStream))
        groups.append(group("Frame rates", "Frame rate", rates, source: TechnicalReading.firstVideoStream))
        groups.append(group("Scan", "Scan", scans, source: TechnicalReading.firstVideoStream))
        groups.append(group("Cameras (make / model)", "Make / model", cameras, source: "embedded tag"))
        groups.append(group("Encoders / muxers", "Encoder / muxer", encoders, source: "embedded tag"))
        groups.append(embeddedDates(try reader.observationEmbeddedDates(scope)))
        groups.append(Group(title: "Probe", rows: [
            Row.files("Probed", totals.contents - totals.unprobed - totals.probeFailed, source: probe, standing: .fact),
            Row.files("Not probed yet", totals.unprobed, source: probe, standing: .missing),
            Row.files("Probe failed", totals.probeFailed, source: probe, standing: .missing),
        ]))
        let summary = totals.contents == 0 ? "nothing in scope"
            : (readings.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { "\(readings.count) format reading\(readings.count == 1 ? "" : "s") · most common: \($0.key) (\(files($0.value)))" }
               ?? "no probe facts yet")
        return Tier(layer: .technical, summary: summary, groups: groups)
    }

    /// Embedded creation dates by decade, each with what kind of date it is (TechnicalReading.classifyCreationTime's rules).
    static func embeddedDates(_ groups: [CatalogRow.ObservationEmbeddedDateGroup]) -> Group {
        var byDecade: [Int: [String: Int]] = [:]
        for g in groups {
            let kind: String
            if g.decade < 1980 || g.decade > 2100 { kind = "not evidence (a sentinel or impossible date)" }
            else if TechnicalReading.transferCodecs[g.videoCodec.lowercased()] != nil { kind = "when the carrier was digitised (a transfer), not the shoot" }
            else if g.videoCodec.lowercased() == "dvvideo" { kind = "when the DV was copied to a computer, not shot" }
            else if g.deviceTag { kind = "almost certainly the recording date (device tags present)" }
            else { kind = "a weak date: the camera's clock or an export" }
            byDecade[g.decade, default: [:]][kind, default: 0] += g.contents
        }
        let rows = byDecade.keys.sorted().map { decade -> Row in
            let kinds = byDecade[decade] ?? [:]
            let total = kinds.values.reduce(0, +)
            let words = kinds.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\(files($0.value)) \($0.key)" }.joined(separator: "; ")
            return Row(label: "\(decade)s", value: files(total), count: total, source: "embedded tag", evidence: words, standing: .observation)
        }
        return Group(title: "Embedded creation dates", rows: rows)
    }

    // MARK: Tier 2 — Patterns & events (what the models concluded)

    static func patternsTier(reader: any CatalogObservationsReading, scope: ObservationsScope, totals: CatalogRow.ObservationTotals,
                             coverage: CatalogRow.ObservationCoverage, eras: [CatalogRow.ObservationEraVerdict],
                             captions: CatalogRow.ObservationCaptions, speech: CatalogRow.ObservationSpeech,
                             agreement: MachineEraConvergence) throws -> Tier {
        var groups: [Group] = []
        groups.append(eraGroup(eras, videoNoEra: coverage.videoNoEra))
        let burned = try reader.observationBurnedInDates(scope, limit: topBurnedIn)
        if !burned.isEmpty {
            groups.append(Group(title: "Burned-in dates", rows: burned.map {
                Row.files($0.key, $0.contents, source: "8B date reader, unconfirmed",
                          evidence: "Dates the model read off the picture (ocr.date). A reading, never a date of the file.")
            }))
        }
        groups.append(scenesGroup(captions, videoNotCaptioned: coverage.videoNotCaptioned))
        let described = try histogram(reader: reader, scope: scope, kind: "scene")
        if !described.isEmpty {
            groups.append(Group(title: "Most described", rows: described.map {
                Row(label: $0.key, value: "\($0.count.formatted()) mention\($0.count == 1 ? "" : "s")", count: $0.count,
                    source: captions.models.first.map { "\($0.model) captions, counted words" } ?? "scene captions, counted words",
                    evidence: "How often the word appears in the scene captions in scope (letters only, 3+ characters, common words dropped). "
                        + "A count of the model's words, not of what is in the footage.", standing: .observation)
            }))
        }
        groups.append(speechGroup(speech, audioNotTranscribed: coverage.audioNotTranscribed))
        let said = try histogram(reader: reader, scope: scope, kind: "transcript")
        if !said.isEmpty {
            groups.append(Group(title: "Most said", rows: said.map {
                Row(label: $0.key, value: "\($0.count.formatted()) mention\($0.count == 1 ? "" : "s")", count: $0.count,
                    source: speech.models.first.map { "\($0.model) transcripts, counted words" } ?? "transcripts, counted words",
                    evidence: "How often the word appears in the transcripts in scope (letters only, 3+ characters, common words dropped).",
                    standing: .observation)
            }))
        }
        groups.append(onScreenGroup(captions))
        groups.append(peopleGroup(try reader.observationPeople(scope, limit: topNames * 3)))
        groups.append(inferredGroup(try reader.observationInferredDates(scope)))
        groups.append(eventsGroup(try reader.observationEvents(scope, limit: topEvents)))
        let found = eras.filter(\.found).reduce(0) { $0 + $1.contents }
        var parts: [String] = []
        if found > 0 { parts.append("\(files(found)) with a machine era") }
        if captions.sceneContents > 0 { parts.append("\(files(captions.sceneContents)) with scenes described") }
        if speech.withSpeech > 0 { parts.append("\(files(speech.withSpeech)) with speech") }
        return Tier(layer: .patterns, summary: parts.isEmpty ? "nothing analyzed yet" : parts.joined(separator: " · "), groups: groups)
    }

    /// The machine era by decade words, then the verdicts that are not an era (never shown as one).
    static func eraGroup(_ eras: [CatalogRow.ObservationEraVerdict], videoNoEra: Int) -> Group {
        var decades: [String: Int] = [:]
        var readings: [String: Int] = [:]
        var rejected = 0, none = 0, gaveUp = 0
        var signers = Set<String>()
        for v in eras {
            signers.insert(v.by)
            if v.found, let value = v.value {
                if let r = MachineEraResolver.range(value) {
                    let mid = Int((Double(r.lo + r.hi) / 2).rounded(.down))
                    decades["\(mid - mid % 10)s", default: 0] += v.contents
                } else {
                    decades["unreadable value", default: 0] += v.contents
                }
                readings[AnalysisResultsReport.eraWords(value), default: 0] += v.contents
            } else if v.rejected { rejected += v.contents }
            else if v.gaveUp { gaveUp += v.contents }
            else if v.none { none += v.contents }
        }
        let who = signers.map(MachineEraResolver.modelShortName(by:)).sorted().joined(separator: ", ")
        let source = who.isEmpty ? "era analyzer" : "\(who) era, unconfirmed"
        var rows = decades.sorted { $0.key < $1.key }.map {
            Row.files($0.key, $0.value, source: source,
                      evidence: "Files whose shown era (the signer's newest fused era, your rejections honoured — MachineEraResolver's rule) "
                        + "has its middle year in this decade. An era is a reading of the pictures, never a date.")
        }
        rows += readings.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(topBurnedIn).map {
            Row.files("Reading: " + $0.key, $0.value, source: source, evidence: "The era in words, then the range. Never a date.")
        }
        rows.append(Row.files("No usable era", none, source: source, evidence: "The analyzer looked at the whole file and found no usable era (era.none). Not an era.", standing: .nothingFound))
        rows.append(Row.files("Given up", gaveUp, source: source, evidence: "Three tries ended with no answer; the Results sheet lists the reasons.", standing: .missing))
        rows.append(Row.files("Rejected by you", rejected, source: "Rick",
                              evidence: "The analyzer gave an era and you rejected it: shown as the comparison it is, never counted as found.", standing: .fact))
        rows.append(Row.files("Not analyzed yet", videoNoEra, source: source, evidence: "Video files no era analyzer has reached.", standing: .missing))
        return Group(title: "Machine era", rows: rows)
    }

    static func scenesGroup(_ c: CatalogRow.ObservationCaptions, videoNotCaptioned: Int) -> Group {
        let model = c.models.first?.model ?? "scene captions"
        return Group(title: "Scenes described", rows: [
            Row.files("Files with scenes described", c.sceneContents, source: model,
                      evidence: "Files with at least one scene caption (captions.kind = scene)."),
            Row(label: "Frames described", value: "\(c.sceneRows.formatted()) frame\(c.sceneRows == 1 ? "" : "s")", count: c.sceneRows, source: model,
                evidence: "Scene caption rows in scope.", standing: .observation),
            Row.files("No scenes described", c.ranNoScenes, source: model, evidence: "The captioner ran (caption_runs) and stored no scene.", standing: .nothingFound),
            Row.files("Not described yet", videoNotCaptioned, source: "scene captions", evidence: "Video files with no caption run.", standing: .missing),
        ] + c.models.map { Row.files("Model: " + $0.model, $0.contents, source: $0.model, evidence: runWords($0), standing: .fact) })
    }

    static func speechGroup(_ s: CatalogRow.ObservationSpeech, audioNotTranscribed: Int) -> Group {
        let model = s.models.first?.model ?? "transcript"
        return Group(title: "Speech", rows: [
            Row.files("Files with speech", s.withSpeech, source: model, evidence: "Transcripts with text."),
            Row.files("No speech found", s.noSpeech, source: model, evidence: "Whisper ran and heard no speech (an empty transcript).", standing: .nothingFound),
            Row.files("Not transcribed yet", audioNotTranscribed, source: "transcript", evidence: "Files with an audio stream and no transcript row.", standing: .missing),
            Row(label: "Words in all", value: "\(s.words.formatted()) words", count: Int(clamping: s.words), source: model,
                evidence: "Spaces + 1 per transcript with text; a plain count.", standing: .observation),
            Row(label: "Longest transcript", value: "\(s.longestWords.formatted()) words", count: s.longestWords, source: model, standing: .observation),
        ] + s.models.map { Row.files("Model: " + $0.model, $0.contents, source: $0.model, evidence: runWords($0), standing: .fact) })
    }

    static func onScreenGroup(_ c: CatalogRow.ObservationCaptions) -> Group {
        let model = c.models.first?.model ?? "on-screen text reader"
        return Group(title: "On-screen text", rows: [
            Row.files("Files with on-screen text", c.ocrTextContents, source: model, evidence: "captions.kind = ocrText."),
            Row(label: "Reads", value: "\(c.ocrTextRows.formatted()) read\(c.ocrTextRows == 1 ? "" : "s")", count: c.ocrTextRows, source: model, standing: .observation),
            Row.files("Files with on-screen dates", c.ocrDateContents, source: model, evidence: "captions.kind = ocrDate (the usable reads; GH #402)."),
            Row.files("None found (reader proven to have run)", max(0, c.ocrProvenRan - c.ocrTextContents), source: model,
                      evidence: "The full dossier pass stamped the run and the captions with one instant (the dossier's Ran.ocr rule), and stored no on-screen text.",
                      standing: .nothingFound),
        ])
    }

    static func peopleGroup(_ people: [CatalogRow.ObservationPerson]) -> Group {
        let machine = people.filter { $0.kind == "detected" || $0.kind == "suspected" }
        let confirmed = people.filter { $0.kind == "confirmed" }.reduce(0) { $0 + $1.contents }
        var rows = machine.prefix(topNames).map {
            Row.files("\($0.name) (\($0.kind))", $0.contents, source: "face recognition, unconfirmed",
                      evidence: "people_tags.kind = \($0.kind): the machine's guess, not a confirmed identity.")
        }
        if rows.isEmpty { rows.append(Row(label: "People found", value: "none yet", count: 0, source: "face recognition", standing: .missing)) }
        rows.append(Row.files("Confirmed by you (the comparison)", confirmed, source: "Rick",
                              evidence: "Confirmed people tags: yours, shown beside the machine's guesses, never as an observation.", standing: .fact))
        return Group(title: "People the machine found", rows: rows)
    }

    static func inferredGroup(_ i: CatalogRow.ObservationInferredDates) -> Group {
        var rows = i.decades.map {
            Row.files($0.key, $0.contents, source: "date triangulator",
                      evidence: "inferred_dates.date_at by decade: the triangulated answer (GH #201), an inference.")
        }
        rows.append(Row.files("Examined, no evidence", i.noEvidence, source: "date triangulator",
                              evidence: "An inferred_dates row with a reason and no date.", standing: .nothingFound))
        return Group(title: "Inferred dates", rows: rows)
    }

    static func eventsGroup(_ events: [CatalogRow.ObservationEvent]) -> Group {
        guard !events.isEmpty else {
            return Group(title: "Events", rows: [Row(label: "Events", value: "none touch these files", count: 0, source: "related-score ladder", standing: .missing)])
        }
        return Group(title: "Events", rows: events.map {
            Row(label: $0.name, value: "\(files($0.members)) · \($0.state == "confirmed" ? "confirmed by you" : "dismissed by you")", count: $0.members,
                source: "related-score ladder", evidence: "An event the ladder grouped (events + event_members); its state is yours.",
                standing: $0.state == "confirmed" ? .fact : .nothingFound)
        })
    }

    // MARK: Tier 3 — Across the collection (statistics)

    static func collectionTier(totals: CatalogRow.ObservationTotals, coverage: CatalogRow.ObservationCoverage,
                               eras: [CatalogRow.ObservationEraVerdict], captions: CatalogRow.ObservationCaptions,
                               speech: CatalogRow.ObservationSpeech, agreement: MachineEraConvergence) -> Tier {
        let nothing = max(0, totals.contents - coverage.analyzedAny)
        func percent(_ n: Int) -> String { totals.contents == 0 ? "—" : "\(Int((Double(n) * 100 / Double(totals.contents)).rounded())) %" }
        let scopeGroup = Group(title: "This scope", rows: [
            Row(label: "Files", value: "\(totals.files.formatted()) file\(totals.files == 1 ? "" : "s") · \(totals.contents.formatted()) distinct content\(totals.contents == 1 ? "" : "s")",
                count: totals.files, source: "catalog.sqlite", evidence: "files rows in scope; contents = distinct whole-file hashes.", standing: .fact),
            Row(label: "Duration in all", value: TechnicalReading.durationWords(totals.durationSeconds), count: Int(totals.durationSeconds), source: probe, standing: .fact),
            Row.files("Video", totals.videoContents, source: probe, standing: .fact),
            Row.files("Audio", totals.audioContents, source: probe, standing: .fact),
            Row(label: "Analyzed by any machine", value: "\(files(coverage.analyzedAny)) (\(percent(coverage.analyzedAny)))", count: coverage.analyzedAny,
                source: "every analyzer", evidence: "A caption run, a transcript, an inferred date, a machine people tag or a machine assertion.", standing: .observation),
            Row(label: "Nothing yet", value: "\(files(nothing)) (\(percent(nothing)))", count: nothing, source: "every analyzer", standing: .missing),
            Row.files("Observed in the last 24 h", coverage.last24Hours, source: "every analyzer", standing: .observation),
        ])
        var decadeSpan: ClosedRange<Int>?
        for v in eras where v.found { if let value = v.value, let r = MachineEraResolver.range(value) {
            decadeSpan = decadeSpan.map { min($0.lowerBound, r.lo)...max($0.upperBound, r.hi) } ?? r.lo...r.hi
        } }
        let eraGroup = Group(title: "Machine eras across the collection", rows: [
            Row(label: "Agrees with your date within 5 years", value: AnalysisResultsReport.agreementWords(agreement), count: agreement.agree,
                source: "comparison with your dates", evidence: "Files with your date and a machine era whose middle year is within 5 years of yours "
                    + "(range at most 10 years wide) — the Results sheet's and Catalog Status's rule. Your date is the comparison, not an observation.",
                standing: .fact),
            Row(label: "Span of machine eras", value: decadeSpan.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "no era yet", count: decadeSpan.map { $0.count },
                source: "era analyzers", evidence: "The earliest and latest year of any shown era in scope. Words about the pictures, never dates.",
                standing: decadeSpan == nil ? .missing : .observation),
        ])
        var runs: [Row] = []
        runs += captions.models.map { Row.files("Scene captions · " + $0.model, $0.contents, source: $0.model, evidence: runWords($0), standing: .fact) }
        runs += speech.models.map { Row.files("Transcripts · " + $0.model, $0.contents, source: $0.model, evidence: runWords($0), standing: .fact) }
        runs += coverage.eraSigners.map {
            Row.files("Era · " + MachineEraResolver.modelShortName(by: $0.model), $0.contents, source: $0.model, evidence: runWords($0), standing: .fact)
        }
        if runs.isEmpty { runs.append(Row(label: "Models", value: "no run yet", count: 0, source: "every analyzer", standing: .missing)) }
        let modelsGroup = Group(title: "Models and runs", rows: runs)
        let speechGroup = Group(title: "Speech en masse", rows: [
            Row(label: "Words in all transcripts", value: "\(speech.words.formatted()) words", count: Int(clamping: speech.words), source: speech.models.first?.model ?? "transcript", standing: .observation),
            Row(label: "Average per transcript", value: speech.withSpeech == 0 ? "no transcript yet" : "\((Int(speech.words) / speech.withSpeech).formatted()) words",
                count: speech.withSpeech == 0 ? nil : Int(speech.words) / speech.withSpeech, source: speech.models.first?.model ?? "transcript",
                standing: speech.withSpeech == 0 ? .missing : .observation),
            Row(label: "Characters in all", value: speech.characters.formatted(), count: Int(clamping: speech.characters), source: speech.models.first?.model ?? "transcript", standing: .observation),
        ])
        let summary = totals.contents == 0 ? "nothing in scope"
            : "\(files(totals.contents)) · \(TechnicalReading.durationWords(totals.durationSeconds)) · \(percent(coverage.analyzedAny)) analyzed by a machine"
        return Tier(layer: .collection, summary: summary, groups: [scopeGroup, eraGroup, modelsGroup, speechGroup])
    }

    /// The agreement with Rick's dates, scoped — the resolver picks the era exactly as the inspector does.
    static func agreement(reader: any CatalogObservationsReading, scope: ObservationsScope) throws -> MachineEraConvergence {
        var c = MachineEraConvergence(total: 0, agree: 0)
        try reader.observationEraRowsOfDatedContents(scope) { rickDate, rows in
            guard let year = MachineEraResolver.rickYear(rickDate), let era = MachineEraResolver.eras(fromRowsOfOneSubject: rows).first else { return }
            c.total += 1
            if MachineEraResolver.closeEnough(era: era, rickYear: year) { c.agree += 1 }
        }
        return c
    }

    // MARK: Words

    public static func files(_ n: Int) -> String { "\(n.formatted()) file\(n == 1 ? "" : "s")" }

    static func runWords(_ r: CatalogRow.ObservationModelRun) -> String {
        func day(_ t: Int64?) -> String { t.map { TechnicalReading.day(Date(timeIntervalSince1970: TimeInterval($0))) } ?? "unknown" }
        return "\(files(r.contents)); first run \(day(r.firstAt)), last run \(day(r.lastAt))."
    }

    // MARK: The word histograms (bounded)

    public struct WordCount: Sendable, Equatable {
        public var key: String
        public var count: Int
    }

    /// Words a caption or transcript says about nothing in particular (and the VLM's framing words).
    public static let stopWords: Set<String> = [
        "the", "and", "with", "for", "are", "this", "that", "from", "has", "have", "his", "her", "its", "their", "there", "they", "them",
        "was", "were", "been", "being", "but", "not", "can", "will", "would", "could", "should", "into", "onto", "over", "under", "about",
        "what", "when", "where", "which", "who", "whom", "why", "how", "all", "any", "some", "such", "than", "then", "too", "very", "just",
        "also", "one", "two", "three", "out", "off", "our", "you", "your", "yours", "him", "she", "him", "did", "does", "doing", "don",
        "yeah", "yes", "okay", "like", "know", "think", "get", "got", "going", "gonna", "say", "said", "see", "well", "right", "here",
        "image", "images", "frame", "frames", "scene", "scenes", "shows", "showing", "shown", "appears", "appear", "visible", "seen",
        "video", "photo", "picture", "pictured", "background", "foreground", "likely", "possibly", "seems", "there", "these", "those",
        "while", "near", "left", "right", "front", "behind", "small", "large", "white", "black", "wearing", "standing", "sitting",
        "person", "people", "man", "woman", "boy", "girl", "child", "children", "adult", "young", "old", "around", "something", "someone",
    ]

    /// Lowercase letters only, 3+ characters, common words dropped.
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for ch in text.lowercased() {
            if ch.isLetter { word.append(ch) } else if !word.isEmpty { if word.count >= 3, !stopWords.contains(word) { out.append(word) }; word = "" }
        }
        if word.count >= 3, !stopWords.contains(word) { out.append(word) }
        return out
    }

    /// The `topWords` most frequent words over the scope's scene captions or transcripts.
    /// Memory: the dictionary stops taking NEW keys at `wordKeyCap` (existing keys still count).
    static func histogram(reader: any CatalogObservationsReading, scope: ObservationsScope, kind: String) throws -> [WordCount] {
        var counts: [String: Int] = [:]
        try reader.observationTexts(scope, kind: kind) { text in
            for token in tokens(text) {
                if let n = counts[token] { counts[token] = n + 1 } else if counts.count < wordKeyCap { counts[token] = 1 }
            }
        }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(topWords).map { WordCount(key: $0.key, count: $0.value) }
    }
}
