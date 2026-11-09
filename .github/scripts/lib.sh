#!/usr/bin/env bash
# Shared helpers for the scripts in .github/scripts. Source this file; it runs nothing on its own.
# Works under bash 3.2 and later on Linux and macOS. Messages, annotations and log
# groups go to stderr (the runner reads workflow commands there too) so stdout stays free for values.

HOS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOS_CONFIG_FILE="$HOS_LIB_DIR/../hos-toolchain.env"

# Prints a message to stderr so it never mixes with values a function prints on stdout.
log() {
  printf '%s\n' "$*" >&2
}

# Escapes text for a GitHub workflow command (annotations, groups).
gh_escape() {
  local s="$1"
  s="${s//'%'/'%25'}"
  s="${s//$'\r'/'%0D'}"
  s="${s//$'\n'/'%0A'}"
  printf '%s' "$s"
}

# Prints a warning; in GitHub Actions it becomes a warning annotation.
warn() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::warning::%s\n' "$(gh_escape "$*")" >&2
  else
    printf 'warning: %s\n' "$*" >&2
  fi
}

# Prints a notice; in GitHub Actions it becomes a notice annotation.
notice() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::notice::%s\n' "$(gh_escape "$*")" >&2
  else
    printf 'notice: %s\n' "$*" >&2
  fi
}

# Prints an error (an error annotation in GitHub Actions) and exits with status 1.
die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$(gh_escape "$*")" >&2
  else
    printf 'error: %s\n' "$*" >&2
  fi
  exit 1
}

# Opens a collapsible log group in GitHub Actions, or prints a heading elsewhere.
group() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::group::%s\n' "$(gh_escape "$*")" >&2
  else
    printf '\n==> %s\n' "$*" >&2
  fi
}

# Closes the log group opened by group().
endgroup() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::endgroup::\n' >&2
  fi
  return 0
}

# Exports a variable in this shell and, under GitHub Actions, for the following steps.
export_var() {
  export "$1=$2"
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_ENV"
  fi
}

# Prepends a directory to PATH in this shell and, under GitHub Actions, for the following steps.
prepend_path() {
  export PATH="$1:$PATH"
  if [ -n "${GITHUB_PATH:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_PATH"
  fi
}

# Appends Markdown lines to the job summary when running under GitHub Actions.
summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Writes key=value to the step outputs when running under GitHub Actions.
set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

# Prints the SHA-256 digest of a file.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Downloads URL ($1) to FILE ($2), sending an optional request header ($3); retries transient failures.
fetch() {
  local header=()
  if [ -n "${3:-}" ]; then
    header=(-H "$3")
  fi
  curl -fsSL --retry 5 --retry-delay 5 --retry-all-errors --connect-timeout 30 ${header[@]+"${header[@]}"} -o "$2" "$1"
}

# Prints the final HTTP status of a HEAD request to a URL, retrying when there is no answer or a 5xx.
http_status() {
  local code attempt
  for attempt in 1 2 3 4 5; do
    code="$(curl -sIL --connect-timeout 30 -o /dev/null -w '%{http_code}' "$1" || true)"
    case "$code" in
      000 | 5??) sleep $((attempt * 3)) ;;
      *) break ;;
    esac
  done
  printf '%s\n' "${code:-000}"
}

# Prints the size of a file in bytes.
file_size() {
  wc -c < "$1" | tr -d ' '
}

# Prints the first value of a "key": "value" pair found in a JSON or JSON5 file.
json_string_value() {
  local key="$1" file="$2"
  grep -E "\"$key\"[[:space:]]*:" "$file" | head -1 | sed -E "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/"
}

# Loads .github/hos-toolchain.env; a variable that is already set and non-empty keeps its value.
load_config() {
  local line key value
  [ -f "$HOS_CONFIG_FILE" ] || die "missing $HOS_CONFIG_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in '' | '#'*) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    if [ -z "${!key:-}" ]; then
      export "$key=$value"
    fi
  done < "$HOS_CONFIG_FILE"
}

# Fails unless every named command is available on PATH.
require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
  done
}
