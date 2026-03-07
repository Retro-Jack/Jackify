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

## Usage

```bash
jackify.sh [OPTIONS]
```

A preset **must** be specified on every run to prevent mistakes.

### Options

| Flag | Description |
|---|---|
| `-jack` | Use the Jack 1080 preset |
| `-loren` | Use the Loren 720 preset |
| `-h, --help` | Show help message |

### Examples

```bash
# Convert using the Jack 1080 preset
jackify.sh -jack

# Convert using the Loren 720 preset
jackify.sh -loren
```

## How It Works

1. **Copy** — Videos and subtitle files are copied from `DOWNLOADS_DIR` to `STAGING_DIR`, preserving folder structure. Already-copied files are skipped. If `DOWNLOADS_DIR` is empty, this step is skipped and existing files in `STAGING_DIR` are used instead.
2. **Convert** — All videos in `STAGING_DIR` are converted using HandBrakeCLI with the selected preset. A progress bar is shown for each conversion. Already-converted files are skipped. If a video is the only media file in its directory, the output is placed directly in `OUTPUT_DIR` rather than recreating the subdirectory. Matching subtitle files are copied alongside the converted video.
3. **Cleanup** — Output filenames and folder names are cleaned: DVD title number prefixes (`## - name`) are stripped, known source/release tags are removed, dots/underscores/hyphens used as word separators are replaced with spaces, and title case is applied.
4. **Staging cleanup** — After the final report, you are prompted whether to delete the contents of `STAGING_DIR`.

If any warnings or errors occur during a run, they are logged to `error_log.txt` in `OUTPUT_DIR`.

## Presets

Preset JSON files live in the `Handbrake Presets/` folder. Each file contains a single HandBrake preset exported from the HandBrake GUI. The `-jack` and `-loren` flags select between them.

To add a new preset: export it from HandBrake GUI, drop the JSON into `Handbrake Presets/`, and add a corresponding flag to the argument parsing section of `jackify.sh`.
