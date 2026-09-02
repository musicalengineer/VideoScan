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

OPENERS = ("who", "what", "where", "when", "why", "how", "which", "whose",
           "did", "do", "does", "is", "was", "are", "were", "can", "could",
           "would", "should", "show", "tell", "find", "play", "list", "give",
           "any", "count", "say", "pronounce", "describe", "get", "search")
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
    return words[0] in FILLERS and len(words) > 1 and words[1] in OPENERS


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


def harvest(turns, existing, include_statements=False, stamp=None):
    stamp = stamp or time.strftime("%Y-%m-%d")
    seen, out = set(existing), []
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
        if not is_question(text) and not include_statements:
            last_session, last_kept = session, False
            continue
        seen.add(key)
        entry = {
            "id": f"lv{stamp.replace('-', '')[2:]}-{len(out) + 1:03d}",
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
    entries = harvest(read_turns(args.since), existing, args.include_statements)
    if not args.append:
        print(json.dumps(entries, indent=1, ensure_ascii=False))
        print(f"[harvest] {len(entries)} new", file=sys.stderr)
        return 0
    corpus["questions"].extend(entries)
    corpus["description"] = re.sub(r"\d+ questions", f"{len(corpus['questions'])} questions",
                                   corpus["description"], count=1)
    with open(args.corpus, "w") as f:
        json.dump(corpus, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"[harvest] appended {len(entries)} → {args.corpus} ({len(corpus['questions'])} questions)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
