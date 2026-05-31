#!/usr/bin/env bash
# Run a single snapshot test case.
#
# File format (.sexc-test):
#
#   ;; sexc-flags: --no-prelude    (optional first line — disables implicit prelude)
#   ... SexC source ...
#   ;==EXPECTED==
#   ... expected C output (line-for-line) ...
#
# The marker line is searched verbatim; everything above it is fed to sexc,
# everything below is the golden output. With UPDATE=1, the expected block is
# rewritten in place from the current sexc output. By default the implicit
# prelude is loaded — opt out per-test via the magic comment above.
#
# Args: $1 = path to .sexc-test
# Env:  RESULTS_DIR — auto-set by run.sh
#       SEXC, ROOT, UPDATE

set -uo pipefail

case_path="$1"
rel="${case_path#${ROOT}/}"
slug="case-$(printf '%s' "${rel}" | tr -c 'a-zA-Z0-9' '_')"
results="${RESULTS_DIR:-/tmp}"

MARKER=';==EXPECTED=='

flags=(--quiet)
first_line="$(head -n1 "${case_path}" 2>/dev/null || true)"
if [[ "${first_line}" =~ sexc-flags:[[:space:]]*--no-prelude ]]; then
    flags=(--quiet --no-prelude)
fi

# Split file into source / expected via marker.
marker_line=$(grep -nFx "${MARKER}" "${case_path}" | head -n1 | cut -d: -f1)
src_file="${results}/${slug}.src"
expected_file="${results}/${slug}.expected"

if [[ -z "${marker_line}" ]]; then
    cp "${case_path}" "${src_file}"
    : > "${expected_file}"
    has_expected=0
else
    head -n "$((marker_line - 1))" "${case_path}" > "${src_file}"
    tail -n "+$((marker_line + 1))" "${case_path}" > "${expected_file}"
    has_expected=1
fi

actual_file="${results}/${slug}.actual"
err_file="${results}/${slug}.err"

"${SEXC}" "${flags[@]}" - < "${src_file}" > "${actual_file}" 2> "${err_file}"
status=$?

if [[ ${status} -ne 0 ]]; then
    {
        printf '\033[31mFAIL\033[0m %s (sexc exit %d)\n' "${rel}" "${status}"
        sed 's/^/    /' "${err_file}" | head -20
    } | tee "${results}/${slug}.fail"
    exit 0
fi

if [[ -n "${UPDATE}" ]]; then
    {
        cat "${src_file}"
        printf '%s\n' "${MARKER}"
        cat "${actual_file}"
    } > "${case_path}.tmp"
    mv "${case_path}.tmp" "${case_path}"
    printf '\033[36mUPDATE\033[0m %s\n' "${rel}"
    touch "${results}/${slug}.pass"
    exit 0
fi

if [[ ${has_expected} -eq 0 ]]; then
    {
        printf '\033[33mMISS\033[0m %s (no %s marker; run UPDATE=1 to create)\n' "${rel}" "${MARKER}"
    } | tee "${results}/${slug}.fail"
    exit 0
fi

if diff -q "${actual_file}" "${expected_file}" > /dev/null 2>&1; then
    printf '\033[32mPASS\033[0m %s\n' "${rel}"
    touch "${results}/${slug}.pass"
    exit 0
fi

{
    printf '\033[31mFAIL\033[0m %s (output mismatch)\n' "${rel}"
    diff -u "${expected_file}" "${actual_file}" | sed 's/^/    /' | head -40
} | tee "${results}/${slug}.fail"
exit 0
