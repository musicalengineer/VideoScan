// IdentityAnnotationScaleTests.swift
// SCALE dimension + model-layer annotate coverage for the POI
// identity-metadata feature (feature-test checklist items 1, 2 & 5).
//
// The identityEvidenceProvider closure (wired in ContentView) does ONE
// O(records) pass over the catalog per annotate call — batch, never
// per-row. These tests pin that complexity class at 100k synthetic
// records with wall-clock budgets, per the checklist rule for anything
// that iterates `records`. Budgets are generous (Debug build, loaded
// test hosts): they are sensors for an O(records×rows) regression, not
// micro-benchmarks.
//
// Also covers PersonFinderModel.annotateIdentityPlausibility behavior:
// scored rows, the nil + "no date/scene evidence" path, idempotency,
// the provider-didSet re-annotation, and the no-priors skip.

import Testing
import Foundation
@testable import VideoScan

// @Suite(.serialized) ≈ forcing sequential execution for this suite so
// parallel neighbors can't inflate the wall-clock measurements.
@Suite(.serialized) @MainActor
struct IdentityAnnotationScaleTests {

    // MARK: - Shared synthetic fixtures

    /// 100k catalog records shaped like real ones; every 4th carries
    /// dossier evidence (inferred date + a scene caption).
    private func syntheticRecords(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            r.filename = "clip\(i).mov"
            r.fullPath = "/Volumes/Scale\(i % 8)/dir\(i % 41)/clip\(i).mov"
            if i % 4 == 0 {
                // ~1989 + a spread, so ages land in sane buckets.
                r.inferredRecordDate = Date(timeIntervalSince1970: 600_000_000 + Double(i))
                r.sceneCaptions = [SceneCaption(timestamp: 0, text: "a boy playing in the yard")]
            }
            return r
        }
    }

    /// The EXACT closure shape ContentView wires as the provider:
    /// one pass over records, Set-filter on paths, map to evidence.
    private func makeProvider(records: [VideoRecord])
        -> (Set<String>) -> [String: PFIdentityEvidence] {
        { paths in
            guard !paths.isEmpty else { return [:] }
            var out: [String: PFIdentityEvidence] = [:]
            out.reserveCapacity(paths.count)
            for rec in records where paths.contains(rec.fullPath) {
                out[rec.fullPath] = PFIdentityEvidence(
                    recordDate: rec.inferredRecordDate,
                    sceneDescriptions: rec.sceneCaptions.map(\.text)
                )
            }
            return out
        }
    }

    private func makeRow(path: String) -> ClipResult {
        ClipResult(
            videoFilename: (path as NSString).lastPathComponent,
            videoPath: path, videoDuration: 60, presenceSecs: 5,
            segmentCount: 1, bestDistance: 0.4, clipFiles: [],
            outputDir: "/tmp/out"
        )
    }

    private func sonProfile() -> POIProfile {
        var dc = DateComponents()
        dc.year = 1983; dc.month = 6; dc.day = 15; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        let birth = Calendar(identifier: .gregorian).date(from: dc)
        return POIProfile(name: "Son", referencePath: "/tmp/ref",
                          birthdate: birth, sex: .male)
    }

    // MARK: - 1. Provider walk at 100k records, within budget

    @Test("provider-shaped catalog walk at 100k records stays inside budget",
          .timeLimit(.minutes(2)))
    func providerWalkAt100kRecordsWithinBudget() {
        let records = syntheticRecords(100_000)
        let provider = makeProvider(records: records)
        // 200 matched rows spread across the catalog; index i*500 is
        // divisible by 4, so every requested path has evidence.
        let paths = Set((0..<200).map { records[$0 * 500].fullPath })

        // SuspendingClock.measure ≈ timing with steady_clock — pauses
        // while the machine sleeps, so a lid-close can't fail the test.
        let clock = SuspendingClock()
        var evidence: [String: PFIdentityEvidence] = [:]
        let elapsed = clock.measure {
            evidence = provider(paths)
        }

        #expect(evidence.count == 200)
        #expect(evidence.values.allSatisfy { $0.recordDate != nil })
        #expect(evidence.values.allSatisfy { !$0.sceneDescriptions.isEmpty })
        // One O(100k) pass with a Set probe per record is single-digit
        // milliseconds; 1s only trips on a complexity-class regression.
        #expect(elapsed < .seconds(1),
                "provider walk took \(elapsed) for 100k records — the O(records) pass has regressed")
    }

    // MARK: - 2. annotate = ONE catalog pass, even with many rows

    @Test("annotate with 1,000 result rows against 100k records calls the provider once and stays inside budget",
          .timeLimit(.minutes(2)))
    func annotateAt100kRecordsIsOnePassWithinBudget() {
        let records = syntheticRecords(100_000)
        let realProvider = makeProvider(records: records)

        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/Volumes/Scale0")
        job.assignedProfile = sonProfile()
        // 1,000 rows, all backed by evidence-bearing records (i*100 % 4 == 0).
        job.results = (0..<1_000).map { makeRow(path: records[$0 * 100].fullPath) }

        var providerCalls = 0
        model.identityEvidenceProvider = { paths in
            providerCalls += 1
            return realProvider(paths)
        }
        providerCalls = 0  // discard any didSet-triggered calls (job isn't in model.jobs)

        let clock = SuspendingClock()
        let elapsed = clock.measure {
            model.annotateIdentityPlausibility(for: job)
        }

        #expect(providerCalls == 1,
                "annotate must do ONE batch evidence lookup, not per-row — saw \(providerCalls)")
        #expect(job.results.allSatisfy { $0.plausibility != nil },
                "every evidence-backed row must be scored")
        // Healthy shape: one O(100k) walk + 1,000 pure scoring calls.
        // A per-row provider regression is 1,000 × O(100k) record
        // touches and lands far past this.
        #expect(elapsed < .seconds(2),
                "annotate took \(elapsed) at 100k records × 1,000 rows — smells like O(records×rows)")
    }
}

