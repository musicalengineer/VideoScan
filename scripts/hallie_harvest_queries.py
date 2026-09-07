#!/usr/bin/env python3
"""Harvest Rick's real Hallie questions into the eval testbed.

Rick, 2026-09-01: "Every time I have a session, you should pick up any new
queries you don't already have and add them to the hallie testbed."

Reads the app-client user turns from the conversation transcript
(~/Library/Logs/VideoScan/Hallie/hallie-conversation-*.jsonl), drops what the
corpus already has, and prints corpus entries under category "live" with a
GUESSED expectation and the note "expectation unconfirmed" — a human reads
the answer in the next eval run and confirms or fixes the expectation.

Statements ("Ellen is my sister.") are skipped by default: replayed in a
headless eval they would enter telling mode and write to CyberBrain. Pass
--include-statements to list them for hand review. Pronunciation-drill
turns ("say latta", "let me rate the pronunciations") are skipped too.

Usage:
  scripts/hallie_harvest_queries.py --since 2026-09-01            # print JSON entries
  scripts/hallie_harvest_queries.py --since 2026-09-01 --append   # append to the corpus
"""
import argparse
import glob
import json
import re
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOG_DIR = Path.home() / "Library/Logs/VideoScan/Hallie"
CORPUS = REPO / "tests/hallie_eval_corpus.json"

# The lineage route accepts trace/follow/walk/take as query verbs
# (HallieLineageQuestion.swift:262) but the harvester did not, so
# "trace my line back to europe" — a live 2026-09-07 miss that produced a
# self-contradictory answer — never reached the corpus. If the app treats a
# verb as a question, so does this.
OPENERS = ("who", "what", "where", "when", "why", "how", "which", "whose",
           "did", "do", "does", "is", "was", "are", "were", "can", "could",
           "would", "should", "show", "tell", "find", "play", "list", "give",
           "any", "count", "say", "pronounce", "describe", "get", "search",
           "trace", "follow", "walk", "take", "open", "compare")
FILLERS = ("hallie", "ok", "okay", "so", "and", "please", "hey", "now")
PRONUNCIATION = re.compile(r"\b(pronounc|pronunciation|say it|say \w+$|drill|respell)", re.I)
SOCIAL = re.compile(r"^(hi|hello|hey|thanks|thank you|bye|good ?night|good morning|how are you)", re.I)
MEDIA = re.compile(r"\b(video|videos|clip|clips|footage|film|tape|catalog|archive|photo|photos|picture)\b", re.I)
KIN = re.compile(r"\b(brothers?|sisters?|sons?|daughters?|father|mother|dad|mom|ma|parents?|married|marry|wife|husband|cousins?|uncles?|aunts?|grand\w*|siblings?|born|died|ancestors?|related|family tree|tree)\b", re.I)
COUNT = re.compile(r"\b(how many|count)\b", re.I)


def normalize(text):
    return re.sub(r"\s+", " ", text.strip().lower())


def is_question(text):
    words = normalize(text).split()
    if not words:
        return False
    if text.strip().endswith("?"):
        return True
    # "Ellen is my sister" is a statement even though its second word is
    # an opener; only a lead-in filler may precede the opener.
    if words[0] in OPENERS:
        return True
    if words[0] in FILLERS and len(words) > 1 and words[1] in OPENERS:
        return True
    # A FRONTED CLAUSE STILL ASKS (2026-09-07). Only the first word of the
    # whole line was ever consulted, so Rick's
    #   "in the family tree going back, find the highest level of royalty"
    # was dropped for starting with "in" — while "search the family tree for
    # a title like king", the same question asked plainly, was kept. Both
    # failed live that morning and only one reached the testbed. Each
    # comma-separated clause gets the same opener test.
    for clause in normalize(text).split(","):
        clause_words = clause.split()
        if clause_words and clause_words[0] in OPENERS:
            return True
        if (len(clause_words) > 1 and clause_words[0] in FILLERS
                and clause_words[1] in OPENERS):
            return True
    return False


# A CORRECTION IS A TURN WORTH TESTING (2026-09-07). "not in videos, in family
# tree" is neither a question nor a statement, so it was dropped — yet it is
# exactly where Hallie failed: the refinement path answered "I can only drop a
# person, not a topic word". Deliberately narrow, and it must never widen to
# swallow ordinary statements ("she was born in 1943"), which replay into
# telling mode and write to CyberBrain.
CORRECTION = re.compile(
    r"^(no[,.]?\s|not\s|i meant\b|i mean\b|nope\b|wrong\b|that'?s not\b)", re.I)


