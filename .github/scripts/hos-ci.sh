#!/usr/bin/env bash
# Toolchain setup, plugin alignment, lint and HAR checks for the HarmonyOS SDK workflows.
#
# Usage: hos-ci.sh <command> [args]
#   config                 Print the effective toolchain settings and write them as step outputs.
#   install-toolchain      Download, verify and unpack the Command Line Tools, then put hvigorw, ohpm,
#                          codelinter, hdc and Emulator on PATH.
#   align-plugin           Drop the hvigor-ohos-plugin pin from hvigor/hvigor-config.json5 when it differs
#                          from the plugin bundled with the active hvigor.
#   lint [OUT_DIR]         Run codelinter with code-linter.json5 and fail per HOS_LINT_FAIL_ON.
#   check-har HAR OUT_DIR  Validate a built HAR and stage it as countly-sdk-hos-<version>.har with a .sha256.
#
# Run from the repository root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

# Prints the platform key used in the HOS_CLT_SHA256_<KEY> settings, such as LINUX_X64.
platform_key() {
  local os arch
  os="${RUNNER_OS:-$(uname -s)}"
  arch="${RUNNER_ARCH:-$(uname -m)}"
  case "$os" in
    Linux) os=LINUX ;;
    macOS | Darwin) os=MACOS ;;
    *) die "unsupported OS: $os" ;;
  esac
  case "$arch" in
    X64 | x86_64 | amd64) arch=X64 ;;
    ARM64 | arm64 | aarch64) arch=ARM64 ;;
    *) die "unsupported architecture: $arch" ;;
  esac
  printf '%s_%s\n' "$os" "$arch"
}

# Prints the mirror archive name for a platform key.
mirror_archive_name() {
  case "$1" in
    LINUX_X64) echo "ohos-sdk-linux-amd64.tar.gz" ;;
    MACOS_ARM64) echo "ohos-sdk-mac-arm64.zip" ;;
    MACOS_X64) echo "ohos-sdk-mac-amd64.zip" ;;
    *) die "no Command Line Tools archive for $1" ;;
  esac
}

# Prints the SHA-256 the archive for this platform must have (HOS_CLT_SHA256_<KEY>).
expected_clt_digest() {
  local var
  var="HOS_CLT_SHA256_$(platform_key)"
  printf '%s\n' "${!var:-}"
}

# Prints the archive URL set in HOS_CLT_URL_<KEY> for this platform, or nothing to use the mirror.
custom_clt_url() {
  local var
  var="HOS_CLT_URL_$(platform_key)"
  printf '%s\n' "${!var:-}"
}

# Prints the folder the Command Line Tools are installed under (cached between runs by the workflows).
clt_home() {
  printf '%s\n' "${HOS_CLT_HOME:-$HOME/hos-clt}"
}

# Prints the effective settings and writes clt_version, clt_home and clt_cache_key as step outputs.
cmd_config() {
  load_config
  local key digest cache_key
  key="$(platform_key)"
  digest="$(expected_clt_digest)"
  cache_key="hos-clt-${key}-${HOS_CLT_VERSION}-${digest:0:12}"
  log "Command Line Tools: ${HOS_CLT_VERSION} (${key})"
  log "Source: $(custom_clt_url | grep . || echo "$HOS_CLT_MIRROR/$HOS_CLT_VERSION/$(mirror_archive_name "$key")")"
  log "Expected SHA-256: ${digest:-<not pinned>}"
  set_output clt_version "$HOS_CLT_VERSION"
  set_output clt_home "$(clt_home)"
  set_output clt_cache_key "$cache_key"
}

# Downloads the archive into DIR, from HOS_CLT_URL_<KEY> or the split mirror parts, and prints its path.
download_clt_archive() {
  local dir="$1" key name base part url archive custom count=0
  custom="$(custom_clt_url)"
  if [ -n "$custom" ]; then
    name="$(basename "${custom%%\?*}")"
    case "$name" in *.zip | *.tar.gz | *.tgz) ;; *) name="$name.${HOS_CLT_ARCHIVE_TYPE:-zip}" ;; esac
    archive="$dir/$name"
    log "Downloading $name"
    fetch "$custom" "$archive" "${HOS_CLT_AUTH_HEADER:-}" || die "download failed: $custom"
    printf '%s\n' "$archive"
    return 0
  fi
  key="$(platform_key)"
  name="$(mirror_archive_name "$key")"
  base="$HOS_CLT_MIRROR/$HOS_CLT_VERSION/$name"
  archive="$dir/$name"
  : > "$archive"
  for part in aa ab ac ad ae af ag ah; do
    url="$base.$part"
    local status
    status="$(http_status "$url")"
    if [ "$status" = "404" ]; then
      break
    fi
    [ "$status" = "200" ] || die "unexpected HTTP $status for $url"
    log "Downloading $name.$part"
    fetch "$url" "$dir/$name.$part" || die "download failed: $url"
    cat "$dir/$name.$part" >> "$archive"
    rm -f "$dir/$name.$part"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "no archive parts found at $base.aa (is HOS_CLT_VERSION $HOS_CLT_VERSION published?)"
  printf '%s\n' "$archive"
}

