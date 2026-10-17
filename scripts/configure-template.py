#!/usr/bin/env python3
"""Replace literal bootstrap placeholders without sed's replacement metacharacter traps."""
from pathlib import Path
import sys

if len(sys.argv) != 6:
    raise SystemExit("usage: configure-template.py PKGBUILD OWNER REPO MAINTAINER_NAME MAINTAINER_EMAIL")
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = {
    "__GITHUB_OWNER__": sys.argv[2],
    "__GITHUB_REPO__": sys.argv[3],
    "__AUR_MAINTAINER_NAME__": sys.argv[4],
    "__AUR_MAINTAINER_EMAIL__": sys.argv[5],
}
for marker, value in replacements.items():
    text = text.replace(marker, value)
if any(marker in text for marker in replacements):
    raise SystemExit("one or more PKGBUILD template markers remain after configuration")
path.write_text(text, encoding="utf-8")
