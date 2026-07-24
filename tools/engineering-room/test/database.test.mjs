import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RoomDatabase } from "../src/database.mjs";

test("topics and attributed messages survive a database restart", () => {
  const path = join(mkdtempSync(join(tmpdir(), "engineering-room-db-")), "room.sqlite3");
  let db = new RoomDatabase(path);
  const topic = db.createTopic("Recognition metrics");
  const message = db.createMessage({ topicId: topic.id, author: "rick", body: "Keep quality honest." });
  const claude = db.createMessage({ topicId: topic.id, author: "claude", body: "Measure the boundary cases.", providerResponseId: "msg-provider-42", deltaKind: "evidence", deltaDetail: "Boundary cases measured" });
  db.setSession("codex", "thread-42");
  db.setState("autopilot.enabled", true);
  db.setState("autopilot.run", { status: "intervention", completedTurns: 1 });
  db.close();

  db = new RoomDatabase(path);
  const snapshot = db.snapshot();
  assert.equal(snapshot.topics.find(item => item.id === topic.id).title, "Recognition metrics");
  assert.equal(snapshot.messages.find(item => item.id === message.id).body, "Keep quality honest.");
  assert.equal(snapshot.messages.find(item => item.id === claude.id).author, "claude");
  assert.equal(snapshot.messages.find(item => item.id === claude.id).providerResponseId, "msg-provider-42");
  assert.equal(snapshot.messages.find(item => item.id === claude.id).deltaKind, "evidence");
  assert.equal(db.getSession("codex").externalThreadId, "thread-42");
  assert.equal(db.getState("autopilot.enabled"), true);
  assert.equal(db.getState("autopilot.run").completedTurns, 1);
  db.close();
});

test("topic state can be parked and reactivated", () => {
  const path = join(mkdtempSync(join(tmpdir(), "engineering-room-db-")), "room.sqlite3");
  const db = new RoomDatabase(path);
  const topic = db.createTopic("A/V stitching");
  assert.equal(db.updateTopic(topic.id, { status: "parked" }).status, "parked");
  assert.equal(db.updateTopic(topic.id, { status: "active" }).status, "active");
  db.close();
});
