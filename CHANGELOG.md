# Changelog

## v1.4.4 — 2026-05-03

### Changed
- **Lone video with embedded subtitles** — when a solo video has an extractable English text-based subtitle track but no sibling `.srt`, the converted output is now placed in `OUTPUT_DIR/<source folder>/` (or `OUTPUT_DIR/<stem>/` if it lives at staging root) so the `.mp4`, extracted `.srt`, and burned-subs `.mp4` stay grouped together instead of being dumped flat into `OUTPUT_DIR`.
- **Refactor** — extracted `_find_eng_subtitle_track` from `extract_subtitle` so the output-dir picker can probe for embedded subs without duplicating the ffprobe query.

---

## v1.4.3 — 2026-05-03

### Fixed
- **Subtitle extraction** — ffprobe emits `stream_disposition` fields before `stream_tags` fields regardless of `-show_entries` order, so the columns produced by the existing query were `idx,codec,hi,lang`, not `idx,codec,lang,hi`. The read assignment had `lang` and `hi` swapped, which meant `lang` was always `"0"` and never matched `"eng"` — silently disabling embedded subtitle extraction since v1.4.0. Read order corrected.

---

## v1.4.2 — 2026-05-03

### Added
- **`DDP5.1`** added to the source-tag stripper (Dolby Digital Plus audio tag).
- **`GALAXYRG265`** added to the release-group stripper.

### Fixed
- Subtitle copy message now reads "Copying subtitles" (was "Copying subtitle").

---

## v1.4.1 — 2026-05-02

### Changed
- **Error logging** — `error_log.txt` is now created lazily on the first error (clean runs leave no file). When triggered, it gets a session header (timestamp, host, user, PID, preset, paths, HandBrake version) and each entry includes the calling function/line plus a details payload — HandBrake stderr tail, perl stderr, `cp`/`mv` errors, exit codes, free-space on copy failures. HandBrake progress noise (`Encoding: task N of M, …` and percent lines) is filtered out of the tail.
- **Terminal output** — `warn`/`die` print only `[WARN] See <log>` / `[ERROR] See <log>` so the run isn't disrupted by error spam.
- **Pause behaviour** — replaced the 10-second countdown between steps with a "Press any key to continue" prompt. The skip-copy branches clear immediately instead.
- **Burned-subs filename** — converted-with-subtitles output is named `<stem> - burned subs.mp4` (lowercase, no brackets).
- **Internal refactor** — extracted `_perl_rename_loop` (used by `rename_in_path`, `strip_source_tags`, `apply_title_case`), `_handbrake_log_tail`, and `do_copy_from_downloads`; simplified `build_ext_args`.

### Fixed
- **Apostrophe casing** — title case no longer capitalises the letter after an apostrophe (e.g. "Don'T" → "Don't"); straight `'` and curly `’` are both treated as part of the word.
- **Year formatting** — bare four-digit years (1900–2099) are wrapped in parentheses (e.g. `Movie 2007` → `Movie (2007)`).
- **Burned-subs casing** — preserve regex now matches with or without the leading dash, so the suffix survives the separator-cleanup pass and stays lowercase.

---

## v1.4.0 — 2026-04-03

### Added
- **Subtitle extraction** — after each successful conversion, Jackify inspects the input file for an English, non-hearing-impaired, text-based subtitle track using `ffprobe`; if found, it is extracted to a matching `.srt` file via `ffmpeg` so the existing burned-subtitles pass can pick it up automatically
- **Extraction safety checks** — extracted tracks with fewer than `SRT_MIN_CUES` cues (default: 20) are silently discarded to prevent scene-brand or watermark tracks overwriting a proper subtitle
- **SRT size comparison** — if a matching `.srt` already exists, the extracted version takes precedence unless the size difference exceeds `SRT_SIZE_THRESHOLD` percent (default: 20%), in which case the larger file is used
- **`SRT_SIZE_THRESHOLD` / `SRT_MIN_CUES`** config variables added at the top of the script
- **`ffmpeg` and `ffprobe` prerequisite checks** added to startup
- **`check_command` helper** for validating commands available in `PATH`

---

## v1.3.3 — 2026-03-31

### Fixed
- **Subtitle encoding** — burned-subs HandBrake pass now passes `--srt-codeset UTF-8` so non-ASCII characters in SRT files render correctly instead of being mangled

---

## v1.3.2 — 2026-03-30

### Fixed
- **Copy collision handling** — when a file being copied to staging already exists at the target path, it is now renamed with a `(1)`, `(2)`, … suffix instead of being silently skipped

