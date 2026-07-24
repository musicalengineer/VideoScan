import copy
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "publish_search_benchmarks.py"
SPEC = importlib.util.spec_from_file_location("publish_search_benchmarks", MODULE_PATH)
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(module)


def measurement(operation, query=None):
    footprint = operation == "haystack-footprint"
    row = {
        "benchmark": "catalog-search",
        "metric": "catalog_search_haystack_footprint" if footprint else "catalog_search_latency",
        "operation": operation,
        "corpusId": "catalog-search-synthetic",
        "corpusVersion": 1,
        "corpusSeed": "0xb005eed020260723",
        "recordCount": 100_000,
        "unit": "bytes" if footprint else "milliseconds",
        "direction": "lower",
        "warmupCount": 0 if footprint else 3,
        "sampleCount": 1 if footprint else (3 if operation != "query" else 20),
        "resultCount": 100_000 if operation != "query" else 42,
        "expectedResultCount": 100_000 if operation != "query" else 42,
        "correct": True,
    }
    if query is not None:
        row["query"] = query
    if footprint:
        row["value"] = 12_345_678
    else:
        row.update({"min": 1.0, "median": 2.0, "p95": 3.0})
    return row


def matrix():
    rows = [
        measurement("rebuild"),
        measurement("haystack-footprint"),
        measurement("persist-roundtrip"),
    ]
    rows.extend(measurement("query", query) for query in module.EXPECTED_QUERIES)
    return rows


def provenance():
    return {
        "host": "RicksM5",
        "machineClass": "m5",
        "macOS": {"version": "26.0", "build": "25A1"},
        "xcode": {"version": "Xcode 26.3", "build": "Build version 17C1"},
        "architecture": "arm64",
        "configuration": "Release",
        "branch": "main",
        "dirty": False,
        "commit": "a" * 40,
    }


def dashboard_row(run_id, ts, **changes):
    p = provenance()
    p.update(changes)
    measurements = [measurement("rebuild")]
    measurements.extend(measurement("query", query) for query in module.EXPECTED_QUERIES)
    return {
        "schemaVersion": 1, "runId": run_id, "ts": ts,
        "benchmark": "catalog-search", **p,
        "corpus": {"id": "catalog-search-synthetic", "version": 1,
                   "seed": module.CORPUS_SEED, "recordCount": 100_000, "synthetic": True},
        "measurements": measurements,
    }


def execute_dashboard(search_rows):
    harness = r'''
const fs = require("fs");
const html = fs.readFileSync("docs/index.html", "utf8");
let script = html.match(/<script>\n([\s\S]*?)<\/script>/)[1];
script = script.replace(/\nloadData\(\);\s*$/, "\nglobalThis.__dashboardDone = loadData();");
const elements = new Map();
function element(id = "") {
  const classes = new Set();
  const value = { id, children: [], innerHTML: "", textContent: "", style: {},
    classList: { add: x => classes.add(x), remove: x => classes.delete(x), contains: x => classes.has(x) },
    appendChild(child) { this.children.push(child); return child; },
    querySelector() { const child = element(); this.children.push(child); return child; } };
  value.parentElement = value;
  return value;
}
globalThis.document = {
  getElementById(id) { if (!elements.has(id)) elements.set(id, element(id)); return elements.get(id); },
  createElement() { return element(); },
};
const charts = [];
globalThis.Chart = function(target, config) { charts.push({ id: target.id, config }); };
const payload = __SEARCH_ROWS__;
globalThis.fetch = async url => {
  if (String(url).includes("/branches/metrics")) return { ok: false };
  if (String(url).includes("search_benchmarks.jsonl")) {
    return payload.length ? { ok: true, text: async () => payload.map(JSON.stringify).join("\n") } : { ok: false };
  }
  if (String(url).includes("history.jsonl")) return { ok: true, text: async () => '{"ts":"2026-07-23T00:00:00Z","sha":"abc"}\n' };
  return { ok: false };
};
(async () => {
  eval(script);
  await globalThis.__dashboardDone;
  const canvas = elements.get("chart-search-benchmarks");
  const searchChart = charts.find(chart => chart.id === "chart-search-benchmarks");
  process.stdout.write(JSON.stringify({
    cards: elements.get("search-benchmark-cards").innerHTML,
    canvasHidden: canvas.classList.contains("hidden"),
    trendLength: searchChart ? searchChart.config.data.datasets[0].data.length : 0,
    provenance: elements.get("search-benchmark-provenance").textContent,
  }));
})().catch(error => { console.error(error); process.exit(1); });
'''.replace("__SEARCH_ROWS__", json.dumps(search_rows))
    result = subprocess.run(["node", "-"], cwd=ROOT, input=harness, text=True,
                            capture_output=True)
    if result.returncode:
        raise AssertionError(f"dashboard Node harness failed:\n{result.stderr}")
    return json.loads(result.stdout)


