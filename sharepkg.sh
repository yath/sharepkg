#!/system/xbin/bash
set -euo pipefail

# only list 3rd-party packages
readonly PMFLAGS="-3"

# busybox's readlink just returns 1 if there's no link
tempdir="$(readlink -f "$0" || printf "%s" "$0").tmp"
trap 'rm -rf "$tempdir"' EXIT

if [ -d "$tempdir" ]; then
    echo "Removing stale temporary directory $tempdir..." >&2
    rm -rf "$tempdir"
fi

mkdir "$tempdir"

choice() {
    choicelist="$1" # filename with lines "<key> <text>\n"
                    # (the newline is important for wc)
    prompt="$2"
    pickfirstifonly="${3:-n}"

    count="$(wc -l < "$choicelist")"

    if [ "$count" -eq 0 ]; then
        echo "Empty list $choicelist" >&2
        exit 1
    elif [ "$count" -eq 1 -a "$pickfirstifonly" = y ]; then
        read key text < "$choicelist"
        echo "Auto-selecting sole choice '$text' for '$prompt'" >&2
        printf "%s" "$key"
        return
    fi

    width="$(printf "%d" "$count" | wc -c)"
    while read key text; do printf "%s\n" "$text"; done < "$choicelist" | nl -b a -w "$width" >&2
    printf "\n%s: " "$prompt" >&2
    read choice # == line number
    if ! printf "%s" "$choice" | grep -qE '^[0-9]+$' || [ "$choice" -gt "$count" ]; then
        echo "Invalid choice '$choice'" >&2
        exit 1
    fi
    # no awk /o\
    sed "${choice}{s/ .*//;p};d" < "$choicelist"
}

pick_user() {
    # $ pm list users
    # Users:
    #         UserInfo{0:Owner:13} running
    #         UserInfo{10:WZT:10} running
    # id:name:hex(flags)
    # http://androidxref.com/6.0.0_r1/xref/frameworks/base/core/java/android/content/pm/UserInfo.java#159

    c="$tempdir/userlist.choices"
    pm list users | grep -Eo '[0-9]+:[^:]+:[0-9]+' | while IFS=: read userid name flags; do
        if [ "$userid" -ne 0 ]; then # skip owner
            printf '%d %s (%d)\n' "$userid" "$name" "$userid"
        fi
    done > "$c"
    choice "$c" "User to install package for" "y"
}

pkglist() {
    args="$PMFLAGS -f"
    [ "${1:-}" ] && args="$args --user $1"
    # $ pm list packages -f
    # package:/data/app/com.google.android.ears-2/base.apk=com.google.android.ears
    pm list packages $args | sed -r -e 's,package:([^=]+)=(.*),\2 \1,;t;d'
}

target="$(pick_user)"

echo "Gathering list of packages..." >&2
allpkgs="$tempdir/pkglist-all"
pkglist | sort > "$allpkgs"

tgtpkgs="$tempdir/pkglist-uid${target}"
pkglist "$target" | sort > "$tgtpkgs"

availpkgs="$tempdir/pkglist-missing-uid${target}"
comm -3 "$allpkgs" "$tgtpkgs" > "$availpkgs"

if [ "$(wc -l < "$availpkgs")" -eq 0 ]; then
    echo "No packages available to share with uid $target."
    exit 0
fi

pkgchoices="$tempdir/pkglist-missing.choices"
while read pkg filename; do
    # application-label:'foo'
    label="$(aapt dump badging "$filename" | sed -r -e "s,application-label:'(.*)',\\1,;t;d")"
    printf "%s %s (%s)\n" "$filename" "$label" "$pkg"
done < "$availpkgs" > "$pkgchoices"
tgtpkg="$(choice "$pkgchoices" "Package to transfer")"

pm install --user "$target" -r "$tgtpkg"
