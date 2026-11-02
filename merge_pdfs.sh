#!/usr/bin/env bash

# Group NUMBER-TITLE[-PART].pdf files and merge in natural filename order.

set -euo pipefail
shopt -s nullglob
export LC_ALL=C

if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash merge_pdfs.sh [INPUT_DIRECTORY] [OUTPUT_DIRECTORY]'
    exit 0

fi

(( $# <= 2 )) || { echo 'Too many arguments.' >&2; exit 2; }

input=${1:-.}
output=${2:-"$input/merged"}
[[ -d $input ]] || { echo "Input directory not found: $input" >&2; exit 2; }

if command -v pdfunite >/dev/null; then backend=pdfunite
elif command -v gs >/dev/null; then backend=gs
else echo 'Poppler (pdfunite) or Ghostscript (gs) is required.' >&2; exit 1
fi

mkdir -p -- "$output"

input=$(cd -- "$input" && pwd -P)
output=$(cd -- "$output" && pwd -P)
[[ $input != "$output" ]] || { echo 'Input and output directories must differ.' >&2; exit 2; }

declare -A groups=()

files=("$input"/*.pdf)

for file in "${files[@]}"; do
    name=${file##*/}
    if [[ $name =~ ^([0-9]+)-([^-]+)(-.*)?\.pdf$ ]]; then
        groups["${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"]=1
    fi
done

(( ${#groups[@]} )) || { echo 'No matching PDF files found.'; exit 0; }

tmp=''
trap '[[ -z $tmp ]] || rm -f -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mapfile -d '' -t keys < <(printf '%s\0' "${!groups[@]}" | sort -zV)

for key in "${keys[@]}"; do
    members=()
    for file in "${files[@]}"; do
        name=${file##*/}

        if [[ $name =~ ^([0-9]+)-([^-]+)(-.*)?\.pdf$ ]] && \
            [[ ${BASH_REMATCH[1]}-${BASH_REMATCH[2]} == "$key" ]]; then
            members+=("$file")
        fi
    done

    mapfile -d '' -t sorted < <(printf '%s\0' "${members[@]}" | sort -zV)

    target="$output/$key.pdf"
    [[ ! -e $target && ! -L $target ]] || { echo "Output already exists: $target" >&2; exit 1; }

    tmp=$(mktemp "$output/.merge.XXXXXXXX.pdf")

    echo "Merging: $key (${#sorted[@]} files)"

    if [[ $backend == pdfunite ]]; then
        pdfunite "${sorted[@]}" "$tmp"
    else
        gs -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite "-sOutputFile=$tmp" -f "${sorted[@]}"
    fi

    [[ -s $tmp ]] || { echo "Empty result: $key" >&2; exit 1; }

    ln -- "$tmp" "$target"
    rm -f -- "$tmp"
    tmp=''

    echo "Saved: $target"
done
