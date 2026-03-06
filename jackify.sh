#!/usr/bin/env bash
# =============================================================================
# Jackify — Automated video conversion and renaming
# =============================================================================
# Copies videos from a downloads folder to a staging folder, converts them
# with HandBrakeCLI, then cleans up output filenames and folder names.
#
# Steps:
#   1. Copy from DOWNLOADS_DIR to STAGING_DIR (skipped if downloads is empty)
#   2. Convert all videos in STAGING_DIR using the selected HandBrake preset
#   3. Strip source tags, clean separators, and apply title case to OUTPUT_DIR
#
# Requires: HandBrakeCLI  (other dependencies are standard on any Linux system)
#
# Options:
#   -jack       Use Jack 1080 preset (required — no default)
#   -loren      Use Loren 720 preset (required — no default)
#   -l, --log   Log output to jackify_log.txt
#   -h, --help  Show this help message
# =============================================================================

set -uo pipefail

# ----- Configuration ---------------------------------------------------------

DOWNLOADS_DIR="/mnt/misc/Downloads/_Torrents/Finished/Files"
STAGING_DIR="/mnt/multimedia/Conversion/Handbrake/1) Staging"
OUTPUT_DIR="/mnt/multimedia/Conversion/Handbrake/2) Done"
HANDBRAKE_CLI="/usr/bin/HandBrakeCLI"
PRESET_DIR="/mnt/applications/Linux Applications/_Handy Scripts/Jackify/Handbrake Presets"
PRESET_FILE=""
PRESET_NAME=""

OUTPUT_FORMAT="mp4"
PROCESS_DELAY=2

VIDEO_EXTENSIONS=(avi mkv mov wmv flv mp4 mpeg mpg m4v ts vob webm)

LOG_FILE="$OUTPUT_DIR/jackify_log.txt"
LOG_ENABLED=false

# ----- Counters --------------------------------------------------------------

files_failed=0
videos_converted=0
videos_skipped=0
videos_failed=0
rename_errors=0

# Set by process_video while HandBrake is running; the EXIT trap removes the
# partial output file if the script is interrupted mid-conversion.
_current_output=""

# ----- Functions -------------------------------------------------------------

print_header() {
    printf '\n==================================================\n'
    printf '      %s\n' "$1"
    printf '==================================================\n'
}

pause_and_clear() {
    # Counts down from 10, then clears. Press any key to skip the wait.
    local i
    echo
    for i in 10 9 8 7 6 5 4 3 2 1; do
        printf '\rContinuing in %d... (press any key to skip)  ' "$i"
        read -r -t 1 -n1 && break
    done
    clear
}

log_message() {
    $LOG_ENABLED || return 0
    printf '%s - %s\n' "$(date '+%H:%M:%S %d/%m/%Y')" "$1" >> "$LOG_FILE"
}

die() {
    printf '[ERROR] %s\n' "$1" >&2
    log_message "ERROR: $1"
    exit 1
}

warn() {
    printf '[WARN]  %s\n' "$1" >&2
    log_message "WARN: $1"
}

_on_exit() {
    [[ -n "$_current_output" && -f "$_current_output" ]] && rm -f "$_current_output"
    log_message "Session ended"
}
trap '_on_exit' EXIT

check_path() {
    [[ -d "$1" ]] || die "Cannot find directory: $1 ($2)"
}

check_file() {
    [[ -f "$1" ]] || die "Cannot find file: $1 ($2)"
}

build_ext_args() {
    # Builds a find -name expression matching all VIDEO_EXTENSIONS.
    # Populates the named array variable passed as $1 with the resulting args.
    local -n _out=$1
    local first=true
    for ext in "${VIDEO_EXTENSIONS[@]}"; do
        if $first; then
            _out+=("-name" "*.${ext}")
            first=false
        else
            _out+=("-o" "-name" "*.${ext}")
        fi
    done
}

