#!/usr/bin/env bash
# Run the SexC regression test suite.
#
# Discovers:
#   tests/cases/*.sexc-test  — golden snapshot tests (source + expected in one file)
#   tests/examples/*.list    — example compile tests (one example path per line)
#
# Usage:
#   ./tests/run.sh           — run all tests
#   UPDATE=1 ./tests/run.sh  — rewrite the expected block in each .sexc-test
#   JOBS=8 ./tests/run.sh    — set parallel worker count (default: nproc)
#   FILTER=pattern ./tests/run.sh — only run cases whose path matches pattern

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${DIR}/.." && pwd)"
SEXC="${SEXC:-${ROOT}/sexc}"

if [[ ! -x "${SEXC}" ]]; then
    echo "error: ${SEXC} not built; run 'make build' first" >&2
    exit 1
fi

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
FILTER="${FILTER:-}"
UPDATE="${UPDATE:-}"

export ROOT SEXC UPDATE

mapfile -t cases < <(find "${DIR}/cases" -type f -name '*.sexc-test' 2>/dev/null | sort)
mapfile -t examples < <(find "${DIR}/examples" -type f -name '*.list' 2>/dev/null | sort)

if [[ -n "${FILTER}" ]]; then
    filtered=()
    for c in "${cases[@]:-}"; do
        [[ "${c}" == *"${FILTER}"* ]] && filtered+=("${c}")
    done
    cases=("${filtered[@]:-}")
fi

total=${#cases[@]}
example_files=()
for list in "${examples[@]:-}"; do
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        [[ -n "${FILTER}" && "${line}" != *"${FILTER}"* ]] && continue
        example_files+=("${line}")
    done < "${list}"
done

if [[ ${total} -eq 0 && ${#example_files[@]} -eq 0 ]]; then
    echo "no tests matched FILTER='${FILTER}'" >&2
    exit 1
fi

printf 'Running %d snapshot cases + %d example compiles on %d workers\n' \
    "${total}" "${#example_files[@]}" "${JOBS}"

start_ns=$(date +%s%N)

results_dir="$(mktemp -d -t sexc-tests.XXXXXX)"
trap 'rm -rf "${results_dir}"' EXIT
export RESULTS_DIR="${results_dir}"

# 1. Snapshot cases
if [[ ${total} -gt 0 ]]; then
    printf '%s\n' "${cases[@]}" | \
        xargs -P "${JOBS}" -I{} "${DIR}/run_one.sh" "{}"
fi

# 2. Example compile cases
if [[ ${#example_files[@]} -gt 0 ]]; then
    printf '%s\n' "${example_files[@]}" | \
        xargs -P "${JOBS}" -I{} "${DIR}/run_example.sh" "{}"
fi

end_ns=$(date +%s%N)
elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

pass=$(find "${results_dir}" -type f -name '*.pass' 2>/dev/null | wc -l | tr -d ' ')
fail=$(find "${results_dir}" -type f -name '*.fail' 2>/dev/null | wc -l | tr -d ' ')
ran=$((pass + fail))

printf '\n'
if [[ ${fail} -gt 0 ]]; then
    printf '\033[31m%d/%d failed\033[0m (%dms)\n' "${fail}" "${ran}" "${elapsed_ms}"
    for f in "${results_dir}"/*.fail; do
        [[ -f "${f}" ]] || continue
        cat "${f}"
    done
    exit 1
fi

printf '\033[32mAll %d tests passed\033[0m (%dms)\n' "${ran}" "${elapsed_ms}"
