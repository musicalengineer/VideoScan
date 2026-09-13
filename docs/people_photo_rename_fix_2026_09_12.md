# People photo preservation on rename

The People editor previously saved only `profile.json` under the new short name,
then moved the old folder and all reference photos to trash. The new JSON pointed
at a folder without its selected portrait. A second profile with the same short
name could also overwrite the first profile, regardless of surname or suffix.

The fix preserves the existing name-based layout and uses the persisted UUID to
check ownership at every ordinary profile save. A genuine rename copies the whole
folder to a private staging directory, updates the staged JSON to its final photo
path, publishes the folder, and only then soft-retires the old folder. Internal
absolute photo links are rebased; external and relative links are preserved.
Failure before publication leaves the old profile and assets intact. Failure to
retire the old name is reported as a warning; both complete copies remain.

Equivalent sanitized names update in place. A destination owned by another UUID,
an unreadable identity, or an already occupied rename destination is refused.
Short names must still be distinct (for example `Dad` and `Rick`, or `Richard Sr`
and `Richard Jr`); this change does not migrate the application to UUID folders.

Photo imports while editing use the original profile's folder until Save commits
the rename. Active settings, queued jobs, and the post-save photo reload use the
committed profile's healed path. Quick-save preserves UUID and biography rather
than replacing them with a new settings-only profile.

## Verification and recovery

`POIProfileFileStoreTests` runs real filesystem transactions with synthetic asset
bytes and links, injected write/retirement failures, and conflicting identities.
`POIProfileRenameIntegrationTests` pins the actual POIProfile save boundary and
refuses to run unless the process has an isolated test POI root.

Existing missing images are a separate data recovery operation. Match a backup to
the live profile by UUID before restoring missing assets; do not overwrite current
biographies with older JSON. The September 5 Dad backup exists in
`.trash/POI-dad-20260905-175047`, but the live `richard` profile inspected September
12 belongs to Richard Jr. Confirm the intended live profile before restoring Dad.
