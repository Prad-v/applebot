#!/usr/bin/env python3
"""Smoke checks for the companion UX docs (runs in Docker docs-check / CI)."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_ux_doc_describes_tabs() -> None:
    ux = (ROOT / "docs" / "ux.md").read_text(encoding="utf-8")
    for tab in ("Chat", "Library", "Health", "You"):
        assert f"**{tab}**" in ux, f"docs/ux.md should describe the {tab} tab"


def test_user_guide_uses_new_navigation() -> None:
    guide = (ROOT / "docs" / "user-guide.md").read_text(encoding="utf-8")
    assert "**Chat** tab" in guide
    assert "**Library → Packs**" in guide or "Library → Packs" in guide
    assert "You →" in guide
    assert "Chats tab" not in guide


def test_site_changelog_mentions_ux() -> None:
    page = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    assert "0.10.0" in page
    assert "Companion UX" in page or "UX redesign" in page


def test_voice_docs_gate_hands_free_to_mic_turns() -> None:
    voice = (ROOT / "docs" / "voice.md").read_text(encoding="utf-8")
    assert "markVoiceTurn" in voice
    assert "noteTypedInput" in voice
    guide = (ROOT / "docs" / "user-guide.md").read_text(encoding="utf-8")
    assert "typing never starts the mic" in guide.lower() or "never starts the mic" in guide.lower()
    page = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    assert "0.10.1" in page


def test_delete_chat_documented() -> None:
    guide = (ROOT / "docs" / "user-guide.md").read_text(encoding="utf-8")
    assert "Delete Chat" in guide or "Delete a conversation" in guide
    page = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    assert "0.10.2" in page
    assert "Delete chat" in page
    ux = (ROOT / "docs" / "ux.md").read_text(encoding="utf-8")
    assert "delete-chat" in ux


def test_health_tab_documented() -> None:
    guide = (ROOT / "docs" / "user-guide.md").read_text(encoding="utf-8")
    assert "## Health" in guide
    health = (ROOT / "docs" / "health.md").read_text(encoding="utf-8")
    assert "wellness" in health.lower()
    assert "medication" in health.lower()
    assert "reminder" in health.lower() or "Taken" in health
    assert "7-day" in health.lower() or "Last 7 days" in health
    page = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    assert "0.11.0" in page
    assert "0.11.1" in page
    assert "0.11.2" in page
    assert "Health tab" in page
    assert "Siri" in health or "Shortcuts" in health


if __name__ == "__main__":
    test_ux_doc_describes_tabs()
    test_user_guide_uses_new_navigation()
    test_site_changelog_mentions_ux()
    test_voice_docs_gate_hands_free_to_mic_turns()
    test_delete_chat_documented()
    test_health_tab_documented()
    print("UX docs smoke tests passed.")
