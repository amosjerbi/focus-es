#!/bin/bash

. /etc/profile 2>/dev/null || true

PORT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
HELPER_DIR="${PORT_DIR}/art-book-next-hltb"
CACHE_DIR="/storage/.cache/art-book-next-hltb"
DATASET="${CACHE_DIR}/all-games-processed.csv"
LOG_FILE="${HELPER_DIR}/sync.log"
STATUS_FILE="${HELPER_DIR}/last-status.txt"

find_frontend_service() {
    if systemctl cat essway.service >/dev/null 2>&1; then
        echo "essway.service"
    elif systemctl cat emustation.service >/dev/null 2>&1; then
        echo "emustation.service"
    fi
}

run_sync() {
    mkdir -p "${CACHE_DIR}" "${HELPER_DIR}"
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'ERROR: python3 is not installed.\n' > "${STATUS_FILE}"
        return 1
    fi

    (
        echo "=== Art Book Next HLTB sync: $(date) ==="
        python3 - \
            --rom-root /storage/roms \
            --dataset "${DATASET}" \
            --backup-suffix .bak-before-main-story <<'PYTHON'
import argparse
import csv
import html
import re
import shutil
import sys
import urllib.request
import xml.etree.ElementTree as ET
from collections import defaultdict
from difflib import SequenceMatcher
from pathlib import Path

SYSTEM_ALIASES = {
    "3ds": ("nintendo 3ds", "nintendo 2ds"),
    "gb": ("game boy",),
    "gbc": ("game boy color",),
    "gba": ("game boy advance",),
    "megadrive": ("sega mega drive genesis", "mega drive", "genesis"),
    "n64": ("nintendo 64",),
    "nds": ("nintendo ds",),
}

ROM_EXTENSIONS = {
    "3ds": {".3ds", ".cci", ".cia"},
    "gb": {".gb", ".zip", ".7z"},
    "gbc": {".gbc", ".zip", ".7z"},
    "gba": {".gba", ".zip", ".7z"},
    "megadrive": {".md", ".gen", ".bin", ".zip", ".7z"},
    "n64": {".z64", ".n64", ".v64", ".zip", ".7z"},
    "nds": {".nds", ".zip", ".7z"},
}

HLTB_URLS = (
    "https://raw.githubusercontent.com/KasumiL5x/hltb-scraper/master/all-games-processed.csv",
    "https://raw.githubusercontent.com/KasumiL5x/hltb-scraper/main/all-games-processed.csv",
)

GAME_RE = re.compile(r"<game(?:\s[^>]*)?>.*?</game>", re.DOTALL)


def normalize_title(value):
    value = Path(value or "").name
    value = re.sub(r"\.(zip|7z|rar|z64|n64|v64|nds|3ds|cia|gba|bin|md|gen)$", "", value, flags=re.I)
    value = re.sub(r"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}", " ", value)
    value = value.replace("&", " and ")
    value = re.sub(r"\b(disc|disk|cd|dvd|side|part|vol|volume)\s*\d+\b", " ", value, flags=re.I)
    value = re.sub(r"[^a-zA-Z0-9]+", " ", value).lower()
    value = re.sub(r"\b([a-z0-9]+)\s+s\b", r"\1s", value)
    value = re.sub(r"\bthe\b", " ", value)
    return " ".join(value.split())


def title_keys(value):
    raw = Path(value or "").name
    raw = re.sub(r"\.(zip|7z|rar|z64|n64|v64|nds|3ds|cia|gba|bin|md|gen)$", "", raw, flags=re.I)
    variants = [raw]
    article = re.match(r"^(.+?),\s*The\b(.*)$", raw, flags=re.I)
    if article:
        variants.append(f"The {article.group(1)} {article.group(2)}")
    keys = []
    for variant in variants:
        key = normalize_title(variant)
        key = re.sub(r"^\d+\s+", "", key)
        key = re.sub(r"\b(?:decrypted|encrypted|the videogame)\b", " ", key)
        key = re.sub(r"\bv?\d+(?:\s+\d+)+$", "", key)
        key = " ".join(key.split())
        if key and key not in keys:
            keys.append(key)
    return keys


def parse_hours(value):
    text = (value or "").strip().lower()
    if not text:
        return None
    try:
        number = float(text)
        return number / 3600.0 if number > 1000 else number
    except ValueError:
        pass
    hours = re.search(r"(\d+(?:\.\d+)?)\s*(?:h|hour)", text)
    minutes = re.search(r"(\d+(?:\.\d+)?)\s*(?:m|min)", text)
    if not hours and not minutes:
        return None
    return (float(hours.group(1)) if hours else 0) + (float(minutes.group(1)) / 60 if minutes else 0)


def format_hours(hours):
    minutes = max(1, int(round(float(hours) * 60)))
    whole_hours, remaining = divmod(minutes, 60)
    if whole_hours and remaining:
        return f"{whole_hours} h {remaining} m"
    if whole_hours:
        return f"{whole_hours} h"
    return f"{remaining} m"


def load_hltb(dataset):
    by_title = defaultdict(list)
    by_platform = defaultdict(list)
    with dataset.open(newline="", encoding="utf-8-sig", errors="replace") as stream:
        for row in csv.DictReader(stream):
            hours = parse_hours(row.get("main_story"))
            key = normalize_title(row.get("title"))
            if not key or hours is None or hours <= 0:
                continue
            entry = {
                "key": key,
                "title": row.get("title", ""),
                "hours": hours,
                "platforms": normalize_title(row.get("platforms", "")),
            }
            by_title[key].append(entry)
            for system, aliases in SYSTEM_ALIASES.items():
                if any(alias in entry["platforms"] for alias in aliases):
                    by_platform[system].append(entry)
    return by_title, by_platform


def ensure_dataset(dataset):
    if dataset.is_file() and dataset.stat().st_size > 100_000:
        return
    dataset.parent.mkdir(parents=True, exist_ok=True)
    last_error = None
    for url in HLTB_URLS:
        temporary = dataset.with_suffix(dataset.suffix + ".download")
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "ROCKNIX Main Story Sync/1.0"})
            with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                shutil.copyfileobj(response, output)
            temporary.replace(dataset)
            return
        except Exception as error:
            last_error = error
            temporary.unlink(missing_ok=True)
    raise RuntimeError(f"Unable to download HLTB dataset: {last_error}")


