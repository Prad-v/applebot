#!/usr/bin/env python3
"""Documentation and static-site consistency checks (stdlib only, runs in Docker).

1. Every relative link/asset in site/*.html resolves to a file.
2. Every docs/*.md is linked from README.md.
3. The newest version in CHANGELOG.md appears on site/changelog.html.
4. Every relative markdown link in README.md and docs/*.md resolves.
"""
from __future__ import annotations

import re
import sys
from html.parser import HTMLParser
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
errors: list[str] = []


class LinkCollector(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.links: list[str] = []

    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src") and value:
                self.links.append(value)


def is_external(link: str) -> bool:
    return bool(re.match(r"^(https?:|mailto:|tel:|#|data:)", link))


def check_site() -> None:
    site = ROOT / "site"
    pages = sorted(site.glob("*.html"))
    if not pages:
        errors.append("site/ has no HTML pages")
    for page in pages:
        collector = LinkCollector()
        collector.feed(page.read_text(encoding="utf-8"))
        for link in collector.links:
            if is_external(link):
                continue
            target = (page.parent / link.split("#")[0].split("?")[0]).resolve()
            if not target.exists():
                errors.append(f"{page.relative_to(ROOT)}: broken link '{link}'")


def check_markdown_links() -> None:
    files = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]
    for md in files:
        for match in re.finditer(r"\]\(([^)\s]+)\)", md.read_text(encoding="utf-8")):
            link = match.group(1)
            if is_external(link):
                continue
            target = (md.parent / link.split("#")[0]).resolve()
            if not target.exists():
                errors.append(f"{md.relative_to(ROOT)}: broken link '{link}'")


def check_docs_linked_from_readme() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for doc in sorted((ROOT / "docs").glob("*.md")):
        if f"docs/{doc.name}" not in readme:
            errors.append(f"README.md does not link docs/{doc.name}")


def check_changelog_in_site() -> None:
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    versions = re.findall(r"^## \[?(\d+\.\d+\.\d+)\]?", changelog, flags=re.MULTILINE)
    if not versions:
        errors.append("CHANGELOG.md has no '## x.y.z' entries")
        return
    page = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    if versions[0] not in page:
        errors.append(f"site/changelog.html is missing latest version {versions[0]}")


def check_ux_navigation_docs() -> None:
    """Companion UX rename: Chat / Library / You must stay documented."""
    ux = (ROOT / "docs" / "ux.md").read_text(encoding="utf-8")
    for tab in ("Chat", "Library", "Health", "You"):
        if f"**{tab}**" not in ux:
            errors.append(f"docs/ux.md should describe the {tab} tab")
    if "lightweight" not in ux.lower() and "Typography over boxes" not in ux:
        errors.append("docs/ux.md should describe the lightweight UX pattern")
    if "You → Theme" not in ux and "Theme" not in ux:
        errors.append("docs/ux.md should document Theme settings")
    for name in ("System", "Daylight", "Midnight", "Ocean", "Forest", "High contrast"):
        if name not in ux:
            errors.append(f"docs/ux.md should list the {name} theme")
    guide = (ROOT / "docs" / "user-guide.md").read_text(encoding="utf-8")
    if "**Chat** tab" not in guide:
        errors.append("docs/user-guide.md should mention the Chat tab")
    if "Chats tab" in guide:
        errors.append("docs/user-guide.md still mentions the old Chats tab name")
    page = (ROOT / "site" / "changelog.html").read_text(encoding="utf-8")
    if "0.10.0" not in page:
        errors.append("site/changelog.html should include 0.10.0 (companion UX)")
    if "0.10.1" not in page:
        errors.append("site/changelog.html should include 0.10.1 (mic auto-start fix)")
    if "0.10.2" not in page or "Delete chat" not in page:
        errors.append("site/changelog.html should include 0.10.2 (delete chat)")
    if "0.11.0" not in page or "Health tab" not in page:
        errors.append("site/changelog.html should include 0.11.0 (Health tab)")
    if "0.11.1" not in page:
        errors.append("site/changelog.html should include 0.11.1 (Health follow-ups)")
    if "0.11.2" not in page:
        errors.append("site/changelog.html should include 0.11.2 (notification Taken / App Intents)")
    if "Delete Chat" not in guide and "Delete a conversation" not in guide:
        errors.append("docs/user-guide.md should document deleting a conversation")
    if "## Health" not in guide:
        errors.append("docs/user-guide.md should document the Health tab")
    health = (ROOT / "docs" / "health.md").read_text(encoding="utf-8")
    if "Not medical" not in health and "not a medical" not in health.lower():
        errors.append("docs/health.md should include a medical disclaimer")
    voice = (ROOT / "docs" / "voice.md").read_text(encoding="utf-8")
    if "markVoiceTurn" not in voice or "noteTypedInput" not in voice:
        errors.append("docs/voice.md should document markVoiceTurn / noteTypedInput hands-free gating")


def main() -> int:
    check_site()
    check_markdown_links()
    check_docs_linked_from_readme()
    check_changelog_in_site()
    check_ux_navigation_docs()
    if errors:
        print("Documentation checks failed:")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("Documentation and site checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
