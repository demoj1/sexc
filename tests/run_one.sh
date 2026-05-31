#!/usr/bin/env bash
# Run a single snapshot test case.
#
# Two file formats are supported (.sexc-test):
#
# 1) Successful compile (default):
#
#      ;; sexc-flags: --no-prelude    (optional first line)
#      ... SexC source ...
#      ;==EXPECTED==
#      ... expected C stdout ...
#
# 2) Compile error (golden stderr):
#
#      ... SexC source that should fail to compile ...
#      ;==EXPECTED-ERROR==
#      ... expected stderr (file:line:col + caret + optional hint block) ...
#
#    Sexc is expected to exit non-zero. stdout is ignored.
#
# Paths in stderr that point into the repo are normalized to "<root>" so the
# golden output is stable across environments.
#
# With UPDATE=1 the matching block is rewritten in place.
#
# Args: $1 = path to .sexc-test
# Env:  RESULTS_DIR — auto-set by run.sh
#       SEXC, ROOT, UPDATE

set -uo pipefail

case_path="$1"
rel="${case_path#${ROOT}/}"
slug="case-$(printf '%s' "${rel}" | tr -c 'a-zA-Z0-9' '_')"
results="${RESULTS_DIR:-/tmp}"

OK_MARKER=';==EXPECTED=='
ERR_MARKER=';==EXPECTED-ERROR=='

flags=(--quiet)
first_line="$(head -n1 "${case_path}" 2>/dev/null || true)"
if [[ "${first_line}" =~ sexc-flags:[[:space:]]*--no-prelude ]]; then
    flags=(--quiet --no-prelude)
fi

# Detect which marker (if any) the file uses.
ok_line=$(grep -nFx "${OK_MARKER}" "${case_path}" | head -n1 | cut -d: -f1)
err_line=$(grep -nFx "${ERR_MARKER}" "${case_path}" | head -n1 | cut -d: -f1)

mode=""
marker=""
marker_line=""
if [[ -n "${err_line}" ]]; then
    mode="error"
    marker="${ERR_MARKER}"
    marker_line="${err_line}"
elif [[ -n "${ok_line}" ]]; then
    mode="ok"
    marker="${OK_MARKER}"
    marker_line="${ok_line}"
fi

src_file="${results}/${slug}.src"
expected_file="${results}/${slug}.expected"

if [[ -z "${marker_line}" ]]; then
    cp "${case_path}" "${src_file}"
    : > "${expected_file}"
    has_expected=0
    # Default mode is OK so MISS messaging makes sense.
    mode="${mode:-ok}"
else
    head -n "$((marker_line - 1))" "${case_path}" > "${src_file}"
    tail -n "+$((marker_line + 1))" "${case_path}" > "${expected_file}"
    has_expected=1
fi

stdout_file="${results}/${slug}.stdout"
stderr_file="${results}/${slug}.stderr"
actual_file="${results}/${slug}.actual"

"${SEXC}" "${flags[@]}" - < "${src_file}" > "${stdout_file}" 2> "${stderr_file}"
status=$?

# Normalize repo-root paths in stderr → "<root>" so golden output is portable.
normalize() {
    sed -e "s|${ROOT}|<root>|g" "$1"
}

case "${mode}" in
    ok)
        if [[ ${status} -ne 0 ]]; then
            {
                printf '\033[31mFAIL\033[0m %s (sexc exit %d, expected success)\n' "${rel}" "${status}"
                sed 's/^/    /' "${stderr_file}" | head -20
            } | tee "${results}/${slug}.fail"
            exit 0
        fi
        cp "${stdout_file}" "${actual_file}"
        ;;
    error)
        if [[ ${status} -eq 0 ]]; then
            {
                printf '\033[31mFAIL\033[0m %s (sexc exit 0, expected non-zero)\n' "${rel}"
                printf '    stdout was:\n'
                sed 's/^/      /' "${stdout_file}" | head -10
            } | tee "${results}/${slug}.fail"
            exit 0
        fi
        normalize "${stderr_file}" > "${actual_file}"
        ;;
esac

if [[ -n "${UPDATE}" ]]; then
    {
        cat "${src_file}"
        printf '%s\n' "${marker:-${OK_MARKER}}"
        cat "${actual_file}"
    } > "${case_path}.tmp"
    mv "${case_path}.tmp" "${case_path}"
    printf '\033[36mUPDATE\033[0m %s\n' "${rel}"
    touch "${results}/${slug}.pass"
    exit 0
fi

if [[ ${has_expected} -eq 0 ]]; then
    {
        printf '\033[33mMISS\033[0m %s (no %s marker; run UPDATE=1 to create)\n' "${rel}" "${marker:-${OK_MARKER}}"
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