# Unpacks a .zip or .tar.gz archive into a folder.
unpack_archive() {
  local archive="$1" dest="$2"
  mkdir -p "$dest"
  case "$archive" in
    *.tar.gz | *.tgz) tar -xzf "$archive" -C "$dest" ;;
    *.zip)
      if command -v 7z >/dev/null 2>&1; then
        7z x -y -bd -o"$dest" "$archive" > /dev/null
      else
        unzip -q "$archive" -d "$dest"
      fi
      ;;
    *) die "unknown archive type: $archive" ;;
  esac
}

# Prints the command-line-tools folder inside an unpacked archive.
find_clt_dir() {
  local root="$1" hit
  hit="$(find "$root" -maxdepth 5 -type f -path '*/hvigor/bin/hvigorw.js' -not -path '*/__MACOSX/*' 2>/dev/null | head -1)"
  [ -n "$hit" ] || return 1
  dirname "$(dirname "$(dirname "$hit")")"
}

# Succeeds when DIR holds an unpacked Command Line Tools build of HOS_CLT_VERSION.
clt_is_installed() {
  local dir="$1"
  [ -f "$dir/version.txt" ] && grep -qE "Version: ${HOS_CLT_VERSION}[[:space:]]*\$" "$dir/version.txt" 2>/dev/null
}

# Makes sure the Command Line Tools are unpacked under clt_home, then activates them.
cmd_install_toolchain() {
  load_config
  local home dir expected actual archive tmp
  home="$(clt_home)"
  dir="$home/command-line-tools"
  if clt_is_installed "$dir"; then
    log "Using cached Command Line Tools in $dir"
  else
    expected="$(expected_clt_digest)"
    [ -n "$expected" ] || die "no SHA-256 pinned for the $(platform_key) archive; set HOS_CLT_SHA256_$(platform_key) in .github/hos-toolchain.env or as a repository variable"
    tmp="$home/download"
    rm -rf "$dir" "$tmp"
    mkdir -p "$tmp"
    group "Download Command Line Tools $HOS_CLT_VERSION"
    archive="$(download_clt_archive "$tmp")"
    actual="$(sha256_of "$archive")"
    log "SHA-256 $actual ($(file_size "$archive") bytes)"
    [ "$actual" = "$expected" ] || die "Command Line Tools checksum mismatch: expected $expected, got $actual"
    unpack_archive "$archive" "$tmp/unpacked"
    rm -f "$archive"
    local found
    found="$(find_clt_dir "$tmp/unpacked")" || die "no command-line-tools folder in the archive"
    mv "$found" "$dir"
    rm -rf "$tmp"
    endgroup
    clt_is_installed "$dir" || warn "version.txt in $dir does not mention $HOS_CLT_VERSION"
  fi
  activate_toolchain "$dir"
}

# Writes an executable bash wrapper NAME into BIN_DIR that runs the given command line with its arguments.
write_wrapper() {
  local bin_dir="$1" name="$2"
  shift 2
  local q="" arg
  for arg in "$@"; do
    q+=" $(printf '%q' "$arg")"
  done
  printf '#!/usr/bin/env bash\nexec%s "$@"\n' "$q" > "$bin_dir/$name"
  chmod +x "$bin_dir/$name"
}

# Prints data.version from an sdk-pkg.json file; its meta block carries an unrelated version first.
sdk_pkg_version() {
  grep -E '"version"[[:space:]]*:' "$1" | tail -1 | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}

# Adds the npm scope for @ohos packages and an ohpm registry when the user has not configured them.
configure_registries() {
  local npmrc="$HOME/.npmrc"
  if ! grep -q '^@ohos:registry=' "$npmrc" 2>/dev/null; then
    printf '@ohos:registry=%s\n' "$HOS_NPM_OHOS_REGISTRY" >> "$npmrc"
    log "Added @ohos:registry=$HOS_NPM_OHOS_REGISTRY to $npmrc"
  fi
  if [ ! -f "$HOME/.ohpm/.ohpmrc" ]; then
    ohpm config set registry "$HOS_OHPM_REGISTRY" > /dev/null
    log "Set the ohpm registry to $HOS_OHPM_REGISTRY"
  fi
}

