#!/usr/bin/env bash

# Fake PDF backends exercise orchestration and failure handling, not PDF fidelity.

set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
temp_root=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
work=$(mktemp -d "$temp_root/utility-script-tests.XXXXXXXX")

cleanup() {
    local resolved
    resolved=$(cd -- "$work" && pwd -P)
    [[ $resolved == "$temp_root"/utility-script-tests.* ]] || return 1
    rm -rf -- "$resolved"
}

trap cleanup EXIT

mkdir -p "$work/bin" "$work/input" "$work/compress input"

cat > "$work/bin/pdfunite" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
out=${!#}
[[ ${FAIL_BACKEND:-0} == 0 ]] || { echo partial > "$out"; exit 9; }
printf '%s\n' "${@:1:$#-1}" > "$out"
BACKEND

cat > "$work/bin/gs" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
    if [[ $arg == -sOutputFile=* ]]; then out=${arg#*=}; fi
done
echo result > "$out"
[[ ${FAIL_BACKEND:-0} == 0 ]]
BACKEND

chmod +x "$work/bin/"*

export PATH="$work/bin:$PATH"

printf original > "$work/input/01-Alpha-10.pdf"
printf original > "$work/input/01-Alpha-2.pdf"
printf original > "$work/input/01-Beta-1.pdf"

bash "$root/merge_pdfs.sh" "$work/input"

[[ -s "$work/input/merged/01-Alpha.pdf" && -s "$work/input/merged/01-Beta.pdf" ]]
[[ $(head -1 "$work/input/merged/01-Alpha.pdf") == */01-Alpha-2.pdf ]]

before=$(cat "$work/input/merged/01-Alpha.pdf")

if bash "$root/merge_pdfs.sh" "$work/input"; then exit 1; fi
[[ $(cat "$work/input/merged/01-Alpha.pdf") == "$before" ]]

if FAIL_BACKEND=1 bash "$root/merge_pdfs.sh" "$work/input" "$work/failed-merge"; then exit 1; fi
[[ -z $(ls -A "$work/failed-merge") ]]

printf original > "$work/compress input/-test file.pdf"

bash "$root/compress_pdf.sh" "$work/compress input"

[[ $(cat "$work/compress input/-test file.pdf") == original ]]
[[ -s "$work/compress input/compressed/-test file.pdf" ]]

if bash "$root/compress_pdf.sh" "$work/compress input"; then exit 1; fi
if FAIL_BACKEND=1 bash "$root/compress_pdf.sh" "$work/compress input" "$work/failed-compress"; then exit 1; fi

[[ -z $(ls -A "$work/failed-compress") ]]

if bash "$root/compress_pdf.sh" "$work/compress input" "$work/invalid" invalid; then exit 1; fi

echo 'Shell regression tests passed.'
