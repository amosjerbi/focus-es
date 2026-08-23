# HLTB Average Main Story Sync

[`HLTB avg main story.sh`](./HLTB%20avg%20main%20story.sh) adds average main-story
completion times to ROCKNIX game metadata for display by the Focus theme.

The script does not use ScreenScraper for completion times. On its first run it
downloads the processed HowLongToBeat dataset published by
[`KasumiL5x/hltb-scraper`](https://github.com/KasumiL5x/hltb-scraper), caches it,
matches it against local ROM names, and writes the formatted time to each game's
`<arcadesystemname>` field in `gamelist.xml`.

## Supported systems

- Nintendo 3DS (`3ds`)
- Game Boy (`gb`)
- Game Boy Color (`gbc`)
- Game Boy Advance (`gba`)
- Sega Mega Drive / Genesis (`megadrive`)
- Nintendo 64 (`n64`)
- Nintendo DS (`nds`)

## Installation

1. Copy `HLTB avg main story.sh` into `/storage/roms/ports/` on ROCKNIX.
2. Make it executable if the permission was not preserved:

   ```sh
   chmod +x "/storage/roms/ports/HLTB avg main story.sh"
   ```

3. Refresh the Ports game list or restart EmulationStation.

## Usage

Launch **HLTB avg main story** from the Ports system. The script starts a
detached synchronization job, temporarily stops EmulationStation while the
gamelists are being changed, and starts the frontend again when finished.

An internet connection and Python 3 are required for the first run. Later runs
reuse the cached dataset.

## What it changes

For every supported ROM directory under `/storage/roms`, the script:

1. Opens or creates `gamelist.xml`.
2. Adds minimal entries for ROM files missing from the gamelist.
3. Normalizes game names and tries an exact title/platform match.
4. Uses a conservative fuzzy match only when an exact match is unavailable.
5. Writes values such as `12 h` or `8 h 30 m` to `<arcadesystemname>`.

Before changing an existing gamelist for the first time, it creates:

```text
gamelist.xml.bak-before-main-story
```

The Focus theme reads `<arcadesystemname>` and displays it as **Avg. Main**.

## Generated files

- Dataset cache: `/storage/.cache/art-book-next-hltb/all-games-processed.csv`
- Full run log: `/storage/roms/ports/art-book-next-hltb/sync.log`
- Last result: `/storage/roms/ports/art-book-next-hltb/last-status.txt`

Delete the cached CSV before running the script if you want it to download the
dataset again.

## Limitations

- Completion times come from a community-maintained processed HLTB dataset, not
  a live HowLongToBeat API request.
- Some regional, translated, hacked, or unusually named ROMs may remain
  unmatched.
- The script repurposes `<arcadesystemname>` for the completion time and will
  replace an existing value in that field for matched games.
- The backup is created once. Keep additional backups before making repeated or
  manual metadata changes.
- Systems not listed above are currently skipped.

HowLongToBeat names and data belong to their respective owners. This helper is
an independent metadata synchronization tool and is not affiliated with
HowLongToBeat.
