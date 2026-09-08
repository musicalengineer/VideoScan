# Hallie — who decides which field a question asks for

Status: **DESIGN AGREED IN PRINCIPLE, not started.** Written 2026-09-07 from
the three-way discussion Rick asked for (Claude, codex, qwen2.5-coder).

## The problem, from Rick's own session

He asked five questions about one deceased person and got the same death
sentence to all of them, including "whom did he marry" and "tell me all about
Edward III". Minutes later "his spouse?" answered correctly. The prose was not
in this codebase — the wording changed every time — so the **model** was
composing it: after a long run of turns about a dead man the translator
settled on `operation: death` and answered everything that way.

Nothing was broken. The guess was unreliable and unchecked.

## What was shipped today, and why it is not the answer

Three deterministic guards (`ea588b97`) run after the model and override the
operation when the sentence settles it: a place cue, exactly one relation
word, a whole-person request. They work, and they closed three of Rick's
failing shapes.

They are still the wrong shape. "how old was he when he died?" remains wrong
because age is a fourth field with no guard, and there will be a fifth. One
corrector per field is not a plan.

## The three views

**qwen2.5-coder:32b** — asked twice, the second time with neutral framing and
no signalled preference — picks full inversion: decide the operation
deterministically, remove it from the model's output schema. Its argument
against the guards is the sharp one: *post-checks still inherit the model's
first interpretation*, so complexity accumulates around a decision that
remains unreliable. Asked for the abstention rule, both times it said "defer
when ambiguous or context-dependent", which is a restatement of the problem.

**Claude (me)** — proposed the same inversion, and should be read with the
knowledge that my first prompt to qwen argued for it before asking. I had no
abstention principle either.

**codex** — disagreed with both of us, and is right. Not a total classifier: a
**partial recognizer**, adopted incrementally, with **three** outcomes rather
than two.

## The design (codex's, adopted)

```
        ┌─ recognized  → typed intent, executed
utterance ─┼─ abstain     → the model proposes; execution validates
        └─ conflict    → distinct from abstain, and reported as such
```

**The abstention principle, which is the part nobody else had.** A sentence is
recognized **only when the recognizer can account for its FULL supported
semantic shape** — every constraint in the utterance, not merely a cue it
spotted. Spotting a keyword and claiming the sentence is what my guards do,
and it is exactly how today's regressions happened:

- `"when did he get married"` — my resolver saw "when" and claimed it as a
  BIRTH question. It never accounted for "married". The full-shape rule
  refuses it, because a relation is present that the recognizer cannot place.
- `"how old was he when he died?"` — **derived age**, not a death date. A cue
  spotter sees "died"; a shape recognizer sees a derived quantity it has no
  intent for, and abstains.
- Compound asks ("where was he born and who did he marry") are multi-intent or
  abstain — never silently one of the two.

**The model proposes on abstention, and execution validates the proposal
against the current utterance and the executor's actual capability.** So the
model is not removed; it is demoted to a proposer whose output is checked,
which is the standing 2026-08-14 decision (deterministic composer, LLM
translates) applied one level deeper.

**Measurement — the thing that settles it rather than arguing.** Shadow-compare:
run the recognizer alongside the model on held-out paraphrases and the
multi-turn corpus, and optimize **wrong-operation rate** together with
coverage. We have 345 corpus questions and Rick's live sessions. This is what
makes "do the rules lose more than they gain" a measurable question rather
than a matter of taste, and it is checkable before anything ships.

Worth adding, from qwen: **track the abstention rate on live traffic.**
Climbing means the rules are too narrow; near zero means they are
over-claiming. It is the sensor that would have caught my birth-versus-death
mistake this afternoon within a day.

## What this does NOT settle

Entity resolution has the same abstention problem, and my proposed split had a
hole in it. Rick asked "how are we related, if at all, to king henry the 8th?"
and got a **true** answer about Philippa de Hainaut — the previous turn's
subject, inherited when the named person failed to resolve. Henry VIII is in
neither tree. Asked alone, "King Henry 8th" declines correctly; asked as one
of two people in a relationship question, a MISSING person is reported as an
AMBIGUOUS one.

So "the model keeps entity resolution because it needs judgement" is not
sufficient. Judgement must include being able to say *no such person*, and the
recognizer/abstain/conflict shape probably applies there too. See
`hallie_live_failures.md` for the three phrasings and their three different
answers.

## Order of work, when Rick says go

1. Shadow harness first — recognizer runs, result is compared and logged, and
   nothing it decides reaches an answer. Free to be wrong while it is measured.
2. One intent family at a time, promoted only when its wrong-operation rate on
   the corpus beats the model's.
3. The existing three guards become the first recognizers and stop being
   post-hoc overrides.
4. Entity resolution afterwards, on the same shape, once the field work has
   proven the pattern.

Nothing here is started. It replaces guard #4, #5 and #6, which is the point.