copy_file_to_input() {
    # Copies a single file from DOWNLOADS_DIR to STAGING_DIR, preserving its
    # relative path.
    local source_file="$1"
    local relative_path="${source_file#"$DOWNLOADS_DIR"/}"
    local target_file="$STAGING_DIR/$relative_path"
    local target_dir
    target_dir="$(dirname "$target_file")"

    if ! mkdir -p "$target_dir"; then
        warn "Could not create directory: $target_dir — skipping $(basename "$source_file")"
        files_failed=$((files_failed + 1))
        return
    fi

    if [[ ! -f "$target_file" ]]; then
        echo "  Copying: $(basename "$source_file") -> $(basename "$target_file")"
        if ! cp "$source_file" "$target_file"; then
            warn "Copy failed: $source_file"
            files_failed=$((files_failed + 1))
        fi
    fi
}

process_video() {
    # Converts a single video file using HandBrakeCLI. Skips files that have
    # already been converted. Output streams live to the terminal; --log
    # additionally tees it to the log file.
    local input_file="$1"
    local current_num="$2"
    local total_num="$3"

    local relative_path="${input_file#"$STAGING_DIR"/}"
    local relative_noext="${relative_path%.*}"
    local output_file="$OUTPUT_DIR/${relative_noext}.${OUTPUT_FORMAT}"
    local output_dir
    output_dir="$(dirname "$output_file")"

    if ! mkdir -p "$output_dir"; then
        warn "Could not create output directory: $output_dir — skipping $(basename "$input_file")"
        videos_failed=$((videos_failed + 1))
        return
    fi

    if [[ -f "$output_file" ]]; then
        echo "[$current_num/$total_num] SKIPPING: $(basename "$input_file") (already converted)"
        videos_skipped=$((videos_skipped + 1))
        return
    fi

    clear
    print_header "Converting Video $current_num of $total_num"
    echo
    echo "Source: $(basename "$input_file")"
    echo "Output: $output_file"
    echo "Preset: $PRESET_NAME"
    echo
    echo "Converting (this may take several minutes)..."
    echo

    log_message "Converting: $(basename "$input_file")"

    # _current_output is cleared by the EXIT trap on interruption, which
    # removes the partial file. --preset-import-file + --preset are both
    # required to select a named preset from a JSON file.
    local hb_ok
    _current_output="$output_file"
    if $LOG_ENABLED; then
        "$HANDBRAKE_CLI" \
            -i "$input_file" \
            -o "$output_file" \
            --preset-import-file "$PRESET_FILE" \
            --preset "$PRESET_NAME" 2>&1 | tee -a "$LOG_FILE"
        hb_ok=${PIPESTATUS[0]}
    else
        "$HANDBRAKE_CLI" \
            -i "$input_file" \
            -o "$output_file" \
            --preset-import-file "$PRESET_FILE" \
            --preset "$PRESET_NAME" 2>&1
        hb_ok=$?
    fi

    if [[ $hb_ok -eq 0 ]]; then
        _current_output=""
        echo "[SUCCESS] Conversion complete"
        videos_converted=$((videos_converted + 1))
    else
        _current_output=""
        rm -f "$output_file"
        warn "HandBrake failed on: $(basename "$input_file")${LOG_ENABLED:+ (see log for details)}"
        videos_failed=$((videos_failed + 1))
    fi

    sleep "$PROCESS_DELAY"
}

rename_in_path() {
    # Renames files or directories in a path using a Perl regex substitution.
    # Usage: rename_in_path <pattern> <replacement> <directory> [--recursive] [--dirs]
    #
    # --dirs recurses with -depth so children are renamed before parents, preventing
    # path invalidation when a parent directory is renamed mid-traversal.
    local pattern="$1"
    local replacement="$2"
    local directory="$3"
    local recursive=false
    local dirs_only=false
    shift 3

    for arg in "$@"; do
        case "$arg" in
            --recursive) recursive=true ;;
            --dirs)      dirs_only=true ;;
        esac
    done

    local -a find_args=("$directory")

    if $dirs_only; then
        find_args+=("-depth" "-mindepth" "1" "-type" "d")
    else
        find_args+=("-mindepth" "1")
        $recursive || find_args+=("-maxdepth" "1")
        find_args+=("-type" "f")
    fi

    while IFS= read -r -d '' item; do
        local parent name new_name
        parent="$(dirname "$item")"
        name="$(basename "$item")"
        if ! new_name="$(printf '%s' "$name" | perl -pe "s/$pattern/$replacement/gi; s/[. ]+\$//" 2>/dev/null)"; then
            warn "Perl regex failed on: $name (pattern: $pattern)"
            rename_errors=$((rename_errors + 1))
            continue
        fi

        if [[ -n "$new_name" && "$new_name" != "$name" ]]; then
            if [[ -e "$parent/$new_name" ]]; then
                warn "Rename skipped (target exists): $name -> $new_name"
                rename_errors=$((rename_errors + 1))
                continue
            fi
            echo "  Renaming: $name -> $new_name"
            if ! mv "$item" "$parent/$new_name"; then
                warn "Could not rename: $item"
                rename_errors=$((rename_errors + 1))
            fi
        fi
    done < <(find "${find_args[@]}" -print0 2>/dev/null)
}

