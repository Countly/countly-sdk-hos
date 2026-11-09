#!/usr/bin/env bash
# Installs the ohosTest HAP on a connected device or emulator, runs the suite with aa test and
# judges the result from the OHOS_REPORT_RESULT line.
#
# Usage: device-tests.sh <command> [args]
#   classes [LIST_FILE]     Print the describe() names registered in List.test.ets, comma separated.
#   run [HAP] [OUT_DIR]     Install HAP, run every registered suite, write OUT_DIR/aa-test.log and parse it.
#   parse LOG               Summarise an aa test log; exits 1 on any failure, error, crash or empty run.
#
# Settings (environment):
#   HOS_HDC               hdc binary (default: hdc on PATH)
#   HOS_HDC_TARGET        hdc connect key of the device to use (default: the only connected one)
#   HOS_TEST_BUNDLE       bundle name (default: bundleName in AppScope/app.json5)
#   HOS_TEST_MODULE       test module name (default: name in library/src/ohosTest/module.json5)
#   HOS_TEST_CLASSES      suites to run (default: output of the classes command)
#   HOS_TEST_TIMEOUT_MS   per-test timeout passed to aa test (default 60000)
#   HOS_TEST_RUN_LIMIT_S  seconds the whole aa test run may take before it is stopped (default 900)
#   HOS_TEST_MIN_COUNT    fail when fewer tests run than this (default 1)
#
# Run from the repository root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

DEFAULT_LIST="library/src/ohosTest/ets/test/List.test.ets"
DEFAULT_HAP="library/build/default/outputs/ohosTest/library-ohosTest-unsigned.hap"
TEST_RUNNER="/ets/testrunner/OpenHarmonyTestRunner"

# Prints the describe() names of every suite imported by List.test.ets, in import order, comma separated.
cmd_classes() {
  local list="${1:-$DEFAULT_LIST}" dir module file names="" name
  [ -f "$list" ] || die "test list not found: $list"
  dir="$(dirname "$list")"
  while IFS= read -r module; do
    file="$dir/$module.ets"
    if [ ! -f "$file" ]; then
      warn "List.test.ets imports $module but $file does not exist"
      continue
    fi
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      case ",$names," in *",$name,"*) continue ;; esac
      names="${names:+$names,}$name"
    done < <(grep -oE "describe\([\"'][^\"']+[\"']" "$file" | sed -E "s/describe\([\"']([^\"']+)[\"']/\1/")
  done < <(grep -E "^[[:space:]]*import[[:space:]]+[A-Za-z0-9_]+[[:space:]]+from[[:space:]]+'\./[^']+\.test'" "$list" | sed -E "s/.*'\.\/([^']+)'.*/\1/")
  [ -n "$names" ] || die "no describe() suites found through $list"
  printf '%s\n' "$names"
}

# Runs hdc against HOS_HDC_TARGET when it is set, otherwise against the only connected device.
hdc_cmd() {
  local hdc="${HOS_HDC:-hdc}"
  if [ -n "${HOS_HDC_TARGET:-}" ]; then
    "$hdc" -t "$HOS_HDC_TARGET" "$@"
  else
    "$hdc" "$@"
  fi
}

# Prints the connect keys of the devices hdc can see, one per line.
connected_targets() {
  "${HOS_HDC:-hdc}" list targets 2>/dev/null | tr -d '\r' | grep -vE '^[[:space:]]*$|\[Empty\]' || true
}

# Installs the HAP, runs aa test for every registered suite and parses the log.
cmd_run() {
  local hap="${1:-$DEFAULT_HAP}" out_dir="${2:-device-test-results}" bundle module classes timeout_ms run_limit remote install_out targets status
  local hdc_target=()
  [ -s "$hap" ] || die "test HAP not found: $hap"
  mkdir -p "$out_dir"
  bundle="${HOS_TEST_BUNDLE:-$(json_string_value bundleName AppScope/app.json5)}"
  module="${HOS_TEST_MODULE:-$(json_string_value name library/src/ohosTest/module.json5)}"
  classes="${HOS_TEST_CLASSES:-$(cmd_classes)}"
  timeout_ms="${HOS_TEST_TIMEOUT_MS:-60000}"
  run_limit="${HOS_TEST_RUN_LIMIT_S:-900}"
  if [ -n "${HOS_HDC_TARGET:-}" ]; then
    hdc_target=(-t "$HOS_HDC_TARGET")
  fi
  [ -n "$bundle" ] && [ -n "$module" ] || die "could not read the bundle or test module name"

  targets="$(connected_targets)"
  [ -n "$targets" ] || die "hdc sees no device; start an emulator or connect a device first"
  log "Devices: $(tr '\n' ' ' <<< "$targets")"
  if [ -z "${HOS_HDC_TARGET:-}" ] && [ "$(wc -l <<< "$targets" | tr -d ' ')" -gt 1 ]; then
    die "several devices are connected; set HOS_HDC_TARGET to one of: $(tr '\n' ' ' <<< "$targets")"
  fi

  group "Install $(basename "$hap") as $bundle"
  remote="data/local/tmp/countly-ci-$$"
  hdc_cmd uninstall "$bundle" > /dev/null 2>&1 || true
  hdc_cmd shell "mkdir -p $remote"
  hdc_cmd file send "$hap" "$remote/" 2>&1 | tr -d '\r' >&2 || die "hdc file send failed"
  install_out="$(hdc_cmd shell "bm install -p $remote" 2>&1 | tr -d '\r')"
  hdc_cmd shell "rm -rf $remote" || true
  log "$install_out"
  grep -qi "successfully" <<< "$install_out" || die "bm install failed: $install_out"
  hdc_cmd shell "power-shell wakeup" > /dev/null 2>&1 || true
  endgroup

  log "Suites: $classes"
  group "aa test"
  set +e
  with_time_limit "$run_limit" "${HOS_HDC:-hdc}" ${hdc_target[@]+"${hdc_target[@]}"} shell aa test -b "$bundle" -m "$module" \
    -s unittest "$TEST_RUNNER" -s class "$classes" -s timeout "$timeout_ms" 2>&1 | tr -d '\r' | tee "$out_dir/aa-test.log"
  status="${PIPESTATUS[0]}"
  set -e
  endgroup

  if [ "$status" = 124 ]; then
    warn "aa test was stopped after ${run_limit}s (HOS_TEST_RUN_LIMIT_S)"
    hdc_cmd shell "aa dump -a" > "$out_dir/aa-dump.txt" 2>&1 || true
  fi
  hdc_cmd shell "hilog -x" > "$out_dir/hilog.txt" 2>/dev/null || true
  cmd_parse "$out_dir/aa-test.log"
}

