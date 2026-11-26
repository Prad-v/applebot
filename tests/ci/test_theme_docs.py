#!/usr/bin/env python3
"""Smoke checks for theme settings docs."""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_theme_in_user_guide() -> None:
    guide = (ROOT / "docs" / "user-guide.md").read_text(encoding="utf-8")
    assert "You → Theme" in guide
    assert "High contrast" in guide


def test_theme_in_site() -> None:
    page = (ROOT / "site" / "user-guide.html").read_text(encoding="utf-8")
    assert "You &rarr; Theme" in page
    changelog = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    assert "Theme settings" in changelog


if __name__ == "__main__":
    test_theme_in_user_guide()
    test_theme_in_site()
    print("Theme docs smoke tests passed.")