---

## v1.3.1 — 2026-03-24

### Fixed
- **TV episode regex** — moved inline pattern to a variable to avoid bash 5.3 interpreting the leading `.` in `[._ ]` as a POSIX collating element, which caused a syntax error

---

## v1.1.0 — 2026-03-12

### Added
- **`do_rename` helper** — shared rename-with-collision-check logic extracted from the three cleanup functions
- **`_parse_find_opts` helper** — shared `--recursive` / `--dirs` argument parsing extracted from the three cleanup functions
- **`_build_find_args` helper** — shared `find` argument builder extracted from the three cleanup functions
- **Subtitle copy error handling** — failed subtitle copies now log a warning instead of silently failing

### Changed
- **`rename_in_path`**, **`strip_source_tags`**, **`apply_title_case`** — refactored to use shared helpers, eliminating duplicated logic across all three functions

---

## v1.0.4 — 2026-03-12

### Added
- **Quit prompt** — "Press any key to quit" prompt added at the end of the script

### Changed
- **Copy step** — when both downloads and staging folders contain files, Jackify now prompts whether to copy new files into staging rather than silently skipping the copy
- **Presets** — sample presets renamed to `My 720p Flicks` and `My 1080p Flicks`
- **Excluded basenames** — `trailer` removed from the default exclusion list

## v1.0.1 — 2026-03-08

### Fixed
- **Source tag stripping** — `AAC5.1` (and similar codec+channel combos) was not being stripped because the word-boundary guards prevented `AAC` and `5.1` from matching when adjacent to each other; `AAC` in the tag pattern now greedily consumes a trailing channel suffix (`AAC(?:\d+\.\d+)?`)
- **Title case** — all-uppercase filenames (e.g. `THE GENISES CHILDREN`) were incorrectly treated as acronyms and left unchanged; the acronym heuristic now only applies to words of 4 characters or fewer that are not minor words

## v1.0.0 — 2026-03-07

### Added
- **Subtitle support** — subtitle files (srt, ass, ssa, vtt, sub, idx, sup) are now copied from `DOWNLOADS_DIR` to `STAGING_DIR` alongside videos, and from `STAGING_DIR` to the appropriate output path after each successful conversion, matched by filename stem
- **Progress bar** — HandBrake output is replaced with an inline progress bar (`[████░░░░] 45%`), initialised at 0% immediately so it is visible before the first percentage is reported
- **Output path flattening** — if a video is the only media file in its source directory, the converted output is placed directly in `OUTPUT_DIR` root rather than recreating the subdirectory structure
- **Automatic error logging** — warnings and errors are written to `error_log.txt` in `OUTPUT_DIR` automatically; the file is only created if something goes wrong
- **Dynamic header width** — `print_header` now sizes the border to fit the title and centres the text, preventing overflow on longer headers
- **Countdown after Step 1** — a 10-second countdown (skippable with any key) is shown after the copy step in both the copy and skip-copy branches
- **`perl` noted as a requirement** in README

### Changed
- **Step 2 header** now shows the video count and selected preset: `STEP 2: Converting 7 videos - Preset: My 1080p Flicks`
- **Per-conversion display** simplified: verbose HandBrake output removed; each job now shows only the filename above the progress bar
- **Logging overhauled** — opt-in full logging (`-l`/`--log` flag, `jackify_log.txt`) removed and replaced with automatic error-only logging to `error_log.txt`
- **After Steps 2 and 3** — countdown replaced with "Press any key to continue" prompt
- **Title case** — minor words (e.g. "the", "and") that immediately follow a digit sequence are now capitalised, fixing episode titles such as `S02E01 The Dundies`
- **Cleanup functions** (`strip_source_tags`, `rename_in_path`, `apply_title_case`) now restrict file operations to known video and subtitle extensions, and explicitly exclude `error_log.txt`
- **`build_ext_args`** generalised to accept any named extensions array via an optional second argument (default: `VIDEO_EXTENSIONS`)
- **Single video** — Step 2 header now reads "video" instead of "videos" when only one file is being converted

### Changed
- Error log timestamps now use the locale's short date and time format (`%x %X`)
- If staging already contains files when the script starts, the copy step is skipped regardless of whether downloads also has files — staging always takes priority

### Fixed
- Stale `${LOG_ENABLED:+ ...}` reference in `warn` call on HandBrake failure, which would have caused an unbound variable error under `set -u`
- Outdated `build_ext_args` comment still referencing `VIDEO_EXTENSIONS` specifically
