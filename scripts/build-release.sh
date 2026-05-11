#!/usr/bin/env bash
#
# Build a release-ready .har for countly-sdk-hos.
#
# Pipeline:
#   1. Resolve a DevEco install whose hvigor matches the plugin pinned in
#      hvigor/hvigor-config.json5.
#   2. Clean.
#   3. assembleHap (entry, release) — fails the script if the demo can't link.
#   4. assembleHar (library, release).
#   5. Run the on-device test suite (unless --skip-tests).
#   6. Validate the .har (format, embedded version, debug flag, bytecode).
#   7. Copy to dist/countly-sdk-hos-<version>.har + sha256.
#
# Tests are gated on `hdc list targets` returning a connected device.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --skip-tests       Skip the on-device test step (no device required).
  --skip-hap         Skip the source-based assembleHap smoke build.
  --validate-har     After staging, swap entry's dep to the staged .har and
                     re-build the HAP. Proves the published artifact is
                     consumable. Entry's oh-package.json5 is restored on exit.
  --no-clean         Skip the initial 'hvigor clean'.
  --keep-debug       Don't fail if the .har metadata reports debug=true.
  -h, --help         Show this help.

Environment:
  DEVECO_STUDIO_HOME  Override DevEco install. Should be the .app/Contents path,
                     e.g. "/Applications/DevEco-Studio 2.app/Contents".
EOF
}

