// CatalogObservationsRows.swift (VideoScanCore/Store)
// What the Observations window reads of catalog.sqlite (Rick 2026-11-06,
// "where can I query the observations and see what the models have
// learned?"; docs/design/file_dossier_view.md Part II): the values and the
// read-only seam. READ ONLY — every method runs inside a `read` (a
// snapshot); nothing here writes, and no schema changes.
//
// Machine observations only (Rick 11/06, §II.0): every value here comes from
// what an analyzer wrote — the probe's columns, captions, transcripts,
// provenance assertions, machine people tags, inferred dates, events. The
// one human column read (`user_dates.value`) feeds the "agrees with your
// date" COMPARISON and nothing else; no filename, path, note or tag is ever
// searched (ObservationsSensorTests pins the SQL).
//
// Every count is aggregated in SQLite (GROUP BY over the scope's CTE), never
// by walking records in Swift; the two streamed reads (texts for the word
// histograms, the dated contents' era rows for the agreement) hand the
// caller one row at a time.
//
// Typed at the row boundary: a stored column that names one of a set (an era
// verdict, a people tag's kind, an event's state, a hit's kind) is decoded
// into an enum ONCE, where the row is read. A value outside the set is
// refused in words (a set this file's SQL closes) or carried as
// `unknown(String)` (a set a later schema may widen) — never defaulted.
//
// (For Rick: the DAO header — value structs plus one read-only interface.
// The enums are `enum class` parsed where the row is read, instead of a
// `std::string kind` compared at every use.)

import Foundation

extension CatalogRow {

    /// The scope's size.
    public struct ObservationTotals: Sendable, Equatable {
        public var files: Int
        public var contents: Int
        public var videoContents: Int
        public var audioContents: Int
        /// `stream_type = ''`: never probed.
        public var unprobed: Int
        /// `stream_type = 'ffprobe failed'`.
        public var probeFailed: Int
        public var durationSeconds: Double
        public init(files: Int, contents: Int, videoContents: Int, audioContents: Int, unprobed: Int, probeFailed: Int, durationSeconds: Double) {
            self.files = files
            self.contents = contents
            self.videoContents = videoContents
            self.audioContents = audioContents
            self.unprobed = unprobed
            self.probeFailed = probeFailed
            self.durationSeconds = durationSeconds
        }
    }

    /// One distinct probe tuple and how many contents carry it (the technical tier interprets each once).
    public struct ObservationTechnicalTuple: Sendable, Equatable, Hashable {
        public var container: String
        public var ext: String
        public var videoCodec: String
        public var audioCodec: String
        public var streamType: String
        public var resolution: String
        public var frameRate: String
        public var scanType: String
        public var audioSampleRate: String
        public var audioChannels: String
        public var make: String
        public var model: String
        public var encoder: String
        public var contents: Int
        public var durationSeconds: Double
        public init(container: String, ext: String, videoCodec: String, audioCodec: String, streamType: String, resolution: String,
                    frameRate: String, scanType: String, audioSampleRate: String, audioChannels: String, make: String, model: String,
                    encoder: String, contents: Int, durationSeconds: Double) {
            self.container = container
            self.ext = ext
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
            self.streamType = streamType
            self.resolution = resolution
            self.frameRate = frameRate
            self.scanType = scanType
            self.audioSampleRate = audioSampleRate
            self.audioChannels = audioChannels
            self.make = make
            self.model = model
            self.encoder = encoder
            self.contents = contents
            self.durationSeconds = durationSeconds
        }

        /// The facts TechnicalReading reads, from the stored columns (the same parsing as `TechnicalFacts(record:)`).
        public var facts: TechnicalFacts {
            func text(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
            let size = TechnicalReading.frameSize(resolution)
            return TechnicalFacts(container: TechnicalReading.containerKey(container: container, ext: ext), containerName: text(container),
                                  hasVideo: streamType == "Video+Audio" || streamType == "Video only",
                                  hasAudio: streamType == "Video+Audio" || streamType == "Audio only",
                                  codec: text(videoCodec), width: size?.0, height: size?.1, fps: TechnicalReading.rate(frameRate),
                                  fieldOrder: text(scanType)?.lowercased(), audioCodec: text(audioCodec),
                                  audioRate: TechnicalReading.leadingInt(audioSampleRate), audioChannels: TechnicalReading.leadingInt(audioChannels),
                                  encoder: text(encoder), make: text(make), model: text(model))
        }
    }

