# Changelog

## v1.4.14 — 2026-05-03

### Changed
- **Final report layout** — restructured into three sections separated by `------------------------` rules:
  1. Preset / videos found / videos converted
  2. Subtitle counters: `Found subs`, `Found subs burned`, `Subs extracted`, `Extracted subs burned` (always shown, even when zero)
  3. Name cleanup / videos skipped / failure counters (failures only shown when non-zero)
- **Burn-counter split** — the single `Burned subs made` total has been replaced by the per-source split: `Found subs burned` (burns whose `.srt` was a pre-existing sibling) and `Extracted subs burned` (burns whose `.srt` was just extracted from the source). The internal `videos_burned` aggregate has been removed.
- **`Found subs` counter** — counts videos that had a sibling `.srt` available before extraction was attempted.

---

## v1.4.13 — 2026-05-03

### Added
- **Final report counters** — added `Subs extracted` (count of times an embedded track was extracted and written/replaced the target `.srt`) and `Extracted subs burned` (count of burns whose source `.srt` was the just-extracted one rather than a pre-existing sibling). Both lines only render when their counter is non-zero. Report column padding widened to fit the new labels.

---

## v1.4.12 — 2026-05-03

### Fixed
- **Title-number stripping** — the `## - name` prefix removal was scoped to `*.${OUTPUT_FORMAT}` (i.e. `*.mp4`) only and skipped `.srt` siblings entirely. It also never ran on directories, so `1 - Foo Folder/` stayed prefixed. `remove_title_number` now follows the same `<directory> [--recursive] [--dirs]` shape as the other cleanup functions, walks all media files (video + subtitle) plus folders, and preserves the existing `(1)`, `(2)`, … collision-handling.

---

## v1.4.11 — 2026-05-03

### Changed
- **SDH heuristic threshold** — raised from 2 bracket/paren pairs to 10. The 2-pair threshold caused false positives on normal dialogue tracks that contain a handful of legitimate parentheticals (song titles, asides). Real SDH tracks pepper their entire runtime with sound-effect cues, so 10+ pairs remains a strong signal.

---

## v1.4.10 — 2026-05-03

### Fixed
- **MP4 subtitle extraction** — MP4 muxers commonly leave the subtitle language tag as `und` (undefined) instead of `eng`, so the strict `lang == "eng"` filter was rejecting otherwise-valid English `mov_text` tracks. `_find_eng_subtitle_track` now prefers an `eng`-tagged track but falls back to the first `und` or empty-language text track when none is present. Foreign-language tags are still skipped.

---

## v1.4.9 — 2026-05-03

### Changed
- **Burned-subs filename** — output is now `<stem> burned subs.mp4` (single space, no dash). The title-case preserve regex still tolerates a legacy dash so older outputs are normalised on rerun.

---

## v1.4.8 — 2026-05-03

### Fixed
- **Burned-subs HandBrake pass freeze** — both `HandBrakeCLI` invocations and the `ffmpeg` extraction call inherited the parent shell's stdin, so any subprocess that read from the tty (libass init, format probe, etc.) could silently block waiting for input — observed as a hang at 0% during the burn pass on x265 sources. All three subprocesses now have stdin redirected from `/dev/null` (`ffmpeg` uses the explicit `-nostdin` flag) so they can never read from the terminal.

---

## v1.4.7 — 2026-05-03

### Fixed
- **Subtitle extraction freeze** — `mktemp` pre-created the SRT target, so `ffmpeg` saw the file already existed and silently waited on stdin for "File exists, overwrite? [y/N]"; the script appeared to hang until Enter was pressed. Added `-y` to skip the prompt.
- **Cue-count regex** — extracted SRTs commonly use CRLF line endings, which made `^[0-9]+$` match nothing. Updated to `^[0-9]+\r?$` so cue counting works on both LF and CRLF files.
- **`cue_count` parsing** — `grep -c ... || echo 0` produced `"0\n0"` (grep prints `0` to stdout *and* exits non-zero on no match, which then triggered the `|| echo 0` to append a second `0`), causing `[[ $cue_count -lt … ]]` to throw an arithmetic syntax error. Replaced with `${cue_count:-0}` fallback after a clean `grep -c`.

---

## v1.4.6 — 2026-05-03

### Changed
- **Progress bar** — pre-built `FULL_BAR` / `EMPTY_BAR` constants once at startup and slice with `${var:0:N}` instead of forking `perl` on every progress tick (dozens of forks per video saved).
- **Embedded-subs probe cached** — `process_video` now passes the ffprobe-found track index to `extract_subtitle` so a solo video with embedded subs no longer probes twice (once for output-dir routing, once for extraction).
- **`process_video` cleanup** — `stem` hoisted to a single declaration at the top of the function; `output_file = "$output_dir/$stem.$OUTPUT_FORMAT"` factored out of the four solo-video branches; redundant `has_embedded_subs` flag removed (folded into `[[ -n "$embedded_track" ]]`).

---

## v1.4.5 — 2026-05-03

### Added
- **SDH content heuristic** — extracted subtitles with two or more `[...]` or `(...)` pairs anywhere in the file are now treated as SDH/HI and discarded. The container's `hearing_impaired` disposition flag is rarely set on scene/torrent rips, so this fills the gap by catching common SDH cue markers (`[door slams]`, `(LAUGHTER)`, etc.). The check runs after the cue-count guard inside `extract_subtitle`.

---

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
