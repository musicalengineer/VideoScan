"""Shared by every Python test (2026-11-22).

The test lanes give each test host a sealed home holding a COPY of the real App Support
(scripts/sealed_home.py). A Python test that drives a lane must never make that copy of Rick's real
data: here the copy's SOURCE is an empty folder for every test. It only chooses what is copied from —
the sealed home itself is always scratch."""
import pytest


@pytest.fixture(autouse=True)
def _seal_copies_nothing_real(tmp_path_factory, monkeypatch):
    monkeypatch.setenv("VIDEOSCAN_SEAL_SOURCE_HOME", str(tmp_path_factory.mktemp("no-real-home")))
