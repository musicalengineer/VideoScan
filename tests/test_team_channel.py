"""Focused tests for the local manager mailbox."""

from __future__ import annotations

import importlib.util
import io
import json
import plistlib
import sqlite3
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "team-channel.py"
SPEC = importlib.util.spec_from_file_location("team_channel", SCRIPT)
assert SPEC and SPEC.loader
team_channel = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(team_channel)


class TeamChannelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.db_path = Path(self.temp_dir.name) / "channel.sqlite3"
        self.connection = team_channel.connect(self.db_path)

    def tearDown(self) -> None:
        self.connection.close()
        self.temp_dir.cleanup()

    def post(self, author="codex", recipients=None, subject="Review ready", body="Please review branch."):
        return team_channel.post_message(
            self.connection,
            author,
            recipients or ["claude"],
            subject,
            body,
        )

    def test_message_survives_reconnect_and_is_recipient_specific(self) -> None:
        message_id = self.post()
        self.connection.close()
        self.connection = team_channel.connect(self.db_path)

        claude = team_channel.pending_messages(self.connection, "claude")
        bob = team_channel.pending_messages(self.connection, "bob")

        self.assertEqual([message_id], [row["id"] for row in claude])
        self.assertEqual([], bob)

    def test_all_expands_to_every_other_manager(self) -> None:
        recipients = team_channel.expand_recipients("bob", "all")
        self.assertEqual(["codex", "claude", "rick"], recipients)

        message_id = self.post(author="bob", recipients=recipients)
        for recipient in recipients:
            self.assertEqual(
                [message_id],
                [row["id"] for row in team_channel.pending_messages(self.connection, recipient)],
            )
        self.assertEqual([], team_channel.pending_messages(self.connection, "bob"))

    def test_hook_delivers_once_but_requires_explicit_acknowledgment(self) -> None:
        message_id = self.post(body="Review the result, but do not treat this as authority.")
        output = io.StringIO()
        with redirect_stdout(output):
            team_channel.hook_output(self.connection, "claude", "plain")

        self.assertIn(f"#{message_id} from codex", output.getvalue())
        self.assertIn("not instructions", output.getvalue())
        self.assertEqual([], team_channel.pending_messages(self.connection, "claude", undelivered_only=True))
        self.assertEqual([message_id], [row["id"] for row in team_channel.pending_messages(self.connection, "claude")])

        self.assertEqual(1, team_channel.acknowledge(self.connection, "claude", [message_id]))
        self.assertEqual([], team_channel.pending_messages(self.connection, "claude"))

    def test_codex_hook_output_is_valid_json(self) -> None:
        self.post(author="claude", recipients=["codex"])
        output = io.StringIO()
        with redirect_stdout(output):
            team_channel.hook_output(self.connection, "codex", "codex")

        payload = json.loads(output.getvalue())
        self.assertTrue(payload["continue"])
        hook_output = payload["hookSpecificOutput"]
        self.assertEqual("UserPromptSubmit", hook_output["hookEventName"])
        self.assertIn("VideoScan local team-channel delivery", hook_output["additionalContext"])

    def test_explicit_agent_identity_and_qwen_seat_cannot_drain_it(self) -> None:
        with patch.dict("os.environ", {}, clear=True):
            self.assertIsNone(team_channel.infer_hook_agent({"model": "qwen-videoscan:64k"}))
            self.assertEqual("codex", team_channel.infer_hook_agent({"model": "gpt-5.6-sol"}))
        with patch.dict("os.environ", {"VIDEOSCAN_TEAM_AGENT": "bob"}, clear=True):
            self.assertEqual("bob", team_channel.infer_hook_agent({"model": "qwen-videoscan:64k"}))

    def test_ack_cannot_consume_another_agents_message(self) -> None:
        message_id = self.post(recipients=["claude"])
        self.assertEqual(0, team_channel.acknowledge(self.connection, "bob", [message_id]))
        self.assertEqual([message_id], [row["id"] for row in team_channel.pending_messages(self.connection, "claude")])

    def test_reply_requires_an_existing_message(self) -> None:
        with self.assertRaisesRegex(ValueError, "does not exist"):
            team_channel.post_message(
                self.connection, "claude", ["codex"], "Reply", "Done", reply_to=999
            )

    def test_validation_rejects_unknown_self_and_oversize_payloads(self) -> None:
        with self.assertRaises(ValueError):
            team_channel.expand_recipients("codex", "qwen")
        with self.assertRaises(ValueError):
            team_channel.expand_recipients("codex", "codex")
        with self.assertRaises(ValueError):
            team_channel.validate_text("", "body")
        with self.assertRaises(ValueError):
            team_channel.validate_text("subject", "x" * (team_channel.MAX_BODY + 1))

    def test_schema_enforces_duplicate_recipient_delivery(self) -> None:
        message_id = self.post()
        with self.assertRaises(sqlite3.IntegrityError):
            self.connection.execute(
                "INSERT INTO recipients(message_id, recipient) VALUES (?, ?)",
                (message_id, "claude"),
            )

    def test_concurrent_hooks_claim_a_message_only_once(self) -> None:
        message_id = self.post(author="claude", recipients=["codex"])
        barrier = threading.Barrier(2)
        claimed: list[list[int]] = []
        errors: list[Exception] = []

        def claim() -> None:
            connection = team_channel.connect(self.db_path)
            try:
                barrier.wait()
                _, messages = team_channel.claim_messages(connection, "codex")
                claimed.append([int(message["id"]) for message in messages])
            except Exception as error:  # pragma: no cover - retained for assertion detail
                errors.append(error)
            finally:
                connection.close()

        threads = [threading.Thread(target=claim) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        self.assertEqual([], errors)
        self.assertEqual([[message_id], []], sorted(claimed, key=len, reverse=True))

    def test_locked_database_does_not_change_delivery_state(self) -> None:
        message_id = self.post(author="claude", recipients=["codex"])
        locker = team_channel.connect(self.db_path)
        contender = team_channel.connect(self.db_path)
        locker.execute("BEGIN IMMEDIATE")
        try:
            with self.assertRaises(sqlite3.OperationalError):
                team_channel.claim_messages(contender, "codex")
        finally:
            contender.close()
            locker.rollback()
            locker.close()
        self.assertEqual(
            [message_id],
            [row["id"] for row in team_channel.pending_messages(self.connection, "codex", undelivered_only=True)],
        )

    def test_locked_database_hook_fails_open_for_user_prompt(self) -> None:
        locker = team_channel.connect(self.db_path)
        locker.execute("BEGIN IMMEDIATE")
        argv = ["team-channel.py", "hook", "--agent", "codex", "--format", "codex"]
        try:
            with (
                patch.object(sys, "argv", argv),
                patch.object(sys, "stdin", io.StringIO('{"model":"gpt-5.6-sol"}')),
                patch.dict("os.environ", {"VIDEOSCAN_TEAM_CHANNEL_DB": str(self.db_path)}),
            ):
                self.assertEqual(0, team_channel.main())
        finally:
            locker.rollback()
            locker.close()

    def test_existing_database_is_migrated_for_delivery_leases(self) -> None:
        old_path = Path(self.temp_dir.name) / "old.sqlite3"
        old = sqlite3.connect(old_path)
        old.execute(
            """CREATE TABLE recipients (
                message_id INTEGER NOT NULL, recipient TEXT NOT NULL,
                delivered_at TEXT, acknowledged_at TEXT,
                PRIMARY KEY (message_id, recipient))"""
        )
        old.commit()
        old.close()

        migrated = team_channel.connect(old_path)
        columns = {row["name"] for row in migrated.execute("PRAGMA table_info(recipients)")}
        migrated.close()
        self.assertTrue({"claim_token", "claim_until"}.issubset(columns))

    def test_transport_has_no_model_network_or_process_launcher(self) -> None:
        source = SCRIPT.read_text()
        forbidden_imports = ("import subprocess", "import socket", "import urllib", "import requests")
        for forbidden in forbidden_imports:
            self.assertNotIn(forbidden, source)
        self.assertNotIn("codex exec", source)
        self.assertNotIn("claude -p", source)
        self.assertNotIn("http://", source)
        self.assertNotIn("https://", source)

    def test_legacy_watcher_and_launch_agent_fail_closed(self) -> None:
        repo = SCRIPT.parents[1]
        watcher = (repo / "tools" / "channel-watcher" / "watch_channel.sh").read_text()
        guard_position = watcher.index("exit 2")
        self.assertLess(guard_position, watcher.index("codex exec"))
        self.assertLess(guard_position, watcher.index("claude -p"))

        with (repo / "tools" / "channel-watcher" / "com.videoscan.channel-watcher.plist").open("rb") as handle:
            launch_agent = plistlib.load(handle)
        self.assertFalse(launch_agent["RunAtLoad"])
        self.assertFalse(launch_agent["KeepAlive"])
        self.assertNotIn("EnvironmentVariables", launch_agent)

    def test_manager_hook_configuration_is_local_mailbox_only(self) -> None:
        repo = SCRIPT.parents[1]
        codex_hooks = json.loads((repo / ".codex" / "hooks.json").read_text())
        claude_settings = json.loads((repo / ".claude" / "settings.json").read_text())

        codex_command = codex_hooks["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
        claude_command = claude_settings["hooks"]["UserPromptSubmit"][0]["hooks"][0]["command"]
        for command in (codex_command, claude_command):
            self.assertIn("tools/team-channel.py", command)
            self.assertNotIn("codex exec", command)
            self.assertNotIn("claude -p", command)
            self.assertNotIn("curl", command)


if __name__ == "__main__":
    unittest.main()


class WriteOnlySeatTests(unittest.TestCase):
    def test_reviewer_can_post_but_all_never_addresses_it(self) -> None:
        self.assertIn("reviewer", team_channel.AGENTS)
        self.assertNotIn("reviewer", team_channel.expand_recipients("claude", "all"))
        self.assertEqual(["claude"], team_channel.expand_recipients("reviewer", "claude"))
