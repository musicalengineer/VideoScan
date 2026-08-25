# GEDCOM export and VideoScan import

Last verified: 2026-08-24

VideoScan uses a local GEDCOM file as its family-tree source of truth. Keep the
original export unchanged and treat online trees as research sources: distant
shared-tree relationships can be incomplete, disputed, or weakly sourced.

## Exporting an Ancestry tree

Ancestry exports the entire tree owned by the signed-in user. It does not offer
a generation-count option for GEDCOM export, and guests or editors cannot
export another owner's tree.

1. Open the tree in Ancestry.
2. In the left toolbar, choose **More** (the three-dot button), then
   **Tree Settings**.
3. Under **Manage your tree**, choose **Export tree**, then **Export**.
4. When generation finishes, choose **Download Your GEDCOM File**.
5. Unzip the downloaded file to obtain the `.ged` file.

Ancestry's current instructions are in
[Uploading and Downloading Trees](https://ancestrysupport.zendesk.com/hc/en-us/articles/53933352542867-Uploading-and-Downloading-Trees).

GEDCOM is primarily genealogical text and relationships. Ancestry photos and
other media are not embedded in the exported GEDCOM. Preserve those media
separately in the Master Archive.

### When the export stops after only a few generations

Ancestry does not normally impose a six-generation limit on a whole-tree
export. Check the source tree for these common causes:

- Distant people visible onscreen are hints or members of someone else's
  public tree, not people attached to the owned tree.
- A parent-child relationship is missing somewhere in the line.
- The export came from a different owned tree.
- Suggested ancestors were viewed but never accepted and connected.

Open several of the distant ancestors before exporting and verify that each is
actually connected through parent relationships in the owned tree.

## Exporting from FamilySearch

FamilySearch does not currently provide direct GEDCOM export from its shared
Family Tree. Its help center recommends downloading with compatible third-party
genealogy software instead:

- [Downloading information from Family Tree](https://www.familysearch.org/en/help/helpcenter/article/how-do-i-download-information-from-family-tree)
- [Creating a GEDCOM file](https://www.familysearch.org/en/help/helpcenter/article/how-do-i-create-a-gedcom-file)

For macOS, the free edition of
[RootsMagic](https://rootsmagic.com/RootsMagic) is a practical option. It can
connect to FamilySearch, download tree information into a local database, and
export GEDCOM. Once the people are local, RootsMagic can select a person and
export a chosen number of ancestor or descendant generations; see
[RootsMagic's generation-selection instructions](https://support.rootsmagic.com/hc/en-us/articles/224924967-How-to-export-ancestors-and-descendant-of-a-selected-person).

A cautious FamilySearch workflow is:

1. Create a separate RootsMagic database.
2. Connect it to FamilySearch and start from the confirmed FamilySearch Person
   ID.
3. Download the desired ancestral lines.
4. Export a GEDCOM from the local database.
5. Compare it with the Ancestry export before adopting either as authoritative.

Living-person records are private in FamilySearch and may not connect or
download like the shared deceased-person tree. Long ancestral lines should be
reviewed for sources before they are presented by Hallie as family fact.

## Installing a new GEDCOM for VideoScan

The preferred Master Archive location is:

```text
<Master Archive>/40_Family_Tree/GEDCOM/
```

VideoScan selects the newest valid `.ged` file in its configured family-tree
locations. Use a dated filename, for example:

```text
ancestry-breen-family-2026-08-24.ged
```

Do not overwrite or delete the prior export until the new file has passed a
preflight comparison. Useful checks include:

- person and family counts;
- maximum ancestor depth;
- missing or broken parent, spouse, and child links;
- the expected English and Irish lines;
- connections among living immediate-family records;
- duplicate people and conflicting dates or places.

The Family Tree view currently displays a bounded number of generations around
the selected person. That display depth does not truncate the underlying GEDCOM
graph.

## Photos and the People tab

A new GEDCOM can improve family relationships and ancestral depth, but it does
not automatically bridge GEDCOM people to VideoScan People profiles or their
cover photos. That identity/photo bridge is a separate application concern.
Keep user-owned portraits under the Master Archive family-tree assets rather
than expecting an Ancestry or FamilySearch GEDCOM export to carry them.

## Future FamilySearch integration

VideoScan's proposed direct FamilySearch integration remains local-first and
read-oriented. The implementation and approval constraints are documented in
[familysearch_api_notes.md](familysearch_api_notes.md). Direct API data must not
silently overwrite the local GEDCOM.
