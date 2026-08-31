# Web interface — taking Hallie and the archive beyond the LAN

**Status:** Preliminary design — not implemented. No code has been changed.
**Last updated:** 2026-08-31
**Author:** Claude, under Rick's direction
**TL;DR:** A working web interface already exists (`HallieWeb*.swift`, ~1,700
lines) and is deliberately scoped to the home network. Exposing it to the public
internet requires four security fixes and one feature that does not exist yet:
per-item public marking. The recommended shape is that the Swift server is
*never* exposed — it binds to loopback and a tunnel in front of it terminates TLS
and does per-person authentication.

---

## Goal

Let Rick's siblings — invited individually, revocable individually — reach
Hallie chat, the video archive, and photos from outside the house. They see only
what Rick has explicitly marked public, never the whole catalog.

This supersedes the forward references in
[family-archivist-design.md](family-archivist-design.md), which anticipated this
work from two directions:

- *Vision:* "a natural-language frontend so Rick — and eventually less-technical
  family, possibly via a future web interface — can talk to the archive."
- *Web reuse:* "translator is a pure String→spec function — the future family web
  interface reuses it behind HTTP."

The second point still holds and is why the server side was cheap to build: the
NL translator sits behind a seam that HTTP can call. Those passages stay in that
document as design rationale for the translator; this document owns the
deployment question.

---

## What exists today

`HallieWebAccess` is the on/off switch, owned by the app and persisted in the
same `archivist.*` defaults the chat window uses:

| Default key | Meaning |
|---|---|
| `archivist.webEnabled` | Start the server at launch |
| `archivist.webPort` | Listen port (default 8765) |
| `archivist.webPassphrase` | The single shared secret |

`HallieWebServer` is the listener (`NWListener`, one request per connection).
`HallieWebBridge` routes and does the work. `HallieWebPage` is the single-page
client. `HallieWebProxy` makes 720p H.264 access copies for tapes Safari cannot
decode, and `HallieWebPoster` caches poster frames — both respecting the
catalog's one-reader-per-HDD rule.

Routes, and whether they check the passphrase:

| Route | Auth | Purpose |
|---|---|---|
| `GET /`, `GET /index.html` | **no** | The page shell |
| `GET /api/ping` | **no** | Liveness; returns archivist name + browse flag |
| `POST /api/ask` | yes | Hallie chat turn |
| `GET /api/timeline` | yes | Archive Timeline for the Browse tab |
| `GET /api/media/{id}` | yes | Media stream, HTTP Range supported |
| `GET /api/media/{id}/status` | yes | Proxy-transcode progress |
| `GET /api/poster/{id}` | yes | Poster frame |
| `GET /api/attachment/{token}` | yes | Image attached to an answer this launch |

Sessions are keyed by a client-supplied id, idle limit six hours.

One thing already right: media resolves by **record ID**, not by a
caller-supplied path, and image serving is guarded by an `isDescendant`
containment check. There is no obvious path-traversal surface.

---

## Why it must not face the internet as-is

Four blockers. Each is small to fix except the last, which is a feature.

**1. No TLS.** [`HallieWebServer.swift:211`](../VideoScan/VideoScan/HallieWebServer.swift)
uses `NWParameters.tcp` — plain HTTP. The passphrase and every frame of family
video would cross the network in cleartext.

**2. Authentication fails open.**
[`HallieWebBridge.swift:128`](../VideoScan/VideoScan/HallieWebBridge.swift):

```swift
let required = config.passphrase.trimmingCharacters(in: .whitespacesAndNewlines)
guard !required.isEmpty else { return true }
```

An empty passphrase authorises everything. On a LAN that is a reasonable
convenience. Facing the internet it is an open door, and the failure mode is
silent — nothing warns that the archive is unprotected.

**3. The secret is accepted in the URL.** `request.query["key"]` is honoured
alongside the `x-hallie-key` header, so the passphrase leaks into browser
history, proxy logs, and `Referer` headers on any outbound link.

**4. One shared secret for everyone.** There is no way to invite one sibling or
revoke another. Rick's actual requirement — invite-only, per person — cannot be
expressed at all.

Minor, but worth fixing while nearby: `/api/ping` is unauthenticated and
discloses the archivist name and whether browse is enabled, and the passphrase
comparison is not constant-time.

---

## The missing feature: per-item public marking

**Nothing in the Swift sources carries an `isPublic`, `isShared`, or equivalent
visibility flag.** `HallieWebBridge` serves any record the catalog holds. Today,
anyone who authenticates sees the entire archive.

That is the gap between what the code does and what Rick asked for, and it is
app work rather than deployment work. It should land *before* anything is
reachable from outside, because the tunnel and the auth in front of it are
worthless if the thing behind them serves everything.

Design questions still open:

- **Granularity** — per item, per person, or per collection? Per-collection is
  the least clicking for a decades-deep archive; per-item is the most precise.
- **Default** — private unless marked. Not negotiable: a fail-open default here
  repeats blocker 2 at the data layer.
- **Scope of the flag** — does "public" mean *all* invitees, or does a sibling
  get their own subset? The second is much more work and probably not wanted
  yet, but the schema should not foreclose it.
- **Enforcement point** — one filter applied centrally in the bridge, not a
  check repeated per route. Repeated checks are how a route eventually ships
  without one.

---

## Recommended deployment

**Never expose the Swift server.** Bind it to `127.0.0.1`, and let a tunnel be
the only way in. No port forwarding, no inbound firewall hole, nothing on the
home router that a scanner can find.

Options, with honest trade-offs against Rick's stated preference for self-hosted
and open standards:

| Approach | Fit | Cost |
|---|---|---|
| **Cloudflare Tunnel + Access** | Lowest friction for non-technical siblings: TLS at the edge, per-email invite with a one-time PIN, revocable per person | Vendor dependency; free-tier terms have historically restricted bulk video, so verify before leaning on it for the archive |
| **Tailscale** | Best security — nothing is ever public, and identity is per person | Every sibling installs an app and signs in; more friction, less "click a link" |
| **Own VPS + WireGuard + Caddy** | Most control, no lock-in, matches the self-hosted preference | Rick maintains a public-facing box, patches it, and owns the consequences |

Cloudflare Access is the recommendation *for this audience* specifically: the
invite-and-revoke model maps exactly onto "only those people I invite", and the
siblings' experience is a link and an emailed code. If the vendor dependency is
unacceptable, Tailscale is the next best and gives up only convenience.

---

## Work order

1. **Per-item public marking**, private by default, enforced centrally. The
   feature, and the prerequisite for everything below.
2. **Bind to loopback only**, so the tunnel is the sole path in.
3. **Reject the query-parameter key**; header only.
4. **Fail closed on an empty passphrase**, and refuse to start when the server is
   enabled without one.
5. **Constant-time comparison** for the shared secret; authenticate `/api/ping`
   or strip the identifying fields from it.
6. **Then** stand up the tunnel and invite one sibling as a trial.

Steps 2–5 are small and self-contained. Step 1 is a design conversation whose
outcome shapes the rest.

---

## Notes

- The `127.0.0.1:8765` references in `team-channel/` progress notes are the
  engineering-room service, not this server. Same port, different thing.
- Filename here is `web_interface.md` as requested; `docs/README.md` conventions
  ask for kebab-case, so rename to `web-interface.md` if the convention wins.
