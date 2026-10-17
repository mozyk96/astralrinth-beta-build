#!/usr/bin/env python3
"""Create a stable KDE launcher and icon alias from the upstream Debian payload."""
from __future__ import annotations
import re
import shlex
import shutil
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: normalize-desktop.py PAYLOAD_ROOT")
root = Path(sys.argv[1]).resolve()
apps_dir = root / "usr/share/applications"
if not apps_dir.is_dir():
    raise SystemExit("ERROR: .deb payload has no /usr/share/applications directory")
files = sorted(apps_dir.glob("*.desktop"))
if not files:
    raise SystemExit("ERROR: upstream build did not produce a .desktop entry")

def score(path: Path) -> tuple[int, str]:
    data = path.read_text(encoding="utf-8", errors="replace").lower()
    points = 10 * ("astralrinth" in data) + 4 * ("type=application" in data) + 2 * ("exec=" in data)
    return (-points, path.name)

desktop = sorted(files, key=score)[0]
lines = desktop.read_text(encoding="utf-8", errors="replace").splitlines()
if "[Desktop Entry]" not in lines:
    raise SystemExit(f"ERROR: invalid desktop file: {desktop}")

fields = {
    "Name": "AstralRinth (Beta)",
    "GenericName": "Minecraft Launcher",
    "Comment": "Unofficial community-built AstralRinth beta",
    "Keywords": "AstralRinth;Minecraft;Modrinth;Launcher;Beta;",
    "Categories": "Game;",
    "Terminal": "false",
    "Type": "Application",
}
result, seen = [], set()
for line in lines:
    if re.match(r"^Name\[[^]]+\]=", line):
        continue
    m = re.match(r"^([A-Za-z][A-Za-z0-9-]*)=", line)
    if m and m.group(1) in fields:
        key=m.group(1)
        if key not in seen:
            result.append(f"{key}={fields[key]}")
            seen.add(key)
        continue
    result.append(line)
header = result.index("[Desktop Entry]")
missing = [f"{k}={v}" for k,v in fields.items() if k not in seen]
result[header+1:header+1] = missing

icon_line = next((x.partition("=")[2].strip() for x in result if x.startswith("Icon=")), "")
if not icon_line:
    raise SystemExit("ERROR: upstream desktop entry has no Icon= value")
allowed={".png", ".svg", ".xpm", ".jpg", ".jpeg"}
icon_file = None
if icon_line.startswith("/"):
    candidate = root / icon_line.lstrip("/")
    if candidate.is_file() and candidate.suffix.lower() in allowed:
        icon_file = candidate
else:
    stem = Path(icon_line).stem if Path(icon_line).suffix.lower() in allowed else icon_line
    roots = [root/"usr/share/icons", root/"usr/share/pixmaps"]
    candidates = [p for r in roots if r.exists() for p in r.rglob("*")
                  if p.is_file() and p.suffix.lower() in allowed and p.stem.casefold()==stem.casefold()]
    if candidates:
        candidates.sort(key=lambda p: (0 if "scalable" in p.parts else 1, len(p.parts), p.as_posix()))
        icon_file = candidates[0]
if icon_file is None:
    raise SystemExit(f"ERROR: could not find an actual image for upstream Icon={icon_line}")

# A stable theme-independent icon name avoids casing/spaces differences between DEB and KDE.
pixmaps = root / "usr/share/pixmaps"
pixmaps.mkdir(parents=True, exist_ok=True)
stable_icon = pixmaps / f"astralrinth-beta{icon_file.suffix.lower()}"
if icon_file.resolve() != stable_icon.resolve():
    shutil.copy2(icon_file, stable_icon)
result = [f"Icon=astralrinth-beta" if x.startswith("Icon=") else x for x in result]

exec_line = next((x.partition("=")[2].strip() for x in result if x.startswith("Exec=")), "")
if not exec_line:
    raise SystemExit("ERROR: desktop entry has no Exec= command")
try:
    executable = shlex.split(exec_line)[0]
except (ValueError, IndexError):
    raise SystemExit(f"ERROR: cannot parse Exec= value: {exec_line}")
if executable.startswith("/"):
    target = root / executable.lstrip("/")
    if not target.exists():
        raise SystemExit(f"ERROR: Exec target is missing from package payload: {executable}")
else:
    search_roots=[root/"usr/bin", root/"bin", root/"opt", root/"usr/lib"]
    if not any((base/executable).exists() for base in search_roots if base.exists()):
        # Handle Tauri's unusual product names by locating the exact executable path.
        matches=[p for base in [root/"usr",root/"opt"] if base.exists() for p in base.rglob(executable) if p.is_file()]
        if not matches:
            raise SystemExit(f"ERROR: Exec executable '{executable}' not found in package payload")

out=apps_dir/"astralrinth-beta.desktop"
if desktop != out:
    desktop.unlink()
out.write_text("\n".join(result).rstrip()+"\n", encoding="utf-8")
print(f"KDE launcher: {out.relative_to(root)}")
print(f"KDE icon: usr/share/pixmaps/{stable_icon.name} (Icon=astralrinth-beta)")
