# VideoScan documentation

Start with the theme guides. They explain decisions, implemented behavior,
remaining proposals and test contracts. Status is tied to the revision/date in
each guide; a historical test result is not a current build result.

## Theme guides

| Theme | Contents |
|---|---|
| [Facial recognition](facial-recognition.md) | Search, Find & Tag, scoring, human review, evaluation, experiments and model provenance |
| [Hallie](hallie.md) | Family knowledge, identity, grounded answers, conversation, voice, galleries and remaining designs |
| [Media archive](media-archive.md) | Preservation, copies, volume roles, Archive Angel, verified promotion and cleanup protections |
| [Development and review](development.md) | Engineering lessons, review boundaries and current process references |

## Focused specifications and operations

These remain separate because they contain detailed contracts or serve a
distinct operational purpose. Their original dates and proposal labels matter.

| Area | References |
|---|---|
| Architecture and storage | [Architecture](architecture-overview.md), [database](database_design.md), [catalog write safety](catalog_write_safety_design.md), [analysis ledger](analysis_ledger_design.md) |
| Media details | [Avid recovery](Avid-Format-Reverse-Engineering.md), [volume relocation](relocate_volume_plan.md), [perceptual comparison](perceptual_compare.md), [date inference](date_inference_catchup_and_propagation.md), [import/export](import_export.md) |
| Recognition details | [AdaFace conversion](design/adaface-plugin.md), [compilation bucketing](compilation-bucketing.md), [family tagging roadmap](family-tagging-and-search-roadmap.md) |
| Knowledge and Hallie | [CyberBrain](cyberbrain_design.md), [proposer/tools](hallie_proposer_with_tools_design.md), [two modes](hallie_two_mode_design.md), [failure ledger](hallie_live_failures.md), [neural voice](hallie-local-neural-voice.md), [pronunciation research](pronunciation_training_research.md) |
| Family tree | [GEDCOM](gedcom.md), [offline cache](offline_family_tree_cache.md), [ingest/compile](tree_ingest_compile_plan_2026_08_28.md), [FamilySearch API](familysearch_api_notes.md), [kinship inference](kinship_inference_design.md), [People UUID folders](people_uuid_folders_design.md) |
| Web and remote use | [Web interface](web_interface.md), [remote use](remote_use_design.md), [iOS direction](ios_port.md) |
| Testing | [Categories and isolation](testing.md), [Gauntlet](gauntlet.md), [five-dimension checklist](testing_retrospective_2026_07_05.md), [regression backlog](regression_test_backlog.md) |
| Engineering operations | [Development policy](software_dev_policy.md), [compute assignments](compute-assignments.md), [nightly metrics](nightly-metrics-setup.md), [team channel](team-channel/README.md), [Engineering Room](../tools/engineering-room/README.md) |
| Hardware | [Fleet inventory](mac-hw-inventory-2026-08-21.md), [drive health](drive_health.md), [archive storage](storage_raid_recommendations.md) |
| Research and proposals | [Research index](research/README.md), [ideas](Ideas.md), [scene captions](scene_captions_plan.md) |

## Recent review evidence

Retain incident reports and unresolved review evidence until the decisions and
regression coverage are preserved in their owning theme. Recent entry points:

- [September 15 code review](codex_review_2026_09_15.md) and
  [technical-debt review](tech_debt_review_2026_09_15.md).
- [September 14 findings](findings_2026_09_14_overnight.md) and
  [sandbox rename incident](incident_2026_09_14_sandbox_rename_wedge.md).
- [Hallie response commit refactor](hallie_response_commit_refactor_2026_09_13.md)
  and [refactoring assessment](refactoring_assessment_2026_09_13.md).

## Maintenance and retention

- Update the owning theme instead of starting another overlapping plan.
  Keep a focused companion only when its detailed contract warrants one.
- Label **implemented**, **proposed**, **deferred** and **historical** explicitly;
  cite the source revision and validation evidence. Never infer completion from
  the existence of a design or a source file.
- Keep team chatter for 2–3 days, at most seven. Move lasting decisions and
  unresolved findings into maintained docs before retiring the conversation.
  The live mailbox has separate retention; this is a docs policy.
- Retire completed handoffs, duplicate plans and stale status snapshots after
  preserving their useful design decisions. Age alone does not obsolete a spec.
- Move retired originals to repository `.trash/` and keep Git provenance.
  Do not retire machine-consumed datasets, benchmark streams, fixtures or
  dashboards as if they were prose clutter.
- Prefer lowercase-kebab filenames for new theme docs. Include update date,
  status, source identity and a short purpose statement.

The [documentation map](documentation-map.md) records the September 16
consolidation, source recovery and Claude's review checklist.
