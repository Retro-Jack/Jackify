# Changelog

## v1.10.0 — 2026-07-28

### Added
- **All text and PGS subtitles can now be burned in, not just SRT.** The "burned subs" pass used to fire only when a `.srt` was present. It now also burns styled-text sidecars (`.ass`, `.ssa`, `.vtt`) and PGS picture subs (`.sup`). SRT keeps its direct `--srt-file` path; the others are muxed into a temporary MKV as the sole subtitle track (video and audio stream-copied) and burned from there with the chosen preset — so ASS/SSA styling is preserved through libass, and PGS bitmaps are burned as-is. When several subtitles are present for a video, the burn prefers SRT, then ASS/SSA, then VTT, then SUP. VobSub (`.idx`/`.sub`) still travels alongside the video as a sidecar but is not burned. No new dependency — ffmpeg was already required for subtitle extraction.

---

## v1.9.0 — 2026-07-22

### Added
- **Each profile now gets its own output folder.** Conversions land in `2) Done/<preset name>/` — `Jack 1080` and `Loren 720` each keep their own tree — instead of everything sharing the one `2) Done` root. The subfolder is created automatically after the preset menu, and all the downstream behaviour (movie/srt own-folder placement, `Show - Season N` folders, subtitle extraction and the rename passes) happens inside it. A side benefit: the name-cleaning passes now only ever touch the current profile's files, so one person's run can no longer re-rename output a previous run left for the other. The error log stays shared at the `2) Done` root, one log for all profiles.

---

## v1.8.2 — 2026-07-13

### Fixed
- **Release-group tags now strip off files, not just folders.** v1.7.1 made release-group stripping *trailing-only* (to stop it eating title words), anchored to the end of the name — but name-cleaning runs on the whole filename *including the extension*, so on a file like `Movie.2008.1080p.x264.Deceit.YIFY.mp4` the `.mp4` sat after the group and defeated the anchor, leaving `…Deceit.YIFY.mp4`. Folders (no extension) cleaned fine, files didn't. Both trailing-group passes now tolerate a trailing extension (and a ` burned subs` tag), so bare release groups strip off files too. Bonus: a standalone title that happens to match a group name (a film literally called `Deceit`, or `Deceit (2004)`) is now safe, since a group must be preceded by a separator.

### Added
- **New release groups:** `Deceit` (seen chained before YIFY on Brrip rips) and `Varyg` (anime).

---

## v1.8.1 — 2026-07-11

### Fixed
- **Burned-in subtitle copies get their names cleaned like the original.** A `<name> burned subs.mp4` produced for a 4K Tube video kept its `video <resolution> <language>` tag (e.g. `… Video English burned subs.mp4`) because the tag stripper is anchored to the end of the name and the ` burned subs` suffix sat between the tag and the extension. The stripper now tolerates a trailing ` burned subs`, so the burned copy strips identically to the plain output.

### Changed
- **Internal cleanup (no behaviour change).** The `(n)` collision-suffix naming (used when a target name is already taken) is now a single shared `_dedupe_name` helper instead of being open-coded in `copy_file_to_input`, `_flatten_move_one` and `remove_title_number`. The subtitle-matching and output-routing helpers (`_subtitle_belongs_to_stem`, `_sidecar_subtitle_for`, `_plan_output`) were moved to sit with the other subtitle helpers rather than being split across `process_video`.

---

## v1.8.0 — 2026-07-11

### Added
- **4K Tube downloads are flattened into staging automatically.** 4K Tube saves grabs nested at `…/1) Staging/4ktube/<category>/video/` — `youtube/video/` for single downloads, `playlist/video/` for playlists — levels the converter never scans. A new `flatten_4ktube_staging` step (run once, right after the staging/output dirs are ensured and before the copy/convert scans) lifts each `video/` folder's contents up to the staging root, then deletes the whole `4ktube` tree unconditionally. Two modes by category: **`playlist/`** keeps its `<PlaylistName>/` grouping (the folder moves up as-is, so the output mirrors it), while **everything else (`youtube/`, …)** is **flattened** — the video files are pulled out of their wrapper subfolders (whose names are just batch timestamps like `Batch 2026-07-11 16-08-14`) so they land individually. All folder names are matched case-insensitively; it's a silent no-op on non-YouTube runs; and a staging-root name clash gets a `(1)`, `(2)`, … suffix so a move never overwrites an existing file.