def is_correction(text):
    return bool(CORRECTION.match(text.strip()))


def guess_expect(text):
    if SOCIAL.search(text):
        return "social"
    if COUNT.search(text) and MEDIA.search(text):
        return "catalog"
    if MEDIA.search(text):
        return "catalog"
    if KIN.search(text):
        return "kinship"
    if re.match(r"^(tell me about|who was|who is)\b", text.strip(), re.I):
        return "biography"
    return "catalog"


def read_turns(since):
    turns = []
    for filename in sorted(LOG_DIR.glob("hallie-conversation-*.jsonl")):
        day = filename.name[len("hallie-conversation-"):-len(".jsonl")]
        if day < since:
            continue
        with open(filename) as f:
            for line in f:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if event.get("client") == "app" and event.get("kind") == "user":
                    turns.append(event)
    return turns


def harvest(turns, existing, include_statements=False, stamp=None, used_ids=()):
    stamp = stamp or time.strftime("%Y-%m-%d")
    seen, out = set(existing), []
    # IDS CONTINUE THE DAY, they do not restart it (2026-09-07). The ordinal
    # was len(out) + 1 — the count within THIS run — so a second harvest on
    # the same day began again at 001 and collided with the morning's
    # entries. Two questions shared lv260907-001 and nothing keyed by id
    # could tell them apart.
    prefix = f"lv{stamp.replace('-', '')[2:]}-"
    taken = [int(i[len(prefix):]) for i in used_ids
             if i.startswith(prefix) and i[len(prefix):].isdigit()]
    ordinal = max(taken, default=0)
    last_session, last_kept = None, False
    for index, event in enumerate(turns, 1):
        text = (event.get("text") or "").strip()
        key = normalize(text)
        session = event.get("sessionID")
        if not text or text.startswith(":") or key in seen:
            last_kept = key in seen and session == last_session
            last_session = session
            continue
        if PRONUNCIATION.search(text) or len(text) > 200:
            last_session, last_kept = session, False
            continue
        correction = (is_correction(text) and session == last_session and last_kept)
        if not is_question(text) and not correction and not include_statements:
            last_session, last_kept = session, False
            continue
        seen.add(key)
        entry = {
            "id": f"{prefix}{ordinal + len(out) + 1:03d}",
            "category": "live",
            "text": text,
            "expect": guess_expect(text),
            "notes": f"harvested {stamp} from the app transcript "
                     f"({(event.get('timestamp') or '')[:10]}); expectation unconfirmed",
        }
        if session == last_session and last_kept:
            entry["followsPrevious"] = True
        out.append(entry)
        last_session, last_kept = session, True
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--since", required=True, help="YYYY-MM-DD (transcript day, UTC)")
    parser.add_argument("--corpus", default=str(CORPUS))
    parser.add_argument("--include-statements", action="store_true")
    parser.add_argument("--append", action="store_true", help="write into the corpus")
    args = parser.parse_args(argv)

    with open(args.corpus) as f:
        corpus = json.load(f)
    existing = {normalize(q["text"]) for q in corpus["questions"]}
    entries = harvest(read_turns(args.since), existing, args.include_statements,
                      used_ids={q.get("id", "") for q in corpus["questions"]})
    if not args.append:
        print(json.dumps(entries, indent=1, ensure_ascii=False))
        print(f"[harvest] {len(entries)} new", file=sys.stderr)
        return 0
    corpus["questions"].extend(entries)
    corpus["description"] = re.sub(r"\d+ questions", f"{len(corpus['questions'])} questions",
                                   corpus["description"], count=1)
    with open(args.corpus, "w") as f:
        # indent=1 MATCHES THE FILE (2026-09-07). Writing indent=2 into an
        # indent=1 corpus rewrote all 2,565 lines on every append, so a
        # four-question harvest showed up as a 5,160-line diff and nothing in
        # it could be reviewed — the same shape as every other bug found
        # today: a real change hidden inside noise. A corrupted entry would
        # have been invisible.
        json.dump(corpus, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"[harvest] appended {len(entries)} → {args.corpus} ({len(corpus['questions'])} questions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
