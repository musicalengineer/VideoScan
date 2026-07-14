import { randomBytes } from "node:crypto";
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";

const VALID_TOKEN = /^[A-Za-z0-9_-]{32,}$/;

export function loadOrCreateAccessToken(path) {
  const directory = dirname(path);
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  chmodSync(directory, 0o700);
  if (existsSync(path)) {
    const existing = readFileSync(path, "utf8").trim();
    if (VALID_TOKEN.test(existing)) {
      chmodSync(path, 0o600);
      return existing;
    }
  }
  const token = randomBytes(24).toString("base64url");
  writeFileSync(path, `${token}\n`, { mode: 0o600 });
  chmodSync(path, 0o600);
  return token;
}