### Changed
- **4K Tube's trailing `video <resolution> <language>` tag is stripped from output names.** 4K Tube suffixes its filenames with a descriptor like `video 2160p60 english` / `video 1080p uk` / `video 2160p original`; name-cleaning now removes that whole trailing block (folder and files alike, extension kept), covering the language/region tags `english`/`eng`/`en`/`original`/`orig`/`uk`/`gb`/`us`. The literal `video` marker is required, so a real title that merely ends in a region word (*The Office US*, *Shameless US*) or in *English* is left untouched. Also fixed along the way: the resolution matcher now catches a frame-rate suffix (`2160p60`, `1080p60` — previously slipped through), and a tag stripped immediately before the extension no longer leaves a stray space (`Name .mkv` → `Name.mkv`).
- **Title-embedded years are no longer wrapped like release years.** The year-in-parentheses formatting now skips a **future** year (Cyberpunk 2077, Blade Runner 2049 — a release date can't be in the future) and a **possessive** year (`2026's Biggest…`), leaving them as part of the title. Real release years still wrap (`The Matrix 1999` → `The Matrix (1999)`). A past, non-possessive title year (e.g. `2001 A Space Odyssey`) is indistinguishable from a release year and is still wrapped.
- **A movie + subtitle pair now lands in its own folder.** When a video has a matching subtitle — a sidecar (including a language-tagged `.en.srt`) or an extracted embedded text track — its output goes into `OUTPUT_DIR/<media name>/` with the video and the `.srt` both named after the media, so the pair travels together. Videos without a subtitle are unchanged: a lone video stays flat, a `SxxExx` TV episode still goes to `<Show> - Season N/`, and a kept playlist folder is preserved. Precedence: a TV episode with a subtitle still goes to its season folder; any other subtitled video takes its own folder, even out of a playlist. (The output routing is now factored into a `_plan_output` helper, and sidecar detection is stem-matched via `_sidecar_subtitle_for` so a sibling video's subtitle can't be mistaken for this one's.)
### Fixed
- **Language-tagged sidecar subtitles are now paired with their video.** YouTube / 4K Tube save subtitles as `<video>.en.srt` (also `.eng.srt`, `.pt-BR.srt`, …), but subtitle pairing matched only an exact `<video>.srt`, so those sidecars were silently dropped — neither moved to the output nor burned. Pairing now also accepts an ISO-shaped language tag (2–3 letters + optional region) and normalises the moved file to `<video>.srt` (tag dropped) so it's carried into the output as a sidecar and picked up by the extract / normalise / burn steps. An unrelated `.trailer.srt`-style suffix can't false-match; if two sidecars would collapse to the same name (e.g. `.en.srt` + `.es.srt`), the first wins and the rest are left for staging cleanup.

---

## v1.7.1 — 2026-07-04

### Fixed
- **Release-group names no longer eat title words.** Group tags were stripped case-insensitively anywhere in the name, so titles containing a group word lost it — *Killers Of The Flower Moon* became *Of The Flower Moon* (likewise Don, LOL, Bone, Ember, Fleet…). Groups now live in their own alternation stripped only from the end of the stem (scene convention), in two passes — before the technical tags (group last) and after them (group ahead of the tags, e.g. `Movie.YIFY.1080p`). Technical tags (resolutions, codecs, sources…) still strip anywhere.

### Added
- **New tags from a downloads scan:** release group `MULVAcoded`; descriptive noise `TV Mini-Series` / `Mini-Series` (so `Cilla TV Mini-Series 2014 …` cleans to `Cilla (2014)`).

---

## v1.7.0 — 2026-06-30

### Added
- **OOM safety guards around HandBrake.** A corrupt or partially-downloaded input could send HandBrake into an unbounded allocation loop — exhausting RAM and swap until the kernel OOM-killed the whole terminal session (observed: 22.2 GB RAM + 25.7 GB swap before the kill). Two layers now prevent that:
  1. **Pre-flight integrity check** — `process_video` runs a fast `ffprobe` container probe and skips any file whose duration can't be read before HandBrake touches it (logged via `warn`, counted as a failure).
  2. **Memory-capped, time-limited encodes** — both HandBrake passes (main + subtitle burn) now run inside a `systemd-run --user --scope` with `MemoryMax=$HANDBRAKE_MEM_MAX` (default 8G) and `MemorySwapMax=0`, under a `timeout` of `$HANDBRAKE_TIMEOUT` (default 4h). If an encode exceeds the cap or runs long, only that scope is killed; the script logs it as a normal HandBrake failure and continues. The integrity check catches the obvious bad files; the cap is the hard backstop for everything else (a valid header with a truncated payload can pass the probe but still balloon).

  Both guards degrade gracefully where `systemd-run` / `timeout` / `ffprobe` aren't present. New `HANDBRAKE_MEM_MAX` and `HANDBRAKE_TIMEOUT` config knobs near the top of the script.

---

## v1.6.5 — 2026-06-21

### Changed
- **Consolidated header spacing** — `print_header` now owns the gap below every banner, emitting three blank lines after the box. The per-call `echo`s that used to follow the intro, *Processing Complete*, and *Done* headers were removed, and Step 2's per-video separator now skips the first video so its block sits cleanly under the header. Every step header (intro, Steps 1–3, final report, Done) now has identical spacing.

---

## v1.6.4 — 2026-06-21

### Changed
- **Step 2 spacing** — every video's output block is now separated from the previous one by two blank lines (applied uniformly to both converted and skipped videos), and the redundant blank line after the Step 2 header was removed so the first video lines up with the rest. The `English subtitles found in …` notice is now flush-left (the stray leading space from v1.6.3 is gone).

---

## v1.6.3 — 2026-06-21

### Changed
- **Step 2 output layout** — the main conversion progress bar and its `[SUCCESS] Conversion complete` line are now indented four spaces to match the subtitle-burn block. The `English subtitles found in … - extracting` notice gets a blank line above it and sits at a single-space indent, so the conversion and subtitle phases read as two clearly separated blocks per video.

---

## v1.6.2 — 2026-06-21

### Added
- **Subtitle-extraction notice** — `extract_subtitle` now prints `English subtitles found in <filename> - extracting` once a usable English (or untagged-fallback) text track is located, so the terminal shows why an extraction pass is starting.

---

## v1.6.1 — 2026-06-21

### Added
- **URL / tracker stripping in `strip_source_tags`** — two new substitutions remove site junk from names: any leading `www.<domain>` and bare tracker brands (`UIndex.org`, `YTS.MX`, `RARBG.*`, `EZTV.*`, `ETTV.*`), along with the trailing separator run (e.g. the `   -   ` scene folders insert after the URL). Intentionally **not** a generic `*.tld` strip, which would eat real title words like `Escape.To.Witch.Mountain`.
- **New source tags** — added `REMUX`, `UNCUT`, `Dual-Audio`/`Dual Audio`, the `Opus` audio codec (with optional `2.0`-style channel suffix), a channel-suffix form for `FLAC` (matching the existing `AAC` handling), and release groups `Headpatter`, `WR3CK`, and `OFT` to the tag list. Sourced from real filenames in the downloads folder.

---

## v1.6.0 — 2026-06-21

### Added
- **English-only audio for multi-track sources** — new `_english_audio_args` helper probes the source's audio streams with `ffprobe`. When a file carries more than one audio track, only the English-tagged tracks (`eng`/`en`/`english`) are passed to HandBrake via `--audio`, dropping foreign dubs. Single-track sources are left untouched, so a lone foreign-language track is never lost; likewise a multi-track source with no English stream falls back to the preset's default rather than risk producing a file with no audio. The same selection is reused by the subtitle-burn pass so both outputs stay consistent.

---

## v1.5.3 — 2026-05-03

### Changed
- **Excluded basenames** — removed `featurette` from `EXCLUDED_BASENAMES`; only `sample` and `preview` files are now skipped during the copy step.

---

## v1.5.2 — 2026-05-03

### Added
- **SRT encoding normalisation** — new `_normalise_srt` helper runs after the move/extract step and before each burn pass. It strips any leading UTF-8 BOM in place, detects the file's encoding via `uchardet` (preferred — most reliable on short/Cyrillic SRTs) with a `file -bi` fallback, and runs `iconv -t UTF-8` when the source isn't already UTF-8/ASCII. This lets multibyte glyphs — musical notes (`♪♫`), em-dashes, smart quotes, and non-Latin accents — survive HandBrake's `--srt-codeset UTF-8` burn pass instead of being mangled when the sibling SRT was Windows-1252 / ISO-8859-x.

### Changed
- **Optional dependency: `uchardet`** — present on Arch / Debian / Fedora by default; the script falls back to `file -bi` when it's missing, so it's not added to the prerequisite check.

---

## v1.5.1 — 2026-05-03

### Changed
- **Code cleanup** — dropped redundant `stem` locals in `_perl_rename_loop` and `remove_title_number` (they were assigned and immediately reused as `target`); removed the duplicate `_current_output` comment from `process_video` (already documented at the variable's declaration); refreshed `extract_subtitle`'s docstring to mention the `eng → und/empty` language fallback and the content-based SDH check; corrected the `process_video` output-dir comment to read "embedded text-based subtitle track" (drops a stale "eng" qualifier). No behavioural changes.

---

## v1.4.16 — 2026-05-03

### Changed
- **Final report spacing** — blank line inserted under `Preset:` so the preset name reads as its own header above the counters block.

---

## v1.4.15 — 2026-05-03

### Changed
- **Final report spacing** — failure counters (`Videos failed`, `Copy failures`, `Rename errors`) now sit beneath a blank line so they're visually separated from the cleanup/skipped block. The blank line and the failure block only render when at least one failure counter is non-zero, so clean runs keep their tight layout.

---

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