# Puts hvigorw, ohpm, codelinter, hdc and Emulator from a Command Line Tools folder on PATH for this and later steps.
activate_toolchain() {
  local base="$1" node node_dir hvigor_js ohpm_js lint_js sdk emulator_dir plugin_pkg
  hvigor_js="$base/hvigor/bin/hvigorw.js"
  [ -f "$hvigor_js" ] || die "no hvigor found under $base"
  node_dir="$base/tool/node"
  ohpm_js="$base/ohpm/bin/pm-cli.js"
  lint_js="$base/codelinter/index.js"
  emulator_dir="$base/emulator"
  plugin_pkg="$base/hvigor/hvigor-ohos-plugin/package.json"
  sdk="$base/sdk"
  [ -d "$node_dir/bin" ] && node_dir="$node_dir/bin"
  node="$node_dir/node"
  [ -x "$node" ] || die "node not found at $node"
  [ -d "$sdk" ] || die "SDK folder not found at $sdk"

  local bin_dir="${HOS_BIN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/hos-bin}"
  mkdir -p "$bin_dir"
  write_wrapper "$bin_dir" hvigorw "$node" "$hvigor_js"
  write_wrapper "$bin_dir" ohpm "$node" --no-deprecation "$ohpm_js"
  if [ -f "$lint_js" ]; then
    write_wrapper "$bin_dir" codelinter "$node" "$lint_js" "$sdk"
  fi

  local toolchains="$sdk/default/openharmony/toolchains"
  prepend_path "$toolchains"
  [ -d "$emulator_dir" ] && prepend_path "$emulator_dir"
  prepend_path "$node_dir"
  prepend_path "$bin_dir"

  export_var DEVECO_SDK_HOME "$sdk"
  export_var HOS_TOOLCHAIN_DIR "$base"
  export_var HOS_HDC "$toolchains/hdc"
  export_var HOS_EMULATOR "$emulator_dir/Emulator"
  export_var HOS_HVIGOR_PLUGIN_PKG "$plugin_pkg"

  configure_registries

  group "Toolchain versions"
  log "tools:       $base"
  [ -f "$base/version.txt" ] && cat "$base/version.txt" >&2
  log "node:        $("$node" -v)"
  log "hvigor:      $(json_string_value version "$plugin_pkg")"
  log "ohpm:        $(ohpm -v 2>/dev/null | tail -1)"
  if command -v codelinter >/dev/null 2>&1; then
    log "codelinter:  $(codelinter -v 2>/dev/null | tail -1)"
  fi
  log "SDK:         $(sdk_pkg_version "$sdk/default/sdk-pkg.json") (API $(json_string_value apiVersion "$sdk/default/sdk-pkg.json"))"
  if [ -f "$emulator_dir/sdk-pkg.json" ]; then
    log "Emulator:    $(sdk_pkg_version "$emulator_dir/sdk-pkg.json")"
  fi
  if command -v java >/dev/null 2>&1; then
    log "java:        $(java -version 2>&1 | head -1)"
  fi
  endgroup
}