    /// Embedded creation dates, grouped: the decade, the codec and whether a device tag names the camera.
    public struct ObservationEmbeddedDateGroup: Sendable, Equatable {
        public var decade: Int
        public var videoCodec: String
        /// A make/model tag or the Apple camera tag wrote the date (TechnicalReading's `.camera` kind).
        public var deviceTag: Bool
        public var contents: Int
        public init(decade: Int, videoCodec: String, deviceTag: Bool, contents: Int) {
            self.decade = decade
            self.videoCodec = videoCodec
            self.deviceTag = deviceTag
            self.contents = contents
        }
    }

    /// One (signer, verdict) group of the Results sheet's classification, counted over the scope.
    public struct ObservationEraVerdict: Sendable, Equatable {

        /// What one signer concluded about one content (GRDBCatalogRepository+AnalysisResults.swift's
        /// precedence: found, then rejected, then given up, then no usable era). The fused value
        /// ("1991-1995") rides the two cases that have one.
        /// (C++: a `std::variant` — a verdict cannot be both found and rejected, nor found without a value.)
        public enum Verdict: Sendable, Equatable {
            case found(String)
            case rejected(String)
            case gaveUp
            /// An `era.none` row: the analyzer looked and found no usable era. Never an era.
            case noUsableEra
            /// Rows by the signer but none of the four (only `ocr.date`, or a malformed fused value): analyzed, in no list.
            case other

            /// The classification's four flags and its value → the one verdict. Two flags at once, or
            /// a found / rejected verdict without its value, is not a row this reader understands.
            public init(found: Bool, rejected: Bool, gaveUp: Bool, none: Bool, value: String?) throws {
                switch (found, rejected, gaveUp, none, value) {
                case (true, false, false, false, let value?): self = .found(value)
                case (false, true, false, false, let value?): self = .rejected(value)
                case (false, false, true, false, _): self = .gaveUp
                case (false, false, false, true, _): self = .noUsableEra
                case (false, false, false, false, _): self = .other
                default:
                    throw Refusal("an era verdict that is not one verdict (found \(found), rejected \(rejected), gave up \(gaveUp), "
                                  + "none \(none), value \(value ?? "NULL")): the Observations read refuses it")
                }
            }
        }

        public var by: String
        public var verdict: Verdict
        public var contents: Int
        public init(by: String, verdict: Verdict, contents: Int) {
            self.by = by
            self.verdict = verdict
            self.contents = contents
        }

        /// The shown era's value; nil for every verdict that is not an era.
        public var foundValue: String? {
            if case .found(let value) = verdict { return value }
            return nil
        }
    }

    /// One burned-in date (`ocr.date`), the contents carrying it and every signer that read it.
    public struct ObservationBurnedInDate: Sendable, Equatable {
        public var value: String
        /// The assertions' `by`, whole ("machine:qwen3-vl-8b-4bit/…"), sorted; never empty.
        public var signers: [String]
        public var contents: Int
        public init(value: String, signers: [String], contents: Int) {
            self.value = value
            self.signers = signers
            self.contents = contents
        }
    }

    /// A label and how many contents carry it (an inferred date's decade).
    public struct ObservationCount: Sendable, Equatable {
        public var key: String
        public var contents: Int
        public init(key: String, contents: Int) {
            self.key = key
            self.contents = contents
        }
    }

    /// One model's runs over the scope.
    public struct ObservationModelRun: Sendable, Equatable {
        public var model: String
        public var contents: Int
        public var firstAt: Int64?
        public var lastAt: Int64?
        public init(model: String, contents: Int, firstAt: Int64?, lastAt: Int64?) {
            self.model = model
            self.contents = contents
            self.firstAt = firstAt
            self.lastAt = lastAt
        }
    }

    /// The captions tables over the scope.
    public struct ObservationCaptions: Sendable, Equatable {
        public var sceneContents: Int
        public var sceneRows: Int
        public var ocrTextContents: Int
        public var ocrTextRows: Int
        public var ocrDateContents: Int
        public var ocrDateRows: Int
        /// A caption run stamped, but no scene row: the captioner ran and described nothing.
        public var ranNoScenes: Int
        /// The full dossier pass is PROVEN to have run (dossier stamp = caption stamp, "model+…"), so an absent OCR row means "none found".
        public var ocrProvenRan: Int
        public var models: [ObservationModelRun]
        public init(sceneContents: Int, sceneRows: Int, ocrTextContents: Int, ocrTextRows: Int, ocrDateContents: Int, ocrDateRows: Int,
                    ranNoScenes: Int, ocrProvenRan: Int, models: [ObservationModelRun]) {
            self.sceneContents = sceneContents
            self.sceneRows = sceneRows
            self.ocrTextContents = ocrTextContents
            self.ocrTextRows = ocrTextRows
            self.ocrDateContents = ocrDateContents
            self.ocrDateRows = ocrDateRows
            self.ranNoScenes = ranNoScenes
            self.ocrProvenRan = ocrProvenRan
            self.models = models
        }
    }