strip_source_tags() {
    # Strips common source release tags from filenames and directory names.
    # All square-bracketed content is removed unconditionally. Known technical
    # tags in parentheses are removed; years e.g. "(2007)" are preserved.
    # Orphaned separators left behind are cleaned up afterwards.
    # Usage: strip_source_tags <directory> [--recursive] [--dirs]
    local directory="$1"
    local recursive=false
    local dirs_only=false
    shift 1

    for arg in "$@"; do
        case "$arg" in
            --recursive) recursive=true ;;
            --dirs)      dirs_only=true ;;
        esac
    done

    local -a find_args=("$directory")
    if $dirs_only; then
        find_args+=("-depth" "-mindepth" "1" "-type" "d")
    else
        find_args+=("-mindepth" "1")
        $recursive || find_args+=("-maxdepth" "1")
        find_args+=("-type" "f")
    fi

    local perl_script='
my $t = qr/2160p|1080p|720p|480p|4K|UHD|
    Blu-?Ray|BDRip|BRRip|WEB-DL|WEBRip|HDTV|DVDRip|DVDScr|AMZN|NF|HULU|DSNP|
    H\.?265|H\.?264|x265|x264|XviD|DivX|HEVC|AVC|
    TrueHD|Atmos|DTS-HD|DTS|DD5\.1|AC3|AAC|FLAC|MP3|7\.1|5\.1|
    HDR10\+|HDR10|HDR|SDR|DoVi|10bit|8bit|HLG|
    PROPER|REPACK|EXTENDED|THEATRICAL|UNRATED|IMAX|
    YIFY|YTS/xi;
s/\s*\[[^\]]*\]//g;
s/\s*\(\s*$t\s*\)\s*//gi;
s/(?<![a-zA-Z0-9])$t(?![a-zA-Z0-9])//gi;
s/[.\-_]{2,}([^.])/$1 ? ".$1" : ""/ge;
s/[.\-_]+$//;
s/\s{2,}/ /g;
s/^\s+|\s+$//g;'

    while IFS= read -r -d '' item; do
        local parent name new_name
        parent="$(dirname "$item")"
        name="$(basename "$item")"

        if ! new_name="$(printf '%s' "$name" | perl -pe "$perl_script" 2>/dev/null)"; then
            warn "Tag stripping failed on: $name"
            rename_errors=$((rename_errors + 1))
            continue
        fi

        if [[ -n "$new_name" && "$new_name" != "$name" ]]; then
            if [[ -e "$parent/$new_name" ]]; then
                warn "Rename skipped (target exists): $name -> $new_name"
                rename_errors=$((rename_errors + 1))
                continue
            fi
            echo "  Renaming: $name -> $new_name"
            if ! mv "$item" "$parent/$new_name"; then
                warn "Could not rename: $item"
                rename_errors=$((rename_errors + 1))
            fi
        fi
    done < <(find "${find_args[@]}" -print0 2>/dev/null)
}