// MARK: - annotateIdentityPlausibility behavior (LOGIC dimension)

@MainActor
struct AnnotateIdentityPlausibilityTests {

    private func date(_ y: Int) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = 6; dc.day = 15; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    private func makeRow(path: String) -> ClipResult {
        ClipResult(
            videoFilename: (path as NSString).lastPathComponent,
            videoPath: path, videoDuration: 60, presenceSecs: 5,
            segmentCount: 1, bestDistance: 0.4, clipFiles: [],
            outputDir: "/tmp/out"
        )
    }

    /// Stub provider backed by a fixed dictionary — the test's
    /// source of truth for which paths have which evidence.
    private func stubProvider(_ table: [String: PFIdentityEvidence])
        -> @MainActor (Set<String>) -> [String: PFIdentityEvidence] {
        { paths in table.filter { paths.contains($0.key) } }
    }

    @Test func rowsGetScoredAndNoEvidenceRowsGetNilPlusReason() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "Son", referencePath: "/tmp/ref",
            birthdate: date(1983), sex: .male
        )
        job.results = [
            makeRow(path: "/v/scored.mov"),       // full evidence
            makeRow(path: "/v/dateless.mov"),     // in catalog, but no inferred date
            makeRow(path: "/v/uncataloged.mov")   // not in the catalog at all
        ]
        model.identityEvidenceProvider = stubProvider([
            "/v/scored.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a boy"]),
            "/v/dateless.mov": PFIdentityEvidence(
                recordDate: nil, sceneDescriptions: ["a boy"])
        ])

        model.annotateIdentityPlausibility(for: job)

        // Evidence-backed row: scored (son, age 11, "a boy" → 1.0).
        #expect(job.results[0].plausibility == 1.0)
        #expect(job.results[0].plausibilityReason?.isEmpty == false)

        // Both no-evidence flavors: nil score, explanatory reason —
        // visibly explained, never silently dropped.
        for i in [1, 2] {
            #expect(job.results[i].plausibility == nil,
                    "row \(i) has no usable evidence and must stay unscored")
            #expect(job.results[i].plausibilityReason?
                        .contains("no date/scene evidence") == true)
            // Unevaluated rows sort as neutral 0.5.
            #expect(job.results[i].plausibilitySortKey == 0.5)
        }
    }

    @Test func annotateIsIdempotent() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "Son", referencePath: "/tmp/ref",
            birthdate: date(1983), sex: .male
        )
        job.results = [
            makeRow(path: "/v/scored.mov"),
            makeRow(path: "/v/uncataloged.mov")
        ]
        model.identityEvidenceProvider = stubProvider([
            "/v/scored.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a boy"])
        ])

        model.annotateIdentityPlausibility(for: job)
        let first = job.results.map { ($0.plausibility, $0.plausibilityReason) }

        model.annotateIdentityPlausibility(for: job)
        let second = job.results.map { ($0.plausibility, $0.plausibilityReason) }

        #expect(first.count == second.count)
        for (a, b) in zip(first, second) {
            #expect(a.0 == b.0)
            #expect(a.1 == b.1)
        }
    }

    @Test func settingProviderAnnotatesAlreadyLoadedJobs() {
        // Jobs restored from disk can finish rehydrating before
        // ContentView wires the provider — the didSet must sweep them.
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "Son", referencePath: "/tmp/ref",
            birthdate: date(1983), sex: .male
        )
        job.results = [makeRow(path: "/v/scored.mov")]
        model.jobs.append(job)

        #expect(job.results[0].plausibility == nil, "not yet annotated")

        model.identityEvidenceProvider = stubProvider([
            "/v/scored.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a boy"])
        ])

        #expect(job.results[0].plausibility == 1.0,
                "provider didSet must annotate existing jobs without an explicit call")
    }

    @Test func profileWithoutIdentitySignalsSkipsAnnotation() {
        // No birthdate/deathdate/sex/hair/eyes ⇒ nothing to score with.
        // Rows must be left completely untouched (nil reason too — this
        // is the "skipped" state, distinct from "no evidence").
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(name: "Blank", referencePath: "/tmp/ref")
        job.results = [makeRow(path: "/v/scored.mov")]
        model.identityEvidenceProvider = stubProvider([
            "/v/scored.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a boy"])
        ])

        model.annotateIdentityPlausibility(for: job)

        #expect(job.results[0].plausibility == nil)
        #expect(job.results[0].plausibilityReason == nil)
    }

    @Test func noProviderMeansNoAnnotation() {
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "Son", referencePath: "/tmp/ref", birthdate: date(1983)
        )
        job.results = [makeRow(path: "/v/scored.mov")]

        model.annotateIdentityPlausibility(for: job)  // provider is nil

        #expect(job.results[0].plausibility == nil)
        #expect(job.results[0].plausibilityReason == nil)
    }

    // MARK: - Stale priors after profile edit (QA 2026-07-09 MAJOR)
    //
    // POIProfile is a struct — every job holds a VALUE SNAPSHOT in
    // assignedProfile. Pre-fix, updateProfile() saved the edited profile
    // to disk but never refreshed those snapshots or re-annotated, so
    // editing a birthdate with results on screen left stale Fit badges
    // until app restart — worst case, a CORRECTED birthdate kept showing
    // a wrong, authoritative-looking "Not possible" (0.0) badge.
    //
    // These tests drive refreshJobsForUpdatedProfile directly rather than
    // updateProfile: updateProfile also persists to the real
    // ~/Library/Application Support POI store, which tests must not touch
    // (see the pollution note at the bottom of PersonFinderLifecycleTests).
    // updateProfile delegates the in-memory refresh to this method.

    @Test func editingProfilePriorsRescoresExistingJobsWithoutRestart() {
        let model = PersonFinderModel()

        // Donna's birthdate is WRONG (1996) — the 1994 video scores 0.0.
        let donnaJob = ScanJob(searchPath: "/tmp/donna")
        donnaJob.assignedProfile = POIProfile(
            name: "Donna", referencePath: "/tmp/ref",
            birthdate: date(1996), sex: .female
        )
        donnaJob.results = [makeRow(path: "/v/donna.mov")]

        // Control: a job for someone else must be left untouched.
        let sonJob = ScanJob(searchPath: "/tmp/son")
        sonJob.assignedProfile = POIProfile(
            name: "Son", referencePath: "/tmp/ref2", birthdate: date(1983), sex: .male
        )
        sonJob.results = [makeRow(path: "/v/son.mov")]

        model.jobs = [donnaJob, sonJob]
        model.identityEvidenceProvider = stubProvider([
            "/v/donna.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a woman"]),
            "/v/son.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a boy"])
        ])
        // didSet annotated both jobs against the WRONG priors.
        #expect(donnaJob.results[0].plausibility == 0.0,
                "precondition: wrong 1996 birthdate must score 'born after video' = 0.0")
        let sonBefore = sonJob.results[0].plausibility
        let sonReasonBefore = sonJob.results[0].plausibilityReason

        // Rick corrects the birthdate to 1959 and saves the edit.
        var corrected = donnaJob.assignedProfile!
        corrected.birthdate = date(1959)
        model.refreshJobsForUpdatedProfile(corrected)

        // The job's snapshot AND its Fit badges must reflect the edit
        // immediately — no app restart.
        #expect(donnaJob.assignedProfile?.birthdate == date(1959),
                "job's assignedProfile snapshot must be refreshed")
        let rescored = donnaJob.results[0].plausibility
        #expect(rescored != nil && rescored! > 0.5,
                "corrected birthdate (age 35, 'a woman') must re-score well — got \(String(describing: rescored))")
        #expect(donnaJob.results[0].plausibilityReason?.contains("after video date") != true,
                "the stale 'Not possible' reason must be gone")

        // Control job: same scores, same snapshot — untouched.
        #expect(sonJob.results[0].plausibility == sonBefore)
        #expect(sonJob.results[0].plausibilityReason == sonReasonBefore)
        #expect(sonJob.assignedProfile?.birthdate == date(1983))
    }

    @Test func renamedProfileStillRefreshesJobsViaOldName() {
        // Jobs hold the PRE-edit name in their snapshots; the refresh must
        // match on oldName when the edit renamed the person.
        let model = PersonFinderModel()
        let job = ScanJob(searchPath: "/tmp")
        job.assignedProfile = POIProfile(
            name: "Donna", referencePath: "/tmp/ref",
            birthdate: date(1996), sex: .female
        )
        job.results = [makeRow(path: "/v/donna.mov")]
        model.jobs = [job]
        model.identityEvidenceProvider = stubProvider([
            "/v/donna.mov": PFIdentityEvidence(
                recordDate: date(1994), sceneDescriptions: ["a woman"])
        ])
        #expect(job.results[0].plausibility == 0.0, "precondition")

        var edited = job.assignedProfile!
        edited.name = "Donna B."
        edited.birthdate = date(1959)
        model.refreshJobsForUpdatedProfile(edited, oldName: "Donna")

        #expect(job.assignedProfile?.name == "Donna B.",
                "rename must propagate to the job snapshot via oldName match")
        let rescored = job.results[0].plausibility
        #expect(rescored != nil && rescored! > 0.5,
                "rescore must run for the renamed profile — got \(String(describing: rescored))")
    }
}
