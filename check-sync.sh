#!/usr/bin/env bash
# =============================================================================
# check-sync -- verify tidy-names.sh still matches jackify.sh
# =============================================================================
# tidy-names.sh carries its OWN COPY of the name-cleanup rules: the technical
# tag alternation ($t), the release-group alternation ($g), and the junk
# basename list. It is not shared code, so editing one and forgetting the other
# leaves two tools that quietly disagree about what a filename should become.
#
# That is easy to do — one session added tags four times in an afternoon. This
# script makes the drift loud instead of leaving it to be discovered later by a
# file that came out named differently depending on which tool touched it.
#
# Compares, after stripping comments and whitespace so formatting doesn't
# matter:
#   * $t  technical tags      (resolutions, codecs, sources, HDR, editions)
#   * $g  release groups
#   * the junk basename list  (EXCLUDED_BASENAMES / JUNK_BASENAMES)
#
# Usage:  ./check-sync.sh        # exits 1 if the two have drifted
# =============================================================================

set -uo pipefail
cd "$(dirname "$0")"

A=jackify.sh
B=tidy-names.sh

for f in "$A" "$B"; do
    [[ -f "$f" ]] || { echo "Missing $f — run this from the repo root." >&2; exit 2; }
done

fail=0
ok()  { printf '  \033[32mok\033[0m        %s\n' "$1"; }
bad() { printf '  \033[31mDRIFT\033[0m     %s\n' "$1"; fail=1; }

# Pull a qr// alternation out of a file, with comments and all whitespace
# removed so a reflow or a re-indent doesn't read as a difference.
alternation() {  # file  varname(t|g)
    # The wanted name goes through the environment: passing it as an argument
    # would make perl treat it as another input file.
    WANT="$2" perl -0777 -ne '
        my $want = $ENV{WANT};
        while (/my \$([tg]) = qr\/(.*?)\/xi;/gs) {
            next unless $1 eq $want;
            my $body = $2;
            $body =~ s/#.*//g;      # drop the category comments
            $body =~ s/\s+//g;      # /x means whitespace is decorative
            print $body;
            exit 0;
        }' "$1"
}

# The junk list, normalised to a sorted space-separated set.
junklist() {  # file
    grep -hoE '^(EXCLUDED|JUNK)_BASENAMES=\([^)]*\)' "$1" \
        | sed -E 's/^[A-Z_]+=\(//; s/\)$//' | tr ' ' '\n' | sort | tr '\n' ' '
}

echo "Comparing $B against $A:"

for which in t g; do
    case "$which" in
        t) label="technical tags (\$t)" ;;
        g) label="release groups (\$g)" ;;
    esac
    a="$(alternation "$A" "$which")"
    b="$(alternation "$B" "$which")"
    if [[ -z "$a" || -z "$b" ]]; then
        bad "$label — could not extract from $([[ -z "$a" ]] && echo "$A" || echo "$B")"
    elif [[ "$a" == "$b" ]]; then
        ok "$label"
    else
        bad "$label"
        # Show which entries differ rather than dumping two long regexes.
        comm -3 <(tr '|' '\n' <<<"$a" | sed '/^$/d' | sort -u) \
                <(tr '|' '\n' <<<"$b" | sed '/^$/d' | sort -u) \
            | sed -E "s/^\t/            only in $B: /; s/^([^ \t])/            only in $A: \1/"
    fi
done

ja="$(junklist "$A")"
jb="$(junklist "$B")"
if [[ -z "$ja" || -z "$jb" ]]; then
    bad "junk basenames — could not extract"
elif [[ "$ja" == "$jb" ]]; then
    ok "junk basenames ($ja)"
else
    bad "junk basenames"
    printf '            %s: %s\n' "$A" "$ja"
    printf '            %s: %s\n' "$B" "$jb"
fi

echo
if [[ $fail -eq 0 ]]; then
    echo "In sync."
else
    echo "Drift found. Mirror the change into $B (they are copies, not shared code)."
fi
exit "$fail"