apply_title_case() {
    # Applies title case to filenames and directory names. Minor words (a, an,
    # the, and, etc.) are kept lowercase unless they start the name. All-uppercase
    # words (acronyms such as DVD, HD, TV) are left untouched. For files, title
    # case is applied to the stem only — the extension is preserved as-is.
    # Usage: apply_title_case <directory> [--recursive] [--dirs]
    local directory="$1"
    local recursive=false
    local dirs_only=false
    shift 1

    for arg in "$@"; do
        case "$arg" in
            --recursive) recursive=true ;;
            --dirs)      dirs_only=true ;;
        esac
    done

    local -a find_args=("$directory")

    if $dirs_only; then
        find_args+=("-depth" "-mindepth" "1" "-type" "d")
    else
        find_args+=("-mindepth" "1")
        $recursive || find_args+=("-maxdepth" "1")
        find_args+=("-type" "f")
    fi

    local perl_script='
my @minor = qw(a an the and but or nor for so yet at by in of on to up as);
s/\b(\w+)\b/do{
    my $orig=$1; my $w=lc($1);
    ($orig eq uc($orig) && length($orig)>1) ? $orig :
    (grep{$_ eq $w}@minor) ? $w : ucfirst($w)
}/ge;
s/^(\w)/uc($1)/e'

    while IFS= read -r -d '' item; do
        local parent name stem ext new_name new_stem
        parent="$(dirname "$item")"
        name="$(basename "$item")"
        stem="${name%.*}"
        ext="${name##*.}"

        if [[ "$stem" == "$name" ]]; then
            if ! new_name="$(printf '%s' "$name" | perl -pe "$perl_script" 2>/dev/null)"; then
                warn "Title case failed on: $name"
                rename_errors=$((rename_errors + 1))
                continue
            fi
        else
            if ! new_stem="$(printf '%s' "$stem" | perl -pe "$perl_script" 2>/dev/null)"; then
                warn "Title case failed on: $name"
                rename_errors=$((rename_errors + 1))
                continue
            fi
            new_name="$new_stem.$ext"
        fi

        if [[ -n "$new_name" && "$new_name" != "$name" ]]; then
            if [[ -e "$parent/$new_name" ]]; then
                warn "Rename skipped (target exists): $name -> $new_name"
                rename_errors=$((rename_errors + 1))
                continue
            fi
            echo "  Renaming: $name -> $new_name"
            if ! mv "$item" "$parent/$new_name"; then
                warn "Could not rename: $item"
                rename_errors=$((rename_errors + 1))
            fi
        fi
    done < <(find "${find_args[@]}" -print0 2>/dev/null)
}

remove_title_number() {
    # Strips HandBrake DVD title number prefixes ("## - name.ext" -> "name.ext").
    # If stripping would cause a filename collision, appends (1), (2), etc.
    local filepath filename stem ext new_stem new_name n
    filepath="$(dirname "$1")"
    filename="$(basename "$1")"
    stem="${filename%.*}"
    ext="${filename##*.}"

    [[ "$stem" =~ ^([0-9]+)[[:space:]]+-[[:space:]]+(.+)$ ]] || return 0

    new_stem="${BASH_REMATCH[2]}"
    new_name="${new_stem}.${ext}"

    if [[ -f "$filepath/$new_name" ]]; then
        n=1
        while [[ -f "$filepath/${new_stem}(${n}).${ext}" ]]; do
            n=$((n + 1))
        done
        new_name="${new_stem}(${n}).${ext}"
    fi

    echo "  Renaming: $filename -> $new_name"
    if ! mv "$filepath/$filename" "$filepath/$new_name"; then
        warn "Could not rename: $filepath/$filename"
        rename_errors=$((rename_errors + 1))
    fi
}

# ----- Argument parsing ------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        -l|--log)   LOG_ENABLED=true ;;
        -loren)     PRESET_FILE="$PRESET_DIR/Loren 720.json"; PRESET_NAME="Loren 720" ;;
        -jack)      PRESET_FILE="$PRESET_DIR/Jack 1080.json"; PRESET_NAME="Jack 1080" ;;
        -h|--help)
            printf 'Usage: %s [OPTIONS]\n\n' "$(basename "$0")"
            printf 'Options:\n'
            printf '  -jack       Use Jack 1080 preset\n'
            printf '  -loren      Use Loren 720 preset\n'
            printf '  -l, --log   Enable logging to jackify_log.txt\n'
            printf '  -h, --help  Show this help message\n'
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[[ -z "$PRESET_NAME" ]] && die "No preset selected. Use -jack or -loren."

