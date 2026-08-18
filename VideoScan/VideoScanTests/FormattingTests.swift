import Testing
import Foundation
@testable import VideoScan

// MARK: - Formatting Tests

struct FormattingTests {

    @Test func durationFormatting() {
        #expect(Formatting.duration(0) == "00:00:00")
        #expect(Formatting.duration(59) == "00:00:59")
        #expect(Formatting.duration(60) == "00:01:00")
        #expect(Formatting.duration(3661) == "01:01:01")
        #expect(Formatting.duration(86399) == "23:59:59")
    }

    @Test func fractionParsing() {
        #expect(Formatting.fraction("30000/1001") == "29.97")
        #expect(Formatting.fraction("24000/1001") == "23.976")
        #expect(Formatting.fraction("30/1") == "30")
        #expect(Formatting.fraction("25/1") == "25")
        #expect(Formatting.fraction("0/0") == "0/0")
        #expect(Formatting.fraction("notafraction") == "notafraction")
    }

    // regression: #28 — Byte size formatting: scale crossings (B→KB→MB→GB→TB) render correctly
    // Decimal since 2026-08-18 (routes through MediaBytes — Finder / df base).
    @Test func humanSize() {
        #expect(Formatting.humanSize(0) == "0 B")
        #expect(Formatting.humanSize(512) == "512 B")
        #expect(Formatting.humanSize(1_000) == "1.0 KB")
        #expect(Formatting.humanSize(1_000_000) == "1.0 MB")
        #expect(Formatting.humanSize(1_000_000_000) == "1.0 GB")
        #expect(Formatting.humanSize(1_000_000_000_000) == "1.0 TB")
        #expect(Formatting.humanSize(1_073_741_824) == "1.1 GB")
    }

    @Test func csvEscape() {
        #expect(Formatting.csvEscape("hello") == "hello")
        #expect(Formatting.csvEscape("has,comma") == "\"has,comma\"")
        #expect(Formatting.csvEscape("has\"quote") == "\"has\"\"quote\"")
        #expect(Formatting.csvEscape("has\nnewline") == "\"has\nnewline\"")
    }
}

// MARK: - Catalog CSV Writer Tests

struct CatalogCSVWriterTests {

    @Test func csvTextIncludesHeadersAndEscapedRecordFields() {
        let record = VideoRecord()
        record.filename = "clip, \"one\".mov"
        record.ext = "mov"
        record.streamTypeRaw = "Video+Audio"
        record.size = "1.0 MB"
        record.sizeBytes = 1_048_576
        record.duration = "00:00:10"
        record.duplicateDisposition = .extraCopy
        record.duplicateBestMatchFilename = "keeper.mov"
        record.duplicateReasons = "same hash, size"
        record.fullPath = "/Volumes/Archive/clip, \"one\".mov"
        record.directory = "/Volumes/Archive"
        record.notes = "line one\nline two"

        let lines = CatalogCSVWriter.csvText(records: [record]).components(separatedBy: "\n")

        #expect(lines.first?.hasPrefix("Filename,Extension,Stream Type") == true)
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("\"clip, \"\"one\"\".mov\",mov,Video+Audio"))
        #expect(lines[1].contains("\"same hash, size\""))
        #expect(lines[1].hasSuffix("\"line one"))
        #expect(lines[2] == "line two\"")
    }

    @Test func outputURLUsesScannedFolderName() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let path = CatalogCSVWriter.outputURL(root: "/Volumes/Family Media", date: date).path

        #expect(path.contains("/Desktop/VideoScan_Family Media_"))
        #expect(path.hasSuffix(".csv"))
    }
}

// MARK: - Formatting Extended Tests

struct FormattingExtendedTests {

    @Test func durationEdgeCases() {
        #expect(Formatting.duration(0) == "00:00:00")
        #expect(Formatting.duration(0.5) == "00:00:00")
        #expect(Formatting.duration(59) == "00:00:59")
        #expect(Formatting.duration(60) == "00:01:00")
        #expect(Formatting.duration(3600) == "01:00:00")
        #expect(Formatting.duration(3661) == "01:01:01")
        #expect(Formatting.duration(86400) == "24:00:00")
    }

    // regression: #28 — Byte size formatting: sub-KB values are whole bytes; non-round values one decimal
    @Test func humanSizeEdgeCases() {
        #expect(Formatting.humanSize(0) == "0 B")
        #expect(Formatting.humanSize(1) == "1 B")
        #expect(Formatting.humanSize(999) == "999 B")
        #expect(Formatting.humanSize(2_500_000_000) == "2.5 GB")
    }
}
