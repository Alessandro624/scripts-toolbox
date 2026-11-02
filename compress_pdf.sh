#!/usr/bin/env bash

# Write compressed copies without replacing source PDFs or existing outputs.

set -euo pipefail
shopt -s nullglob

if [[ ${1:-} == --help ]]; then
    echo 'Usage: bash compress_pdf.sh [INPUT_DIRECTORY] [OUTPUT_DIRECTORY] [screen|ebook|printer|prepress|default]'
    exit 0
fi

(( $# <= 3 )) || { echo 'Too many arguments.' >&2; exit 2; }

input=${1:-.}
output=${2:-"$input/compressed"}
quality=${3:-ebook}

case $quality in screen|ebook|printer|prepress|default) ;; *) echo 'Invalid quality preset.' >&2; exit 2 ;; esac

[[ -d $input ]] || { echo "Input directory not found: $input" >&2; exit 2; }

command -v gs >/dev/null || { echo 'Ghostscript (gs) is required.' >&2; exit 1; }

mkdir -p -- "$output"

input=$(cd -- "$input" && pwd -P)
output=$(cd -- "$output" && pwd -P)
[[ $input != "$output" ]] || { echo 'Input and output directories must differ.' >&2; exit 2; }

tmp=''

trap '[[ -z $tmp ]] || rm -f -- "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

files=("$input"/*.pdf)
(( ${#files[@]} )) || { echo 'No PDF files found.'; exit 0; }

for file in "${files[@]}"; do
    target="$output/${file##*/}"

    [[ ! -e $target && ! -L $target ]] || { echo "Output already exists: $target" >&2; exit 1; }

    tmp=$(mktemp "$output/.compress.XXXXXXXX.pdf")

    echo "Compressing: ${file##*/}"

    gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 "-dPDFSETTINGS=/$quality" \
        -dNOPAUSE -dQUIET -dBATCH "-sOutputFile=$tmp" -f "$file"
    [[ -s $tmp ]] || { echo "Empty result: $file" >&2; exit 1; }

    # Hard-link publication fails atomically if the destination already exists.
    ln -- "$tmp" "$target"
    rm -f -- "$tmp"
    tmp=''

    echo "Saved: $target"
done
