#!/usr/bin/env bash
# =============================================================================
# Jackify — Automated video conversion and renaming
# =============================================================================
# Copies videos from DOWNLOADS_DIR to STAGING_DIR, converts them with
# HandBrakeCLI using a preset chosen interactively from PRESET_DIR/*.json,
# and writes cleaned-up output to OUTPUT_DIR.
#
# Pipeline:
#   1. Copy: DOWNLOADS_DIR -> STAGING_DIR (skipped if downloads is empty)
#   2. Convert: HandBrakeCLI on each video; sibling subtitles are moved from
#      staging to OUTPUT_DIR and embedded eng/und text tracks are extracted
#      directly into OUTPUT_DIR. If a same-stem .srt ends up there, a second
#      HandBrake pass burns it into a " burned subs" copy.
#   3. Clean names: strip tags/encoder groups, wrap years in parens, normalise
#      separators, apply title case (with apostrophe + acronym handling)
#
# Errors are written lazily to OUTPUT_DIR/error_log.txt; the terminal only
# sees a "[WARN] See <log>" pointer. The log is not created on clean runs.
#
# Requires: HandBrakeCLI, perl. Other tools (find, sed, awk, mv, cp) are
# standard on any Linux system.
# =============================================================================

set -uo pipefail

# ----- Configuration ---------------------------------------------------------

DOWNLOADS_DIR="/mnt/misc/Downloads/_Torrents/Finished/Files"
STAGING_DIR="/mnt/multimedia/Conversion/Handbrake/1) Staging"
OUTPUT_DIR="/mnt/multimedia/Conversion/Handbrake/2) Done"
HANDBRAKE_CLI="/usr/bin/HandBrakeCLI"
PRESET_DIR="/mnt/applications/Linux Applications/_Handy Scripts/Jackify/Handbrake Presets"

OUTPUT_FORMAT="mp4"
PROCESS_DELAY=2

# Each HandBrake encode runs inside a memory-capped systemd scope (when
# available) and under a wall-clock timeout, so a corrupt/partial file that
# makes HandBrake leak gets killed locally instead of OOM-ing the whole desktop
# session. Both degrade gracefully if systemd-run / timeout aren't present.
HANDBRAKE_MEM_MAX="8G"   # hard RAM ceiling for a single HandBrake encode
HANDBRAKE_TIMEOUT="4h"   # wall-clock ceiling for a single HandBrake encode

VIDEO_EXTENSIONS=(avi mkv mov wmv flv mp4 mpeg mpg m4v ts vob webm)
SUBTITLE_EXTENSIONS=(srt ass ssa vtt sub idx sup)
EXCLUDED_BASENAMES=(sample preview)

ERROR_LOG="$OUTPUT_DIR/error_log.txt"

SRT_SIZE_THRESHOLD=20  # % difference considered substantial when comparing SRT sizes
SRT_MIN_CUES=20        # extracted SRT must have at least this many cues to be used

PROGRESS_BAR_WIDTH=40
# Pre-built bars; sliced with ${var:0:N} during progress updates so each tick
# is a string slice instead of a perl fork (~dozens of forks per video saved).
FULL_BAR="$(perl -e "print '█' x $PROGRESS_BAR_WIDTH")"
EMPTY_BAR="$(perl -e "print '░' x $PROGRESS_BAR_WIDTH")"

# ----- Counters --------------------------------------------------------------

files_failed=0
videos_converted=0
videos_skipped=0
videos_failed=0
subs_found=0
found_subs_burned=0
subs_extracted=0
extracted_subs_burned=0
rename_errors=0

# Set true by extract_subtitle when it actually writes/replaces the target .srt
# (i.e. the extracted track won out over any existing file). Read by
# process_video to attribute a subsequent burn to "extracted" vs "pre-existing".
_last_extract_wrote=false

# Set by process_video while HandBrake is running; the EXIT trap removes the
# partial output file if the script is interrupted mid-conversion.
_current_output=""

# ----- Functions -------------------------------------------------------------