class SearchBenchmarkMetricsTests(unittest.TestCase):
    def write_rows(self, directory, rows):
        path = pathlib.Path(directory) / "raw.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        return path

    def test_complete_fixed_matrix_builds_typed_run_with_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            row = module.build_run(
                self.write_rows(directory, matrix()), "catalog-search-test-0001",
                provenance(), "2026-07-23T12:00:00Z",
            )
        self.assertEqual(row["benchmark"], "catalog-search")
        self.assertEqual(row["corpus"]["recordCount"], 100_000)
        self.assertTrue(row["corpus"]["synthetic"])
        self.assertEqual(len(row["measurements"]), 13)
        self.assertEqual(row["configuration"], "Release")
        self.assertEqual(row["architecture"], "arm64")
        self.assertEqual(row["commit"], "a" * 40)

    def test_missing_or_duplicate_matrix_case_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.ValidationError, "incomplete 100k matrix"):
                module.load_raw(self.write_rows(directory, matrix()[:-1]))
            rows = matrix()
            rows[-1] = copy.deepcopy(rows[-2])
            with self.assertRaisesRegex(module.ValidationError, "duplicate operation/query"):
                module.load_raw(self.write_rows(directory, rows))

    def test_nonfinite_wrong_counts_and_invalid_stat_order_are_rejected(self):
        cases = []
        rows = matrix()
        rows[0]["median"] = float("nan")
        cases.append((rows, "finite"))
        rows = matrix()
        rows[3]["resultCount"] += 1
        cases.append((rows, "does not match"))
        rows = matrix()
        rows[0].update({"min": 3.0, "median": 2.0, "p95": 1.0})
        cases.append((rows, "minimum <= median <= p95"))
        for rows, message in cases:
            with self.subTest(message=message), tempfile.TemporaryDirectory() as directory:
                with self.assertRaisesRegex(module.ValidationError, message):
                    module.load_raw(self.write_rows(directory, rows))

    def test_fixed_warmup_and_sample_counts_cannot_drift(self):
        rows = matrix()
        rows[3]["sampleCount"] = 10
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.ValidationError, "warmup/sample"):
                module.load_raw(self.write_rows(directory, rows))

    def test_real_catalog_or_private_path_is_rejected(self):
        rows = matrix()
        rows[3]["source"] = "/Volumes/FamilyArchive/catalog.json"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.ValidationError, "private or real-catalog path"):
                module.load_raw(self.write_rows(directory, rows))

    def test_unknown_raw_fields_and_wrong_seed_are_rejected(self):
        rows = matrix()
        rows[3]["privateFamilyNote"] = "Donna at Christmas"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.ValidationError, "unknown fields.*privateFamilyNote"):
                module.load_raw(self.write_rows(directory, rows))
        rows = matrix()
        rows[0]["corpusSeed"] = "0x0000000000000000"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(module.ValidationError, "invalid corpusSeed"):
                module.load_raw(self.write_rows(directory, rows))

    def test_raw_parser_has_a_hard_size_bound(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "raw.jsonl"
            path.write_bytes(b" " * 1_000_001)
            with self.assertRaisesRegex(module.ValidationError, "too large"):
                module.load_raw(path)

    def test_build_provenance_requires_release_arm64_clean_main_full_sha(self):
        variants = [
            ({"configuration": "Debug"}, "Release on arm64"),
            ({"architecture": "x86_64"}, "Release on arm64"),
            ({"branch": "feature/test"}, "clean main"),
            ({"dirty": True}, "clean main"),
            ({"commit": "abc1234"}, "40-character"),
        ]
        with tempfile.TemporaryDirectory() as directory:
            raw = self.write_rows(directory, matrix())
            for changes, message in variants:
                value = provenance()
                value.update(changes)
                with self.subTest(changes=changes), self.assertRaisesRegex(module.ValidationError, message):
                    module.build_run(raw, "catalog-search-test-0001", value)

    def test_provenance_objects_have_closed_schemas(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = self.write_rows(directory, matrix())
            value = provenance()
            value["privateFamilyNote"] = "not public"
            with self.assertRaisesRegex(module.ValidationError, "unknown run provenance"):
                module.build_run(raw, "catalog-search-test-0001", value)
            value = provenance()
            value["xcode"]["path"] = "/Applications/Xcode.app"
            with self.assertRaisesRegex(module.ValidationError, "unknown OS/Xcode"):
                module.build_run(raw, "catalog-search-test-0001", value)

    def test_atomic_append_is_idempotent_and_run_id_conflicts_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = self.write_rows(directory, matrix())
            row = module.build_run(raw, "catalog-search-test-0001", provenance(), "2026-07-23T12:00:00Z")
            stream = pathlib.Path(directory) / "metrics" / "search_benchmarks.jsonl"
            self.assertTrue(module.atomic_append(stream, row))
            self.assertFalse(module.atomic_append(stream, row))
            self.assertEqual(len(stream.read_text().splitlines()), 1)
            changed = copy.deepcopy(row)
            changed["ts"] = "2026-07-23T12:01:00Z"
            with self.assertRaisesRegex(module.ValidationError, "different content"):
                module.atomic_append(stream, changed)
            unknown = copy.deepcopy(row)
            unknown["privateFamilyNote"] = "must never publish"
            with self.assertRaisesRegex(module.ValidationError, "unknown or missing"):
                module.atomic_append(stream, unknown)

    def test_dashboard_executes_no_data_state(self):
        rendered = execute_dashboard([])
        self.assertIn("No catalog-search benchmark data", rendered["cards"])
        self.assertTrue(rendered["canvasHidden"])
        self.assertEqual(rendered["trendLength"], 0)

    def test_dashboard_trend_excludes_mixed_host_os_and_xcode_provenance(self):
        base = dashboard_row("run-match-1", "2026-07-23T10:00:00Z")
        other_host = dashboard_row("run-host", "2026-07-23T10:01:00Z", host="OtherM5")
        other_os_version = dashboard_row("run-os-version", "2026-07-23T10:02:00Z",
                                         macOS={"version": "26.1", "build": "25A1"})
        other_os_build = dashboard_row("run-os-build", "2026-07-23T10:03:00Z",
                                       macOS={"version": "26.0", "build": "25B2"})
        other_xcode_version = dashboard_row("run-xcode-version", "2026-07-23T10:04:00Z",
                                            xcode={"version": "Xcode 26.4", "build": "Build version 17C1"})
        other_xcode_build = dashboard_row("run-xcode-build", "2026-07-23T10:05:00Z",
                                          xcode={"version": "Xcode 26.3", "build": "Build version 17D1"})
        latest = dashboard_row("run-match-2", "2026-07-23T10:06:00Z")
        rendered = execute_dashboard([
            base, other_host, other_os_version, other_os_build,
            other_xcode_version, other_xcode_build, latest,
        ])
        self.assertEqual(rendered["trendLength"], 2)
        self.assertIn("RicksM5", rendered["provenance"])

    def test_dashboard_and_runner_contract_is_pinned(self):
        page = (ROOT / "docs" / "index.html").read_text()
        runner = (ROOT / "scripts" / "run_catalog_search_benchmarks.sh").read_text()
        self.assertIn('rawUrl("search_benchmarks.jsonl")', page)
        self.assertIn('id="search-benchmark-cards"', page)
        self.assertIn('id="chart-search-benchmarks"', page)
        self.assertIn('row.machineClass === latestSearch.machineClass', page)
        self.assertIn('row.corpus.seed === latestSearch.corpus.seed', page)
        self.assertIn('row.configuration === latestSearch.configuration', page)
        self.assertNotIn('rawUrl("benchmarks.jsonl")', page)
        self.assertIn('No catalog-search benchmark data', page)
        self.assertIn('configuration Release', runner)
        self.assertIn('TEST_RUNNER_VS_RUN_SEARCH_BENCH=1', runner)
        self.assertIn('--allow-m4', runner)
        self.assertIn('git status --porcelain', runner)
        self.assertIn('-only-testing:VideoScanTests/CatalogSearchBenchmarkTests/fullBenchmarkMatrix', runner)


if __name__ == "__main__":
    unittest.main()
