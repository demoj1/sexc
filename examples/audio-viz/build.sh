#!/usr/bin/env bash
# Build audio-viz example.
#
# Pipeline:
#   1. SexC compiles main.sexc (+ imports) → main.c
#   2. gcc links main.c, audio_impl.c (miniaudio impl), with raylib + miniaudio headers.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/../.." && pwd)"

SEXC="${SEXC:-${ROOT}/sexc}"
if [[ ! -x "${SEXC}" ]]; then
    SEXC="${ROOT}/_build/default/src/sexc.exe"
fi
if [[ ! -x "${SEXC}" ]]; then
    echo "error: cannot find sexc binary; run 'make build' in ${ROOT}" >&2
    exit 1
fi

if [[ ! -f "${DIR}/vendor/miniaudio/miniaudio.h" ]]; then
    echo "error: miniaudio submodule missing; run 'git submodule update --init --recursive'" >&2
    exit 1
fi

OUT="${DIR}/audio-viz"

# SexC → C → линк. Реализация miniaudio тоже в SexC
# (audio.sexc делает MINIAUDIO_IMPLEMENTATION+include), отдельного .c нет.
exec "${SEXC}" "${DIR}/main.sexc" -C \
    gcc % \
        -I"${DIR}/vendor/miniaudio" \
        -O2 -Wall \
        -lraylib -lm -lpthread -ldl \
        -o "${OUT}"
