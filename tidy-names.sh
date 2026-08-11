#!/usr/bin/env bash
# =============================================================================
# tidy-names -- Jackify's name cleanup and junk removal, as a standalone tool
# =============================================================================
# Runs the same three passes Jackify applies to its output, against any
# directory you point it at:
#
#   1. DVD title-number removal   "## - Name"  ->  "Name"
#   2. Tag stripping              release tags, tracker URLs, group suffixes,
#                                 bare years wrapped in parentheses
#   3. Title case                 minor words stay lowercase, acronyms survive
#
# Optionally (--delete-junk) it also removes sample/preview clips and folders.
#
# ---------------------------------------------------------------------------
# IT DOES NOTHING BY DEFAULT.
#
# Without --apply this only prints what it *would* do. That is deliberate:
# these rules were written for scene-release filenames sitting briefly in a
# staging folder, where every token that isn't the title is junk. Pointed at a
# curated archive they will happily "fix" names that were already right --
# "Confetti fly camera 1080p.mp4" loses a resolution that was describing the
# asset, not tagging a rip. Read the plan before you trust it.
#
# There is no undo. Check the plan, check it against a backup, then --apply.
# ---------------------------------------------------------------------------
#
# Usage:
#   ./tidy-names.sh <dir>                     # dry run (default)
#   ./tidy-names.sh --apply <dir>             # rename for real
#   ./tidy-names.sh --delete-junk <dir>       # dry run, incl. junk removal
#   ./tidy-names.sh --apply --delete-junk <d> # rename and delete for real
#   ./tidy-names.sh --files-only <dir>        # skip directory renames
#
# The full plan is always written to ./tidy-names-plan.txt.
# =============================================================================

set -uo pipefail

JUNK_BASENAMES=(sample samples preview previews)
PLAN="${PLAN_FILE:-./tidy-names-plan.txt}"

APPLY=false
DELETE_JUNK=false
FILES_ONLY=false
TARGET=""

while (( $# )); do
    case "$1" in
        --apply)       APPLY=true ;;
        --delete-junk) DELETE_JUNK=true ;;
        --files-only)  FILES_ONLY=true ;;
        -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
        -*)            echo "Unknown option: $1" >&2; exit 2 ;;
        *)             TARGET="$1" ;;
    esac
    shift
done

[[ -n "$TARGET" ]] || { echo "Usage: $0 [--apply] [--delete-junk] [--files-only] <dir>" >&2; exit 2; }
[[ -d "$TARGET" ]] || { echo "Not a directory: $TARGET" >&2; exit 2; }

# Refuse to operate anywhere that would be catastrophic to get wrong.
TARGET="$(cd -- "$TARGET" && pwd -P)"
case "$TARGET" in
    /|/home|/root|/usr|/etc|/var|/bin|/sbin|/lib|/boot|/mnt|/media)
        echo "Refusing to run on $TARGET" >&2; exit 2 ;;
esac

command -v perl >/dev/null || { echo "perl is required" >&2; exit 2; }

renames=0 deletions=0 collisions=0 errors=0

: > "$PLAN"
log() { printf '%s\n' "$*" >> "$PLAN"; }

log "tidy-names plan"
log "target : $TARGET"
log "mode   : $($APPLY && echo APPLY || echo 'DRY RUN (nothing will change)')"
log "junk   : $($DELETE_JUNK && echo 'sample/preview removal ON' || echo 'sample/preview removal off')"
log "date   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "$(printf '%.0s-' {1..70})"
log ""

# ----- the name transform (identical to Jackify's) ---------------------------

read -r -d '' PERL_CLEAN <<'PERL'
my $t = qr/
    2160p|1080p|720p|480p|4K|UHD|
    Blu-?Ray|BDRip|BRRip|WEB-DL|WEBRip|HDTV|DVDRip|DVDScr|AMZN|NF|HULU|DSNP|
    H\.?265|H\.?264|x265|x264|XviD|DivX|HEVC|AVC|
    TrueHD|Atmos|DTS-HD|DTS|DDP?\d+\.\d+|AC3|AAC(?:\d+\.\d+)?|FLAC(?:\d+\.\d+)?|Opus(?:\d+\.\d+)?|MP3|7\.1|5\.1|Dual-?Audio|
    HDR10\+|HDR10|HDR|SDR|DoVi|10bit|8bit|HLG|900mb|REMUX|
    PROPER|REPACK|EXTENDED|THEATRICAL|UNRATED|UNCUT|IMAX|
    TV[\s._-]?Mini-?Series|Mini-?Series/xi;
my $g = qr/
    YIFY|YTS|RARBG|SPARKS|GECKOS|DRONES|ROVERS|LOL|DIMENSION|KILLERS|FLEET|IMMERSE|BATV|DEFLATE|TBS|
    CtrlHD|DON|EbP|NTb|Tigole|QxR|UTR|HiDt|HDMaNiAcS|10bit-GalaxyRG265|GalaxyRG|GalaxyTV|
    HorribleSubs|Erai-raws|SubsPlease|Judas|EMBER|AnimeRG|Varyg|
    TERMiNAL|EPSiLON|FraMeSToR|WiLDCAT|COASTER|MULVAcoded|
    NTG|FLUX|ION10|CAKES|PECULATE|Headpatter|WR3CK|OFT|Deceit|AJP69|LAMA|HAiKU|Grym|HiC|
    aXXo|ViTE|DiAMOND|WAF|ESiR|BONE/xi;