print_header() {
    local title="$1"
    local width=$(( ${#title} + 8 ))
    (( width < 50 )) && width=50
    local pad=$(( (width - ${#title}) / 2 ))
    local border
    border="$(printf '%*s' "$width" '' | tr ' ' '=')"
    # One blank line above the box, three below — the trailing gap is the
    # single source of truth for header spacing, so callers must not add their
    # own blank line after a header.
    printf '\n%s\n%*s%s\n%s\n\n\n\n' "$border" "$pad" '' "$title" "$border"
}

pause_and_clear() {
    echo
    read -r -s -n1 -p "Press any key to continue . . . "
    echo
    clear
}

_log_initialised=false

_init_error_log() {
    # Writes a one-time session header to the error log. Called lazily from
    # warn/die so the file only appears on disk when a real error occurs.
    $_log_initialised && return 0
    _log_initialised=true
    {
        printf '\n%s\n' "============================================================"
        printf 'Jackify run started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
        printf 'Host: %s | User: %s | PID: %s\n' "$(hostname)" "$USER" "$$"
        printf 'Preset: %s (%s)\n' "${PRESET_NAME:-?}" "${PRESET_FILE:-?}"
        printf 'Downloads: %s\n' "$DOWNLOADS_DIR"
        printf 'Staging:   %s\n' "$STAGING_DIR"
        printf 'Output:    %s\n' "$OUTPUT_DIR"
        printf 'HandBrake: %s\n' "$("$HANDBRAKE_CLI" --version 2>&1 | head -1)"
        printf '%s\n\n' "============================================================"
    } >> "$ERROR_LOG"
}

_log_details() {
    # Appends a labelled details block (caller, optional context payload, and a
    # trailing blank line) to the error log. Used by die/warn when extra context
    # is available beyond the one-line summary.
    local details="$1"
    local caller="${FUNCNAME[2]:-MAIN}:${BASH_LINENO[1]:-0}"
    printf '  caller: %s\n' "$caller" >> "$ERROR_LOG"
    if [[ -n "$details" ]]; then
        printf '  details:\n' >> "$ERROR_LOG"
        printf '%s\n' "$details" | sed 's/^/    /' >> "$ERROR_LOG"
    fi
    printf '\n' >> "$ERROR_LOG"
}

die() {
    # Usage: die <message> [<details>]
    # Full detail is written to ERROR_LOG; the terminal only sees a one-line
    # pointer so users aren't spammed with stack traces during a run.
    _init_error_log
    printf '[ERROR] See %s\n' "$ERROR_LOG" >&2
    printf '%s - ERROR: %s\n' "$(date '+%x %X')" "$1" >> "$ERROR_LOG"
    _log_details "${2:-}"
    exit 1
}

warn() {
    # Usage: warn <message> [<details>]
    # Full detail is written to ERROR_LOG; the terminal only sees a one-line
    # pointer so users aren't spammed with stack traces during a run.
    _init_error_log
    printf '[WARN]  See %s\n' "$ERROR_LOG" >&2
    printf '%s - WARN: %s\n' "$(date '+%x %X')" "$1" >> "$ERROR_LOG"
    _log_details "${2:-}"
}

_on_exit() {
    [[ -n "$_current_output" && -f "$_current_output" ]] && rm -f "$_current_output"
}
trap '_on_exit' EXIT

check_path() {
    [[ -d "$1" ]] || die "Cannot find directory: $1 ($2)"
}

check_file() {
    [[ -f "$1" ]] || die "Cannot find file: $1 ($2)"
}

check_command() {
    command -v "$1" &>/dev/null || die "Cannot find command: $1 ($2)"
}

build_ext_args() {
    # Builds a `-name X -o -name Y …` find expression in the named array.
    # Usage: build_ext_args <out_array> [<extensions_array=VIDEO_EXTENSIONS>]
    local -n _out=$1
    local -n _exts=${2:-VIDEO_EXTENSIONS}
    for ext in "${_exts[@]}"; do
        [[ ${#_out[@]} -gt 0 ]] && _out+=("-o")
        _out+=("-name" "*.${ext}")
    done
}

build_exclude_args() {
    # Builds `! -iname X.* ! -iname Y.* …` from EXCLUDED_BASENAMES into the named array.
    local -n _out=$1
    for name in "${EXCLUDED_BASENAMES[@]}"; do
        _out+=("!" "-iname" "${name}.*")
    done
}

_parse_find_opts() {
    # Parses --recursive and --dirs flags into named boolean variables.
    # Usage: _parse_find_opts <recursive_var> <dirs_only_var> "$@"
    local -n _r=$1 _d=$2
    shift 2
    for arg in "$@"; do
        case "$arg" in
            --recursive) _r=true ;;
            --dirs)      _d=true ;;
        esac
    done
}

_build_find_args() {
    # Populates a named array with find arguments for cleanup functions.
    # Usage: _build_find_args <array_var> <directory> <recursive> <dirs_only>
    local -n _fa=$1
    local directory="$2" recursive="$3" dirs_only="$4"
    _fa=("$directory")
    if $dirs_only; then
        _fa+=("-depth" "-mindepth" "1" "-type" "d")
    else
        _fa+=("-mindepth" "1")
        $recursive || _fa+=("-maxdepth" "1")
        _fa+=("-type" "f" "!" "-name" "error_log.txt" "(" "${media_ext_args[@]}" ")")
    fi
}

_perl_rename_loop() {
    # Runs a perl one-liner per matching path under <directory>, capturing
    # stderr so regex errors get logged. The transformed basename is fed to
    # do_rename; for files, only the stem is transformed and the extension is
    # re-attached. Used by rename_in_path / strip_source_tags / apply_title_case
    # to share file/dir traversal, error capture, and stem/ext handling.
    # Usage: _perl_rename_loop <warn_label> <stem_only:true|false> <perl_script> <directory> <recursive> <dirs_only>
    local label="$1" stem_only="$2" script="$3" directory="$4" recursive="$5" dirs_only="$6"
    local -a find_args
    _build_find_args find_args "$directory" "$recursive" "$dirs_only"

    local item name ext target new_target new_name perl_err
    while IFS= read -r -d '' item; do
        name="$(basename "$item")"
        if $stem_only && [[ "$name" == *.* && ! -d "$item" ]]; then
            ext="${name##*.}"
            target="${name%.*}"
        else
            ext=""
            target="$name"
        fi
        perl_err=$(mktemp)
        if ! new_target="$(printf '%s' "$target" | perl -pe "$script" 2>"$perl_err")"; then
            warn "$label failed on: $name" "$(<"$perl_err")"
            ((rename_errors++))
            rm -f "$perl_err"
            continue
        fi
        rm -f "$perl_err"
        new_name="$new_target"
        [[ -n "$ext" ]] && new_name="$new_target.$ext"
        do_rename "$item" "$new_name"
    done < <(find "${find_args[@]}" -print0 2>/dev/null)
}

do_rename() {
    # Renames a file or directory to a new name within the same parent directory.
    # Skips if new_name is empty, unchanged, or would collide with an existing path.
    # Usage: do_rename <item> <new_name>
    local item="$1" new_name="$2"
    local parent name
    parent="$(dirname "$item")"
    name="$(basename "$item")"
    [[ -n "$new_name" && "$new_name" != "$name" ]] || return 0
    if [[ -e "$parent/$new_name" ]]; then
        warn "Rename skipped (target exists): $name -> $new_name" "parent: $parent"
        ((rename_errors++))
        return 0
    fi
    echo "  Renaming: $name -> $new_name"
    local mv_err
    if ! mv_err=$(mv "$item" "$parent/$new_name" 2>&1); then
        warn "Could not rename: $item -> $new_name" "$mv_err"
        ((rename_errors++))
    fi
}

_dedupe_name() {
    # Given a parent dir, a base stem, and an extension (with leading dot, or
    # empty for a directory / extensionless name), echo a basename that does not
    # already exist under the parent — appending (1), (2), … before the
    # extension. Called after the plain name is found to be taken.
    # Usage: _dedupe_name <parent> <stem> <ext>
    local parent="$1" stem="$2" ext="$3" n=1
    while [[ -e "$parent/${stem}(${n})${ext}" ]]; do n=$((n + 1)); done
    printf '%s' "${stem}(${n})${ext}"
}

copy_file_to_input() {
    # Copies a single file from DOWNLOADS_DIR to STAGING_DIR, preserving its
    # relative path.
    local source_file="$1"
    local relative_path="${source_file#"$DOWNLOADS_DIR"/}"
    local target_file="$STAGING_DIR/$relative_path"
    local target_dir
    target_dir="$(dirname "$target_file")"

    local mkdir_err
    if ! mkdir_err=$(mkdir -p "$target_dir" 2>&1); then
        warn "Could not create directory: $target_dir — skipping $(basename "$source_file")" "$mkdir_err"
        ((files_failed++))
        return
    fi

    if [[ -f "$target_file" ]]; then
        local stem
        stem="$(basename "${target_file%.*}")"
        target_file="$target_dir/$(_dedupe_name "$target_dir" "$stem" ".${target_file##*.}")"
    fi
    echo "  Copying: $(basename "$source_file") -> $(basename "$target_file")"
    local cp_err
    if ! cp_err=$(cp "$source_file" "$target_file" 2>&1); then
        local src_size="?" free_space="?"
        src_size=$(stat -c %s "$source_file" 2>/dev/null || echo "?")
        free_space=$(df -h "$target_dir" 2>/dev/null | awk 'NR==2 {print $4" free of "$2}')
        warn "Copy failed: $source_file -> $target_file" "$cp_err
size: $src_size bytes
target: $free_space"
        ((files_failed++))
    fi
}

_flatten_move_one() {
    # Move one path into the staging root, adding a (1), (2), … suffix if the
    # name is already taken (as in copy_file_to_input) so nothing is clobbered.
    # Usage: _flatten_move_one <path>
    local src="$1" base target stem ext mv_err
    base="$(basename "$src")"; target="$STAGING_DIR/$base"
    if [[ -e "$target" ]]; then
        if [[ "$base" == *.* && ! -d "$src" ]]; then
            stem="${base%.*}"; ext=".${base##*.}"
        else
            stem="$base"; ext=""
        fi
        target="$STAGING_DIR/$(_dedupe_name "$STAGING_DIR" "$stem" "$ext")"
    fi
    echo "  Moving: $base"
    if ! mv_err=$(mv "$src" "$target" 2>&1); then
        warn "4ktube move failed: $base" "$mv_err"
    fi
}

flatten_4ktube_staging() {
    # 4K Tube nests downloads at STAGING_DIR/4ktube/<category>/video/ — e.g.
    # youtube/video/ for single grabs, playlist/video/ for playlists. For each
    # such video/ folder (matched case-insensitively) the contents are lifted up
    # to the staging root, then the whole 4ktube tree is removed — ALWAYS, even
    # with nothing to move. Two modes, by category:
    #   * playlist/ — KEEP the grouping: its <PlaylistName>/ subfolders move up
    #     as-is, so Jackify mirrors that folder in the output.
    #   * anything else (youtube, …) — FLATTEN: the video files themselves are
    #     pulled out to the root, dropping the wrapper subfolders (whose names
    #     are just batch timestamps like "Batch 2026-07-11 16-08-14").
    # Silent no-op when there's no 4ktube folder. A staging-root name clash gets
    # a (1), (2), … suffix so a move never clobbers an existing file.
    # Usage: flatten_4ktube_staging
    local tube_dir
    tube_dir="$(find "$STAGING_DIR" -mindepth 1 -maxdepth 1 -type d -iname '4ktube' -print -quit 2>/dev/null)"
    [[ -n "$tube_dir" ]] || return 0

    local announced=false vid_dir category entry
    while IFS= read -r -d '' vid_dir; do
        category="$(basename "$(dirname "$vid_dir")")"
        if [[ "${category,,}" == "playlist" ]]; then
            # keep groupings: move each top-level entry (the playlist folders) as-is
            while IFS= read -r -d '' entry; do
                $announced || { echo "Flattening 4K Tube downloads into staging..."; announced=true; }
                _flatten_move_one "$entry"
            done < <(find "$vid_dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
        else
            # flatten: pull the files out of any batch subfolders to the root
            while IFS= read -r -d '' entry; do
                $announced || { echo "Flattening 4K Tube downloads into staging..."; announced=true; }
                _flatten_move_one "$entry"
            done < <(find "$vid_dir" -mindepth 1 -type f -print0 2>/dev/null)
        fi
    done < <(find "$tube_dir" -mindepth 2 -maxdepth 2 -type d -iname 'video' -print0 2>/dev/null)

    local rm_err
    rm_err=$(rm -rf "$tube_dir" 2>&1) || warn "Could not remove 4ktube folder: $tube_dir" "$rm_err"
    echo
}

_handbrake_log_tail() {
    # Returns the last 30 lines of a HandBrake stdout/stderr log with
    # progress noise filtered out: percent updates ("45.6 %") and the
    # per-task "Encoding: task N of M, …" status lines.
    grep -viE '^[[:space:]]*[0-9]+\.[0-9]+[[:space:]]*%|^[[:space:]]*Encoding:[[:space:]]*task' "$1" | tail -n 30
}

show_progress() {
    # Optional first argument: indent string (default: "  ")
    local indent="${1:-  }"
    local pct filled
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)\.[0-9]+[[:space:]]*% ]]; then
            pct=${BASH_REMATCH[1]}
            filled=$(( pct * PROGRESS_BAR_WIDTH / 100 ))
            printf '\r%s[%s%s] %3d%%' \
                "$indent" \
                "${FULL_BAR:0:filled}" \
                "${EMPTY_BAR:0:$((PROGRESS_BAR_WIDTH - filled))}" \
                "$pct"
        fi
    done
    printf '\r%s[%s] 100%%\n' "$indent" "$FULL_BAR"
}

process_video() {
    # Converts a single video with HandBrakeCLI; skips inputs whose target
    # already exists. Output destination is decided by _plan_output:
    #   - movie/srt pair (matching sidecar OR embedded text track)
    #                                             -> OUTPUT_DIR/<media>/ (its own
    #                                                folder; the .srt is moved in
    #                                                beside it, renamed to match).
    #   - Lone TV episode (SxxExx pattern)        -> OUTPUT_DIR/<Show> - Season <N>/.
    #   - Videos sharing a folder (kept playlist, …), no subtitle
    #                                             -> preserve relative path under OUTPUT_DIR.
    #   - Otherwise                               -> OUTPUT_DIR/ (flat).
    # On success: moves the matching subtitle (renamed to <stem>.<ext>) into
    # output_dir, extracts any embedded eng/und text track there, and if a
    # <stem>.srt is present runs a second HandBrake pass to produce
    # "<stem> burned subs.mp4".
    # Usage: process_video <input> <current_index> <total>
    local input_file="$1"
    local current_num="$2"
    local total_num="$3"

    local input_dir stem
    input_dir="$(dirname "$input_file")"
    stem="$(basename "${input_file%.*}")"
    local sibling_count
    sibling_count=$(find -L "$input_dir" -maxdepth 1 -type f "${exclude_args[@]}" \( "${ext_args[@]}" \) | wc -l)

    # Cached and reused later by extract_subtitle to avoid a second ffprobe call.
    local embedded_track=""

    # Route the output: a movie/srt pair (matching sidecar, or an embedded text
    # track) lands in its OWN folder named after the media file, with the .srt
    # moved in beside it renamed to match. See _plan_output for the full rules.
    local output_file output_dir
    _plan_output "$input_file" "$sibling_count"

    local out_mkdir_err
    if ! out_mkdir_err=$(mkdir -p "$output_dir" 2>&1); then
        warn "Could not create output directory: $output_dir — skipping $(basename "$input_file")" "$out_mkdir_err"
        ((videos_failed++))
        return
    fi

    # Two blank lines separate this video's block from the previous one. The
    # first video is skipped — its block already sits under the three blank
    # lines that follow the STEP 2 header.
    (( current_num > 1 )) && printf '\n\n'

    if [[ -f "$output_file" ]]; then
        echo "[$current_num/$total_num] SKIPPING: $(basename "$input_file") (already converted)"
        ((videos_skipped++))
        return
    fi

    echo "$(basename "$input_file")"

    # --- INTEGRITY CHECK SHIELD ---
    # Fast container check to catch partial torrents/corrupted streams before HandBrake freezes the system.
    local check_err
    if ! check_err=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$input_file" 2>&1); then
        warn "Skipping corrupted or incomplete file: $(basename "$input_file")" "ffprobe duration check failed:
$check_err"
        ((videos_failed++))
        return
    fi
    # ------------------------------

    # When the source has more than one audio track, keep only English ones.
    # Empty array => leave the preset's audio selection alone (≤1 track, or no
    # English track present). Reused verbatim by the subtitle-burn pass below.
    local -a audio_args
    _english_audio_args audio_args "$input_file"
    [[ ${#audio_args[@]} -gt 0 ]] && echo "  Audio: multiple tracks — keeping English only (${audio_args[1]})"

    # --preset-import-file + --preset are both required to select a named
    # preset from a JSON file (HandBrake quirk).
    local hb_ok hb_log
    hb_log=$(mktemp)
    printf '    [%s]   0%%' "$EMPTY_BAR"
    _current_output="$output_file"
    { "${HB_GUARD[@]}" "$HANDBRAKE_CLI" \
        -i "$input_file" \
        -o "$output_file" \
        --preset-import-file "$PRESET_FILE" \
        --preset "$PRESET_NAME" \
        "${audio_args[@]}" </dev/null 2>&1; } | tee "$hb_log" | tr '\r' '\n' | show_progress "    "
    hb_ok=${PIPESTATUS[0]}

    if [[ $hb_ok -eq 0 ]]; then
        _current_output=""
        echo "    [SUCCESS] Conversion complete"
        ((videos_converted++))

        local had_sibling_srt=false

        # Move sibling subtitles from staging to output_dir before extraction, so
        # the .srt that extract_subtitle compares against already lives at its
        # final home and the burn pass reads from there. A sidecar may carry a
        # language tag (YouTube / 4K Tube write video.en.srt, video.eng.srt,
        # video.pt-BR.srt): those are matched too, and the destination name is
        # normalised to <stem>.<ext> (tag dropped) so the extract / normalise /
        # burn steps — which key on <stem>.srt — pick it up. If two sidecars
        # would collapse to the same name (e.g. .en.srt + .es.srt), the first
        # wins and the rest are left for staging cleanup.
        local sub sub_name sub_ext sub_dest sub_mv_err
        while IFS= read -r -d '' sub; do
            sub_name="$(basename "$sub")"
            sub_ext="${sub_name##*.}"
            _subtitle_belongs_to_stem "$sub_name" "$stem" || continue
            sub_dest="$output_dir/$stem.$sub_ext"
            [[ -e "$sub_dest" && "$sub" != "$sub_dest" ]] && continue
            echo
            echo "    Moving subtitles: $sub_name"
            [[ "${sub_ext,,}" == "srt" ]] && had_sibling_srt=true
            if ! sub_mv_err=$(mv "$sub" "$sub_dest" 2>&1); then
                warn "Subtitle move failed: $sub_name" "src: $sub
dst: $sub_dest
$sub_mv_err"
            fi
        done < <(find -L "$input_dir" -type f "${exclude_args[@]}" \( "${sub_ext_args[@]}" \) -print0 2>/dev/null)

        extract_subtitle "$input_file" "$output_dir/$stem.srt" "$embedded_track"
        $had_sibling_srt && ((subs_found++))

        local srt_path="$output_dir/$stem.srt"
        if [[ -f "$srt_path" ]]; then
            _normalise_srt "$srt_path"
            local burned_file="$output_dir/$stem burned subs.${OUTPUT_FORMAT}"
            if [[ -f "$burned_file" ]]; then
                echo "  [BURNED SUBS] Already exists, skipping"
            else
                echo "    Burning subtitles: $(basename "$srt_path")"
                printf '    [%s]   0%%' "$EMPTY_BAR"
                _current_output="$burned_file"
                local burn_log
                burn_log=$(mktemp)
                { "${HB_GUARD[@]}" "$HANDBRAKE_CLI" \
                    -i "$input_file" \
                    -o "$burned_file" \
                    --preset-import-file "$PRESET_FILE" \
                    --preset "$PRESET_NAME" \
                    "${audio_args[@]}" \
                    --srt-file "$srt_path" \
                    --srt-codeset UTF-8 \
                    --srt-burn 1 </dev/null 2>&1; } | tee "$burn_log" | tr '\r' '\n' | show_progress "    "
                local burn_ok=${PIPESTATUS[0]}
                if [[ $burn_ok -eq 0 ]]; then
                    _current_output=""
                    echo "    [SUCCESS] Burned subs complete"
                    if $_last_extract_wrote; then
                        ((extracted_subs_burned++))
                    else
                        ((found_subs_burned++))
                    fi
                else
                    _current_output=""
                    rm -f "$burned_file"
                    local burn_details
                    burn_details=$(_handbrake_log_tail "$burn_log")
                    warn "Subtitle burn failed on: $(basename "$input_file") (exit $burn_ok, srt: $(basename "$srt_path"))" "$burn_details"
                fi
                rm -f "$burn_log"
            fi
        fi
    else
        _current_output=""
        rm -f "$output_file"
        local hb_details
        hb_details=$(_handbrake_log_tail "$hb_log")
        warn "HandBrake failed on: $(basename "$input_file") (exit $hb_ok, preset: $PRESET_NAME)" "$hb_details"
        ((videos_failed++))
    fi
    rm -f "$hb_log"

    sleep "$PROCESS_DELAY"
}

rename_in_path() {
    # Renames files or directories in a path using a Perl regex substitution.
    # Operates on the WHOLE basename (extension included) since the patterns
    # used for separator cleanup must see the dot before the extension.
    # --dirs recurses with -depth so children are renamed before parents.
    # Usage: rename_in_path <pattern> <replacement> <directory> [--recursive] [--dirs]
    local pattern="$1" replacement="$2" directory="$3"
    local recursive=false dirs_only=false
    shift 3
    _parse_find_opts recursive dirs_only "$@"
    _perl_rename_loop "Perl regex (pattern: $pattern)" false \
        "s/$pattern/$replacement/gi; s/[. ]+\$//" \
        "$directory" "$recursive" "$dirs_only"
}

strip_source_tags() {
    # Strips bracketed content, site/tracker URLs (www.* domains and bare
    # tracker brands like YTS.MX / UIndex.org), technical source tags (1080p,
    # x264, REMUX, Dual-Audio, encoder group names, …) and orphan separators
    # from basenames. Bare four-digit years are wrapped in parentheses.
    # Usage: strip_source_tags <directory> [--recursive] [--dirs]
    local directory="$1"
    local recursive=false dirs_only=false
    shift 1
    _parse_find_opts recursive dirs_only "$@"

    # $t is the master tag alternation, matched case-insensitively in /x mode
    # (free-spacing) so each category sits on its own commented line.
    local perl_script='
my $t = qr/
    # resolutions
    2160p|1080p|720p|480p|4K|UHD|
    # disc sources and streaming services
    Blu-?Ray|BDRip|BRRip|WEB-DL|WEBRip|HDTV|DVDRip|DVDScr|AMZN|NF|HULU|DSNP|
    # video codecs
    H\.?265|H\.?264|x265|x264|XviD|DivX|HEVC|AVC|
    # audio codecs and channel layouts
    TrueHD|Atmos|DTS-HD|DTS|DD5\.1|AC3|AAC(?:\d+\.\d+)?|FLAC(?:\d+\.\d+)?|Opus(?:\d+\.\d+)?|MP3|7\.1|5\.1|DDP5.1|Dual-?Audio|
    # HDR, bit-depth and remux markers
    HDR10\+|HDR10|HDR|SDR|DoVi|10bit|8bit|HLG|900mb|REMUX|
    # edition and re-release tags
    PROPER|REPACK|EXTENDED|THEATRICAL|UNRATED|UNCUT|IMAX|
    # descriptive metadata
    TV[\s._-]?Mini-?Series|Mini-?Series/xi;
# Release groups live in their own alternation, stripped ONLY from the end
# of the stem (scene convention puts the group last). Several are common
# English words — KILLERS, DON, LOL, FLEET, EMBER, BONE — and stripping
# them anywhere eats real title words ("Killers Of The Flower Moon" lost
# its first word before this split).
my $g = qr/
    # release groups
    YIFY|YTS|RARBG|SPARKS|GECKOS|DRONES|ROVERS|LOL|DIMENSION|KILLERS|FLEET|IMMERSE|BATV|DEFLATE|TBS|
    # release groups (encoders)
    CtrlHD|DON|EbP|NTb|Tigole|QxR|UTR|HiDt|HDMaNiAcS|10bit-GalaxyRG265|GalaxyRG|
    # anime fansub groups
    HorribleSubs|Erai-raws|SubsPlease|Judas|EMBER|AnimeRG|
    # release groups
    TERMiNAL|EPSiLON|FraMeSToR|WiLDCAT|COASTER|MULVAcoded|
    # release groups
    NTG|FLUX|ION10|CAKES|PECULATE|Headpatter|WR3CK|OFT|
    # release groups (legacy)
    aXXo|ViTE|DiAMOND|WAF|ESiR|BONE/xi;
# Drop [bracketed] segments wholesale.
s/\s*\[[^\]]*\]//g;
# Site/tracker URLs. A leading www. domain is always junk; the trailing
# separator run — including the " - " scene folders insert after the URL —
# is consumed with it. Deliberately NOT a generic *.tld strip: that would
# eat real title words like "Escape.To.Witch.Mountain".
s/\bwww\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+[\s._-]*//gi;
# Bare tracker brand without the www. prefix (UIndex.org, YTS.MX, …).
s/(?<![A-Za-z0-9])(?:UIndex|YTS|RARBG|EZTV|ETTV)\.[A-Za-z]{2,}\b[\s._-]*//gi;
# Trailing release group(s), before the technical tags go — the group is
# only recognisable as junk while it is still at the very end. Repeat in
# case separators reveal another one.
1 while s/(?<![A-Za-z0-9])(?:$g)[\s._-]*$//i;
# Tag wrapped in (parentheses).
s/\s*\(\s*$t\s*\)\s*//gi;
# Tag standing alone on token boundaries.
s/(?<![a-zA-Z0-9])$t(?![a-zA-Z0-9])//gi;
# Second trailing-group pass: a group that sat before the technical tags
# ("Movie.YIFY.1080p") only reaches the end once those tags are gone.
1 while s/(?<![A-Za-z0-9])(?:$g)[\s._-]*$//i;
# 4K Tube appends a "video <resolution> <language>" descriptor before the file
# extension (e.g. "video 2160p60 english", "video 1080p uk", "video 2160p
# original"). Strip that whole trailing block (each part after "video" optional),
# keeping any extension. The literal "video" marker is REQUIRED, so a real title
# that merely ends in a region/language word — say "The Office US", or a title
# ending in the word English — is never touched.
1 while s/[\s._-]+video(?:[\s._-]+(?:2160|1440|1080|720|576|480|360)p\d{0,3})?(?:[\s._-]+(?:english|eng|en|original|orig|uk|gb|us))?(?=[\s._-]*(?:\.[A-Za-z0-9]{1,4})?$)//i;
# Resolution with a frame-rate suffix (2160p60, 1080p60) that the plain
# 2160p/1080p tags above miss (their word boundary is defeated by the fps digits).
s/(?<![A-Za-z0-9])(?:2160|1440|1080|720|576|480|360)p\d{2,3}(?![A-Za-z0-9])//gi;
# Collapse separator runs left behind by the removals above.
s/[.\-_]{2,}([^.])/$1 ? ".$1" : ""/ge;
# Trim any trailing separators.
s/[.\-_]+$//;
# Drop any separator/space left immediately before a file extension (a tag
# stripped from the very end leaves "Name .mkv"); keep the extension.
s/[\s._-]+(\.[A-Za-z0-9]{1,4})$/$1/;
# Wrap a bare 4-digit release year in parentheses — but leave title-embedded
# years alone: a FUTURE year (Cyberpunk 2077, Blade Runner 2049) cannot be a
# release date, and a possessive year (2026 followed by apostrophe-s, as in a
# video title) is part of the title, not a release stamp. \x{27}/\x{2019} are the
# straight/curly apostrophes (a literal one would close this single-quoted block).
s{(?<![\(\d])\b(19\d{2}|20\d{2})\b(?![\x{27}\x{2019}])(?!\))}{$1 <= 1900 + (localtime())[5] ? "($1)" : $1}ge;
# Collapse runs of spaces.
s/\s{2,}/ /g;
# Trim leading and trailing whitespace.
s/^\s+|\s+$//g;'

    _perl_rename_loop "Tag stripping" false "$perl_script" \
        "$directory" "$recursive" "$dirs_only"
}

apply_title_case() {
    # Title-cases basenames (stem only, for files). Minor words (a, an, the,
    # and, …) stay lowercase unless they start the name. Short all-caps tokens
    # (DVD, HD, TV) are preserved. Apostrophes (straight and curly) are part of
    # the word so "Don't" stays "Don't". The " burned subs" suffix is stripped
    # before casing and re-appended verbatim (matching with or without a legacy
    # dash so older outputs are normalised on rerun).
    # Usage: apply_title_case <directory> [--recursive] [--dirs]
    local directory="$1"
    local recursive=false dirs_only=false
    shift 1
    _parse_find_opts recursive dirs_only "$@"

    local perl_script
    perl_script=$(cat <<'PERL'
my @minor = qw(a an the and but or nor for so yet at by in of on to up as);
my $burned = "";
if (s/\s*-?\s*burned subs\s*$//i) { $burned = " burned subs"; }
s/(\w[\w'\x{2019}]*)/do{
    my $orig=$1; my $w=lc($1);
    ($orig eq uc($orig) && length($orig)>1 && length($orig)<=4 && !grep{$_ eq lc($orig)}@minor) ? $orig :
    (grep{$_ eq $w}@minor) ? $w : ucfirst($w)
}/ge;
s/(?<=\d) ([a-z][\w'\x{2019}]*)/" ".(grep{$_ eq $1}@minor ? $1 : ucfirst($1))/ge;
s/^(\w)/uc($1)/e;
$_ .= $burned
PERL
)

    _perl_rename_loop "Title case" true "$perl_script" \
        "$directory" "$recursive" "$dirs_only"
}

remove_title_number() {
    # Strips HandBrake DVD title number prefixes ("## - name[.ext]" -> "name[.ext]")
    # from files and directories. On collision, appends (1), (2), … to the new name.
    # Usage: remove_title_number <directory> [--recursive] [--dirs]
    local directory="$1"
    local recursive=false dirs_only=false
    shift 1
    _parse_find_opts recursive dirs_only "$@"
    local -a find_args
    _build_find_args find_args "$directory" "$recursive" "$dirs_only"

    local item parent name ext target new_target new_name mv_err
    while IFS= read -r -d '' item; do
        parent="$(dirname "$item")"
        name="$(basename "$item")"
        if [[ ! -d "$item" && "$name" == *.* ]]; then
            ext="${name##*.}"
            target="${name%.*}"
        else
            ext=""
            target="$name"
        fi
        [[ "$target" =~ ^([0-9]+)[[:space:]]+-[[:space:]]+(.+)$ ]] || continue
        new_target="${BASH_REMATCH[2]}"
        new_name="${new_target}${ext:+.$ext}"
        if [[ -e "$parent/$new_name" && "$parent/$new_name" != "$item" ]]; then
            new_name="$(_dedupe_name "$parent" "$new_target" "${ext:+.$ext}")"
        fi
        echo "  Renaming: $name -> $new_name"
        if ! mv_err=$(mv "$item" "$parent/$new_name" 2>&1); then
            warn "Could not rename: $item -> $new_name" "$mv_err"
            ((rename_errors++))
        fi
    done < <(find "${find_args[@]}" -print0 2>/dev/null)
}

_subtitle_belongs_to_stem() {
    # Return 0 if subtitle basename <name> belongs to video stem <stem>: it is
    # "<stem>.<ext>" or "<stem>.<lang>.<ext>" — a language-tagged sidecar such as
    # video.en.srt / video.eng.srt / video.pt-BR.srt (YouTube & 4K Tube write
    # these). The language tag is restricted to an ISO-code shape (2–3 letters,
    # optional -/_ region) so an unrelated ".trailer.srt" etc. can't false-match.
    # Usage: _subtitle_belongs_to_stem <name> <stem>
    local base="${1%.*}" stem="$2"
    [[ "$base" == "$stem" ]] && return 0
    if [[ "$base" == "$stem".* ]]; then
        local lang="${base#"$stem".}"
        [[ "$lang" =~ ^[A-Za-z]{2,3}([-_][A-Za-z0-9]{2,4})?$ ]] && return 0
    fi
    return 1
}

_sidecar_subtitle_for() {
    # Echo the basename of a subtitle in <input_file>'s own directory that
    # belongs to it (matched by _subtitle_belongs_to_stem, so language-tagged
    # sidecars count), or nothing. First match wins.
    # Usage: _sidecar_subtitle_for <input_file>
    local input_file="$1" dir stem sub sub_name
    dir="$(dirname "$input_file")"
    stem="$(basename "${input_file%.*}")"
    while IFS= read -r -d '' sub; do
        sub_name="$(basename "$sub")"
        if _subtitle_belongs_to_stem "$sub_name" "$stem"; then
            printf '%s' "$sub_name"
            return 0
        fi
    done < <(find -L "$dir" -maxdepth 1 -type f "${exclude_args[@]}" \( "${sub_ext_args[@]}" \) -print0 2>/dev/null)
    return 1
}

_plan_output() {
    # Decide output_dir + output_file for <input_file>, and cache embedded_track.
    # Placement rules, in order:
    #   1. lone TV episode (SxxExx)                 -> OUTPUT_DIR/<Show> - Season N/
    #   2. movie/srt pair — a matching sidecar OR    -> OUTPUT_DIR/<media>/  (its OWN
    #      an embedded English text track               folder; the .srt is moved in
    #                                                    beside it, renamed to match)
    #   3. lone plain video                         -> OUTPUT_DIR/  (flat)
    #   4. video sharing a folder (e.g. a kept       -> preserve that relative folder
    #      playlist), no subtitle                       under OUTPUT_DIR
    # Assigns the caller's output_dir / output_file / embedded_track (bash
    # dynamic scope — process_video declares them local before calling).
    # Usage: _plan_output <input_file> <sibling_count>
    local input_file="$1" sibling_count="$2" input_dir stem sub_here
    input_dir="$(dirname "$input_file")"
    stem="$(basename "${input_file%.*}")"

    embedded_track=""
    sub_here="$(_sidecar_subtitle_for "$input_file")"
    [[ -z "$sub_here" ]] && embedded_track="$(_find_eng_subtitle_track "$input_file")"

    local tv_pattern='^(.*)[._ ][Ss]([0-9]{1,2})[Ee][0-9]+'
    if [[ $sibling_count -eq 1 && "$stem" =~ $tv_pattern ]]; then
        local show_raw="${BASH_REMATCH[1]}"
        local season_num=$(( 10#${BASH_REMATCH[2]} ))
        local show_name
        show_name="$(printf '%s' "$show_raw" | perl -pe 's/[._]/ /g; s/\s{2,}/ /g; s/^\s+|\s+$//g')"
        output_dir="$OUTPUT_DIR/$show_name - Season $season_num"
        output_file="$output_dir/$stem.${OUTPUT_FORMAT}"
    elif [[ -n "$sub_here" || -n "$embedded_track" ]]; then
        output_dir="$OUTPUT_DIR/$stem"
        output_file="$output_dir/$stem.${OUTPUT_FORMAT}"
    elif [[ $sibling_count -eq 1 ]]; then
        output_dir="$OUTPUT_DIR"
        output_file="$output_dir/$stem.${OUTPUT_FORMAT}"
    else
        local relative_path="${input_file#"$STAGING_DIR"/}"
        output_file="$OUTPUT_DIR/${relative_path%.*}.${OUTPUT_FORMAT}"
        output_dir="$(dirname "$output_file")"
    fi
}

_english_audio_args() {
    # Echoes HandBrake `--audio <list>` args (in the named array) that restrict
    # the encode to English audio tracks — but ONLY when the source carries more
    # than one audio track. A single-track source is left untouched (so a lone
    # foreign-language track is never dropped), as is a multi-track source that
    # has no English-tagged stream (we keep the preset's default rather than
    # risk producing a file with no audio).
    # HandBrake numbers audio tracks 1-based in source order, so the position
    # counter below — not the ffmpeg stream index — is what gets passed through.
    # Usage: _english_audio_args <out_array> <input_file>
    local -n _out=$1
    local input_file="$2"
    _out=()

    local -a eng_positions=()
    local pos=0 total=0 idx lang
    while IFS=',' read -r idx lang; do
        ((pos++)); ((total++))
        case "${lang,,}" in
            eng|en|english) eng_positions+=("$pos") ;;
        esac
    done < <(ffprobe -v quiet -select_streams a \
        -show_entries stream=index:stream_tags=language \
        -of csv=p=0 "$input_file" 2>/dev/null)

    if (( total > 1 && ${#eng_positions[@]} > 0 )); then
        local IFS=,
        _out=(--audio "${eng_positions[*]}")
    fi
}

_find_eng_subtitle_track() {
    # Echoes the index of an English (or untagged) non-hearing-impaired
    # text-based subtitle stream in <input_file>, or nothing if none exists.
    # Preference order: eng > und/empty. Foreign-language tags are skipped.
    # The und/empty fallback applies to every container — MP4 muxers commonly
    # leave the language as `und`, but MKVs / WebM / TS files can be tagged
    # the same way when the original muxer didn't set a language.
    # ffprobe emits stream_disposition fields before stream_tags fields
    # regardless of -show_entries order, so the columns are: idx,codec,hi,lang.
    local input_file="$1"
    local text_codecs="subrip|ass|ssa|webvtt|mov_text|microdvd"
    local eng_idx="" und_idx=""
    while IFS=',' read -r idx codec hi lang; do
        [[ "$hi" == "1" ]] && continue
        [[ "$codec" =~ ^($text_codecs)$ ]] || continue
        case "${lang,,}" in
            eng) [[ -z "$eng_idx" ]] && eng_idx="$idx" ;;
            ""|und) [[ -z "$und_idx" ]] && und_idx="$idx" ;;
        esac
    done < <(ffprobe -v quiet -select_streams s \
        -show_entries stream=index,codec_name:stream_tags=language:stream_disposition=hearing_impaired \
        -of csv=p=0 "$input_file" 2>/dev/null)
    if [[ -n "$eng_idx" ]]; then printf '%s' "$eng_idx"; return 0; fi
    if [[ -n "$und_idx" ]]; then printf '%s' "$und_idx"; return 0; fi
    return 1
}

_normalise_srt() {
    # Convert <srt_path> to UTF-8 without BOM, in place. Guarantees the bytes
    # match HandBrake's --srt-codeset UTF-8 contract so multibyte glyphs
    # (♪♫, em-dashes, smart quotes, accents) survive the burn pass instead
    # of being mangled when the source SRT was Windows-1252 / ISO-8859-x.
    # Encoding detection uses uchardet when available (most reliable on
    # short SRTs), falling back to file -bi.
    local srt="$1"
    [[ -f "$srt" ]] || return 0

    # Strip a UTF-8 BOM (EF BB BF) in place — libass and some renderers
    # treat the BOM as the first cue's first character.
    if [[ "$(head -c 3 "$srt" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "efbbbf" ]]; then
        local tmp
        tmp="$(mktemp --suffix=.srt)"
        tail -c +4 "$srt" > "$tmp" && mv "$tmp" "$srt"
        echo "  Subtitle: stripped UTF-8 BOM from $(basename "$srt")"
    fi

    local enc=""
    if command -v uchardet &>/dev/null; then
        enc="$(uchardet "$srt" 2>/dev/null)"
    fi
    if [[ -z "$enc" || "$enc" == "unknown" ]]; then
        enc="$(file -bi "$srt" 2>/dev/null | sed -n 's/.*charset=//p')"
    fi
    enc="${enc,,}"

    case "$enc" in
        utf-8|us-ascii|ascii|"") return 0 ;;
    esac

    local tmp
    tmp="$(mktemp --suffix=.srt)"
    if iconv -f "$enc" -t UTF-8 "$srt" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$srt"
        echo "  Subtitle: converted $(basename "$srt") from $enc to UTF-8"
    else
        rm -f "$tmp"
        warn "SRT encoding conversion failed: $(basename "$srt")" "detected: $enc"
    fi
}

extract_subtitle() {
    # Extracts a text-based subtitle track (eng-preferred, und/empty fallback;
    # foreign tags skipped; HI disposition skipped) from <input> and writes it
    # to <target.srt>. After ffmpeg extraction the SRT is rejected if it has
    # fewer than SRT_MIN_CUES cues (scene brands / watermarks) or if it
    # contains 10+ bracket/paren pairs (likely SDH — see comment below).
    # If <target.srt> already exists, the larger file wins when the size
    # difference exceeds SRT_SIZE_THRESHOLD percent; otherwise the extracted
    # version takes precedence.
    # Usage: extract_subtitle <input> <target.srt> [<track_index>]
    # The optional track_index lets process_video pass a previously-probed
    # index so we don't re-run ffprobe on the same input.
    local input_file="$1"
    local target_srt="$2"
    local track_index="${3:-}"

    _last_extract_wrote=false
    [[ -z "$track_index" ]] && track_index=$(_find_eng_subtitle_track "$input_file")
    [[ -z "$track_index" ]] && return 0

    echo
    echo "English subtitles found in $(basename "$input_file") - extracting"

    local temp_srt
    temp_srt="$(mktemp --suffix=.srt)"
    if ! ffmpeg -nostdin -v quiet -y -i "$input_file" -map "0:$track_index" -c:s srt "$temp_srt" 2>/dev/null; then
        rm -f "$temp_srt"
        warn "Subtitle extraction failed for: $(basename "$input_file")"
        return 0
    fi

    # Reject trivially short extractions (scene brands, watermarks, etc.).
    # Allow trailing \r since extracted SRTs commonly use CRLF line endings.
    local cue_count
    cue_count=$(grep -cE $'^[0-9]+\r?$' "$temp_srt" 2>/dev/null)
    cue_count=${cue_count:-0}
    if [[ $cue_count -lt $SRT_MIN_CUES ]]; then
        rm -f "$temp_srt"
        echo "  Subtitle: extracted track has only $cue_count cue(s) — ignoring"
        return 0
    fi

    # SDH/HI heuristic: SDH tracks pepper sound-effect and speaker cues in
    # square brackets or parentheses ([door slams], (LAUGHTER), etc.). Ten or
    # more such pairs anywhere in the file is treated as a strong SDH signal;
    # a normal dialogue track may have a handful of legitimate parentheticals
    # (song titles, asides) so a low threshold causes false positives.
    local bracket_pairs
    bracket_pairs=$(grep -oE '\[[^]]*\]|\([^)]*\)' "$temp_srt" 2>/dev/null | wc -l)
    if [[ $bracket_pairs -ge 10 ]]; then
        rm -f "$temp_srt"
        echo "  Subtitle: $bracket_pairs bracket/paren pair(s) — likely SDH, ignoring"
        return 0
    fi

    if [[ -f "$target_srt" ]]; then
        local existing_size extracted_size
        existing_size=$(stat -c%s "$target_srt")
        extracted_size=$(stat -c%s "$temp_srt")

        local diff larger pct
        diff=$(( extracted_size > existing_size ? extracted_size - existing_size : existing_size - extracted_size ))
        larger=$(( extracted_size > existing_size ? extracted_size : existing_size ))
        pct=$(( diff * 100 / larger ))

        if [[ $pct -gt $SRT_SIZE_THRESHOLD ]]; then
            if [[ $extracted_size -gt $existing_size ]]; then
                mv "$temp_srt" "$target_srt"
                _last_extract_wrote=true
                ((subs_extracted++))
                echo "  Subtitle: using extracted (${pct}% larger than existing)"
            else
                rm -f "$temp_srt"
                echo "  Subtitle: keeping existing (${pct}% larger than extracted)"
            fi
        else
            mv "$temp_srt" "$target_srt"
            _last_extract_wrote=true
            ((subs_extracted++))
            echo "  Subtitle: using extracted (sizes similar, ${pct}% difference)"
        fi
    else
        mv "$temp_srt" "$target_srt"
        _last_extract_wrote=true
        ((subs_extracted++))
        echo "  Subtitle: extracted from embedded track ($cue_count cues)"
    fi
}

select_preset() {
    # Scans PRESET_DIR for JSON files, extracts each preset's name, and presents
    # a numbered menu. Sets PRESET_FILE and PRESET_NAME from the user's choice.
    local -a preset_files preset_names
    local file name

    while IFS= read -r -d '' file; do
        name="$(perl -ne 'print "$1\n" if /"PresetName"\s*:\s*"([^"]+)"/' "$file")"
        if [[ -n "$name" ]]; then
            preset_files+=("$file")
            preset_names+=("$name")
        fi
    done < <(find "$PRESET_DIR" -maxdepth 1 -name "*.json" -print0 2>/dev/null | sort -z)

    [[ ${#preset_files[@]} -eq 0 ]] && die "No preset files found in: $PRESET_DIR"

    echo "Choose preset:"
    local i
    for ((i = 0; i < ${#preset_names[@]}; i++)); do
        printf '  %d) %s\n' $((i + 1)) "${preset_names[$i]}"
    done
    echo

    local choice
    while true; do
        read -r -p "Enter number: " choice
        if [[ "$choice" =~ ^[0-9]+$ && $choice -ge 1 && $choice -le ${#preset_files[@]} ]]; then
            PRESET_FILE="${preset_files[$((choice - 1))]}"
            PRESET_NAME="${preset_names[$((choice - 1))]}"
            break
        fi
        echo "Invalid choice, try again."
    done
}


# ----- Initialisation --------------------------------------------------------

clear
print_header "Jackify"
echo "Checking prerequisites..."
echo

check_path "$DOWNLOADS_DIR" "Downloads directory"
check_file "$HANDBRAKE_CLI"  "HandBrake CLI"
check_path "$PRESET_DIR"     "Preset directory"
check_command ffmpeg          "FFmpeg"
check_command ffprobe         "FFprobe"

echo "[OK] Prerequisites met"
echo

# Build the HandBrake guard prefix: a memory-capped systemd scope + a wall-clock
# timeout, each added only if its tool is actually available and working, so the
# script still runs on a box without systemd/timeout (just without the cap).
# MemorySwapMax=0 stops a runaway from thrashing tens of GB of swap before the
# cgroup OOM-kills it — the kill stays inside the scope, the desktop survives.
HB_GUARD=()
if command -v systemd-run &>/dev/null && systemd-run --user --scope -q --collect true &>/dev/null; then
    HB_GUARD=(systemd-run --user --scope -q --collect \
        -p "MemoryMax=$HANDBRAKE_MEM_MAX" -p "MemorySwapMax=0")
    echo "[OK] HandBrake capped at $HANDBRAKE_MEM_MAX RAM (systemd scope)"
fi
if command -v timeout &>/dev/null; then
    HB_GUARD=(timeout -k 30s "$HANDBRAKE_TIMEOUT" "${HB_GUARD[@]}")
    echo "[OK] HandBrake timeout: $HANDBRAKE_TIMEOUT per encode"
fi
echo

select_preset
echo

check_file "$PRESET_FILE" "HandBrake preset file"
echo "[OK] Preset: $PRESET_NAME"
echo

mkdir -p "$STAGING_DIR"  || die "Could not create staging directory: $STAGING_DIR"
mkdir -p "$OUTPUT_DIR"   || die "Could not create output directory: $OUTPUT_DIR"

# Flatten any 4K Tube YouTube downloads nested in staging up to the staging root
# (and delete the 4ktube folder) before the copy/convert scans below see them.
flatten_4ktube_staging

# ----- Step 1: Copy from downloads -------------------------------------------

ext_args=()
build_ext_args ext_args

sub_ext_args=()
build_ext_args sub_ext_args SUBTITLE_EXTENSIONS

exclude_args=()
build_exclude_args exclude_args

media_ext_args=("${ext_args[@]}" "-o" "${sub_ext_args[@]}")

mapfile -d '' downloads_list < <(find -L "$DOWNLOADS_DIR" -type f "${exclude_args[@]}" \( "${ext_args[@]}" \) -print0)
mapfile -d '' staging_list  < <(find -L "$STAGING_DIR"   -type f "${exclude_args[@]}" \( "${ext_args[@]}" \) -print0)

do_copy_from_downloads() {
    print_header "STEP 1: Copying from Downloads"
    local file
    for file in "${downloads_list[@]}"; do
        copy_file_to_input "$file"
    done
    while IFS= read -r -d '' file; do
        copy_file_to_input "$file"
    done < <(find -L "$DOWNLOADS_DIR" -type f "${exclude_args[@]}" \( "${sub_ext_args[@]}" \) -print0)
    pause_and_clear
}

if [[ ${#downloads_list[@]} -gt 0 && ${#staging_list[@]} -eq 0 ]]; then
    do_copy_from_downloads
elif [[ ${#staging_list[@]} -gt 0 && ${#downloads_list[@]} -gt 0 ]]; then
    echo "Both downloads and staging folders have files."
    echo
    read -r -p "Copy new files from downloads into staging? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
        do_copy_from_downloads
    else
        echo "Skipping copy — using existing staging folder contents."
        echo
        clear
    fi
else
    echo "Downloads folder is empty — skipping copy, using staging folder."
    echo
    clear
fi

# ----- Step 2: Convert -------------------------------------------------------

mapfile -d '' video_list < <(find -L "$STAGING_DIR" -type f "${exclude_args[@]}" \( "${ext_args[@]}" \) -print0)
total_videos=${#video_list[@]}

if [[ $total_videos -eq 0 ]]; then
    die "No videos found in staging folder. Nothing to do."
else
    print_header "STEP 2: Converting $total_videos $([ "$total_videos" -eq 1 ] && echo video || echo videos) - Preset: $PRESET_NAME"
    for ((i = 0; i < total_videos; i++)); do
        process_video "${video_list[$i]}" $((i + 1)) "$total_videos"
    done
fi

pause_and_clear

# ----- Step 3: Clean up names ------------------------------------------------

print_header "STEP 3: Cleaning Up Names"

remove_title_number "$OUTPUT_DIR" --recursive
remove_title_number "$OUTPUT_DIR" --dirs

echo "Stripping source tags..."
strip_source_tags "$OUTPUT_DIR" --recursive
strip_source_tags "$OUTPUT_DIR" --dirs
echo

echo "Cleaning file names..."
rename_in_path '[._-](?=[^.]*\.)' ' ' "$OUTPUT_DIR" --recursive
rename_in_path '\s{2,}' ' ' "$OUTPUT_DIR" --recursive
echo

echo "Cleaning folder names..."
rename_in_path '[._-]' ' ' "$OUTPUT_DIR" --dirs
rename_in_path '\s{2,}' ' ' "$OUTPUT_DIR" --dirs
echo

echo "Applying title case..."
apply_title_case "$OUTPUT_DIR" --recursive
apply_title_case "$OUTPUT_DIR" --dirs
echo

echo "Cleanup complete!"
echo
pause_and_clear

# ----- Final report ----------------------------------------------------------

print_header "Processing Complete"
printf 'Preset:                %s\n' "$PRESET_NAME"
echo
printf 'Videos found:          %d\n' "$total_videos"
printf 'Videos converted:      %d\n' "$videos_converted"
echo  "------------------------"
printf 'Found subs:            %d\n' "$subs_found"
printf 'Found subs burned:     %d\n' "$found_subs_burned"
printf 'Subs extracted:        %d\n' "$subs_extracted"
printf 'Extracted subs burned: %d\n' "$extracted_subs_burned"
echo  "------------------------"
echo  "Name cleanup:          Completed"
printf 'Videos skipped:        %d\n' "$videos_skipped"
if (( videos_failed + files_failed + rename_errors > 0 )); then
    echo
    [[ $videos_failed -gt 0 ]] && printf 'Videos failed:         %d\n' "$videos_failed"
    [[ $files_failed  -gt 0 ]] && printf 'Copy failures:         %d\n' "$files_failed"
    [[ $rename_errors -gt 0 ]] && printf 'Rename errors:         %d\n' "$rename_errors"
fi
echo
[[ -f "$ERROR_LOG" ]] && echo "Errors logged to:      $ERROR_LOG"
echo

read -r -p "Clean staging folder? [y/N] " answer
if [[ "${answer,,}" == "y" ]]; then
    echo "Cleaning staging folder..."
    find "$STAGING_DIR" -mindepth 1 -delete
    echo "Done."
fi
echo
print_header "Done"
read -r -s -n1 -p "Press any key to quit . . . "
echo
