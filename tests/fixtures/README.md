# Test fixtures — media policy

This public repo contains **no personal media, in any form** — not even
encrypted. What you'll find:

- `videos/test_*.{mp4,mov,mkv,mxf,wav,m4a}` — synthetic clips generated with
  ffmpeg. Tracked in git, free to use.

Everything else the person-finding features need — reference photo
galleries, labeled family video corpora, the About-screen collage sources —
lives only on the project owner's machines and backups, restored to a new
machine by ordinary file copy. CI needs none of it; only the local
PersonFinder manifest suite (`tests/run_personfinder_tests.py`) reads real
photos.

## If you are anyone else

**You must supply your own photos and videos.** The person-finding features
are tested against reference photos of real people — bring 5–10 photos per
person per decade (see `docs/donna-recipe-v1.md` for what makes a good
reference set) and your own labeled video clips, arranged as:

    tests/fixtures/photos/<YourPerson>/<era>/*.jpg
    tests/fixtures/videos/<YourPerson>TestVideos/{<YourPerson>,Not<YourPerson>}/*.mov

These paths are gitignored — your media can never be committed either.

(`tools/media-vault/` is an optional owner-side tool for making
AES-256-encrypted copies of the galleries onto backup drives; its output is
gitignored and never pushed.)
