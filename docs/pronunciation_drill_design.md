# Pronunciation drill — Hallie learns names from Rick, not from guesses

**Status:** PROPOSED 2026-08-29 (Rick's idea). Build after auto-pins + relationships overview. Verify: codex nightly STT lane (#860/#861).

Rick: "we have the most common pronunciations in a sheet and have hallie go through it until I judge it correct. McGill is Ma-Gill or MicGill. Edith is Ee-dith… every time we find a new one, I can spell it out for Hallie in the chat and tell her 'pronounce McGill like MahGill or MicGill' and she will say 'OK, noted', and then she will say it back."

## Principles
- The machine builds the sheet; Rick judges; Hallie confirms by saying it back. No derived pronunciation is spoken as if correct until judged (the neighbor-demo lesson).
- Taught entries are the truth (`Hallie/pronunciations.json`, existing). Alternatives allowed ("MahGill | MicGill"); first is spoken.
- Codex verifies at night: STT round-trip on every taught name; report drift.

## Pieces
1. **Drill list (derived):** distinct given names + surnames from the compiled tree + People tab, ordered by expected utterance frequency (People-tab family → roots' near ancestry → the rest by descendant count), minus names already taught; persisted with status (untested / judged-ok / taught / alternatives), keyed by normalized name.
2. **Drill mode (chat or a small sheet):** "Hallie, let's practice names" → she says the next name (Kokoro), shows it; Rick replies "right" / "no — MahGill" / "either MahGill or MicGill" / "skip"; she says "OK, noted — McGill" (read-back with the new pronunciation) and advances. Voice or text input; deterministic parsing (no model).
3. **One-off teaching in chat:** "pronounce X like Y" (exists) + read-back (add) + "OK, noted".
4. **Manifest for verification:** machine-readable expected tokens (name → phonemes/respelling → status) for codex's nightly audit (his ask in #861).
5. **Logging:** counts and applied sources only; never full names/prose at public OSLog level (codex #861).

## Tests
Parser matrix (right/no/either/skip/like forms), list ordering with a synthetic tree + profiles, persistence/isolation, read-back text, manifest shape, scale (39k names < 200 ms).
