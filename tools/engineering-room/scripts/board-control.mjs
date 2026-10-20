#!/usr/bin/env node
// Use the existing worker protocol against the desktop board's separate port.
process.env.ENGINEERING_ROOM_PORT ??= "8766";
await import("./team-control.mjs");
