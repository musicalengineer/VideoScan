# FamilySearch API integration notes

Status: research only; no FamilySearch calls or credentials are implemented here.

Checked against official FamilySearch documentation on 2026-08-22. Re-check the linked documentation before implementation or release because access rules, endpoints, and legal terms can change.

## BLOCKER (added 2026-08-25): VideoScan cannot obtain a production key

Everything below this section is sound engineering guidance, but it cannot
currently be exercised against real data. FamilySearch's
[certification guide](https://www.familysearch.org/developers/docs/guides/implementation-cert)
states that only a legal, registered business is eligible for verification,
and that **sole proprietorships are not eligible**. There is no personal-use,
hobbyist, or non-commercial path. Registering an app grants Integration
(Sandbox) access automatically — synthetic data only. Production requires
acceptance into the Compatible Solution Program.

The ceiling for a direct integration is therefore a working OAuth/PKCE flow
against people who do not exist. Treat the rest of this document as a design
that is ready if the eligibility rule ever changes, not as a roadmap that can
be started today.

Ancestry is not an alternative: it has had no public API since the early
2010s. GEDCOM export is the only supported route out of an Ancestry tree.

**What shipped instead:** the Family Tree tab's *Get Family Tree* button
(`FamilySearchPull.swift`), which hands a `getmyancestors` command to Terminal
so the user authenticates directly with the tool. See `gedcom.md`. That design
keeps the rule above this section intact — VideoScan still never collects or
proxies the FamilySearch password.

## Recommendation for VideoScan

Keep the local GEDCOM as the source of truth. FamilySearch is a remote, user-authorized reference and enrichment source, not the owner of VideoScan's tree.

- Continue loading and editing the local GEDCOM independently of network availability or a FamilySearch account.
- Store an explicitly confirmed FamilySearch Person ID as a GEDCOM custom tag, for example:

  ```gedcom
  0 @I42@ INDI
  1 NAME Eileen /Latta/
  1 _FSFTID G2S4-WS4
  ```

  `_FSFTID` is a VideoScan convention, not a standard GEDCOM field. The importer and exporter must preserve unknown/custom tags on round trip. Do not replace the local GEDCOM cross-reference (`@I42@`) with the FamilySearch ID.
- Treat linking as an explicit user decision. Store remote values with provenance, retrieval time, and ETag in a derived local cache; show differences instead of silently overwriting GEDCOM facts.
- Handle merged FamilySearch people: a Person read can return `301` with the survivor URI. Offer to update `_FSFTID`, while retaining an audit record of the former ID.
- Start read-only. Any future write-back should be a separate reviewed feature with attribution, conflict handling, and explicit confirmation.
- Do not commit an app key, access token, refresh token, authorization code, client secret, or real-person response fixture. Keep tokens in macOS Keychain, redact them from logs, and use synthetic fixtures in tests. A desktop/native client is public and must not embed a client secret.

This design preserves Hallie's useful local family view when FamilySearch is unavailable, avoids making remote shared-tree edits implicitly, and limits exposure of living-person data.

## Developer enrollment and app key

FamilySearch's current onboarding is gated:

1. Enroll and be accepted into the Solution Provider program.
2. In the Solutions Community, register a new application solution for the Integration Server (formerly "Sandbox"). Supply a solution name, app type, and one or more absolute redirect URIs.
3. Choose **Mac** as the app type for VideoScan. FamilySearch requires a separate app key for each app type.
4. Save the application to receive its unique app key (`client_id`). The callback used by the app must exactly match a registered redirect URI.

An app key is automatically enabled for Integration/Sandbox. Beta and Production require special access; Production requires acceptance into the Compatible Solution Program and completion of compatibility review. See FamilySearch's [Getting Started guide](https://developers.familysearch.org/main/docs/getting-started), [App Approval Considerations](https://developers.familysearch.org/main/docs/app-approval-considerations), and [Developer Support](https://developers.familysearch.org/main/docs/developer-support).

App keys and callback registrations are environment-specific. FamilySearch support says keys do not automatically carry from one environment to another and redirect URIs must be pre-registered for each requested environment. Do not assume an Integration key or callback is valid in Beta or Production; use the Developer Portal/support process documented in [Developer Support](https://developers.familysearch.org/main/docs/developer-support).

## OAuth 2 for a macOS app

Use OAuth 2.0 **Authorization Code Flow with PKCE** for VideoScan:

1. Generate a high-entropy `state` value and PKCE verifier/challenge (`S256`).
2. Open FamilySearch's authorization page in the user's browser. Never collect or proxy the user's FamilySearch password.
3. Include `client_id` (the app key), the exact registered `redirect_uri`, `response_type=code`, `state`, `code_challenge`, and `code_challenge_method=S256`. Validate the returned `state` before accepting the code.
4. Exchange the short-lived code at the token resource using form-encoded `client_id`, `grant_type=authorization_code`, the same redirect URI, and the original `code_verifier`.
5. Send the resulting access token in `Authorization: Bearer …`; do not put it in URLs. Store access/refresh tokens in Keychain and provide a disconnect/logout path.

FamilySearch documents these authorization endpoints:

- Beta: `https://identbeta.familysearch.org/cis-web/oauth2/v3/authorization`
- Production: `https://ident.familysearch.org/cis-web/oauth2/v3/authorization`

The official [Authorization Code Flow](https://developers.familysearch.org/main/docs/authorization-code-flow) documents PKCE specifically for native/mobile apps, exact callback matching, token exchange, access/refresh tokens, and optional OpenID Connect. The general [Authentication guide](https://developers.familysearch.org/main/docs/authentication) says authorization code authentication is supported for desktop apps. Unauthenticated sessions are limited and not accepted by every API; client-credentials authentication is not generally available, so neither is the correct basis for a signed-in Family Tree feature.

The current authorization guide is not a complete environment-routing registry (for example, its token-endpoint wording is Beta-oriented). Obtain the exact Integration, Beta, and Production authorization/token endpoints associated with the registered app from the portal/support; do not mix an authorization code, token, app key, or redirect registration across environments.

## Environments

| Environment | Intended use | Access notes |
|---|---|---|
| Integration / Sandbox | Initial development against non-production data | App key is enabled here on registration. |
| Beta | Production-like testing against an older production snapshot | Special request; may not always be available. The API reference's interactive examples target Beta. |
| Production | Real FamilySearch data | Compatible Solution Program acceptance and compatibility review are required. |

These roles and approval requirements come from [Getting Started](https://developers.familysearch.org/main/docs/getting-started); the Beta behavior of the API explorer is described by the [API Reference Guide](https://developers.familysearch.org/main/reference/api-reference-guide). Keep each environment's base URLs and credentials in runtime configuration, with a non-production default for developer builds.

## Initial read endpoints

All paths below are relative to the API base URL for the selected environment. The current reference pages display the Beta host. Request a versioned representation such as `Accept: application/x-gedcomx-v1+json` (or the FamilySearch extension media type where that endpoint requires it) and include the bearer token.

### Person

`GET /platform/tree/persons/{pid}` retrieves one person, including names, gender, and facts. Optional query flags include related people and source descriptions. A merged ID can produce `301` with a survivor location; the documented outcomes also include not found, deleted, and throttled responses. See [Read Person](https://developers.familysearch.org/main/reference/readperson).

Use this as the first validation after a user confirms or enters an `_FSFTID`. Preserve the response's `links.person` URI and ETag rather than treating a hand-built URL as permanently canonical; FamilySearch recommends following returned persistent links and conditional reads in [Keeping in Sync with FamilySearch Data](https://developers.familysearch.org/main/docs/keeping-in-sync-with-familysearch-data).

### Ancestry

`GET /platform/tree/ancestry?person={pid}&generations={n}` returns the root and ancestors, identified in display properties by Ahnentafel/ascendancy numbers. The current reference allows 1–8 generations (default 3), with optional spouse, person detail, marriage detail, and descendant-related parameters. See [Read Ancestry](https://developers.familysearch.org/main/reference/readancestry).

For Hallie, request only the depth needed for the visible answer (for example, five generations), then map the returned people into a derived view. Do not write those people into the GEDCOM merely because they were returned.

### Descendancy

`GET /platform/tree/descendancy?person={pid}&generations={n}` returns descendants using d'Aboville-style descendancy numbers; spouse entries use an appended spouse marker. The current reference allows 1–4 generations (default 1) and optional person/marriage detail. See [Read Descendancy](https://developers.familysearch.org/main/reference/readdescendancy).

The ancestry and descendancy resources return sets of people, not a ready-made local pedigree database. Parse identifiers and relationship/display numbering defensively and tolerate additional JSON properties.

## Request, routing, caching, and throttling constraints

- Send a useful `User-Agent` containing at least the current application version. Use an explicit, versioned `Accept` media type and bearer authorization header; see FamilySearch's [HTTP guide](https://developers.familysearch.org/main/docs/http).
- Follow response hypermedia links and HTTP redirects instead of assuming resource locations never change. This matters especially after person merges. Clients must tolerate additive fields and other compatible API evolution; see [API Evolution](https://developers.familysearch.org/main/docs/api-evolution).
- Cache conservatively. Save ETags for Person/relationship data and use `If-None-Match`; a `304 Not Modified` avoids downloading an unchanged person. See [Keeping in Sync](https://developers.familysearch.org/main/docs/keeping-in-sync-with-familysearch-data) and [Caching](https://developers.familysearch.org/main/docs/caching).
- Throttling is per user; for an unsigned session it is by app key. Policies are based on processing time and can differ by endpoint. FamilySearch does **not** publish one durable requests-per-minute number to build against. On `429 Too Many Requests`, stop and honor `Retry-After`; also honor `Retry-After` when supplied with `503 Service Unavailable`. Track `X-PROCESSING-TIME`, serialize/bound concurrency, coalesce duplicate requests, and use cached data. See [Throttling](https://developers.familysearch.org/main/docs/throttling).
- Do not retry authentication, authorization, validation, not-found, or deleted responses as if they were transient. Bound all retries and add jitter for transient failures after the server-directed delay.

## Terms, privacy, and product safeguards

This is engineering guidance, not legal advice. Before enabling Production, re-review the current approval agreement and policies with the exact feature set.

- FamilySearch's public terms generally limit site materials to personal, noncommercial use unless another use is specifically permitted, restrict redistribution, require users to have the right to submit contributed content, and permit access to be limited or revoked. See the current [FamilySearch Terms of Use](https://www.familysearch.org/en/legal/terms).
- Living-person data needs stricter treatment. FamilySearch's Privacy Notice says users are responsible for living data they submit/share and describes consent, access, correction/deletion, and regional obligations. VideoScan should minimize cached living-person data, keep it local, avoid telemetry, provide deletion/disconnect controls, and never use a living person's record as a shared fixture. See the [FamilySearch Privacy Notice](https://www.familysearch.org/en/legal/privacy/).
- Approval is not automatic. FamilySearch evaluates technical load, support impact, compatibility, business considerations, and whether a solution adds value rather than merely copying data out. See [App Approval Considerations](https://developers.familysearch.org/main/docs/app-approval-considerations).
- Photos/memories are separately governed content. Do not assume that API access grants a right to redistribute or permanently copy a FamilySearch-hosted image into the VideoScan archive. For the initial rich Hallie view, prefer user-owned local photos. If remote portraits are later added, review the applicable endpoint, attribution, content rights, caching behavior, and approval terms first.

## Suggested implementation gate (later work)

Before code is written:

1. Confirm Solution Provider enrollment and register the Mac app and callback.
2. Obtain Integration access and verify the environment-specific endpoint set with FamilySearch Developer Support.
3. Implement the system-browser authorization code + PKCE flow and Keychain storage behind a protocol that can be replaced with a fake in tests.
4. Implement read-only Person first, including `301`, `304`, `410`, `429`, `503`, cancellation, redaction, and offline-cache behavior.
5. Add bounded Ancestry/Descendancy reads only after Person linking is explicit and reversible.
6. Complete compatibility/privacy review before enabling Production. No Production switch should be controlled by a committed credential or an unreviewed build flag.
