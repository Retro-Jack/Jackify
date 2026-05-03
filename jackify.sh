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

VIDEO_EXTENSIONS=(avi mkv mov wmv flv mp4 mpeg mpg m4v ts vob webm)
SUBTITLE_EXTENSIONS=(srt ass ssa vtt sub idx sup)
EXCLUDED_BASENAMES=(sample preview featurette)

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
    printf '\n%s\n%*s%s\n%s\n' "$border" "$pad" '' "$title" "$border"
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
        local stem ext n
        stem="$(basename "${target_file%.*}")"
        ext="${target_file##*.}"
        n=1
        while [[ -f "$target_dir/${stem}(${n}).${ext}" ]]; do
            n=$((n + 1))
        done
        target_file="$target_dir/${stem}(${n}).${ext}"
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
    # already exists. Output destination depends on context:
    #   - Sibling videos in the same folder       -> preserve relative path under OUTPUT_DIR.
    #   - Lone TV episode (SxxExx pattern)        -> OUTPUT_DIR/<Show> - Season <N>/.
    #   - Lone video with a sibling subtitle OR
    #     an embedded text-based subtitle track   -> OUTPUT_DIR/<source folder>/
    #                                                (or OUTPUT_DIR/<stem>/ if at staging root)
    #                                                so the .mp4, .srt, and burned-subs files stay grouped.
    #   - Otherwise                               -> OUTPUT_DIR/ (flat).
    # On success: moves matching subtitle files from staging to output_dir,
    # extracts any embedded eng/und text track directly into output_dir, and
    # if a same-stem .srt is present there, runs a second HandBrake pass to
    # produce "<stem> burned subs.mp4".
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

    local output_file output_dir
    if [[ $sibling_count -eq 1 ]]; then
        local tv_pattern='^(.*)[._ ][Ss]([0-9]{1,2})[Ee][0-9]+'
        if [[ "$stem" =~ $tv_pattern ]]; then
            local show_raw="${BASH_REMATCH[1]}"
            local season_num=$(( 10#${BASH_REMATCH[2]} ))
            local show_name
            show_name="$(printf '%s' "$show_raw" | perl -pe 's/[._]/ /g; s/\s{2,}/ /g; s/^\s+|\s+$//g')"
            output_dir="$OUTPUT_DIR/$show_name - Season $season_num"
        else
            local sub_count
            sub_count=$(find -L "$input_dir" -maxdepth 1 -type f "${exclude_args[@]}" \( "${sub_ext_args[@]}" \) | wc -l)
            [[ $sub_count -eq 0 ]] && embedded_track=$(_find_eng_subtitle_track "$input_file")
            if [[ ($sub_count -gt 0 || -n "$embedded_track") && "$input_dir" != "$STAGING_DIR" ]]; then
                output_dir="$OUTPUT_DIR/$(basename "$input_dir")"
            elif [[ -n "$embedded_track" ]]; then
                output_dir="$OUTPUT_DIR/$stem"
            else
                output_dir="$OUTPUT_DIR"
            fi
        fi
        output_file="$output_dir/$stem.${OUTPUT_FORMAT}"
    else
        local relative_path="${input_file#"$STAGING_DIR"/}"
        output_file="$OUTPUT_DIR/${relative_path%.*}.${OUTPUT_FORMAT}"
        output_dir="$(dirname "$output_file")"
    fi

    local out_mkdir_err
    if ! out_mkdir_err=$(mkdir -p "$output_dir" 2>&1); then
        warn "Could not create output directory: $output_dir — skipping $(basename "$input_file")" "$out_mkdir_err"
        ((videos_failed++))
        return
    fi

    if [[ -f "$output_file" ]]; then
        echo "[$current_num/$total_num] SKIPPING: $(basename "$input_file") (already converted)"
        ((videos_skipped++))
        return
    fi

    echo
    echo "$(basename "$input_file")"

    # --preset-import-file + --preset are both required to select a named
    # preset from a JSON file (HandBrake quirk).
    local hb_ok hb_log
    hb_log=$(mktemp)
    printf '  [%s]   0%%' "$EMPTY_BAR"
    _current_output="$output_file"
    { "$HANDBRAKE_CLI" \
        -i "$input_file" \
        -o "$output_file" \
        --preset-import-file "$PRESET_FILE" \
        --preset "$PRESET_NAME" </dev/null 2>&1; } | tee "$hb_log" | tr '\r' '\n' | show_progress "  "
    hb_ok=${PIPESTATUS[0]}

    if [[ $hb_ok -eq 0 ]]; then
        _current_output=""
        echo "[SUCCESS] Conversion complete"
        ((videos_converted++))

        local had_sibling_srt=false
        [[ -f "$input_dir/$stem.srt" ]] && had_sibling_srt=true

        # Move sibling subtitles (any extension) from staging to output_dir
        # before extraction, so the .srt that extract_subtitle compares against
        # already lives at its final home and the burn pass reads from there.
        while IFS= read -r -d '' sub; do
            local sub_name
            sub_name="$(basename "$sub")"
            if [[ "${sub_name%.*}" == "$stem" ]]; then
                echo
                echo "    Moving subtitles: $sub_name"
                local sub_mv_err
                if ! sub_mv_err=$(mv "$sub" "$output_dir/" 2>&1); then
                    warn "Subtitle move failed: $sub_name" "src: $sub
dst: $output_dir/
$sub_mv_err"
                fi
            fi
        done < <(find -L "$input_dir" -type f "${exclude_args[@]}" \( "${sub_ext_args[@]}" \) -print0 2>/dev/null)

        extract_subtitle "$input_file" "$output_dir/$stem.srt" "$embedded_track"
        $had_sibling_srt && ((subs_found++))

        local srt_path="$output_dir/$stem.srt"
        if [[ -f "$srt_path" ]]; then
            local burned_file="$output_dir/$stem burned subs.${OUTPUT_FORMAT}"
            if [[ -f "$burned_file" ]]; then
                echo "  [BURNED SUBS] Already exists, skipping"
            else
                echo "    Burning subtitles: $(basename "$srt_path")"
                printf '    [%s]   0%%' "$EMPTY_BAR"
                _current_output="$burned_file"
                local burn_log
                burn_log=$(mktemp)
                { "$HANDBRAKE_CLI" \
                    -i "$input_file" \
                    -o "$burned_file" \
                    --preset-import-file "$PRESET_FILE" \
                    --preset "$PRESET_NAME" \
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
    # Strips bracketed content, technical source tags (1080p, x264, encoder
    # group names, …) and orphan separators from basenames. Bare four-digit
    # years are wrapped in parentheses.
    # Usage: strip_source_tags <directory> [--recursive] [--dirs]
    local directory="$1"
    local recursive=false dirs_only=false
    shift 1
    _parse_find_opts recursive dirs_only "$@"

    local perl_script='
my $t = qr/2160p|1080p|720p|480p|4K|UHD|
    Blu-?Ray|BDRip|BRRip|WEB-DL|WEBRip|HDTV|DVDRip|DVDScr|AMZN|NF|HULU|DSNP|
    H\.?265|H\.?264|x265|x264|XviD|DivX|HEVC|AVC|
    TrueHD|Atmos|DTS-HD|DTS|DD5\.1|AC3|AAC(?:\d+\.\d+)?|FLAC|MP3|7\.1|5\.1|DDP5.1|
    HDR10\+|HDR10|HDR|SDR|DoVi|10bit|8bit|HLG|
    PROPER|REPACK|EXTENDED|THEATRICAL|UNRATED|IMAX|
    YIFY|YTS|RARBG|SPARKS|GECKOS|DRONES|ROVERS|LOL|DIMENSION|KILLERS|FLEET|IMMERSE|BATV|DEFLATE|TBS|
    CtrlHD|DON|EbP|NTb|Tigole|QxR|UTR|HiDt|HDMaNiAcS|GALAXYRG265|
    HorribleSubs|Erai-raws|SubsPlease|Judas|EMBER|AnimeRG|
    TERMiNAL|EPSiLON|FraMeSToR|WiLDCAT|COASTER|
    NTG|FLUX|ION10|CAKES|PECULATE|
    aXXo|ViTE|DiAMOND|WAF|ESiR|BONE/xi;
s/\s*\[[^\]]*\]//g;
s/\s*\(\s*$t\s*\)\s*//gi;
s/(?<![a-zA-Z0-9])$t(?![a-zA-Z0-9])//gi;
s/[.\-_]{2,}([^.])/$1 ? ".$1" : ""/ge;
s/[.\-_]+$//;
s/(?<![\(\d])\b(19\d{2}|20\d{2})\b(?!\))/($1)/g;
s/\s{2,}/ /g;
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

    local item parent name ext target new_target new_name n mv_err
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
            n=1
            while [[ -e "$parent/${new_target}(${n})${ext:+.$ext}" ]]; do
                n=$((n + 1))
            done
            new_name="${new_target}(${n})${ext:+.$ext}"
        fi
        echo "  Renaming: $name -> $new_name"
        if ! mv_err=$(mv "$item" "$parent/$new_name" 2>&1); then
            warn "Could not rename: $item -> $new_name" "$mv_err"
            ((rename_errors++))
        fi
    done < <(find "${find_args[@]}" -print0 2>/dev/null)
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
echo
echo "Checking prerequisites..."
echo

check_path "$DOWNLOADS_DIR" "Downloads directory"
check_file "$HANDBRAKE_CLI"  "HandBrake CLI"
check_path "$PRESET_DIR"     "Preset directory"
check_command ffmpeg          "FFmpeg"
check_command ffprobe         "FFprobe"

echo "[OK] Prerequisites met"
echo
select_preset
echo

check_file "$PRESET_FILE" "HandBrake preset file"
echo "[OK] Preset: $PRESET_NAME"
echo

mkdir -p "$STAGING_DIR"  || die "Could not create staging directory: $STAGING_DIR"
mkdir -p "$OUTPUT_DIR"   || die "Could not create output directory: $OUTPUT_DIR"

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
    echo
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
echo
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
echo
read -r -s -n1 -p "Press any key to quit . . . "
echo
