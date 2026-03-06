#!/usr/bin/env bash
# =============================================================================
# VIDEO CONVERSION AND RENAMING AUTOMATION SCRIPT
# =============================================================================
# 1. Copies videos from source folder to input folder (preserving structure),
#    renaming HandBrake DVD title numbers ("## - name.ext" -> "DVD Title ##.ext")
# 2. Converts videos using HandBrakeCLI with a custom preset
# 3. Cleans up file and folder names (optional)
#
# Requires: bash >= 4.4, perl, GNU find, HandBrakeCLI
#
# Options:
#   -l, --log   Enable logging to jackify_log.txt
#   -d, --dvd   Rename HandBrake title numbers on copy ("## - name" -> "DVD Title ##")
#   -loren      Use Loren 720 preset
#   -jack       Use Jack 1080 preset
# =============================================================================

set -uo pipefail

# ----------------------------- CONFIGURATION ---------------------------------

SOURCE_DIR="/mnt/misc/Downloads/_Torrents/Finished/Files"
INPUT_DIR="/mnt/multimedia/Conversion/Handbrake/Input"
OUTPUT_DIR="/mnt/multimedia/Conversion/Handbrake/Output"
HANDBRAKE_CLI="/usr/bin/HandBrakeCLI"
PRESET_DIR="/mnt/applications/Linux Applications/_Handy Scripts/Jackify/Handbrake Presets"
PRESET_FILE=""
PRESET_NAME=""

OUTPUT_FORMAT="mp4"
ENABLE_CLEANUP="true"
PROCESS_DELAY=2
DVD_MODE=false

VIDEO_EXTENSIONS=(avi mkv mov wmv flv mp4 mpeg mpg m4v ts vob webm)

LOG_FILE="$(dirname "$(realpath "$0")")/jackify_log.txt"
LOG_ENABLED=false

# ----------------------------- COUNTERS --------------------------------------

files_copied=0
files_failed=0
videos_converted=0
videos_skipped=0
videos_failed=0
rename_errors=0

# Tracks the output file currently being written; cleared by the EXIT trap.
_current_output=""

# ----------------------------- FUNCTIONS -------------------------------------

print_header() {
    printf '\n==================================================\n'
    printf '      %s\n' "$1"
    printf '==================================================\n'
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

_on_exit() {
    [[ -n "$_current_output" && -f "$_current_output" ]] && rm -f "$_current_output"
    log_message "Session ended"
}
trap '_on_exit' EXIT

warn() {
    printf '[WARN]  %s\n' "$1" >&2
    log_message "WARN: $1"
}

check_path() {
    [[ -d "$1" ]] || die "Cannot find directory: $1 ($2)"
}

check_file() {
    [[ -f "$1" ]] || die "Cannot find file: $1 ($2)"
}

# Build a find expression for all VIDEO_EXTENSIONS.
# Populates the named array variable with (-name "*.ext" -o ...) args.
build_ext_args() {
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
    local source_file="$1"
    local relative_path="${source_file#"$SOURCE_DIR"/}"
    local target_file="$INPUT_DIR/$relative_path"
    local target_dir
    target_dir="$(dirname "$target_file")"

    # Rename HandBrake DVD title numbers on the way in: "## - name.ext" -> "DVD Title ##.ext"
    local filename stem ext
    filename="$(basename "$target_file")"
    stem="${filename%.*}"
    ext="${filename##*.}"
    if $DVD_MODE && [[ "$stem" =~ ^([0-9]+)[[:space:]]+-[[:space:]]+ ]]; then
        target_file="$target_dir/DVD Title ${BASH_REMATCH[1]}.${ext}"
    fi

    if ! mkdir -p "$target_dir"; then
        warn "Could not create directory: $target_dir — skipping $(basename "$source_file")"
        files_failed=$((files_failed + 1))
        return
    fi

    if [[ ! -f "$target_file" ]]; then
        echo "  Copying: $(basename "$source_file") -> $(basename "$target_file")"
        if cp "$source_file" "$target_file"; then
            files_copied=$((files_copied + 1))
        else
            warn "Copy failed: $source_file"
            files_failed=$((files_failed + 1))
        fi
    fi
}

process_video() {
    local input_file="$1"
    local current_num="$2"
    local total_num="$3"

    local relative_path="${input_file#"$INPUT_DIR"/}"
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

    # --preset-import-file loads the JSON; --preset selects by name within it.
    # _current_output lets the EXIT trap remove a partial file on SIGINT/SIGTERM.
    local hb_out
    $LOG_ENABLED && hb_out="$LOG_FILE" || hb_out="/dev/null"
    _current_output="$output_file"
    if "$HANDBRAKE_CLI" \
        -i "$input_file" \
        -o "$output_file" \
        --preset-import-file "$PRESET_FILE" \
        --preset "$PRESET_NAME" >> "$hb_out" 2>&1; then
        _current_output=""
        echo "[SUCCESS] Conversion complete"
        videos_converted=$((videos_converted + 1))
    else
        _current_output=""
        rm -f "$output_file"
        warn "HandBrake failed on: $(basename "$input_file") (see log for details)"
        videos_failed=$((videos_failed + 1))
    fi

    sleep "$PROCESS_DELAY"
}

# Rename files or directories using a Perl regex.
# Usage: rename_in_path <pattern> <replacement> <directory> [--recursive] [--dirs]
#
# --dirs always recurses fully and uses -depth so children are renamed before
# parents, preventing path invalidation when a parent dir is renamed mid-traversal.
# --recursive only applies to file mode (without --dirs).
rename_in_path() {
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
        # -depth ensures bottom-up order: rename children before parents.
        # Global options (-depth, -mindepth) must precede test predicates (-type).
        find_args+=("-depth" "-mindepth" "1" "-type" "d")
    else
        # Global options first, then test predicates.
        find_args+=("-mindepth" "1")
        $recursive || find_args+=("-maxdepth" "1")
        find_args+=("-type" "f")
    fi

    while IFS= read -r -d '' item; do
        local parent name new_name
        parent="$(dirname "$item")"
        name="$(basename "$item")"
        # perl handles full regex (lookaheads, \s, etc.); strip trailing spaces/dots
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

# ----------------------------- ARGUMENT PARSING ------------------------------

for arg in "$@"; do
    case "$arg" in
        -l|--log)   LOG_ENABLED=true ;;
        -d|--dvd)   DVD_MODE=true ;;
        -loren)  PRESET_FILE="$PRESET_DIR/Loren 720.json"; PRESET_NAME="Loren 720" ;;
        -jack)   PRESET_FILE="$PRESET_DIR/Jack 1080.json"; PRESET_NAME="Jack 1080" ;;
        -h|--help)
            printf 'Usage: %s [OPTIONS]\n\n' "$(basename "$0")"
            printf 'Options:\n'
            printf '  -l, --log   Enable logging to jackify_log.txt\n'
            printf '  -d, --dvd   Rename HandBrake title numbers on copy ("## - name" -> "DVD Title ##")\n'
            printf '  -loren      Use Loren 720 preset\n'
            printf '  -jack       Use Jack 1080 preset\n'
            printf '  -h, --help  Show this help message\n'
            exit 0
            ;;
        *) die "Unknown argument: $arg" ;;
    esac
