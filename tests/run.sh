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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${DIR}/.." && pwd -P)"
SEXC="${SEXC:-${ROOT}/sexc}"

if [[ ! -x "${SEXC}" ]]; then
    echo "error: ${SEXC} not built; run 'make build' first" >&2
    exit 1
fi

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
FILTER="${FILTER:-}"
UPDATE="${UPDATE:-}"

export ROOT SEXC UPDATE

# Portable array fill (no mapfile — macOS ships bash 3.2). Filenames in this
# repo have no spaces/newlines, so word-splitting on the sorted find output is safe.
cases=()
while IFS= read -r line; do cases+=("${line}"); done < <(find "${DIR}/cases" -type f -name '*.sexc-test' 2>/dev/null | sort)
examples=()
while IFS= read -r line; do examples+=("${line}"); done < <(find "${DIR}/examples" -type f -name '*.list' 2>/dev/null | sort)

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

printf 'Running %d snapshot cases + %d example compile/run checks on %d workers\n' \
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

# 3. CLI smoke checks — `sexc check` exit codes + silent-on-success.
if [[ -z "${FILTER}" ]]; then
    printf '(defn int main () (return 0))\n' > "${results_dir}/ok.sexc"
    printf '(defn int main () (when))\n'     > "${results_dir}/bad.sexc"
    smoke() {
        local name="$1" expected="$2"; shift 2
        local slug="smoke-${name}"
        local out; out="$("${SEXC}" "$@" 2>/dev/null)"; local got=$?
        if [[ "${got}" -eq "${expected}" ]]; then
            printf '\033[32mPASS\033[0m smoke %s\n' "${name}"
            touch "${results_dir}/${slug}.pass"
        else
            printf '\033[31mFAIL\033[0m smoke %s (exit %s, expected %s)\n' \
                "${name}" "${got}" "${expected}" | tee "${results_dir}/${slug}.fail"
        fi
        # stash stdout for the silent-success assertion below
        printf '%s' "${out}" > "${results_dir}/${slug}.out"
    }
    smoke "check-ok"  0 --quiet check "${results_dir}/ok.sexc"
    smoke "check-bad" 1 --quiet check "${results_dir}/bad.sexc"
    if [[ -s "${results_dir}/smoke-check-ok.out" ]]; then
        printf '\033[31mFAIL\033[0m smoke check-ok-silent (stdout not empty)\n' \
            | tee "${results_dir}/smoke-check-ok-silent.fail"
    else
        printf '\033[32mPASS\033[0m smoke check-ok-silent\n'
        touch "${results_dir}/smoke-check-ok-silent.pass"
    fi
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
