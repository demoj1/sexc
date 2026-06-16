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

    # A piped buffer (editor/flymake) has no path, but its relative %import must
    # still resolve against the working directory the editor runs the compiler in.
    mkdir -p "${results_dir}/imp"
    printf '(%%module m)\n(defn int helper () (return 7))\n' > "${results_dir}/imp/m.sexc"
    printf '(%%import "./m")\n(defn int main () (return (m/helper)))\n' > "${results_dir}/imp/main.sexc"
    if ( cd "${results_dir}/imp" && "${SEXC}" --quiet - < main.sexc >/dev/null 2>&1 ); then
        printf '\033[32mPASS\033[0m smoke stdin-import\n'
        touch "${results_dir}/smoke-stdin-import.pass"
    else
        printf '\033[31mFAIL\033[0m smoke stdin-import (relative %%import not resolved from cwd)\n' \
            | tee "${results_dir}/smoke-stdin-import.fail"
    fi

    # obj::method resolution (xref/eldoc) via the object's type, and :on-error in
    # the defn signature.
    methods_file="${results_dir}/methods.sexc"
    {
        printf '(struct Box\n'
        printf '  :fields (int v)\n'
        printf '  :methods\n'
        printf '  (defn int get ((:* Box self)) :on-error -1\n'
        printf '    (return (-> self v))))\n'
        printf '(defn int main ()\n'
        printf '  (decl (:* Box b) NULL)\n'
        printf '  (decl (int x) b::get)\n'
        printf '  (return x))\n'
    } > "${methods_file}"
    # b is declared on line 7, used as b::get on line 8 → resolves to Box/get
    if "${SEXC}" xref --at 8:18 "b::get" "${methods_file}" 2>/dev/null | grep -q 'Box/get'; then
        printf '\033[32mPASS\033[0m smoke method-xref\n'
        touch "${results_dir}/smoke-method-xref.pass"
    else
        printf '\033[31mFAIL\033[0m smoke method-xref (b::get did not resolve to Box/get)\n' \
            | tee "${results_dir}/smoke-method-xref.fail"
    fi
    if "${SEXC}" show-doc "Box/get" "${methods_file}" 2>/dev/null | grep -q ':on-error -1'; then
        printf '\033[32mPASS\033[0m smoke onerror-sig\n'
        touch "${results_dir}/smoke-onerror-sig.pass"
    else
        printf '\033[31mFAIL\033[0m smoke onerror-sig (:on-error missing from signature)\n' \
            | tee "${results_dir}/smoke-onerror-sig.fail"
    fi

    # --help is ASCII-only (no em-dash / arrow), exits 0, and lists Commands.
    help_out="$("${SEXC}" --help 2>&1)"; help_rc=$?
    if [[ ${help_rc} -eq 0 ]] && printf '%s' "${help_out}" | grep -q '^Commands:' \
        && ! printf '%s' "${help_out}" | grep -qP '[\x{2014}\x{2192}]'; then
        printf '\033[32mPASS\033[0m smoke help\n'
        touch "${results_dir}/smoke-help.pass"
    else
        printf '\033[31mFAIL\033[0m smoke help (exit %s / missing Commands / non-ASCII)\n' "${help_rc}" \
            | tee "${results_dir}/smoke-help.fail"
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