# Removes the hvigor-ohos-plugin pin when it does not match the plugin bundled with the active hvigor.
cmd_align_plugin() {
  local cfg="hvigor/hvigor-config.json5" pinned bundled
  [ -f "$cfg" ] || die "run from the repository root ($cfg not found)"
  [ -n "${HOS_HVIGOR_PLUGIN_PKG:-}" ] || die "run install-toolchain first"
  pinned="$(grep -F '"@ohos/hvigor-ohos-plugin"' "$cfg" | head -1 | sed -E 's|.*"@ohos/hvigor-ohos-plugin"[[:space:]]*:[[:space:]]*"([^"]*)".*|\1|' || true)"
  bundled="$(json_string_value version "$HOS_HVIGOR_PLUGIN_PKG")"
  if [ -z "$pinned" ]; then
    log "hvigor-config.json5 does not pin @ohos/hvigor-ohos-plugin; hvigor uses its bundled $bundled"
    return 0
  fi
  if [ "$pinned" = "$bundled" ]; then
    log "The pinned @ohos/hvigor-ohos-plugin $pinned matches the toolchain"
    return 0
  fi
  if [ "${HOS_KEEP_PLUGIN_PIN:-false}" = "true" ]; then
    warn "Keeping @ohos/hvigor-ohos-plugin $pinned although the toolchain bundles $bundled (HOS_KEEP_PLUGIN_PIN=true)"
    return 0
  fi
  sed -i.bak -E '/"@ohos\/hvigor-ohos-plugin"[[:space:]]*:/d' "$cfg"
  rm -f "$cfg.bak"
  warn "hvigor-config.json5 pins @ohos/hvigor-ohos-plugin $pinned but this toolchain's hvigor is $bundled; the pin is removed for this run so the bundled plugin is used."
  summary "> hvigor-ohos-plugin pin $pinned removed for this run (toolchain bundles $bundled)."
}

# Runs codelinter, writes the JSON report and a summary, annotates findings and fails per HOS_LINT_FAIL_ON.
cmd_lint() {
  local out_dir="${1:-lint-report}" fail_on="${HOS_LINT_FAIL_ON:-error}" report status
  require_cmd codelinter node
  case "$fail_on" in error | warn | none) ;; *) die "HOS_LINT_FAIL_ON must be error, warn or none" ;; esac
  mkdir -p "$out_dir"
  report="$(cd "$out_dir" && pwd)/codelinter.json"
  rm -f "$report"
  set +e
  codelinter -c "$PWD/code-linter.json5" -f json -o "$report" --exit-on error,warn "$PWD" > "$out_dir/codelinter.log" 2>&1
  status=$?
  set -e
  # codelinter exits with a bitmask of the severities found (4 error, 2 warn); anything else is a tool failure.
  case "$status" in
    0 | 2 | 4 | 6) ;;
    *)
      cat "$out_dir/codelinter.log" >&2
      die "codelinter failed to run (exit $status)"
      ;;
  esac
  [ -f "$report" ] || die "codelinter wrote no report"
  HOS_LINT_ROOT="$PWD" HOS_LINT_FAIL_ON="$fail_on" node "$SCRIPT_DIR/lint-report.js" "$report"
}

# Validates a HAR and copies it, with a SHA-256 file, into OUT_DIR as countly-sdk-hos-<version>.har.
cmd_check_har() {
  local har="${1:-}" out_dir="${2:-}" listing pkg expected embedded debug name sha
  [ -n "$har" ] && [ -n "$out_dir" ] || die "usage: hos-ci.sh check-har HAR OUT_DIR"
  [ -s "$har" ] || die "HAR not found or empty: $har"
  listing="$(tar -tzf "$har")" || die "$har is not a gzip tar archive"
  local entry
  for entry in package/oh-package.json5 package/ets/modules.abc package/Index.d.ets; do
    grep -qx "$entry" <<< "$listing" || die "HAR is missing $entry"
  done
  pkg="$(tar -xzOf "$har" package/oh-package.json5)"
  expected="$(json_string_value version library/oh-package.json5)"
  embedded="$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' <<< "$pkg" | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  [ "$embedded" = "$expected" ] || die "HAR version $embedded does not match library/oh-package.json5 $expected"
  debug="$(grep -oE '"debug"[[:space:]]*:[[:space:]]*(true|false)' <<< "$pkg" | head -1 | sed -E 's/.*:[[:space:]]*//')"
  if [ "$debug" = "true" ] && [ "${HOS_ALLOW_DEBUG_HAR:-false}" != "true" ]; then
    die "HAR metadata says debug=true; build it with -p buildMode=release"
  fi
  mkdir -p "$out_dir"
  name="countly-sdk-hos-$embedded.har"
  cp "$har" "$out_dir/$name"
  sha="$(sha256_of "$out_dir/$name")"
  printf '%s  %s\n' "$sha" "$name" > "$out_dir/$name.sha256"
  log "HAR OK: $name, $(file_size "$out_dir/$name") bytes, sha256 $sha"
  set_output har_name "$name"
  summary "### HAR" "" "| File | Size | SHA-256 |" "|---|---|---|" "| \`$name\` | $(file_size "$out_dir/$name") bytes | \`$sha\` |" ""
}

# Dispatches to the command named by the first argument.
main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    config) cmd_config "$@" ;;
    install-toolchain) cmd_install_toolchain "$@" ;;
    align-plugin) cmd_align_plugin "$@" ;;
    lint) cmd_lint "$@" ;;
    check-har) cmd_check_har "$@" ;;
    *) die "usage: hos-ci.sh config|install-toolchain|align-plugin|lint [OUT_DIR]|check-har HAR OUT_DIR" ;;
  esac
}

main "$@"
