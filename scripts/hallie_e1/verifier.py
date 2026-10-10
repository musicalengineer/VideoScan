"""Verifier for submit_answer (Python port of the rev-5 rules, spec §5.2).

1. Turn-local provenance: every id a claim cites must have been returned by a
   tool in THIS turn. Otherwise the claim is dropped and counted as an
   unverified fact (a fact about last turn's person cannot be spoken).
2. Prose: a sentence citing only dropped claims is removed; an uncited
   sentence that states a name, date, number or place is removed. Words the
   asker used, names listed as unresolved, and the candidate names in a
   which-one question are not assertions and do not trigger removal.
3. Subject check: every person the asker named and resolve_person resolved
   this turn must be in subjectIDs (or the name in `unresolved`). A miss is
   wrong_subject and the turn becomes a decline.

Not ported (left to the judge pass): re-deriving each claim's VALUE from the
snapshot (exact date incl. qualifier, re-run counts, BFS path).
"""
from __future__ import annotations

import re

CITE = re.compile(r"\[(c\d+)\]")
SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"'“(\[])")
NOT_NAMES = {"I", "I'm", "I'd", "I'll", "I've", "Hallie", "OK", "Okay", "Yes", "No", "Hi", "Hello", "Sorry",
             "Thanks", "Thank", "Want", "Would", "Shall", "Should", "Could", "Can", "Do", "Did", "Does", "Is",
             "Are", "Was", "Were", "There", "That", "This", "These", "Those", "It", "The", "A", "An", "If",
             "And", "But", "Or", "So", "As", "For", "In", "On", "At", "By", "With", "From", "To", "Of",
             "Here", "Your", "You", "My", "We", "Our", "They", "Their", "He", "She", "His", "Her", "Which",
             "What", "When", "Where", "Who", "Why", "How", "One", "Both", "Neither", "None", "Some", "All",
             "Family", "Tree", "People", "Videos", "Video", "Transcript", "Transcripts"}
DECLINED_TEXT = "I couldn't confirm that from the records, so I won't guess. Can you tell me a bit more?"
WRONG_SUBJECT_TEXT = ("I'm not sure I found the person you mean, so I won't guess. "
                      "Could you tell me a bit more about who you're asking about?")


def _norm_tokens(s: str) -> list[str]:
    s = (s or "").lower().replace("’", "").replace("'", "")
    return re.findall(r"[a-z0-9]+", s)


def split_sentences(prose: str) -> list[str]:
    parts = []
    for para in (prose or "").split("\n"):
        parts += [p for p in SENTENCE.split(para.strip()) if p.strip()]
    return parts


def states_fact(sentence: str, question: str, exempt_words: set[str]) -> bool:
    """A name, date, number or place the asker did not supply."""
    body = CITE.sub("", sentence)
    q_digits = set(re.findall(r"\d+", question))
    if any(d not in q_digits for d in re.findall(r"\d+", body)):
        return True
    q_words = {w.lower() for w in re.findall(r"[A-Za-z][\w'’-]*", question)}
    words = re.findall(r"[A-Za-z][\w'’-]*", body)
    for i, w in enumerate(words):
        if not w[0].isupper() or w in NOT_NAMES:
            continue
        base = w.lower().rstrip("s").replace("’", "'").split("'")[0]
        if w.lower() in q_words or base in q_words or w.lower() in exempt_words or base in exempt_words:
            continue
        if i == 0:
            continue     # sentence-initial capital is grammar, not a name
        return True
    return False


def asked_names(question: str, resolve_calls: list[tuple[str, dict]]) -> list[tuple[str, dict]]:
    """resolve_person calls whose name came from the question's own words."""
    q = _norm_tokens(question)
    out = []
    for name, res in resolve_calls:
        toks = [t for t in _norm_tokens(name) if t not in ("my", "the", "s", "of", "side")]
        if not toks or not res.get("ok") or not res.get("items"):
            continue
        if all(any(qt == t or qt.startswith(t) for qt in q) for t in toks):
            out.append((name, res))
    return out


def verify(submit: dict, turn_ids: set[str], question: str,
           resolve_calls: list[tuple[str, dict]]) -> dict:
    claims = submit.get("claims") or []
    kept, dropped = [], []
    for c in claims:
        cites = [x for x in (c.get("cites") or []) if isinstance(x, str)]
        bad = [x for x in cites if x not in turn_ids]
        if not cites:
            dropped.append({**c, "why": "no citation"})
        elif bad:
            dropped.append({**c, "why": f"cites id(s) no tool returned this turn: {bad}"})
        else:
            kept.append(c)
    kept_ids = {c.get("id") for c in kept}
    outcome = submit.get("outcome") or "answered"
    unresolved = [u for u in (submit.get("unresolved") or []) if isinstance(u, str)]
    exempt = {w.lower() for u in unresolved for w in re.findall(r"[A-Za-z][\w'’-]*", u)}
    out, stripped = [], []
    for s in split_sentences(submit.get("prose") or ""):
        refs = CITE.findall(s)
        if refs and not any(r in kept_ids for r in refs):
            stripped.append({"sentence": s, "why": "cites only dropped or unknown claims"})
            continue
        if not refs and states_fact(s, question, exempt):
            if outcome == "needsClarification" and s.rstrip().endswith("?"):
                out.append(s)      # naming the candidates in a which-one question is not an assertion
                continue
            stripped.append({"sentence": s, "why": "uncited name/date/number/place"})
            continue
        out.append(s)

    subject_ids = [x for x in (submit.get("subjectIDs") or []) if x in turn_ids]
    wrong = []
    if outcome == "answered":
        for name, res in asked_names(question, resolve_calls):
            cand = set()
            for it in res["items"]:
                cand.add(it.get("id"))
                cand |= set(it.get("sameAs") or [])
            if cand & set(subject_ids):
                continue
            if any(name.lower() in u.lower() or u.lower() in name.lower() for u in unresolved):
                continue
            wrong.append(name)

    answer_cited = " ".join(out).strip()
    answer = re.sub(r"\s+([.,;:!?])", r"\1", CITE.sub("", answer_cited)).strip()
    answer = re.sub(r"\s{2,}", " ", answer)
    final_outcome, empty = outcome, False
    if wrong:
        final_outcome, answer, answer_cited = "declined", WRONG_SUBJECT_TEXT, WRONG_SUBJECT_TEXT
    elif not answer:
        final_outcome, answer, answer_cited, empty = "declined", DECLINED_TEXT, DECLINED_TEXT, True
    return {
        "outcome": final_outcome, "answer": answer, "answerCited": answer_cited,
        "claims": kept, "droppedClaims": dropped, "unverifiedFacts": len(dropped),
        "strippedSentences": stripped, "subjectIDs": subject_ids,
        "subjectIDsNotThisTurn": [x for x in (submit.get("subjectIDs") or []) if x not in turn_ids],
        "unresolved": unresolved, "wrongSubject": bool(wrong), "wrongSubjectNames": wrong,
        "emptyAfterVerify": empty,
    }
