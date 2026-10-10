"""API key lookup. The key lives in memory only.

Order (spec §6): ANTHROPIC_API_KEY env, else the macOS Keychain item
`security find-generic-password -s hallie-e1 -a anthropic -w`, else the SDK's
own credential resolution (an `ant auth login` profile). Only the SOURCE
("env" | "keychain" | "profile") is ever recorded. Every key found is
registered with `scrub`, which every file writer and console print passes
through, so a key cannot reach a log even by accident.
"""
from __future__ import annotations

import os
import subprocess

KEYCHAIN_SERVICE = "hallie-e1"
_SECRETS: set[str] = set()


def register_secret(value: str | None) -> None:
    if value and len(value) >= 8:
        _SECRETS.add(value)


def scrub(text: str) -> str:
    for s in _SECRETS:
        if s in text:
            text = text.replace(s, "[REDACTED-KEY]")
    return text


def _keychain(account: str, runner=subprocess.run) -> str | None:
    try:
        out = runner(["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
                     capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    v = (out.stdout or "").strip()
    return v or None


def resolve_key(env_var: str, account: str, env=None, runner=subprocess.run) -> tuple[str | None, str]:
    env = os.environ if env is None else env
    v = env.get(env_var)
    if v:
        register_secret(v)
        return v, "env"
    v = _keychain(account, runner)
    if v:
        register_secret(v)
        return v, "keychain"
    return None, "profile" if account == "anthropic" else "none"


def anthropic_key(env=None, runner=subprocess.run):
    return resolve_key("ANTHROPIC_API_KEY", "anthropic", env, runner)


def ollama_key(env=None, runner=subprocess.run):
    return resolve_key("OLLAMA_API_KEY", "ollama", env, runner)
