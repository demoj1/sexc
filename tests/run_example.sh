#!/usr/bin/env bash
# Compile a SexC example end-to-end through gcc and check exit status.
#
# Args: $1 = relative path to example .sexc (from repo root)
# Env:  SEXC, ROOT, RESULTS_DIR
#
# Examples that need extra link flags can declare them in their first line:
#   ;; sexc-test-flags: -lm -lpthread

set -uo pipefail

src="$1"
abs="${ROOT}/${src}"
name="$(basename "${src%.sexc}")"
slug="example-$(printf '%s' "${src}" | tr -c 'a-zA-Z0-9' '_')"
results="${RESULTS_DIR:-/tmp}"

if [[ ! -f "${abs}" ]]; then
    {
        printf '\033[31mFAIL\033[0m compile %s (file not found)\n' "${src}"
    } | tee "${results}/${slug}.fail"
    exit 0
fi

extra_flags=()
first_line="$(head -n1 "${abs}" 2>/dev/null || true)"
if [[ "${first_line}" =~ sexc-test-flags:[[:space:]]*(.+)$ ]]; then
    # shellcheck disable=SC2206
    extra_flags=(${BASH_REMATCH[1]})
fi

out_bin="$(mktemp -t "sexc_${name}.XXXXXX")"
log="${results}/${slug}.log"

if "${SEXC}" --quiet "${abs}" -C gcc % -O0 -w "${extra_flags[@]}" -lm -o "${out_bin}" \
        > "${log}" 2>&1; then
    rm -f "${out_bin}"
    printf '\033[32mPASS\033[0m compile %s\n' "${src}"
    touch "${results}/${slug}.pass"
    exit 0
fi

rm -f "${out_bin}"
{
    printf '\033[31mFAIL\033[0m compile %s\n' "${src}"
    sed 's/^/    /' "${log}" | head -30
} | tee "${results}/${slug}.fail"
exit 0