s/^(\d+)[\s]+-[\s]+(.+)$/$2/;
s/\s*\[[^\]]*\]//g;
s/\bwww\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+[\s._-]*//gi;
s/(?<![A-Za-z0-9])(?:UIndex|YTS|RARBG|EZTV|ETTV)\.[A-Za-z]{2,}\b[\s._-]*//gi;
1 while s/[\s._-]+(?:$g)(?=[\s._-]*(?:\.[A-Za-z0-9]{1,4})?$)//i;
s/\s*\(\s*$t\s*\)\s*//gi;
s/(?<![a-zA-Z0-9])$t(?![a-zA-Z0-9])//gi;
1 while s/[\s._-]+(?:$g)(?=[\s._-]*(?:\.[A-Za-z0-9]{1,4})?$)//i;
s/(?<![A-Za-z0-9])(?:2160|1440|1080|720|576|480|360)p\d{2,3}(?![A-Za-z0-9])//gi;
s/[.\-_]{2,}([^.])/$1 ? ".$1" : ""/ge;
s/[.\-_]+$//;
s/[\s._-]+(\.[A-Za-z0-9]{1,4})$/$1/;
s{(?<![\(\d])\b(19\d{2}|20\d{2})\b(?!\))}{"($1)"}ge;
s/\s{2,}/ /g;
s/^\s+|\s+$//g;
my @minor = qw(a an the and but or nor for so yet at by in of on to up as);
s/(\w[\w'\x{2019}]*)/do{
    my $orig=$1; my $w=lc($1);
    ($orig eq uc($orig) && length($orig)>1 && length($orig)<=4 && !grep{$_ eq lc($orig)}@minor) ? $orig :
    (grep{$_ eq $w}@minor) ? $w : ucfirst($w)
}/ge;
s/(?<=\d) ([a-z][\w'\x{2019}]*)/" ".ucfirst($1)/ge;
s/^(\w)/uc($1)/e;
PERL

clean_name() {
    # Usage: clean_name <name> [has-extension]
    local name="$1" has_ext="${2:-true}" stem ext out
    if $has_ext && [[ "$name" == *.* ]]; then
        ext=".${name##*.}"; stem="${name%.*}"
    else
        ext=""; stem="$name"
    fi
    out="$(printf '%s' "$stem" | perl -CSD -pe "$PERL_CLEAN" 2>/dev/null)" || return 1
    printf '%s%s' "$out" "$ext"
}

# ----- junk removal ----------------------------------------------------------

junk_globs=()
for n in "${JUNK_BASENAMES[@]}"; do
    junk_globs+=("$n" "$n.*" "*[._ -]$n.*" "*[._ -]$n")
done
junk_match=("(")
first=true
for g in "${junk_globs[@]}"; do
    $first || junk_match+=("-o"); first=false
    junk_match+=("-iname" "$g")
done
junk_match+=(")")

if $DELETE_JUNK; then
    log "== JUNK REMOVAL =="
    while IFS= read -r -d '' item; do
        [[ "$item" == "$TARGET"/?* ]] || continue
        log "DELETE  ${item#$TARGET/}"
        ((deletions++))
        if $APPLY; then
            rm -rf -- "$item" || { log "  !! failed"; ((errors++)); }
        fi
    done < <(find -L "$TARGET" -mindepth 1 \( -type f -o -type d \) "${junk_match[@]}" -print0 2>/dev/null)
    log ""
fi

# ----- renames ---------------------------------------------------------------
# Depth-first so a directory is renamed only after its contents are handled.

log "== RENAMES =="
find_args=(-mindepth 1 -depth)
$FILES_ONLY && find_args+=(-type f)

PLAN_ABS="$(cd -- "$(dirname -- "$PLAN")" 2>/dev/null && pwd -P)/$(basename -- "$PLAN")"

while IFS= read -r -d '' item; do
    # Never rename the plan we are writing into.
    [[ "$item" == "$PLAN_ABS" ]] && continue
    parent="$(dirname -- "$item")"
    base="$(basename -- "$item")"
    if [[ -d "$item" ]]; then new="$(clean_name "$base" false)"; else new="$(clean_name "$base" true)"; fi
    [[ -n "$new" && "$new" != "$base" ]] || continue
    if [[ -e "$parent/$new" ]]; then
        log "SKIP    ${item#$TARGET/}"
        log "        target exists: $new"
        ((collisions++)); continue
    fi
    log "RENAME  ${item#$TARGET/}"
    log "     -> $new"
    ((renames++))
    if $APPLY; then
        mv -n -- "$item" "$parent/$new" || { log "  !! failed"; ((errors++)); }
    fi
done < <(find -L "$TARGET" "${find_args[@]}" -print0 2>/dev/null)

# ----- report ----------------------------------------------------------------

echo
echo "  target      : $TARGET"
echo "  mode        : $($APPLY && echo 'APPLY — changes written' || echo 'DRY RUN — nothing changed')"
printf '  renames     : %d\n' "$renames"
printf '  collisions  : %d (skipped, target name already exists)\n' "$collisions"
$DELETE_JUNK && printf '  deletions   : %d\n' "$deletions"
(( errors > 0 )) && printf '  errors      : %d\n' "$errors"
echo "  full plan   : $PLAN"
$APPLY || echo "  Re-run with --apply to make these changes. There is no undo."
echo
