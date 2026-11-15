// HallieBrainDecoding.swift
// The strict decoders every brain's reply passes through (2026-11-07).
//
// Split out of OllamaQueryTranslator when Hallie gained a second brain
// (Cloud / Anthropic). The model's JSON is judged HERE, by the same code,
// whichever brain produced it — so "the model translates, executors answer,
// the verifier rejects anything not in the plan" (DECISIONS 2026-08-14) holds
// for both without a second copy of the rules. A brain only has to hand back
// the raw JSON text it was asked for; it never decides what is acceptable.

import Foundation
import os

private let decodingLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                 category: "HallieTranslator")

enum HallieBrainDecoding {

    /// A dropped year changes what was searched, so it is in videoscan.log,
    /// not only the unified log. The note holds a field name and a number,
    /// never the question.
    static func logDroppedYears(_ notes: [String]) {
        for note in notes where note.hasPrefix("dropped payload.year") {
            appLog.write("[hallie] translation: \(note)")
        }
    }

    /// How much of a rejected reply rides in the error. 120 stopped short of
    /// the offending field whenever a list came first (2026-11-15); a whole
    /// QueryAST reply is rarely longer than this.
    static let replyExcerpt = 300

    /// v1 NLQuerySpec, strict wire decode.
    static func spec(content: String, data: Data) throws -> NLQuerySpec {
        do {
            return try NLQuerySpec.decodeStrictWire(data)
        } catch {
            throw NLTranslatorError.badResponse(
                "content is not a strict NLQuerySpec "
                    + "(\(OllamaQueryTranslator.decodeFailureDetail(error))): "
                    + String(content.prefix(Self.replyExcerpt)))
        }
    }

    /// QueryAST-v2. Tolerant of benign extras (`limit` on a presence payload,
    /// `confidence`, nulls) — see ArchivistQueryAST.decodeTranslatorOutput.
    /// Genuinely malformed shapes still fail here.
    static func ast(content: String, data: Data, question: String) throws -> ArchivistQueryAST {
        do {
            let decoded = try ArchivistQueryAST.decodeTranslatorOutput(
                data, question: question)
            if !decoded.notes.isEmpty {
                let notes = decoded.notes.joined(separator: "; ")
                decodingLog.notice(
                    "translator output normalized: \(notes, privacy: .public)")
                Self.logDroppedYears(decoded.notes)
            }
            return OllamaQueryTranslator.repairPossessiveSpeakerPronoun(
                in: decoded.ast, originalQuestion: question)
        } catch {
            throw NLTranslatorError.badResponse(
                "content is not a strict ArchivistQueryAST "
                    + "(\(OllamaQueryTranslator.decodeFailureDetail(error))): \(content.prefix(Self.replyExcerpt))")
        }
    }

    /// One turn → archive AST or the bounded conversation lane. Archive shapes
    /// use the exact established decoder and repair path; `conversation` is
    /// never an ArchivistQueryAST.
    static func interpretation(content: String, data: Data,
                               question: String) throws -> HallieTurnInterpretation {
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            let shape = (object as? [String: Any])?["shape"] as? String
            if shape == "conversation" {
                return .conversation(
                    try HallieTurnInterpretation.decodeConversation(data))
            }
            let decoded = try ArchivistQueryAST.decodeTranslatorOutput(
                data, question: question)
            if !decoded.notes.isEmpty {
                decodingLog.notice(
                    "turn interpretation normalized: \(decoded.notes.joined(separator: "; "), privacy: .public)")
                Self.logDroppedYears(decoded.notes)
            }
            return .archive(OllamaQueryTranslator.repairPossessiveSpeakerPronoun(
                in: decoded.ast, originalQuestion: question))
        } catch let error as NLTranslatorError {
            throw error
        } catch {
            throw NLTranslatorError.badResponse(
                "content is not a strict Hallie turn interpretation "
                    + "(\(OllamaQueryTranslator.decodeFailureDetail(error))): \(content.prefix(Self.replyExcerpt))")
        }
    }
}