# ----- Initialisation --------------------------------------------------------

clear
print_header "Jackify"
echo
$LOG_ENABLED && echo "Log file: $LOG_FILE"
log_message "Session started"

echo "Checking prerequisites..."
echo

check_path "$DOWNLOADS_DIR" "Downloads directory"
check_file "$HANDBRAKE_CLI"  "HandBrake CLI"
check_file "$PRESET_FILE"    "HandBrake preset file"

echo "[OK] All prerequisites met"
echo

mkdir -p "$STAGING_DIR"  || die "Could not create staging directory: $STAGING_DIR"
mkdir -p "$OUTPUT_DIR"   || die "Could not create output directory: $OUTPUT_DIR"

# ----- Step 1: Copy from downloads -------------------------------------------

ext_args=()
build_ext_args ext_args

mapfile -d '' downloads_list < <(find "$DOWNLOADS_DIR" -type f \( "${ext_args[@]}" \) -print0)

if [[ ${#downloads_list[@]} -gt 0 ]]; then
    print_header "STEP 1: Copying from Downloads"

    for file in "${downloads_list[@]}"; do
        copy_file_to_input "$file"
    done

    pause_and_clear
else
    echo "Downloads folder is empty — skipping copy, using staging folder."
    echo
fi

# ----- Step 2: Convert -------------------------------------------------------

print_header "STEP 2: Converting Videos"

mapfile -d '' video_list < <(find "$STAGING_DIR" -type f \( "${ext_args[@]}" \) -print0)
total_videos=${#video_list[@]}

if [[ $total_videos -eq 0 ]]; then
    die "No videos found in staging folder. Nothing to do."
else
    echo "Found $total_videos video(s) to process"
    echo
    for ((i = 0; i < total_videos; i++)); do
        process_video "${video_list[$i]}" $((i + 1)) "$total_videos"
    done
fi

pause_and_clear

# ----- Step 3: Clean up names ------------------------------------------------

print_header "STEP 3: Cleaning Up Names"

while IFS= read -r -d '' file; do
    remove_title_number "$file"
done < <(find "$OUTPUT_DIR" -type f -name "*.${OUTPUT_FORMAT}" -print0)

echo "Stripping source tags..."
strip_source_tags "$OUTPUT_DIR" --recursive
strip_source_tags "$OUTPUT_DIR" --dirs

echo "Cleaning file names..."
rename_in_path '[._-](?=[^.]*\.)' ' ' "$OUTPUT_DIR" --recursive
rename_in_path '\s{2,}' ' ' "$OUTPUT_DIR" --recursive

echo "Cleaning folder names..."
rename_in_path '[._-]' ' ' "$OUTPUT_DIR" --dirs
rename_in_path '\s{2,}' ' ' "$OUTPUT_DIR" --dirs

echo "Applying title case..."
apply_title_case "$OUTPUT_DIR" --recursive
apply_title_case "$OUTPUT_DIR" --dirs

echo "Cleanup complete!"
echo
pause_and_clear

# ----- Final report ----------------------------------------------------------

print_header "Processing Complete"
echo
printf 'Videos found:     %d\n' "$total_videos"
printf 'Videos converted: %d\n' "$videos_converted"
printf 'Videos skipped:   %d\n' "$videos_skipped"
[[ $videos_failed  -gt 0 ]] && printf 'Videos failed:    %d\n' "$videos_failed"
[[ $files_failed   -gt 0 ]] && printf 'Copy failures:    %d\n' "$files_failed"
[[ $rename_errors  -gt 0 ]] && printf 'Rename errors:    %d\n' "$rename_errors"
echo "Name cleanup:     Completed"
echo
$LOG_ENABLED && echo "Full details available in: $LOG_FILE"
echo

read -r -p "Clean staging folder? [y/N] " answer
if [[ "${answer,,}" == "y" ]]; then
    echo "Cleaning staging folder..."
    find "$STAGING_DIR" -mindepth 1 -delete
    echo "Done."
fi
echo
print_header "Done"
