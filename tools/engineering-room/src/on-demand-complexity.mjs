import { constants } from "node:fs";
import { open } from "node:fs/promises";
import { join } from "node:path";

const MAX_BYTES = 128 * 1024;
const COUNT_KEYS = ["lines", "files", "functions", "max_ccn", "ccn_over_15", "ccn_over_30"];
const FOLDER_COUNT_KEYS = ["files", "functions", "ccn_over_15", "ccn_over_30", "nloc_over_80", "offenders", "files_over_800"];

// A worker publishes this one atomic snapshot. Browser input never selects a
// path, and this reader neither launches work nor alters the nightly history.
export async function readOnDemandComplexity({ toolRoot, now = new Date() }) {
  const response = { status: "ok", observedAt: now.toISOString(), result: null, stale: false, error: null };
  let file;
  try {
    file = await open(join(toolRoot, "var", "on-demand-complexity-latest.json"), constants.O_RDONLY | constants.O_NONBLOCK | constants.O_NOFOLLOW);
    const stat = await file.stat();
    if (!stat.isFile()) throw new Error("not-file");
    if (stat.size > MAX_BYTES) throw new Error("too-large");
    // At most 128 KiB + one byte, even if the producer grows the file mid-read.
    const buffer = Buffer.alloc(MAX_BYTES + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await file.read(buffer, length, buffer.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > MAX_BYTES) throw new Error("too-large");
    response.result = validateResult(JSON.parse(buffer.subarray(0, length).toString("utf8")));
    response.stale = now.getTime() - Date.parse(response.result.ts) > 24 * 60 * 60 * 1000;
  } catch (error) {
    response.status = error.code === "ENOENT" ? "missing" : "error";
    response.error = response.status === "missing" ? "No on-demand complexity result has been published yet."
      : error.message === "too-large" ? "The on-demand complexity result exceeds the 128 KiB limit."
      : error.message === "not-file" || error.code === "ELOOP" ? "The on-demand complexity result is not a regular file."
      : error instanceof SyntaxError || error.message === "invalid-result" ? "The on-demand complexity result is malformed or unsupported."
      : "The on-demand complexity result could not be read.";
  } finally {
    await file?.close();
  }
  return response;
}

function validateResult(value) {
  requireValue(value && typeof value === "object" && !Array.isArray(value) && value.schemaVersion === 1);
  const result = {
    schemaVersion: 1,
    scope: relativePath(value.scope),
    folder: boundedText(value.folder, 240),
    machine: value.machine,
    ts: boundedText(value.ts, 32),
    sha: boundedText(value.sha, 40),
    sourceRef: boundedText(value.sourceRef, 500),
    sourceDirty: value.sourceDirty,
    lizardVersion: boundedText(value.lizardVersion, 80),
    metrics: {}, folderMetrics: {},
    ccn15Excess: count(value.ccn15Excess),
    topFunctions: [],
  };
  requireValue(["m4", "m5", "m1"].includes(result.machine) && typeof result.sourceDirty === "boolean");
  requireValue(/^[a-f0-9]{40}$/i.test(result.sha));
  requireValue(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(result.ts) && Number.isFinite(Date.parse(result.ts)));
  requireValue(new Date(result.ts).toISOString() === (result.ts.includes(".") ? result.ts : result.ts.replace("Z", ".000Z")));
  requireValue(value.metrics && typeof value.metrics === "object" && !Array.isArray(value.metrics));
  for (const key of COUNT_KEYS) result.metrics[key] = count(value.metrics[key]);
  result.metrics.mean_ccn = nonnegativeNumber(value.metrics.mean_ccn);
  requireValue(result.metrics.ccn_over_30 <= result.metrics.ccn_over_15 && result.metrics.ccn_over_15 <= result.metrics.functions);
  requireValue(result.metrics.mean_ccn <= result.metrics.max_ccn);
  if (value.folderMetrics !== undefined) {
    requireValue(value.folderMetrics && typeof value.folderMetrics === "object" && !Array.isArray(value.folderMetrics));
    for (const key of FOLDER_COUNT_KEYS) if (value.folderMetrics[key] !== undefined) result.folderMetrics[key] = count(value.folderMetrics[key]);
    if (value.folderMetrics.mean_ccn !== undefined) result.folderMetrics.mean_ccn = nonnegativeNumber(value.folderMetrics.mean_ccn);
  }
  if (value.measurementScope !== undefined) result.measurementScope = boundedText(value.measurementScope, 240);
  if (value.presentationScope !== undefined) {
    result.presentationScope = relativePath(value.presentationScope);
    requireValue(result.presentationScope === result.scope);
  }
  if (value.measuredRoots !== undefined) {
    requireValue(Array.isArray(value.measuredRoots) && value.measuredRoots.length <= 30);
    result.measuredRoots = value.measuredRoots.map(relativePath);
  }
  if (value.measuredLanguages !== undefined) {
    requireValue(Array.isArray(value.measuredLanguages) && value.measuredLanguages.length <= 10);
    result.measuredLanguages = value.measuredLanguages.map(language => boundedText(language, 80));
  }
  requireValue(Array.isArray(value.topFunctions) && value.topFunctions.length <= 100);
  result.topFunctions = value.topFunctions.slice(0, 20).map(fn => {
    requireValue(fn && typeof fn === "object" && !Array.isArray(fn));
    const file = relativePath(fn.file);
    requireValue(result.scope === "." || file.startsWith(result.scope + "/"));
    return { file, function: boundedText(fn.function, 500), line: count(fn.line), ccn: count(fn.ccn), nloc: count(fn.nloc) };
  });
  return result;
}

function boundedText(value, limit) {
  requireValue(typeof value === "string" && value.length > 0 && value.length <= limit && !/[\u0000-\u001f]/.test(value));
  return value;
}
function relativePath(value) {
  const path = boundedText(value, 500);
  requireValue(!path.startsWith("/") && !path.includes("\\") && !path.split("/").includes("..") && !/^[a-z]:/i.test(path));
  return path;
}
function nonnegativeNumber(value) { requireValue(typeof value === "number" && Number.isFinite(value) && value >= 0); return value; }
function count(value) { requireValue(Number.isSafeInteger(value) && value >= 0); return value; }
function requireValue(condition) { if (!condition) throw new Error("invalid-result"); }
