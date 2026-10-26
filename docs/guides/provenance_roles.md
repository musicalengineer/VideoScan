# Provenance roles — what each file is, in Rick's words

*Policy, agreed 2026-10-26. Rulings in `docs/DECISIONS.md`. Words chosen by Rick; the CSV carries the standard (FADGI / PBCore) term beside each so a professional can read the index.*

## The starting point

No file is a designated Master yet. Every file's role is **Unknown** until Rick sets it, one by one. Files reached FamilyArchive because they were dated, had their sound checked and were worth keeping — that is not provenance. The machine may **suggest** a role (sound and picture matches, names, DV recorded dates); a suggestion is always shown as a suggestion, never as a fact, and a role Rick rejected is never suggested again for that file.

## The roles

| Role | Means | Example | Standard term (CSV) |
|---|---|---|---|
| **Original** | The physical thing — tape, film reel, camera card. Not a file; named so a Master can say where it came from. *Not stored yet.* | the 1998 Cape Cod DV cassette | Original (carrier) |
| **Master** | The first faithful transfer of the Original — for DV usually a bit-for-bit transfer — untouched. One per Original. | `CapeCodJune1998-Peekaboo.dv` (probably) | Preservation master |
| **Camera Original** | A file that was never on tape: straight off a camcorder or phone. It is its own master. | `.MTS`, iPhone `.mov` | Original (born digital) |
| **Alternate Capture** | Another transfer of the same Original (another deck, another day, another trim). If it turns out better, it becomes the Master and the old Master becomes the Alternate — both decisions are logged. | `CapeCpd_1998.dv` | Preservation master (alternate) |
| **Remastered Copy** | Made from a Master to look or sound better: Topaz, audio balance, deinterlace, colour. | `…_balanced.mov`, `.vs.preserve.mkv` | Mezzanine |
| **Edit Copy** | A working copy made for editing (FCP/iMovie-friendly codec), because the Master's format (e.g. MKV/FFV1) edits badly. | `.vs.edit.mov` | Mezzanine (edit) |
| **Excerpt** | A clip cut from a longer recording; keeps its in/out points (e.g. 5:05–5:30). | `Peekaboo.mov` | Excerpt |
| **View Copy** | For watching, streaming, publishing, sharing: compressed and smaller. | `.vs.archive.mov`, `.mp4` | Access copy |
| **Test Copy** | An experiment kept for reference; never a keeper. | `…_prob4.mov`, `_dtv4`, `_tvai` | — |
| **Unknown** | The default. | every file today | — |

## The rules

1. **A role belongs to the content (whole-file SHA-256), not the path.** Byte-identical copies share one role automatically; a plain copy is not a role.
2. **One Master per Original.** Every other transfer of it is an Alternate Capture.
3. **Everything except a Master or Camera Original points back to what it came from** (the existing `lineage` link): a Remastered, Edit or View Copy to the file it was made from; an Excerpt to its source with in/out times. A Master will point to its Original once Originals are stored.
4. **When the source is lost.** If an Excerpt or a copy is the only surviving version, Rick may mark it **Master** — the role records "source not in the catalog", so it stays honest that it is a clip or a re-encode.
5. **Only Rick sets a role.** Background jobs suggest; they never set.

## In the app

- **Provenance ▸ Find ▸ Master (sound)** — the search (built 10/26). Later finds join this submenu.
- **Provenance ▸ Set Role ▸** Master · Camera Original · Alternate Capture · Remastered Copy · Edit Copy · Excerpt · View Copy · Test Copy · Unknown.
