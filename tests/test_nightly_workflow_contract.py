#!/usr/bin/env python3
"""Headless regression sensors for accidental nightly workflow truncation.

These inspect the repository's conventional two-space job/six-space step
layout, not arbitrary YAML. A changed layout fails explicitly rather than
silently skipping checks. GitHub/actionlint remains the full YAML validator.
No Xcode, runner credentials, network, or third-party parser is required.
"""
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/nightly-analysis.yml"
CRITICAL_JOBS = {
    "strict-concurrency", "codeql", "thread-sanitizer", "lint-strict",
    "lint-warn", "source-ratchets", "aggregate",
}


def job_blocks(source):
    """Extract real job keys; ignore comments, shell text, and other mappings."""
    jobs = re.search(r"(?m)^jobs:\s*$", source)
    if jobs is None:
        raise AssertionError("Missing top-level jobs mapping")
    body = source[jobs.end():]
    next_section = re.search(r"(?m)^\S[^\n]*:", body)
    if next_section:
        body = body[:next_section.start()]
    headers = list(re.finditer(r"(?m)^  ([A-Za-z_][\w-]*):\s*$", body))
    if not headers:
        raise AssertionError("No jobs found; check workflow layout")
    result = {}
    for index, header in enumerate(headers):
        name = header.group(1)
        if name in result:
            raise AssertionError(f"Duplicate job: {name}")
        end = headers[index + 1].start() if index + 1 < len(headers) else len(body)
        result[name] = body[header.end():end]
    return result


def step_blocks(job):
    headers = list(re.finditer(r"(?m)^      - (?:name|uses|id):[^\n]*$", job))
    if not headers:
        raise AssertionError("No steps found; check workflow layout")
    return [job[header.start():headers[index + 1].start()
                if index + 1 < len(headers) else len(job)]
            for index, header in enumerate(headers)]


class NightlyWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = WORKFLOW.read_text()
        cls.jobs = job_blocks(cls.source)

    def job(self, name):
        self.assertIn(name, self.jobs, f"Nightly analysis lost required job {name}")
        return self.jobs[name]

    def step_with_id(self, job, step_id):
        matches = [step for step in step_blocks(self.job(job))
                   if re.search(rf"(?m)^        id: {re.escape(step_id)}\s*$", step)]
        self.assertEqual(len(matches), 1, f"{job} must have one id: {step_id} step")
        return matches[0]

    def test_critical_analysis_jobs_are_preserved(self):
        self.assertFalse(CRITICAL_JOBS - self.jobs.keys(),
                         f"Missing nightly jobs: {sorted(CRITICAL_JOBS - self.jobs.keys())}")

    def test_aggregate_dependencies_resolve_to_real_jobs(self):
        aggregate = self.job("aggregate")
        needs = re.search(r"(?m)^    needs:\s*(\[[^\n]*\]|[\w-]+)?[ \t]*$", aggregate)
        self.assertIsNotNone(needs, "Aggregate needs must be a literal job list")
        if needs.group(1):
            declared = set(re.findall(r"[\w-]+", needs.group(1)))
        else:
            following = aggregate[needs.end():]
            items = re.match(r"(?:\n?      - [\w-]+[ \t]*\n?)+", following)
            self.assertIsNotNone(items, "Missing aggregate needs list entries")
            declared = set(re.findall(r"- ([\w-]+)", items.group()))
        self.assertTrue(declared, "Aggregate must depend on analysis jobs")
        referenced = set(re.findall(r"\bneeds\.([\w-]+)\.", aggregate))
        self.assertFalse(declared - self.jobs.keys(),
                         f"Aggregate needs undefined jobs: {sorted(declared - self.jobs.keys())}")
        self.assertFalse(referenced - declared,
                         f"Aggregate reads jobs absent from needs: {sorted(referenced - declared)}")

    def test_strict_concurrency_count_reports_its_own_findings(self):
        count = self.step_with_id("strict-concurrency", "count")
        self.assertIn("if: always()", count)
        for required in ("strict-concurrency.log", "concurrency=", "warnings=",
                         "GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"):
            with self.subTest(required=required):
                self.assertIn(required, count)
        self.assertNotIn("nightly_lint_report.py", count)

    def test_typecheck_ratchet_still_runs_after_build_failure(self):
        step = self.step_with_id("strict-concurrency", "typecheck")
        self.assertIn("if: always()", step)
        self.assertRegex(step, r"python3\s+scripts/typecheck_timing_ratchet\.py\s+strict-concurrency\.log")
        self.assertIn("--json-out typecheck-timing.json", step)
        self.assertIn("--top-out typecheck-top20.txt", step)

    def test_concurrency_artifact_preserves_diagnostics_and_timings(self):
        uploads = [step for step in step_blocks(self.job("strict-concurrency"))
                   if "uses: actions/upload-artifact@" in step
                   and re.search(r"(?m)^          name: strict-concurrency-log\s*$", step)]
        self.assertEqual(len(uploads), 1, "Missing strict-concurrency-log upload")
        upload = uploads[0]
        self.assertIn("if: always()", upload)
        for artifact in ("strict-concurrency.log", "all-warnings.txt",
                         "concurrency-findings.txt", "perf-findings.txt",
                         "other-findings.txt", "typecheck-saturated.txt",
                         "typecheck-timing.json", "typecheck-top20.txt"):
            with self.subTest(artifact=artifact):
                self.assertRegex(upload, rf"(?m)^            {re.escape(artifact)}\s*$")

    def test_lint_reporter_is_owned_by_lint_job(self):
        owners = [name for name, job in self.jobs.items()
                  for step in step_blocks(job)
                  if re.search(r"(?m)^        run:.*nightly_lint_report\.py|"
                               r"^          .*nightly_lint_report\.py", step)]
        self.assertEqual(owners, ["lint-strict"],
                         "Lint outcome reporting must run exactly once, inside lint-strict")
        reporter = self.step_with_id("lint-strict", "count")
        self.assertIn("nightly_lint_report.py", reporter)
        self.assertIn("if: always()", reporter)
        for tool in ("swiftlint", "periphery"):
            self.step_with_id("lint-strict", tool)
            self.assertIn(f"{tool.upper()}_OUTCOME: ${{{{ steps.{tool}.outcome }}}}", reporter)

    def test_job_outputs_reference_existing_steps(self):
        unresolved = []
        for name, job in self.jobs.items():
            steps = step_blocks(job)
            ids = {match.group(1) for step in steps
                   for match in re.finditer(r"(?m)^        id: ([\w-]+)[ \t]*$", step)}
            # Job-level output mappings precede steps. Comments and run scripts
            # cannot satisfy an output producer merely by mentioning its name.
            prefix = job.split("    steps:", 1)[0]
            producers = set(re.findall(r"\bsteps\.([\w-]+)\.outputs\.", prefix))
            unresolved.extend(f"{name}: {producer}" for producer in sorted(producers - ids))
        self.assertEqual(unresolved, [], "Job outputs reference missing steps")


if __name__ == "__main__":
    unittest.main()