# Prints the failing tests of an aa test log as tab separated class#test, status code and message.
failing_tests() {
  awk '
    /^OHOS_REPORT_STATUS: class=/ { cls = substr($0, index($0, "=") + 1); instream = 0; next }
    /^OHOS_REPORT_STATUS: test=/ { tst = substr($0, index($0, "=") + 1); instream = 0; next }
    /^OHOS_REPORT_STATUS: stream=/ { msg = substr($0, index($0, "=") + 1); instream = 1; next }
    /^OHOS_REPORT_STATUS_CODE: / {
      code = substr($0, index($0, ":") + 2) + 0
      if (code == -1 || code == -2) { gsub(/\t/, " ", msg); printf "%s#%s\t%d\t%s\n", cls, tst, code, msg }
      msg = ""; instream = 0; next
    }
    /^OHOS_REPORT/ { instream = 0; next }
    instream && NF > 0 { msg = msg " " $0 }
  ' "$1"
}

# Prints the value of a "Name: N" field from the OHOS_REPORT_RESULT line, or nothing.
result_field() {
  sed -nE "s/.*[[:space:]=]$1:[[:space:]]*([0-9]+).*/\1/p" <<< "$2" | head -1
}

# Summarises an aa test log and fails on failures, errors, a missing result line or too few tests.
cmd_parse() {
  local log_file="${1:-}" result run failure error pass ignore planned min failed_list count=0
  [ -f "$log_file" ] || die "usage: device-tests.sh parse LOG"
  result="$(grep -E '^OHOS_REPORT_RESULT: stream=Tests run:' "$log_file" | tail -1 || true)"
  failed_list="$(failing_tests "$log_file")"
  planned="$(sed -nE 's/^OHOS_REPORT_STATUS: numtests=([0-9]+).*/\1/p' "$log_file" | sort -n | tail -1)"
  min="${HOS_TEST_MIN_COUNT:-1}"

  if [ -z "$result" ]; then
    summary "### Device tests" "" "No OHOS_REPORT_RESULT line: the run crashed or never started. See the aa-test.log artifact." ""
    log "Last lines of $log_file:"
    tail -25 "$log_file" >&2 || true
    die "aa test produced no OHOS_REPORT_RESULT line (crash, install problem or timeout)"
  fi

  run="$(result_field 'Tests run' "$result")"
  failure="$(result_field Failure "$result")"
  error="$(result_field Error "$result")"
  pass="$(result_field Pass "$result")"
  ignore="$(result_field Ignore "$result")"
  log "${result#OHOS_REPORT_RESULT: stream=}"

  summary "### Device tests" "" "| Run | Pass | Failure | Error | Ignore | Planned |" "|---|---|---|---|---|---|" \
    "| ${run:-?} | ${pass:-?} | ${failure:-?} | ${error:-?} | ${ignore:-?} | ${planned:-?} |" ""
  if [ -n "$failed_list" ]; then
    summary "| Test | Code | Message |" "|---|---|---|"
    while IFS=$'\t' read -r name code message; do
      count=$((count + 1))
      if [ "$count" -le 50 ]; then
        summary "| \`$name\` | $code | ${message:0:300} |"
      fi
      if [ -n "${GITHUB_ACTIONS:-}" ] && [ "$count" -le 20 ]; then
        printf '::error title=%s::%s\n' "$(gh_escape "$name")" "$(gh_escape "${message:0:500}")"
      fi
      log "FAILED $name ($code): ${message:0:300}"
    done <<< "$failed_list"
    summary ""
  fi

  if [ -n "$planned" ] && [ -n "$run" ] && [ "$run" -lt "$planned" ]; then
    warn "aa test planned $planned tests but ran $run"
  fi
  [ "${failure:-1}" = "0" ] && [ "${error:-1}" = "0" ] || die "device tests failed: ${failure:-?} failure(s), ${error:-?} error(s)"
  [ "${run:-0}" -ge "$min" ] || die "only ${run:-0} test(s) ran; expected at least $min"
  log "All ${run} device tests passed"
}

# Dispatches to the command named by the first argument.
main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    classes) cmd_classes "$@" ;;
    run) cmd_run "$@" ;;
    parse) cmd_parse "$@" ;;
    *) die "usage: device-tests.sh classes [LIST_FILE] | run [HAP] [OUT_DIR] | parse LOG" ;;
  esac
}

main "$@"
