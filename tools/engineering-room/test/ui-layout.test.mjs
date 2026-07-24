import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const html = readFileSync(join(root, "public", "index.html"), "utf8");
const css = readFileSync(join(root, "public", "styles.css"), "utf8");
const app = readFileSync(join(root, "public", "app.js"), "utf8");

test("dashboard stays fixed while board and conversation scroll independently", () => {
  assert.match(css, /html, body \{[^}]*height: 100%[^}]*overflow: hidden/s);
  assert.match(css, /\.shell \{[^}]*height: 100(?:vh|dvh)[^}]*overflow: hidden/s);
  assert.match(css, /\.workspace \{[^}]*flex: 1[^}]*min-height: 0[^}]*overflow: hidden/s);
  assert.match(css, /\.team-board \{[^}]*flex: 1[^}]*overflow-y: auto/s);
  assert.match(css, /\.team-board-sticky \{[^}]*position: sticky/s);
  assert.match(css, /\.conversation \{[^}]*min-height: 0[^}]*overflow: hidden/s);
  assert.match(css, /\.timeline \{[^}]*min-height: 0[^}]*overflow-y: auto/s);
});

test("room controls collapse and narrow screens use top-status bottom-chat split", () => {
  assert.match(html, /<details class="room-tools">[\s\S]*Autopilot and work assignment[\s\S]*<form class="composer"/);
  assert.match(css, /@media \(max-width: 800px\)[\s\S]*grid-template-rows: minmax\(210px, 38%\) minmax\(0, 62%\)/);
});

test("Team Board renders progress percentages only from reported percent or ratios", () => {
  assert.match(app, /function parseProgressPercent/);
  assert.match(app, /function progressMeter/);
  assert.match(app, /role", "progressbar"/);
});

test("task dispatch requires and displays an explicit machine route", () => {
  assert.match(html, /<select id="directiveMachine" required>[\s\S]*value="none"[\s\S]*value="m5"[\s\S]*value="m1"[\s\S]*value="m4"/);
  assert.match(app, /machine: elements\.directiveMachine\.value|const machine = elements\.directiveMachine\.value/);
  assert.match(app, /taskRow\.machine \?\? "unrouted"/);
});
