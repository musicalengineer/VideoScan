#!/usr/bin/env node
// Desktop board: existing work and review evidence, with no discussion agents.
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadOrCreateAccessToken } from "../src/access-token.mjs";

const toolRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
process.env.ENGINEERING_ROOM_MODE = "board";
// VideoScan itself uses 8765. Keep this trial on its own port.
process.env.ENGINEERING_ROOM_PORT ??= "8766";
process.env.ENGINEERING_ROOM_DB ??= join(toolRoot, "var", "work-board.sqlite3");
process.env.ENGINEERING_ROOM_TOKEN_FILE ??= join(toolRoot, "var", "access-token");
process.env.ENGINEERING_ROOM_TOKEN ||= loadOrCreateAccessToken(process.env.ENGINEERING_ROOM_TOKEN_FILE);
await import("../src/server.mjs");
