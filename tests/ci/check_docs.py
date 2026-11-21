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


def main() -> int:
    check_site()
    check_markdown_links()
    check_docs_linked_from_readme()
    check_changelog_in_site()
    if errors:
        print("Documentation checks failed:")
        for error in errors:
            print(f"  - {error}")
        return 1
    print("Documentation and site checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
