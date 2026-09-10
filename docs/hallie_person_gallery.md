# Hallie person gallery — "show all photos of X"

*2026-09-10. Rick: "I want to be able to say to Hallie 'show all photos of
<person>'. Hallie looks the person up and if there are photos and documents
in that person's folder, shows them."*

## Intent

Any of these become the one photo shape, `HallieLineageQuestion.personPhoto`
(HallieLineageQuestion.swift), which the executor's photo ask answers
(`HallieTurnExecutor+PhotoAsk.swift`):

- "show all photos of X", "show me all the photos of X", "show every picture
  of X", "all photos of X", "show me pics of X", "show the photos of X"
- "show documents of X", "show me the papers of X", "what documents do we
  have for X" — documents route to the SAME gallery answer
- the older forms still work: "show me a photo of X", "are there any photos of X"

Pinned non-matches: a bare "photos of donna" (a catalog search), any two-person
form ("photos of rick and donna"), and a form with a year ("photos of donna
from 1992").

## Where the files come from

All read-only, all through `FamilyAssetStore`:

1. **Person folders** under `<Master Archive>/40_Family_Tree/People/`:
   the FamilySearch-ID folder, the resolved `<Name>[_bYYYY][_I<ID>]` folder
   (unchanged rule), and — new — every **alias folder**: a folder whose name
   key equals an alias the identity directory knows for that GEDCOM record
   (CyberBrain / People-tab aliases). "Christopher O'Connor" with alias
   "Christopher Dennis O'Connor" reads both `People/Christopher_OConnor/` and
   `People/Christopher_Dennis_OConnor/`. A folder pinned to another record
   (`_I999`), or with a birth year that disagrees with the person's, is never
   his; two bare same-name folders are an ambiguity and neither is read.
   `FamilyAssetStore.readFolderNames(for:aliases:among:)` is the pure rule.
   The WRITE side (`folderForPhotoRequest`) is unchanged: one unambiguous
   folder or refuse.
2. **Group folders** (`RickDonnaBreenFamily`, `Rick_and_Donna`) — as before.
3. **People-tab reference folder** for a person who is in the People tab but
   not in the family tree: cover first, then every other verified image
   directly inside `referencePath` (`ArchivistProfileGallery`; same safety
   rules as the biography cover — regular, non-symlink, ImageIO-decodable).
   These answers ride the presence route, not the graph route.

Photos: jpg / jpeg / png / heic and now **tif / tiff** (a TIFF has no
trailer; it passes on its `II*\0` / `MM\0*` header and ImageIO reading its
directory). Every image is re-verified at display time, as before.

## What counts as a document

A regular, non-symlink file directly inside one of the folders above with
extension **pdf, txt, rtf, md, doc, docx** (`FamilyAssetStore.
allowedDocumentExtensions`). Sidecars (`chosen-photo.json`, `*.notof.json`)
are never documents. Hallie never reads a document's bytes; the Mac card opens
it (or reveals it in Finder), the web page links it (`/api/attachment/<token>`
serves the bytes with the right Content-Type, capped at 48 MB, same
capability and descendant checks as an image token).

## The answer

`HallieGalleryAnswer.result`: photos first (chosen / portrait first, as
`photoURLs` orders), then documents, as attachments. Prose:

- one photo, no documents → "Here's X." (unchanged)
- otherwise "Here are N photos and M documents of X." / "Here is 1 document of X."
- **cap: 24 photos** in the chat — "Here are 30 photos of X — showing the
  first 24; the rest are in the folder."

Basis line: "Basis: N photos and M documents from the Master Archive's
40_Family_Tree/People folder(s) for this person." Offered actions: open in
Family Tree (tree people) and **Show folder in Finder** (`OfferedAction.
revealFolder`, Mac only; shell and web print the label). Three or more photos
render as a grid of 160 pt thumbnails on the Mac; a photo click opens the file.
The photography-floor line and the "put a photo in this folder" card are
unchanged for people with nothing on disk.

## The offer after a biography, and yes / no

`HallieGalleryOffer` (called from `HallieAppTurnCoordinator` after the
biography photo decision): when the biography's person — a unique tree match,
or a unique People profile — has **two or more** files (one photo is already
beside the biography), the prose gains one sentence:

> I have 3 photos and 1 document of her in the archive — want to see them all?

(pronoun from the record's sex; "them" when unknown), and the answer carries a
one-candidate clarification at stage `.galleryOffer` whose intent is
"show all photos of <name>".

- **yes** (also "sure", "please", "that one"…) → the shared matcher's
  single-candidate confirmation selects it; the ordinary continuation runs the
  photo ask with the chosen identity and returns the gallery.
- **no / not now / no thanks / cancel / never mind** →
  `HallieClarificationDecline`: the pending offer is cleared and Hallie says
  "Okay." — never "I won't guess which person you meant" (that line stays for
  real which-one questions). Chat window and shell share the table; the web
  client only takes chip selections.
- any other question just drops the offer (existing behaviour).

No offer when the biography declined, when the person predates photography
with zero files, or when the total is under two.

## Presentation, not evidence

Attachments and offered actions are things to LOOK at. Nothing here reaches
the translator prompt, the grounded composer, or the fact basis; the offer
sentence is a question Hallie asks, appended after composition, and the
answer plan is untouched. The catalog holds no photo or document records —
the person folders are the only source.

Tests: `HalliePersonGalleryStoreTests`, `HalliePersonGalleryDetectTests`,
`HalliePersonGalleryAnswerTests`; advisory eval items `gal001–gal003` in
`tests/hallie_eval_corpus.json`.