def platform_match(entry, system):
    return any(alias in entry["platforms"] for alias in SYSTEM_ALIASES[system])


def hltb_lookup(title_candidates, system, by_title, by_platform):
    keys = []
    for value in title_candidates:
        for key in title_keys(value):
            if key not in keys:
                keys.append(key)
    for key in keys:
        entries = by_title.get(key, ())
        if entries:
            matched = [entry for entry in entries if platform_match(entry, system)]
            return (matched or list(entries))[0], "exact"

    best = None
    runner_up = 0.0
    for key in keys:
        for entry in by_platform.get(system, ()):
            score = SequenceMatcher(None, key, entry["key"]).ratio()
            if best is None or score > best[0]:
                runner_up = best[0] if best else 0.0
                best = (score, entry)
            elif score > runner_up:
                runner_up = score
    if best and best[0] >= 0.92 and best[0] - runner_up >= 0.03:
        return best[1], f"fuzzy:{best[0]:.2f}"
    return None, None


def set_arcade_system_name(block, formatted):
    escaped = html.escape(formatted)
    existing = re.search(r"<arcadesystemname>.*?</arcadesystemname>", block, flags=re.DOTALL)
    if existing:
        return block[: existing.start()] + f"<arcadesystemname>{escaped}</arcadesystemname>" + block[existing.end() :]
    closing = re.search(r"(?P<indent>[ \t]*)</game>\s*$", block)
    indent = closing.group("indent") if closing else "\t"
    insertion = f"{indent}<arcadesystemname>{escaped}</arcadesystemname>\n"
    return block[: closing.start()] + insertion + block[closing.start() :] if closing else block


def add_missing_rom_entries(original, rom_dir, system):
    try:
        root = ET.fromstring(original)
        known_paths = {
            (game.findtext("path") or "").replace("\\", "/").removeprefix("./")
            for game in root.findall("game")
        }
    except ET.ParseError:
        known_paths = set()

    additions = []
    for rom in sorted(rom_dir.iterdir(), key=lambda item: item.name.lower()):
        if not rom.is_file() or rom.name.startswith(".") or rom.name.startswith("._"):
            continue
        if rom.suffix.lower() not in ROM_EXTENSIONS[system] or rom.name in known_paths:
            continue
        title = rom.stem
        additions.append(
            "\t<game>\n"
            f"\t\t<path>./{html.escape(rom.name)}</path>\n"
            f"\t\t<name>{html.escape(title)}</name>\n"
            "\t</game>\n"
        )

    if additions and "</gameList>" in original:
        original = original.replace("</gameList>", "".join(additions) + "</gameList>", 1)
    return original, len(additions)


