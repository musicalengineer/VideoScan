"""scripts/complexity_metrics.py: Swift source neutralised before lizard reads it.

lizard's Swift reader predates Swift 5.7 regex literals and reads every `#` as
a C preprocessor line. Cloud review N1007 (section 0) found the nightly top-15
entry `HallieLineageQuestion.isFetchClause.get` CCN 93 was really three
functions (a `get` inside `/\\b(?:get|fetch)\\b/` opened an "accessor"), and
`HalliePersonaQuestion.init` was really `detect` (`.map(String.init)`).
Synthetic snippets only; nothing here scans the repo."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import complexity_metrics as cm  # noqa: E402

PATH = "VideoScan/VideoScan/Hallie/Synthetic.swift"


def neutral(src: str) -> str:
    out = cm.neutralize_swift_for_lizard(src)
    assert out.count("\n") == src.count("\n"), "line count must never change"
    return out


# ------------------------------------------------------------ tokenizer (pure)

def test_bare_regex_in_expression_position_becomes_an_empty_string():
    src = "let verbs = /\\b(?:get|fetch)\\b/\nif s.firstMatch(of: /a[/]b/) != nil { return /x/ }\n"
    assert neutral(src) == 'let verbs = ""\nif s.firstMatch(of: "") != nil { return "" }\n'


def test_division_is_untouched():
    for src in ("let r = a / b / c\n", "let r = (a)/b/c\n", "let r = total/count/2\n",
                "x /= 2; y = x! / 3 / 4\n", "let r = items[0]/n/m\n",
                "static func / (lhs: V, rhs: V) -> V { lhs }\n"):
        assert neutral(src) == src, src


def test_comments_are_untouched():
    src = ("// see /get/ and a / b /\n"
           "/* a block /get/ comment /* nested /x/ */ still comment */\n"
           "let a = 1 // trailing /get/\n")
    assert neutral(src) == src


def test_strings_and_interpolations_are_untouched():
    src = ('let p = "/usr/bin/get/"\n'
           'let q = "\\(a / b) and /get/ \\("in" + "/x/")"\n'
           'let m = """\n  /get/ "quoted" \\(a / b)\n  """\n')
    assert neutral(src) == src


def test_a_slash_followed_by_space_is_an_operator_not_a_regex():
    src = "let r = f(/ x /)\n"
    assert neutral(src) == src


def test_extended_regex_single_and_multi_line_keep_the_line_count():
    single = 'let r = #/^(.*-)(\\d+)$/#\nlet s = ##/a/#b/##\n'
    assert neutral(single) == 'let r = ""\nlet s = ""\n'
    multi = ("let r = #/\n"
             "  (?<verb> get | fetch )   # a get here\n"
             "  \\s+ tree\n"
             "  /#\n"
             "let after = 1\n")
    out = neutral(multi)
    assert out == 'let r = ""\n\n\n\nlet after = 1\n'
    assert out.split("\n").index("let after = 1") == multi.split("\n").index("let after = 1")


def test_raw_strings_become_empty_strings_and_other_hashes_spaces():
    src = ('return xs.contains { s.range(of: #"\\b"# + $0 + #"\\b"#) != nil }\n'
           '#if DEBUG\n'
           'if #available(macOS 26, *) { f(#selector(g)) }\n'
           '    #endif\n')
    assert neutral(src) == ('return xs.contains { s.range(of: "" + $0 + "") != nil }\n'
                            '#if DEBUG\n'
                            'if  available(macOS 26, *) { f( selector(g)) }\n'
                            '    #endif\n')


def test_regex_spans_report_only_regex_literals():
    src = 'let a = /x/\nlet b = #"y"#\nlet c = #/z/#\n'
    assert [src[s:e] for s, e in cm.swift_regex_literal_spans(src)] == ["/x/", "#/z/#"]


# ------------------------------------------------------------ through lizard

lizard = pytest.importorskip("lizard")

# Modelled on HallieLineageQuestion.isGetFamilyTree / isFetchClause /
# gedcomProvenanceQuestion (2026-10-06): stock lizard reports a `get` "accessor"
# opened inside the first regex that swallows both neighbours.
FETCH_FIXTURE = """enum Lineage {
    static func isGetFamilyTree(_ lower: String) -> Bool {
        lower.split(separator: clauseSeam).contains { clause in
            isFetchClause(String(clause))
        }
    }

    private static func isFetchClause(_ lower: String) -> Bool {
        let verbs = /\\b(?:get|fetch|download|pull)\\b/
        let object = /\\b(?:family ?search|gedcom|tree)\\b/
        guard lower.firstMatch(of: verbs) != nil, lower.firstMatch(of: object) != nil else { return false }
        if lower.firstMatch(of: interrogative) != nil { return false }
        if lower.contains("familysearch") || lower.contains("family search") { return true }
        return lower.firstMatch(of: /\\b(?:get|fetch) (?:more (?:of )?)?(?:the |my )?(?:tree|gedcom)\\b/) != nil
            || lower.firstMatch(of: /\\b(?:more|deeper) (?:generations|ancestors)\\b/) != nil
            || lower.firstMatch(of: /\\b(?:update|refresh) (?:the )?tree\\b/) != nil
    }

    static func provenance(in lower: String) -> String? {
        guard lower.firstMatch(of: /\\b(?:gedcom|tree)\\b/) != nil else { return nil }
        var surname: String?
        if let m = lower.firstMatch(of: /\\bthe ([a-z][a-z'-]+) (?:line|side)\\b/) {
            surname = String(m.1)
        } else if let m = lower.firstMatch(of: /\\b(?:for|of) the ([a-z]+s)\\b/) {
            surname = String(m.1)
        }
        return surname
    }
}
"""


def lizard_names(src: str):
    cm.install_swift_property_support()
    return [f.name for f in lizard.analyze_file.analyze_source_code(PATH, src).function_list]


def test_fixture_reproduces_the_bug_without_neutralising():
    """Red proof: raw lizard opens a `get` inside the regex."""
    assert "get" in lizard_names(FETCH_FIXTURE)


def test_get_inside_a_regex_does_not_create_a_function():
    funcs, _ = cm.analyze_sources({PATH: FETCH_FIXTURE})
    assert [(f.display, f.ccn, f.start_line) for f in sorted(funcs, key=lambda f: f.start_line)] == [
        ("Lineage.isGetFamilyTree", 1, 2),
        ("Lineage.isFetchClause", 7, 8),
        ("Lineage.provenance", 4, 19),
    ]


def test_member_init_reference_does_not_open_an_initializer():
    src = """struct Persona {
    static func detect(_ q: String) -> Int {
        var words = q.split(separator: " ").map(String.init)
        if words.isEmpty { return 0 }
        if words.count > 3 { return 2 }
        return cache.get(1) ?? words.count
    }
}
"""
    funcs, _ = cm.analyze_sources({PATH: src})
    assert [(f.display, f.ccn) for f in funcs] == [("Persona.detect", 3)]


def test_raw_string_and_availability_keep_braces_balanced():
    src = """struct Years {
    static func supplies(_ q: String) -> Bool {
        let spelled = ["nineteen", "twenty"]
        return spelled.contains { q.range(of: #"\\b"# + $0 + #"\\b"#, options: .regularExpression) != nil }
    }

    static func modern() -> Int {
        if #available(macOS 26, *) {
            return 1
        }
        return 0
    }

    static func after(_ x: Int) -> Int {
        if x > 1 { return 1 }
        return 0
    }
}
"""
    raw = [(f.name, f.start_line, f.end_line)
           for f in lizard.analyze_file.analyze_source_code(PATH, src).function_list]
    assert raw != [("supplies", 2, 5), ("modern", 7, 12), ("after", 14, 17)]   # red proof
    funcs, _ = cm.analyze_sources({PATH: src})
    assert [(f.display, f.ccn, f.start_line, f.end_line) for f in funcs] == [
        ("Years.supplies", 1, 2, 5),
        ("Years.modern", 2, 7, 12),
        ("Years.after", 2, 14, 17),
    ]
