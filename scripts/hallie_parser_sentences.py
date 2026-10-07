#!/usr/bin/env python3
"""Build the input set for the Hallie parser back-to-back oracles (GH #281, R3).

The refactor of HalliePersonaQuestion.detect (and later the lineage parser)
is gated by a test that runs the frozen pre-refactor code and the new code
over the same sentences and demands identical output. This script gathers
those sentences into tests/fixtures/hallie_parser_sentences.json:

  * every question in the Hallie corpora (text / input / question fields,
    and the prompts / turns lists): hallie_strict_regressions.json (the
    STRICT nightly lane), hallie_eval_corpus.json,
    hallie_interaction_corpus.json, hallie_live_misses_corpus.json,
    archivist_golden_answers.json, hallie_question_testbed.json;
  * every string literal of 2+ words in VideoScanTests/Hallie*.swift and
    Archivist*.swift (the parser tests' own sentences live there).

Case is kept: the persona parser reads capitalisation (a typed name past the
first word is a third party). Output is sorted and de-duplicated so a re-run
diff shows only real additions.

Usage: python3 scripts/hallie_parser_sentences.py   (from anywhere)
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORPORA = [
    "hallie_strict_regressions.json",
    "hallie_eval_corpus.json",
    "hallie_interaction_corpus.json",
    "hallie_live_misses_corpus.json",
    "archivist_golden_answers.json",
    "hallie_question_testbed.json",
]
TEXT_KEYS = {"text", "input", "question"}
LIST_KEYS = {"prompts", "turns"}
OUT = os.path.join(ROOT, "tests", "fixtures", "hallie_parser_sentences.json")

# A Swift string literal on one line ("…" with escapes; not """ blocks).
LITERAL = re.compile(r'(?<!")"((?:[^"\\\n]|\\.)*)"(?!")')


def corpus_strings(node, out, parent=None):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in TEXT_KEYS and isinstance(value, str):
                out.add(value)
            else:
                corpus_strings(value, out, key)
    elif isinstance(node, list):
        for value in node:
            if isinstance(value, str):
                if parent in LIST_KEYS:
                    out.add(value)
            else:
                corpus_strings(value, out, parent)


def unescape(literal):
    if "\\(" in literal:          # interpolation: not a fixed sentence
        return None
    return (literal.replace("\\u{2019}", "’").replace('\\"', '"')
            .replace("\\n", " ").replace("\\t", " ").replace("\\\\", "\\"))


def test_literals(out):
    tests = os.path.join(ROOT, "VideoScan", "VideoScanTests")
    for name in sorted(os.listdir(tests)):
        if not name.endswith(".swift") or not name.startswith(("Hallie", "Archivist")):
            continue
        with open(os.path.join(tests, name), encoding="utf-8") as handle:
            for match in LITERAL.finditer(handle.read()):
                text = unescape(match.group(1))
                if text and len(text.split()) >= 2 and len(text) <= 300:
                    out.add(text)


def main():
    corpus, literals = set(), set()
    for name in CORPORA:
        with open(os.path.join(ROOT, "tests", name), encoding="utf-8") as handle:
            corpus_strings(json.load(handle), corpus)
    test_literals(literals)
    sentences = sorted({s for s in corpus | literals if s.strip()})
    with open(OUT, "w", encoding="utf-8") as handle:
        json.dump({
            "description": "Inputs for the Hallie parser back-to-back oracles; "
                           "regenerate with scripts/hallie_parser_sentences.py",
            "corpusSentences": len(corpus),
            "testLiterals": len(literals),
            "sentences": sentences,
        }, handle, indent=1, ensure_ascii=False)
        handle.write("\n")
    print(f"{len(sentences)} sentences ({len(corpus)} corpus, {len(literals)} test literals) -> {OUT}")


if __name__ == "__main__":
    main()
