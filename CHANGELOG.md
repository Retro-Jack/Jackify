# Changelog

## 2026-03-08

### Added
- **Subtitle support** — subtitle files (srt, ass, ssa, vtt, sub, idx, sup) are now copied from `DOWNLOADS_DIR` to `STAGING_DIR` alongside videos, and from `STAGING_DIR` to the appropriate output path after each successful conversion, matched by filename stem
- **Progress bar** — HandBrake output is replaced with an inline progress bar (`[████░░░░] 45%`), initialised at 0% immediately so it is visible before the first percentage is reported
- **Output path flattening** — if a video is the only media file in its source directory, the converted output is placed directly in `OUTPUT_DIR` root rather than recreating the subdirectory structure
- **Automatic error logging** — warnings and errors are written to `error_log.txt` in `OUTPUT_DIR` automatically; the file is only created if something goes wrong
- **Dynamic header width** — `print_header` now sizes the border to fit the title and centres the text, preventing overflow on longer headers
- **Countdown after Step 1** — a 10-second countdown (skippable with any key) is shown after the copy step in both the copy and skip-copy branches
- **`perl` noted as a requirement** in README

### Changed
- **Step 2 header** now shows the video count and selected preset: `STEP 2: Converting 7 videos - Preset: Jack 1080`
- **Per-conversion display** simplified: verbose HandBrake output removed; each job now shows only the filename above the progress bar
- **Logging overhauled** — opt-in full logging (`-l`/`--log` flag, `jackify_log.txt`) removed and replaced with automatic error-only logging to `error_log.txt`
- **After Steps 2 and 3** — countdown replaced with "Press any key to continue" prompt
- **Title case** — minor words (e.g. "the", "and") that immediately follow a digit sequence are now capitalised, fixing episode titles such as `S02E01 The Dundies`
- **Cleanup functions** (`strip_source_tags`, `rename_in_path`, `apply_title_case`) now restrict file operations to known video and subtitle extensions, and explicitly exclude `error_log.txt`
- **`build_ext_args`** generalised to accept any named extensions array via an optional second argument (default: `VIDEO_EXTENSIONS`)
- **Single video** — Step 2 header now reads "video" instead of "videos" when only one file is being converted

### Changed
- Error log timestamps now use the locale's short date and time format (`%x %X`)

### Fixed
- Stale `${LOG_ENABLED:+ ...}` reference in `warn` call on HandBrake failure, which would have caused an unbound variable error under `set -u`
- Outdated `build_ext_args` comment still referencing `VIDEO_EXTENSIONS` specifically