done

[[ -z "$PRESET_NAME" ]] && die "No preset selected. Use -jack or -loren."

# ----------------------------- INITIALIZATION --------------------------------

clear
print_header "Jackify"
echo
$LOG_ENABLED && echo "Log file: $LOG_FILE"
log_message "Session started"

# ----------------------------- PREREQUISITES CHECK ---------------------------

echo "Checking prerequisites..."
echo

check_path "$SOURCE_DIR" "Source directory"
check_file "$HANDBRAKE_CLI"  "HandBrake CLI"
check_file "$PRESET_FILE"    "HandBrake preset file"

echo "[OK] All prerequisites met"
echo

mkdir -p "$INPUT_DIR"  || die "Could not create input directory: $INPUT_DIR"
mkdir -p "$OUTPUT_DIR" || die "Could not create output directory: $OUTPUT_DIR"

# ----------------------------- STEP 1: COPY FILES ----------------------------

print_header "STEP 1: Copying Video Files"

ext_args=()
build_ext_args ext_args

while IFS= read -r -d '' file; do
    copy_file_to_input "$file"
done < <(find "$SOURCE_DIR" -type f \( "${ext_args[@]}" \) -print0)

echo
echo "Total files copied: $files_copied"
echo

# ----------------------------- STEP 2: CONVERT VIDEOS ------------------------

print_header "STEP 2: Converting Videos"

mapfile -d '' video_list < <(find "$INPUT_DIR" -type f \( "${ext_args[@]}" \) -print0)
total_videos=${#video_list[@]}

if [[ $total_videos -eq 0 ]]; then
    echo "No videos found to process."
else
    echo "Found $total_videos video(s) to process"
    echo
    for ((i = 0; i < total_videos; i++)); do
        process_video "${video_list[$i]}" $((i + 1)) "$total_videos"
    done
fi

# ----------------------------- STEP 3: CLEANUP NAMES ------------------------

if [[ "${ENABLE_CLEANUP,,}" == "false" ]]; then
    echo "Name cleanup disabled - skipping"
else
    print_header "STEP 3: Cleaning Up Names"

    echo "Cleaning file names..."
    # Collapse multiple spaces
    rename_in_path '\s{2,}' ' ' "$OUTPUT_DIR" --recursive
    # Replace dots/underscores/hyphens that are not the extension separator
    rename_in_path '[._-](?=[^.]*\.)' ' ' "$OUTPUT_DIR" --recursive

    echo "Cleaning folder names..."
    rename_in_path '[._-]' ' ' "$OUTPUT_DIR" --dirs
    rename_in_path '\s{2,}' ' ' "$OUTPUT_DIR" --dirs

    echo "Cleanup complete!"
    echo
fi

# ----------------------------- FINAL REPORT ----------------------------------

print_header "Processing Complete"
echo
printf 'Videos found:     %d\n' "$total_videos"
printf 'Videos converted: %d\n' "$videos_converted"
printf 'Videos skipped:   %d\n' "$videos_skipped"
printf 'Files copied:     %d\n' "$files_copied"
[[ $videos_failed  -gt 0 ]] && printf 'Videos failed:    %d\n' "$videos_failed"
[[ $files_failed   -gt 0 ]] && printf 'Copy failures:    %d\n' "$files_failed"
[[ $rename_errors  -gt 0 ]] && printf 'Rename errors:    %d\n' "$rename_errors"
[[ "${ENABLE_CLEANUP,,}" == "true" ]] && echo "Name cleanup:     Completed"
echo
$LOG_ENABLED && echo "Full details available in: $LOG_FILE"
echo
print_header "Done"
