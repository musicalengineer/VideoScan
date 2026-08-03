# Test fixtures — media policy

This public repo contains **no plaintext personal media**. What you'll find:

- `videos/test_*.{mp4,mov,mkv,mxf,wav,m4a}` — synthetic clips generated with
  ffmpeg. Tracked in git, free to use.
- `../../vault/*.tar.gz.enc` — AES-256-encrypted archives of the project
  owner's personal reference photos (family face-recognition galleries and
  test-fixture photos). Without the password these are noise.

## If you are the project owner (or a machine you provisioned)

One-time per machine:

    tools/media-vault/unpack.sh

Enter the vault password once; it lands in the macOS Keychain and the
restored files persist in the working tree (gitignored — they can never be
committed). CI never needs this; only the local PersonFinder manifest suite
(`tests/run_personfinder_tests.py`) reads real photos.

## If you are anyone else

**You must supply your own photos and videos.** The person-finding features
are tested against reference photos of real people — bring 5–10 photos per
person per decade (see `docs/donna-recipe-v1.md` for what makes a good
reference set) and your own labeled video clips, arranged as:

    tests/fixtures/photos/<YourPerson>/<era>/*.jpg
    tests/fixtures/videos/<YourPerson>TestVideos/{<YourPerson>,Not<YourPerson>}/*.mov

The synthetic `test_*` fixtures cover everything that doesn't require a
human face.
