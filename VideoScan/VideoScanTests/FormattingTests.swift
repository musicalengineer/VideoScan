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

    @Test func humanSize() {
        #expect(Formatting.humanSize(0) == "0.0 B")
        #expect(Formatting.humanSize(512) == "512.0 B")
        #expect(Formatting.humanSize(1024) == "1.0 KB")
        #expect(Formatting.humanSize(1_048_576) == "1.0 MB")
        #expect(Formatting.humanSize(1_073_741_824) == "1.0 GB")
        #expect(Formatting.humanSize(1_099_511_627_776) == "1.0 TB")
    }

    @Test func csvEscape() {
        #expect(Formatting.csvEscape("hello") == "hello")
        #expect(Formatting.csvEscape("has,comma") == "\"has,comma\"")
        #expect(Formatting.csvEscape("has\"quote") == "\"has\"\"quote\"")
        #expect(Formatting.csvEscape("has\nnewline") == "\"has\nnewline\"")
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

    @Test func humanSizeEdgeCases() {
        #expect(Formatting.humanSize(0) == "0.0 B")
        #expect(Formatting.humanSize(1) == "1.0 B")
        #expect(Formatting.humanSize(1023) == "1023.0 B")
        #expect(Formatting.humanSize(2_500_000_000) == "2.3 GB")
    }
}
