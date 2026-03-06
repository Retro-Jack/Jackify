# Jackify

A bash script that automates video conversion using HandBrakeCLI. It copies videos from a source folder to an input folder (preserving directory structure), converts them using a named HandBrake preset, then cleans up file and folder names.

## Requirements

- bash >= 4.4
- perl
- GNU find
- [HandBrakeCLI](https://handbrake.fr/downloads2.php)

## Configuration

Edit the variables at the top of `jackify.sh` to match your environment:

| Variable | Description |
|---|---|
| `SOURCE_DIR` | Where your source videos live |
| `INPUT_DIR` | Staging folder for videos to be converted |
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
| `-d, --dvd` | DVD mode: rename HandBrake title numbers on copy (`## - name.ext` → `DVD Title ##.ext`) |
| `-l, --log` | Enable logging to `jackify_log.txt` |
| `-h, --help` | Show help message |

### Examples

```bash
# Convert using the Jack 1080 preset
jackify.sh -jack

# Convert DVD rips using the Loren 720 preset, with logging
jackify.sh -loren --dvd --log
```

## How It Works

1. **Copy** — Videos are copied from `SOURCE_DIR` to `INPUT_DIR`, preserving folder structure. Already-copied files are skipped. In DVD mode, files prefixed with HandBrake title numbers (`01 - name.ext`) are renamed to `DVD Title 01.ext` during the copy.
2. **Convert** — All videos in `INPUT_DIR` are converted using HandBrakeCLI with the selected preset. Already-converted files are skipped.
3. **Cleanup** — File and folder names in `OUTPUT_DIR` are cleaned: dots, underscores, and hyphens used as word separators are replaced with spaces, and multiple spaces are collapsed.

## Presets

Preset JSON files live in the `Handbrake Presets/` folder. Each file contains a single HandBrake preset exported from the HandBrake GUI. The `-jack` and `-loren` flags select between them.

To add a new preset: export it from HandBrake GUI, drop the JSON into `Handbrake Presets/`, and add a corresponding flag to the argument parsing section of `jackify.sh`.