SKIP_TESTS=0
SKIP_HAP=0
VALIDATE_HAR=0
NO_CLEAN=0
KEEP_DEBUG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-tests)   SKIP_TESTS=1 ;;
    --skip-hap)     SKIP_HAP=1 ;;
    --validate-har) VALIDATE_HAR=1 ;;
    --no-clean)     NO_CLEAN=1 ;;
    --keep-debug)   KEEP_DEBUG=1 ;;
    -h|--help)      usage; exit 0 ;;
    *)              echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# ---------- output helpers ----------
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_BLU=''; C_BLD=''; C_RST=''
fi
section() { printf '\n%s==> %s%s\n' "$C_BLD$C_BLU" "$*" "$C_RST"; }
ok()      { printf '%s  ✓ %s%s\n' "$C_GRN" "$*" "$C_RST"; }
warn()    { printf '%s  ! %s%s\n' "$C_YEL" "$*" "$C_RST"; }
fail()    { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
LIB_PKG="$REPO_ROOT/library/oh-package.json5"
HV_CFG="$REPO_ROOT/hvigor/hvigor-config.json5"

[ -f "$LIB_PKG" ] || fail "library/oh-package.json5 not found at $LIB_PKG"
[ -f "$HV_CFG" ] || fail "hvigor/hvigor-config.json5 not found at $HV_CFG"

# ---------- version + plugin info ----------
LIB_VERSION=$(grep -E '"version"[[:space:]]*:' "$LIB_PKG" \
  | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
[ -n "$LIB_VERSION" ] || fail "Could not read version from library/oh-package.json5"

PLUGIN_VERSION=$(grep -E '"@ohos/hvigor-ohos-plugin"' "$HV_CFG" \
  | head -1 \
  | sed -E 's/.*"@ohos\/hvigor-ohos-plugin"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
[ -n "$PLUGIN_VERSION" ] || fail "Could not read hvigor plugin version from $HV_CFG"
PLUGIN_MAJOR="${PLUGIN_VERSION%%.*}"

section "Project"
printf '  library version : %s\n' "$LIB_VERSION"
printf '  hvigor plugin   : %s (major %s)\n' "$PLUGIN_VERSION" "$PLUGIN_MAJOR"

# ---------- locate compatible DevEco install ----------
section "Locate DevEco Studio"
CANDIDATES=()
if [ -n "${DEVECO_STUDIO_HOME:-}" ]; then
  CANDIDATES+=("$DEVECO_STUDIO_HOME")
fi
# Preference order: numbered installs first (typically newer side-by-side).
for app in "/Applications/DevEco-Studio 2.app" "/Applications/DevEco-Studio.app"; do
  [ -d "$app" ] && CANDIDATES+=("$app/Contents")
done

DEVECO_HOME=""
for cand in "${CANDIDATES[@]}"; do
  HVIGOR_BIN="$cand/tools/hvigor/bin/hvigorw"
  [ -x "$HVIGOR_BIN" ] || continue
  HV_VER=$("$HVIGOR_BIN" --version 2>/dev/null | tail -1 || true)
  HV_MAJOR="${HV_VER%%.*}"
  # hvigor major must be >= plugin major.
  if [ -n "$HV_MAJOR" ] && [ "$HV_MAJOR" -ge "$PLUGIN_MAJOR" ] 2>/dev/null; then
    DEVECO_HOME="$cand"
    printf '  using           : %s\n' "$cand"
    printf '  hvigor          : %s\n' "$HV_VER"
    break
  else
    warn "skipping $cand (hvigor $HV_VER < required major $PLUGIN_MAJOR)"
  fi
done

[ -n "$DEVECO_HOME" ] || fail "No DevEco install has hvigor >= $PLUGIN_MAJOR.x. Install DevEco Studio $PLUGIN_MAJOR.x or set DEVECO_STUDIO_HOME."

# ---------- env for hvigor ----------
export DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
export NODE_HOME="$DEVECO_HOME/tools/node"
export OHPM_HOME="$DEVECO_HOME/tools/ohpm"
export PATH="$OHPM_HOME/bin:$NODE_HOME/bin:$PATH"

NODE="$NODE_HOME/bin/node"
HVIGOR_JS="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
HDC="$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc"

[ -x "$NODE" ]       || fail "node not executable at $NODE"
[ -f "$HVIGOR_JS" ]  || fail "hvigorw.js not found at $HVIGOR_JS"

run_hvigor() {
  ( cd "$REPO_ROOT" && "$NODE" "$HVIGOR_JS" "$@" )
}

# ---------- clean ----------
if [ "$NO_CLEAN" -eq 0 ]; then
  section "Clean"
  run_hvigor clean --mode module -p product=default --daemon
  ok "clean"
else
  warn "skipping clean (--no-clean)"
fi

# ---------- build HAP ----------
if [ "$SKIP_HAP" -eq 0 ]; then
  section "Build HAP (entry, release)"
  run_hvigor \
    --mode module \
    -p product=default \
    -p buildMode=release \
    assembleHap \
    --analyze=normal --parallel --incremental --daemon
  ok "HAP built"
else
  warn "skipping HAP build (--skip-hap)"
fi

# ---------- build HAR ----------
section "Build HAR (library, release)"
run_hvigor \
  --mode module \
  -p product=default \
  -p module=library@default \
  -p buildMode=release \
  assembleHar \
  --analyze=normal --parallel --incremental --daemon

HAR_SRC="$REPO_ROOT/library/build/default/outputs/default/library.har"
[ -s "$HAR_SRC" ] || fail "HAR not produced at $HAR_SRC"
ok "HAR built: $HAR_SRC"

# ---------- run tests ----------
if [ "$SKIP_TESTS" -eq 0 ]; then
  section "Run tests on device"

  [ -x "$HDC" ] || fail "hdc not found at $HDC"

  TARGETS=$("$HDC" list targets 2>/dev/null | grep -v -E '^\s*$|^\[Empty\]' || true)
  if [ -z "$TARGETS" ]; then
    fail "No HarmonyOS device connected. Connect a device or re-run with --skip-tests."
  fi
  printf '  device(s)       : %s\n' "$(echo "$TARGETS" | tr '\n' ' ')"

  # Discover test classes from describe('XxxTest', ...) in files imported by List.test.ets.
  LIST_TS="$REPO_ROOT/library/src/ohosTest/ets/test/List.test.ets"
  [ -f "$LIST_TS" ] || fail "Test entry $LIST_TS not found"

  TEST_DIR="$(dirname "$LIST_TS")"
  CLASS_LIST=""
  while IFS= read -r imported; do
    test_file="$TEST_DIR/${imported}.ets"
    [ -f "$test_file" ] || { warn "test file missing: $test_file"; continue; }
    cls=$(grep -oE "describe\([\"'][^\"']+[\"']" "$test_file" \
      | head -1 \
      | sed -E "s/describe\([\"']([^\"']+)[\"']/\1/")
    if [ -n "$cls" ]; then
      CLASS_LIST="${CLASS_LIST:+$CLASS_LIST,}$cls"
    else
      warn "no describe() in $test_file"
    fi
  done < <(grep -E "^import [a-zA-Z]+ from '\./[^']+\.test'" "$LIST_TS" \
            | sed -E "s/.*'\.\/([^']+)'.*/\1/")

  [ -n "$CLASS_LIST" ] || fail "No test classes discovered from List.test.ets"
  printf '  test classes    : %s\n' "$CLASS_LIST"

  section "Build test HAP"
  run_hvigor \
    --mode module \
    -p module=library@ohosTest \
    -p isOhosTest=true \
    -p product=default \
    -p buildMode=test \
    genOnDeviceTestHap \
    --analyze=normal --parallel --incremental --daemon

  TEST_HAP="$REPO_ROOT/library/build/default/outputs/ohosTest/library-ohosTest-unsigned.hap"
  [ -s "$TEST_HAP" ] || fail "Test HAP not produced at $TEST_HAP"
  ok "test HAP: $TEST_HAP"

  BUNDLE="ly.count.sdk.hos.demo"
  TMP_REMOTE="data/local/tmp/countly-test-$$"

  section "Install test HAP"
  "$HDC" uninstall "$BUNDLE" >/dev/null 2>&1 || true
  "$HDC" shell "mkdir -p $TMP_REMOTE"
  "$HDC" file send "$TEST_HAP" "$TMP_REMOTE/" >/dev/null
  "$HDC" shell "bm install -p $TMP_REMOTE"
  "$HDC" shell "rm -rf $TMP_REMOTE"
  ok "installed $BUNDLE"

  section "Run aa test"
  TEST_LOG="$REPO_ROOT/dist/test-output.log"
  mkdir -p "$(dirname "$TEST_LOG")"
  set +e
  "$HDC" shell aa test \
    -b "$BUNDLE" \
    -m library_test \
    -s unittest /ets/testrunner/OpenHarmonyTestRunner \
    -s class "$CLASS_LIST" \
    -s timeout 30000 \
    2>&1 | tee "$TEST_LOG"
  AA_STATUS=${PIPESTATUS[0]}
  set -e

  RESULT_LINE=$(grep -E "OHOS_REPORT_RESULT:\s*stream=Tests run:" "$TEST_LOG" | tail -1 || true)
  if [ -z "$RESULT_LINE" ]; then
    fail "Could not find OHOS_REPORT_RESULT line in test output (see $TEST_LOG). aa exit=$AA_STATUS"
  fi

  FAILURE=$(echo "$RESULT_LINE" | sed -nE 's/.*Failure:[[:space:]]*([0-9]+).*/\1/p')
  ERROR=$(echo   "$RESULT_LINE" | sed -nE 's/.*Error:[[:space:]]*([0-9]+).*/\1/p')
  TOTAL=$(echo   "$RESULT_LINE" | sed -nE 's/.*Tests run:[[:space:]]*([0-9]+).*/\1/p')
  PASS=$(echo    "$RESULT_LINE" | sed -nE 's/.*Pass:[[:space:]]*([0-9]+).*/\1/p')

  printf '  total=%s pass=%s failure=%s error=%s\n' "${TOTAL:-?}" "${PASS:-?}" "${FAILURE:-?}" "${ERROR:-?}"

  if [ "${FAILURE:-0}" != "0" ] || [ "${ERROR:-0}" != "0" ]; then
    fail "tests failed — see $TEST_LOG"
  fi
  ok "all tests passed"
else
  warn "skipping tests (--skip-tests)"
fi

# ---------- validate HAR ----------
section "Validate HAR"

tar -tzf "$HAR_SRC" >/dev/null 2>&1 \
  || fail "$HAR_SRC is not a valid gzip-tar archive"
ok "format: gzip-tar"

HAR_LISTING=$(tar -tzf "$HAR_SRC")

echo "$HAR_LISTING" | grep -q '^package/oh-package.json5$' \
  || fail "HAR missing package/oh-package.json5"

echo "$HAR_LISTING" | grep -q '^package/ets/modules.abc$' \
  || fail "HAR missing compiled bytecode (package/ets/modules.abc)"

echo "$HAR_LISTING" | grep -q '^package/Index.d.ets$' \
  || fail "HAR missing entry declaration (package/Index.d.ets)"

ok "structure: oh-package.json5 + modules.abc + Index.d.ets"

EMBED_PKG=$(tar -xzOf "$HAR_SRC" package/oh-package.json5)
EMBED_VERSION=$(echo "$EMBED_PKG" \
  | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' \
  | head -1 \
  | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
[ "$EMBED_VERSION" = "$LIB_VERSION" ] \
  || fail "Embedded version '$EMBED_VERSION' != library/oh-package.json5 '$LIB_VERSION'"
ok "embedded version: $EMBED_VERSION"

EMBED_DEBUG=$(echo "$EMBED_PKG" \
  | grep -oE '"debug"[[:space:]]*:[[:space:]]*(true|false)' \
  | head -1 \
  | sed -E 's/.*:[[:space:]]*(true|false)/\1/')
if [ "$EMBED_DEBUG" = "true" ]; then
  if [ "$KEEP_DEBUG" -eq 1 ]; then
    warn "HAR metadata has debug=true (allowed by --keep-debug)"
  else
    fail "HAR metadata has debug=true — not a release build. Re-run with release variant or pass --keep-debug."
  fi
else
  ok "release build (debug=${EMBED_DEBUG:-unset})"
fi

if echo "$HAR_LISTING" | grep -q 'sourceMaps\.map'; then
  warn "HAR contains sourceMaps.map (acceptable; flagging for awareness)"
fi

# ---------- rename + checksum ----------
section "Stage release artifact"
mkdir -p "$DIST_DIR"
RELEASE_NAME="countly-sdk-hos-${LIB_VERSION}.har"
RELEASE_HAR="$DIST_DIR/$RELEASE_NAME"
cp "$HAR_SRC" "$RELEASE_HAR"
( cd "$DIST_DIR" && shasum -a 256 "$RELEASE_NAME" > "${RELEASE_NAME}.sha256" )

RELEASE_SIZE=$(wc -c < "$RELEASE_HAR" | tr -d ' ')
RELEASE_SHA=$(awk '{print $1}' "${RELEASE_HAR}.sha256")

# ---------- (optional) validate by consuming the .har from entry ----------
if [ "$VALIDATE_HAR" -eq 1 ]; then
  section "Validate HAR via entry consumption"

  ENTRY_PKG="$REPO_ROOT/entry/oh-package.json5"
  ENTRY_LIBS="$REPO_ROOT/entry/libs"
  [ -f "$ENTRY_PKG" ] || fail "entry/oh-package.json5 not found"

  ENTRY_BACKUP="$(mktemp -t countly-entry-pkg.XXXXXX)"
  cp "$ENTRY_PKG" "$ENTRY_BACKUP"
  printf '  backup          : %s\n' "$ENTRY_BACKUP"

  restore_entry() {
    if [ -f "$ENTRY_BACKUP" ]; then
      cp "$ENTRY_BACKUP" "$ENTRY_PKG"
      rm -f "$ENTRY_BACKUP"
      rm -f "$ENTRY_LIBS/countly-sdk-hos-"*.har 2>/dev/null || true
      # Clear the empty libs dir if we created it.
      rmdir "$ENTRY_LIBS" 2>/dev/null || true
      # Refresh oh_modules so the source dep is wired back up.
      ( cd "$REPO_ROOT" && ohpm install --all ) >/dev/null 2>&1 || true
      printf '%s  restored entry/oh-package.json5%s\n' "$C_YEL" "$C_RST"
    fi
  }
  trap restore_entry EXIT

  # Stage the .har inside entry/libs so the file: path is self-contained.
  mkdir -p "$ENTRY_LIBS"
  cp "$RELEASE_HAR" "$ENTRY_LIBS/$RELEASE_NAME"

  # Rewrite the countly-sdk-hos dep. sed -i.tmp is portable across BSD and GNU.
  sed -i.tmp -E \
    "s|\"countly-sdk-hos\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"countly-sdk-hos\": \"file:./libs/$RELEASE_NAME\"|" \
    "$ENTRY_PKG"
  rm -f "${ENTRY_PKG}.tmp"

  if ! grep -q "file:./libs/$RELEASE_NAME" "$ENTRY_PKG"; then
    fail "Failed to rewrite entry/oh-package.json5 (no countly-sdk-hos dep matched)."
  fi
  ok "entry now consumes file:./libs/$RELEASE_NAME"

  ( cd "$REPO_ROOT" && ohpm install --all )

  section "Build HAP consuming .har"
  run_hvigor \
    --mode module \
    -p product=default \
    -p buildMode=release \
    assembleHap \
    --analyze=normal --parallel --incremental --daemon
  ok "HAP built against the released .har"
fi

section "Done"
printf '  %s%s%s\n' "$C_BLD" "$RELEASE_HAR" "$C_RST"
printf '  size   : %s bytes\n' "$RELEASE_SIZE"
printf '  sha256 : %s\n' "$RELEASE_SHA"
printf '\nNext:\n  gh release create %s %s --title %s --notes-file <(awk "/^## %s$/{f=1;print;next}/^## /{f=0}f" CHANGELOG.md)\n' \
  "$LIB_VERSION" \
  "$RELEASE_HAR ${RELEASE_HAR}.sha256" \
  "$LIB_VERSION" \
  "$LIB_VERSION"
