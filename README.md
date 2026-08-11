# Jackify

A bash script that automates video conversion using HandBrakeCLI. It copies videos and subtitles from a downloads folder to a staging folder, converts them using a named HandBrake preset, extracts and burns subtitles where available, then cleans up file and folder names in the output.

## Requirements

- [HandBrakeCLI](https://handbrake.fr/downloads2.php) — separate package from the HandBrake GUI; must be installed independently
- `ffmpeg` and `ffprobe` — used to extract embedded subtitles from source files
- `perl` — used for filename cleanup and the progress bar (standard on most Linux systems)
- **Whisper** (`openai-whisper`) — identifies the English audio track when a multi-track source has none tagged English. Jackify **builds the venv itself on first run** if `WHISPER_VENV` doesn't already have it (a one-time PyTorch download); point `WHISPER_VENV` at an existing whisper venv to reuse it. Needs `python3`.

## Configuration

Edit the variables at the top of `jackify.sh` to match your environment:

| Variable | Description |
|---|---|
| `DOWNLOADS_DIR` | Your downloads folder |
| `STAGING_DIR` | Staging folder for videos awaiting conversion |
| `OUTPUT_DIR` | Root for converted videos; each run writes to a `<preset name>` subfolder inside it |
| `HANDBRAKE_CLI` | Path to the HandBrakeCLI binary |
| `PRESET_DIR` | Folder containing HandBrake preset JSON files |
| `OUTPUT_FORMAT` | Output container format (default: `mp4`) |
| `PROCESS_DELAY` | Seconds to pause between conversions (default: `2`) |
| `EXCLUDED_BASENAMES` | Filenames (without extension) to skip, e.g. `sample`, `featurette` |
| `SRT_SIZE_THRESHOLD` | % size difference considered substantial when comparing an extracted subtitle against an existing `.srt` (default: `20`) |
| `SRT_MIN_CUES` | Minimum number of cues an extracted subtitle must contain to be used — prevents scene brands and watermark tracks being written (default: `20`) |

## Usage

```bash
jackify.sh
```

Run with no arguments. On startup, Jackify scans `PRESET_DIR` for HandBrake preset JSON files and presents a numbered menu to choose from before proceeding.

## How It Works

1. **Copy** — Videos and subtitle files are copied from `DOWNLOADS_DIR` to `STAGING_DIR`, preserving folder structure. If a file with the same name already exists in staging it is written as `name(1).ext`, `name(2).ext`, etc. Files whose base name matches `EXCLUDED_BASENAMES` (e.g. `sample.mkv`) are ignored at every stage. If `DOWNLOADS_DIR` is empty, this step is skipped and existing files in `STAGING_DIR` are used. If both folders contain files, you are prompted whether to copy before proceeding.

2. **Convert** — All videos in `STAGING_DIR` are converted using HandBrakeCLI with the selected preset. Output goes to a per-profile folder, `OUTPUT_DIR/<preset name>/` (e.g. `2) Done/Jack 1080/`), so each profile keeps its own tree. A progress bar is shown for each job; already-converted files are skipped.

   - **Output placement** — if a video is the only media file in its directory, the output is placed directly in `OUTPUT_DIR` (or in a `Show Name - Season N` subfolder for TV episodes). If sibling files are present, the relative path from `STAGING_DIR` is preserved.
   - **Audio** — a multi-track source is restricted to its English audio. If no track is *tagged* English, Whisper listens to the untagged tracks and picks the one that actually is (spread samples first, speech-targeted samples if needed); a genuinely foreign-only source keeps the preset default. When such a source **also has no English subtitle** (no matching sidecar and no embedded English/undetermined text track), its output is named `<title> - <lang> audio only` — the language coming from the audio tag, or from Whisper when the track is untagged.
   - **Subtitle extraction** — after conversion, Jackify inspects the original source file for an English, non-hearing-impaired, text-based subtitle track. If one is found with at least `SRT_MIN_CUES` cues, it is extracted as a `.srt` alongside the source. If a `.srt` already exists, the extracted version takes precedence — unless the size difference exceeds `SRT_SIZE_THRESHOLD`%, in which case the larger file is used.
   - **Subtitle copy** — any subtitle files matching the video's filename stem are copied to the output directory.
   - **Burned subtitles** — if a matching subtitle is present (extracted or a sidecar), a second HandBrake pass produces a `<name> burned subs` copy with the subtitle burned into the picture. SRT, ASS, SSA, VTT and PGS (`.sup`) can all be burned — text via libass (styling preserved), PGS as bitmaps; ASS/SSA/VTT and PGS are muxed into a temporary MKV first. VobSub (`.idx`/`.sub`) is kept as a sidecar but not burned.

3. **Cleanup** — Output filenames and folder names are cleaned: DVD title-number prefixes (`## - name`) are stripped, known source/release tags are removed, dots/underscores/hyphens used as word separators are replaced with spaces, and title case is applied.

4. **Staging cleanup** — After the final report, you are prompted whether to delete the contents of `STAGING_DIR`.

Warnings and errors are logged to `error_log.txt` in the `OUTPUT_DIR` root — one shared log across profiles, only created if something goes wrong.

## Presets

Preset JSON files live in the `Handbrake Presets/` folder. Each file contains a single HandBrake preset exported from the HandBrake GUI — the preset name is read from the `PresetName` field in the JSON.

To add a preset: export it from the HandBrake GUI and drop the JSON into `Handbrake Presets/`. It will appear in the selection menu automatically on the next run.

## tidy-names.sh

Jackify's name cleanup, as a standalone tool. It runs the same three passes — DVD title-number removal, tag stripping, title case — against any directory you point it at, plus optional sample/preview removal. Use it to tidy a library that already exists, without converting anything.

```bash
./tidy-names.sh <dir>                       # dry run: writes a plan, changes nothing
./tidy-names.sh --apply <dir>               # rename for real
./tidy-names.sh --delete-junk <dir>         # also remove sample/preview files and folders
./tidy-names.sh --files-only <dir>          # leave directory names alone
```

**It does nothing without `--apply`.** The default is a dry run that writes every proposed change to `tidy-names-plan.txt` and touches nothing. That default is deliberate, not caution for its own sake: these rules assume a scene-release filename, where every token that isn't the title is junk. A curated library breaks that assumption — `1080p` may be describing an asset rather than tagging a rip, hashes are identifiers, and ALLCAPS is often intentional. A first dry run over a 100,000-file archive proposed 65,430 renames, nearly all of them wrong.

So: run it, read the plan, then decide. There is no undo.

It refuses to run on `/`, `/home`, `/mnt` and similar; renames depth-first, so a folder is only renamed once its contents are done; never overwrites (a name collision is reported and skipped); and skips its own plan file.
