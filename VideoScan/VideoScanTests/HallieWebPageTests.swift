// HallieWebPageTests.swift
// Structural pins for the family web page (written 2026-10-10 alongside the
// split of `html(archivistName:)` into one piece per concern; the split was
// verified byte-identical against the pre-split output for two names). These
// pin what the page must keep: its sections in document order, the archivist
// name escaped and placed where the family sees it, every script function the
// page relies on, and the offline promise — nothing fetched from outside the
// LAN.

import XCTest
@testable import VideoScan

final class HallieWebPageTests: XCTestCase {

    private let page = HallieWebPage.html(archivistName: "Hallie Mae")

    /// Index of `needle`, failing the test (and returning nil) when absent.
    private func position(of needle: String, in text: String? = nil,
                          file: StaticString = #filePath, line: UInt = #line) -> Int? {
        let haystack = text ?? page
        guard let range = haystack.range(of: needle) else {
            XCTFail("missing: \(needle)", file: file, line: line)
            return nil
        }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    func test_sectionsAppearInDocumentOrder() {
        let landmarks = [
            "<!doctype html>", "<html lang=\"en\">", "<head>", "<meta name=\"viewport\"",
            "<title>Hallie Mae</title>", "<style>", ":root {", "@media (prefers-color-scheme: dark)", "</style>",
            "</head>", "<body>", "<header>", "<h1>Hallie Mae</h1>", "id=\"modePill\"", "id=\"speakToggle\"",
            "id=\"voicePick\"", "id=\"whoBtn\"", "<nav>", "id=\"tabAsk\"", "id=\"tabBrowse\"", "<div id=\"log\">",
            "<div id=\"browse\">", "id=\"bsearch\"", "<form id=\"ask\">", "id=\"mic\"", "id=\"text\"",
            "<script>", "(function () {",
            // the five script pieces, in the order they are wired
            "var store = function", "function askWho()", "function askKey()", "function showMode(m)", "function add(role, text)",
            "// ---- Reading aloud", "function rankVoice(v)", "function fillVoices()", "function sentences(text)", "function sayAloud(text)",
            "function render(r)", "function personLine(p)", "function renderAttachment(a)", "function playInline(container, c)",
            "// ---- Browse", "function setTab(name)", "function loadTimeline()", "function matches(it, q)",
            "function browseRow(it)", "function renderTimeline()",
            "var busy = false;", "function send(payload)", "form.onsubmit", "window.SpeechRecognition",
            "the family archivist", "if (!who) setTimeout(askWho, 300);",
            "})();\n</script>", "</body>", "</html>",
        ]
        var last = -1
        for landmark in landmarks {
            guard let at = position(of: landmark) else { continue }
            XCTAssertGreaterThan(at, last, "\(landmark) is out of order")
            last = at
        }
        XCTAssertTrue(page.hasSuffix("</html>"), "nothing after the closing tag")
    }

    func test_archivistNameIsEscapedAndUsedEverywhereTheFamilySeesIt() {
        let html = HallieWebPage.html(archivistName: "A&B<x>")
        XCTAssertFalse(html.contains("A&B<x>"), "raw name must not reach the page")
        let escaped = "A&amp;B&lt;x>"
        XCTAssertEqual(html.components(separatedBy: escaped).count - 1, 6,
                       "web-app title, <title>, <h1>, the input placeholder, the who-prompt and the greeting")
        XCTAssertTrue(html.contains("<title>\(escaped)</title>"))
        XCTAssertTrue(html.contains("<h1>\(escaped)</h1>"))
        XCTAssertTrue(html.contains("placeholder=\"Ask \(escaped)…\""))
        XCTAssertTrue(html.contains("prompt('Who is talking to \(escaped)?"))
        XCTAssertTrue(html.contains("I\\u2019m \(escaped), the family archivist"))
    }

    func test_pageIsSelfContained_noExternalResources() {
        XCTAssertFalse(page.contains("://"), "no CDN, fonts, tracking or absolute URLs — LAN only")
        XCTAssertFalse(page.contains("<link "), "no external stylesheet")
        XCTAssertFalse(page.contains("src=\"http"), "no remote scripts or media")
        for api in ["/api/ask", "/api/timeline"] {
            XCTAssertTrue(page.contains("fetch('\(api)'"), "\(api) is fetched relative to the Mac")
        }
    }

    func test_scriptPiecesAreBalancedAndPlacedVerbatim() {
        // Each piece must be well-formed on its own (braces balance) and
        // land in the page unchanged, inside the one closure `html` opens.
        let pieces: [(String, String)] = [
            ("shellScript", HallieWebPage.shellScript(name: "Hallie Mae")),
            ("speechScript", HallieWebPage.speechScript),
            ("renderScript", HallieWebPage.renderScript),
            ("browseScript", HallieWebPage.browseScript),
            ("askScript", HallieWebPage.askScript(name: "Hallie Mae")),
        ]
        for (label, js) in pieces {
            let opens = js.filter { $0 == "{" }.count, closes = js.filter { $0 == "}" }.count
            XCTAssertEqual(opens, closes, "\(label): unbalanced braces")
            XCTAssertTrue(page.contains(js), "\(label) is placed verbatim in the page")
        }
        XCTAssertTrue(page.contains("<script>\n(function () {\n" + HallieWebPage.shellScript(name: "Hallie Mae")),
                      "the shell opens the closure")
        XCTAssertTrue(page.hasSuffix(HallieWebPage.askScript(name: "Hallie Mae") + "\n})();\n</script>\n</body>\n</html>"),
                      "asking closes it")
        XCTAssertTrue(page.contains(HallieWebPage.styles))
        XCTAssertTrue(page.contains(HallieWebPage.attachmentScript.components(separatedBy: "\n")[1]),
                      "the attachment cards stay inside renderScript")
    }
}
