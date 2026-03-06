# Jackify

A bash script that automates video conversion using HandBrakeCLI. It copies videos from a downloads folder to an input folder (preserving directory structure), converts them using a named HandBrake preset, then cleans up file and folder names.

## Requirements

- [HandBrakeCLI](https://handbrake.fr/downloads2.php) — note this is a separate package from the HandBrake GUI and must be installed independently

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
| `-l, --log` | Enable logging to `jackify_log.txt` |
| `-h, --help` | Show help message |

### Examples

```bash
# Convert using the Jack 1080 preset
jackify.sh -jack

# Convert using the Loren 720 preset, with logging
jackify.sh -loren --log
```

## How It Works

1. **Copy** — Videos are copied from your downloads folder (`DOWNLOADS_DIR`) to `STAGING_DIR`, preserving folder structure. Already-copied files are skipped. If `DOWNLOADS_DIR` is empty, this step is skipped and existing files in `STAGING_DIR` are used instead.
2. **Convert** — All videos in `STAGING_DIR` are converted using HandBrakeCLI with the selected preset. Already-converted files are skipped.
3. **Cleanup** — Output filenames and folder names are cleaned: DVD title number prefixes (`## - name`) are stripped, known source/release tags are removed, dots/underscores/hyphens used as word separators are replaced with spaces, and title case is applied.
4. **Staging cleanup** — After the final report, you are prompted whether to delete the contents of `STAGING_DIR`.

## Presets

Preset JSON files live in the `Handbrake Presets/` folder. Each file contains a single HandBrake preset exported from the HandBrake GUI. The `-jack` and `-loren` flags select between them.

To add a new preset: export it from HandBrake GUI, drop the JSON into `Handbrake Presets/`, and add a corresponding flag to the argument parsing section of `jackify.sh`.
