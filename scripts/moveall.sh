#!/usr/bin/env bash
set -euo pipefail

read -r -p "Enter source directory: " src
read -r -p "Enter file type (e.g., txt): " ext
read -r -p "Enter destination directory: " dest

if [[ -z "${src}" || -z "${ext}" || -z "${dest}" ]]; then
    echo "Source, file type, and destination are required." >&2
    exit 1
fi

if [[ ! -d "${src}" ]]; then
    echo "Source directory does not exist: ${src}" >&2
    exit 1
fi

mkdir -p "${dest}"

shopt -s nullglob
moved=0
for f in "${src}"/*.${ext}; do
    if [[ -f "${f}" ]]; then
        mv -n -- "${f}" "${dest}/"
        moved=$((moved + 1))
    fi
done

echo "Moved ${moved} file(s) to ${dest}."