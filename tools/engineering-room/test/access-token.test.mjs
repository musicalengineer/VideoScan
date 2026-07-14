import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadOrCreateAccessToken } from "../src/access-token.mjs";

test("LAN access token is stable, private, and repairs invalid contents", () => {
  const directory = mkdtempSync(join(tmpdir(), "engineering-room-token-"));
  const path = join(directory, "access-token");
  writeFileSync(path, "\n");
  const created = loadOrCreateAccessToken(path);
  assert.match(created, /^[A-Za-z0-9_-]{32,}$/);
  assert.equal(readFileSync(path, "utf8").trim(), created);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  assert.equal(statSync(directory).mode & 0o777, 0o700);
  assert.equal(loadOrCreateAccessToken(path), created);
});