    /// The transcripts table over the scope.
    public struct ObservationSpeech: Sendable, Equatable {
        public var withSpeech: Int
        /// `text = ''`: Whisper ran and heard no speech.
        public var noSpeech: Int
        public var characters: Int64
        /// Spaces + 1 per non-empty transcript (a plain count, never a language model's).
        public var words: Int64
        public var longestWords: Int
        public var models: [ObservationModelRun]
        public init(withSpeech: Int, noSpeech: Int, characters: Int64, words: Int64, longestWords: Int, models: [ObservationModelRun]) {
            self.withSpeech = withSpeech
            self.noSpeech = noSpeech
            self.characters = characters
            self.words = words
            self.longestWords = longestWords
            self.models = models
        }
    }

    /// `people_tags.kind`, the three this window reads (`rejected` is never selected).
    public enum ObservationPersonKind: String, Sendable, Equatable, CaseIterable {
        case detected, suspected, confirmed

        /// The machine's guess (`detected` / `suspected`); `confirmed` is Rick's, the comparison.
        public var isMachine: Bool { self != .confirmed }

        public init(stored: String) throws {
            guard let kind = Self(rawValue: stored) else {
                throw Refusal("people_tags.kind \"\(stored)\" is not a kind the Observations read selects")
            }
            self = kind
        }
    }

    /// One person the machine found (`detected` / `suspected`), or Rick confirmed (the comparison).
    public struct ObservationPerson: Sendable, Equatable {
        public var name: String
        public var kind: ObservationPersonKind
        public var contents: Int
        public init(name: String, kind: ObservationPersonKind, contents: Int) {
            self.name = name
            self.kind = kind
            self.contents = contents
        }
    }

    /// Inferred dates: by decade, plus the "examined, no evidence" rows.
    public struct ObservationInferredDates: Sendable, Equatable {
        public var decades: [ObservationCount]
        public var noEvidence: Int
        public var dated: Int
        public init(decades: [ObservationCount], noEvidence: Int, dated: Int) {
            self.decades = decades
            self.noEvidence = noEvidence
            self.dated = dated
        }
    }

    /// `events.state`. The column is not filtered by the read, so a state a later schema adds
    /// arrives as `unknown` and is shown as what it is — never as "dismissed".
    public enum ObservationEventState: Sendable, Equatable {
        case confirmed, dismissed
        case unknown(String)

        public init(stored: String) {
            switch stored {
            case "confirmed": self = .confirmed
            case "dismissed": self = .dismissed
            default: self = .unknown(stored)
            }
        }
    }

    /// One event touching the scope.
    public struct ObservationEvent: Sendable, Equatable {
        public var name: String
        public var state: ObservationEventState
        public var members: Int
        public init(name: String, state: ObservationEventState, members: Int) {
            self.name = name
            self.state = state
            self.members = members
        }
    }

    /// Coverage: which contents any machine reached, and which each reader has not.
    public struct ObservationCoverage: Sendable, Equatable {
        public var analyzedAny: Int
        public var videoNotCaptioned: Int
        public var audioNotTranscribed: Int
        public var videoNoEra: Int
        /// Contents with an observation stamped in the last 24 hours of `now`.
        public var last24Hours: Int
        public var eraSigners: [ObservationModelRun]
        public init(analyzedAny: Int, videoNotCaptioned: Int, audioNotTranscribed: Int, videoNoEra: Int, last24Hours: Int,
                    eraSigners: [ObservationModelRun]) {
            self.analyzedAny = analyzedAny
            self.videoNotCaptioned = videoNotCaptioned
            self.audioNotTranscribed = audioNotTranscribed
            self.videoNoEra = videoNoEra
            self.last24Hours = last24Hours
            self.eraSigners = eraSigners
        }
    }

    /// What a search hit is. The raw values are the literals the hit queries select (the three
    /// `captions.kind` values, and one literal per other source); the queries name every kind
    /// they return, so anything else is refused.
    public enum ObservationHitKind: String, Sendable, Equatable, CaseIterable {
        case scene, ocrText, ocrDate, speech, burnedIn, person, event, era, technical

        public init(stored: String) throws {
            guard let kind = Self(rawValue: stored) else {
                throw Refusal("a search hit of kind \"\(stored)\" is not a kind the Observations read knows")
            }
            self = kind
        }
    }

    /// Which texts the word histograms stream.
    public enum ObservationTextsKind: Sendable, Equatable, CaseIterable {
        /// `captions.kind = 'scene'`.
        case sceneCaptions
        /// `transcripts.text`, the non-empty ones.
        case transcripts
    }

