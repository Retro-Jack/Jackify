# Jackify

[![Latest Release](https://img.shields.io/github/v/release/Retro-Jack/Jackify)](https://github.com/Retro-Jack/Jackify/releases/latest)

A bash script that automates video conversion using HandBrakeCLI. It copies videos and subtitles from a downloads folder to a staging folder (preserving directory structure), converts them using a named HandBrake preset, then cleans up file and folder names in the output.

## Requirements

- [HandBrakeCLI](https://handbrake.fr/downloads2.php) — note this is a separate package from the HandBrake GUI and must be installed independently
- `perl` — used for filename cleanup and the progress bar (standard on most Linux systems)

## Configuration

Edit the variables at the top of `jackify.sh` to match your environment:

| Variable | Description |
|---|---|
| `DOWNLOADS_DIR` | Your downloads folder |
| `STAGING_DIR` | Staging folder for videos to be converted |
| `OUTPUT_DIR` | Where converted videos are written |
| `HANDBRAKE_CLI` | Path to HandBrakeCLI binary |
| `PRESET_DIR` | Folder containing HandBrake preset JSON files |
| `OUTPUT_FORMAT` | Output container format (default: `mp4`) |
| `PROCESS_DELAY` | Seconds to pause between conversions (default: `2`) |
| `EXCLUDED_BASENAMES` | Filenames (without extension) to skip entirely, e.g. `sample`, `preview` (default: `sample preview trailer featurette`) |

## Usage

```bash
jackify.sh
```

Run with no arguments. On startup, Jackify scans `PRESET_DIR` for HandBrake preset JSON files and presents a numbered menu to choose from before proceeding.

## How It Works

1. **Copy** — Videos and subtitle files are copied from `DOWNLOADS_DIR` to `STAGING_DIR`, preserving folder structure. Already-copied files are skipped. Files whose base name matches `EXCLUDED_BASENAMES` (e.g. `sample.mkv`, `trailer.mp4`) are ignored at every stage. If `DOWNLOADS_DIR` is empty, this step is skipped and existing files in `STAGING_DIR` are used instead.
2. **Convert** — All videos in `STAGING_DIR` are converted using HandBrakeCLI with the selected preset. A progress bar is shown for each conversion. Already-converted files are skipped. If a video is the only media file in its directory and has no subtitle file alongside it, the output is placed directly in `OUTPUT_DIR`; if a subtitle is present, the source folder is recreated in `OUTPUT_DIR` and both files are placed inside it. Matching subtitle files are copied alongside the converted video.
3. **Cleanup** — Output filenames and folder names are cleaned: DVD title number prefixes (`## - name`) are stripped, known source/release tags are removed, dots/underscores/hyphens used as word separators are replaced with spaces, and title case is applied.
4. **Staging cleanup** — After the final report, you are prompted whether to delete the contents of `STAGING_DIR`.

If any warnings or errors occur during a run, they are logged to `error_log.txt` in `OUTPUT_DIR`.

## Presets

Preset JSON files live in the `Handbrake Presets/` folder. Each file contains a single HandBrake preset exported from the HandBrake GUI. The preset name is read from the `PresetName` field inside the JSON.

To add a new preset: export it from HandBrake GUI and drop the JSON into `Handbrake Presets/`. It will appear in the menu automatically on the next run.