def update_gamelist(path, system, by_title, by_platform, dry_run, backup_suffix):
    existed = path.is_file()
    original_on_disk = (
        path.read_text(encoding="utf-8", errors="replace")
        if existed
        else '<?xml version="1.0"?>\n<gameList>\n</gameList>\n'
    )
    original, added = add_missing_rom_entries(original_on_disk, path.parent, system)
    matched = []
    unmatched = []

    def replace(match):
        block = match.group(0)
        try:
            game = ET.fromstring(block)
        except ET.ParseError:
            return block
        name = game.findtext("name") or ""
        rom_path = game.findtext("path") or ""
        entry, match_type = hltb_lookup((name, rom_path), system, by_title, by_platform)
        if entry is None:
            unmatched.append(name or rom_path)
            return block
        formatted = format_hours(entry["hours"])
        matched.append((name or rom_path, formatted, f"HLTB/{match_type}: {entry['title']}"))
        return set_arcade_system_name(block, formatted)

    updated = GAME_RE.sub(replace, original)
    changed = updated != original_on_disk
    if not dry_run and changed:
        backup = path.with_name(path.name + backup_suffix)
        if existed and not backup.exists():
            shutil.copy2(path, backup)
        path.write_text(updated, encoding="utf-8")
    return matched, unmatched, changed, added


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rom-root", type=Path, default=Path("/storage/roms"))
    parser.add_argument("--dataset", type=Path, default=Path("/tmp/hltb-main-story.csv"))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--backup-suffix", default=".bak-before-main-story")
    args = parser.parse_args()

    ensure_dataset(args.dataset)
    by_title, by_platform = load_hltb(args.dataset)

    total_matched = total_unmatched = changed = 0
    for system in SYSTEM_ALIASES:
        rom_dir = args.rom_root / system
        gamelist = rom_dir / "gamelist.xml"
        if not rom_dir.is_dir():
            continue
        matched, unmatched, did_change, added = update_gamelist(
            gamelist, system, by_title, by_platform, args.dry_run, args.backup_suffix
        )
        changed += int(did_change)
        total_matched += len(matched)
        total_unmatched += len(unmatched)
        print(f"[{system}] matched={len(matched)} unmatched={len(unmatched)} discovered={added}")
        for title, duration, source in matched:
            print(f"  OK  {title} -> {duration} ({source})")
        for title in unmatched:
            print(f"  --  {title}")
    print(f"SUMMARY matched={total_matched} unmatched={total_unmatched} changed_files={changed} dry_run={args.dry_run}")
    return 0 if total_matched else 2


if __name__ == "__main__":
    sys.exit(main())
PYTHON
        result=$?
        echo "Exit status: ${result}"
        exit "${result}"
    ) > "${LOG_FILE}" 2>&1
    result=$?

    if [ "${result}" -eq 0 ]; then
        summary="$(grep '^SUMMARY ' "${LOG_FILE}" | tail -n 1)"
        printf 'SUCCESS\n%s\nLog: %s\n' "${summary}" "${LOG_FILE}" > "${STATUS_FILE}"
    else
        printf 'FAILED (exit %s)\nLog: %s\n' "${result}" "${LOG_FILE}" > "${STATUS_FILE}"
    fi
    sync
    return "${result}"
}

if [ "${1:-}" = "--detached" ]; then
    sleep 1
    frontend_service="$(find_frontend_service)"
    was_active=false
    if [ -n "${frontend_service}" ] && systemctl is-active --quiet "${frontend_service}"; then
        was_active=true
        systemctl stop "${frontend_service}"
    fi

    run_sync
    result=$?

    if [ "${was_active}" = true ]; then
        systemctl start "${frontend_service}"
    fi
    exit "${result}"
fi

echo "Art Book Next: HLTB Main Story sync starting..."
echo "The frontend will restart automatically when the gamelists are ready."

if command -v systemd-run >/dev/null 2>&1; then
    unit_name="art-book-next-hltb-$(date +%s)"
    if systemd-run --quiet --collect --unit="${unit_name}" /bin/bash "$0" --detached; then
        sleep 2
        exit 0
    fi
fi

echo "Could not start a detached sync; running directly."
run_sync
result=$?
cat "${STATUS_FILE}" 2>/dev/null || true
sleep 6
exit "${result}"