    /// One search hit as the store returns it: the observation and the file that stands for its content in the scope.
    public struct ObservationHitRow: Sendable, Equatable {
        public var digest: String
        public var fileID: String?
        public var filename: String?
        public var path: String?
        public var removed: Bool
        public var kind: ObservationHitKind
        /// Seconds into the clip; nil when untimed.
        public var at: Double?
        /// The observation (a transcript is cut to a window around the match in SQL — memory stays bounded).
        public var text: String
        /// Who said it: the caption/transcript model, the signer, the people tag's kind, the event's state.
        public var by: String
        public var seq: Int64
        /// What tells two rows of one (kind, digest, seq, at, by) apart — a person's name, an event's id
        /// and range; '' where those five already name one row. With them it is the hit's identity.
        public var key: String
        public init(digest: String, fileID: String?, filename: String?, path: String?, removed: Bool, kind: ObservationHitKind, at: Double?,
                    text: String, by: String, seq: Int64, key: String) {
            self.digest = digest
            self.fileID = fileID
            self.filename = filename
            self.path = path
            self.removed = removed
            self.kind = kind
            self.at = at
            self.text = text
            self.by = by
            self.seq = seq
            self.key = key
        }
    }
}

/// The Observations window's reads. Implemented on the GRDB read handle only.
public protocol CatalogObservationsReading {
    func observationTotals(_ scope: ObservationsScope) throws -> CatalogRow.ObservationTotals
    /// Every distinct probe tuple in the scope with its content count (hundreds at most on a family archive).
    func observationTechnicalTuples(_ scope: ObservationsScope) throws -> [CatalogRow.ObservationTechnicalTuple]
    func observationEmbeddedDates(_ scope: ObservationsScope) throws -> [CatalogRow.ObservationEmbeddedDateGroup]
    /// The Results sheet's per-(signer, content) classification, grouped by (signer, verdict) over the scope.
    func observationEraVerdicts(_ scope: ObservationsScope) throws -> [CatalogRow.ObservationEraVerdict]
    /// `ocr.date` values by machine signers, not rejected, with their content counts and signers (most frequent first).
    func observationBurnedInDates(_ scope: ObservationsScope, limit: Int) throws -> [CatalogRow.ObservationBurnedInDate]
    func observationCaptions(_ scope: ObservationsScope) throws -> CatalogRow.ObservationCaptions
    func observationSpeech(_ scope: ObservationsScope) throws -> CatalogRow.ObservationSpeech
    /// People tags by (name, kind), most frequent first; all three kinds (the caller keeps `confirmed` apart as the comparison).
    func observationPeople(_ scope: ObservationsScope, limit: Int) throws -> [CatalogRow.ObservationPerson]
    func observationInferredDates(_ scope: ObservationsScope) throws -> CatalogRow.ObservationInferredDates
    func observationEvents(_ scope: ObservationsScope, limit: Int) throws -> [CatalogRow.ObservationEvent]
    func observationCoverage(_ scope: ObservationsScope, now: Int64) throws -> CatalogRow.ObservationCoverage
    /// For each content in scope with Rick's date: that date and its `era.fused` rows (all signers, rejections included), streamed.
    func observationEraRowsOfDatedContents(_ scope: ObservationsScope,
                                           _ body: (_ rickDate: String, _ rows: [CatalogRow.ProvenanceAssertionReading]) throws -> Void) throws
    /// The scene captions or the transcripts of the scope, one text at a time.
    func observationTexts(_ scope: ObservationsScope, kind: CatalogRow.ObservationTextsKind, _ visit: (String) throws -> Void) throws
    /// Captions (three kinds), transcripts, burned-in dates, machine people, event names whose text contains `query`
    /// literally (ASCII case-insensitive; the reader escapes `%`, `_` and `\` for its LIKE — the caller passes the
    /// query as typed, lowercased), at most `limitPerKind` each.
    func observationTextHits(_ scope: ObservationsScope, query: String, limitPerKind: Int) throws -> [CatalogRow.ObservationHitRow]
    /// Contents whose shown era (found, not rejected) is one of `values`, at most `limit`.
    func observationEraHits(_ scope: ObservationsScope, values: [String], limit: Int) throws -> [CatalogRow.ObservationHitRow]
    /// Contents carrying exactly `tuple`'s probe columns, at most `limit`.
    func observationTechnicalHits(_ scope: ObservationsScope, tuple: CatalogRow.ObservationTechnicalTuple, limit: Int) throws
        -> [CatalogRow.ObservationHitRow]
}
