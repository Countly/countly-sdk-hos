#!/usr/bin/env bash
# Prepares, creates, boots and stops a HarmonyOS emulator for the device test jobs.
#
# Usage: emulator.sh <command> [args]
#   prepare-host               Check and enable what the emulator needs on this runner: KVM, render node and
#                              libraries on Linux; the hypervisor probe and Mesa software OpenGL on Windows.
#   fetch-image                Download HOS_IMAGE_URL, check HOS_IMAGE_SHA256 and unpack it under the image root.
#   create                     Create the instance HOS_EMULATOR_NAME from the unpacked image.
#   start                      Boot the instance in the background, headless when the emulator supports it.
#   wait-boot                  Wait until hdc sees the device and boot has completed.
#   stop                       Stop the instance.
#   collect-logs OUT_DIR       Copy the emulator logs into OUT_DIR.
#   run-tests [HAP] [OUT_DIR]  Boot (or reuse) the emulator, run device-tests.sh run, collect logs and stop.
#
# Settings (environment):
#   HOS_EMULATOR              Emulator binary (exported by hos-ci.sh use-toolchain)
#   HOS_EMULATOR_NAME         instance name (default ci_phone; letters, digits, spaces, _ and + only)
#   HOS_EMULATOR_HOME         working folder for downloads, instances and logs (default $RUNNER_TEMP/hos-emulator)
#   HOS_INSTANCE_ROOT         instance folder (default $HOS_EMULATOR_HOME/deployed when creating, else the
#                             DevEco default for the OS)
#   HOS_IMAGE_ROOT            folder holding system-image/... (default $HOS_EMULATOR_HOME/sdk when creating,
#                             else the DevEco default for the OS)
#   HOS_EMULATOR_CREATE       true: create a fresh instance before booting (hosted runners)
#   HOS_EMULATOR_REUSE        true: use a device that is already booted and leave it running
#   HOS_EMULATOR_HEADLESS     true: always pass -noWindow; false: never; auto (default): when the help lists it
#   HOS_EMULATOR_MEMORY_GB    instance RAM in GB (default 4)
#   HOS_EMULATOR_STORAGE_GB   instance storage in GB (default 8)
#   HOS_HDC_PORT              port to hdc tconn when the emulator does not register itself (default 5555)
#   HOS_BOOT_TIMEOUT          seconds to wait for boot (default 900)
#   HOS_SOFTWARE_GL           false: skip the Mesa software OpenGL setup on Windows

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

if is_windows; then
  export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
fi
export QEMU_AUDIO_DRV="${QEMU_AUDIO_DRV:-none}"

EMU_NAME="${HOS_EMULATOR_NAME:-ci_phone}"
EMU_HOME="$(posix_path "${HOS_EMULATOR_HOME:-${RUNNER_TEMP:-$HOME}/hos-emulator}")"
LOG_DIR="$EMU_HOME/logs"
PID_FILE="$EMU_HOME/emulator.pid"

# Prints the default instance folder: the job's own folder when creating, else where DevEco keeps them.
instance_root() {
  if [ -n "${HOS_INSTANCE_ROOT:-}" ]; then
    posix_path "$HOS_INSTANCE_ROOT"
  elif [ "${HOS_EMULATOR_CREATE:-false}" = "true" ]; then
    printf '%s\n' "$EMU_HOME/deployed"
  elif is_windows; then
    posix_path "$LOCALAPPDATA/Huawei/Emulator/deployed"
  else
    printf '%s\n' "$HOME/.Huawei/Emulator/deployed"
  fi
}

# Prints the default image root: the job's own folder when creating, else where DevEco keeps images.
image_root() {
  if [ -n "${HOS_IMAGE_ROOT:-}" ]; then
    posix_path "$HOS_IMAGE_ROOT"
  elif [ "${HOS_EMULATOR_CREATE:-false}" = "true" ]; then
    printf '%s\n' "$EMU_HOME/sdk"
  elif is_windows; then
    posix_path "$LOCALAPPDATA/Huawei/Sdk"
  elif is_macos; then
    printf '%s\n' "$HOME/Library/Huawei/Sdk"
  else
    printf '%s\n' "$HOME/Huawei/Sdk"
  fi
}

# Runs the Emulator binary with stdin closed, so a confirmation prompt fails instead of hanging the job.
emu() {
  local bin="${HOS_EMULATOR:-Emulator}"
  "$(posix_path "$bin")" "$@" < /dev/null
}

# Prints the emulator's help text, which differs between emulator versions; cached for the job.
emulator_help() {
  local cache="$EMU_HOME/emulator-help.txt"
  if [ ! -s "$cache" ]; then
    mkdir -p "$EMU_HOME"
    emu -help 2>&1 | tr -d '\r' > "$cache" || true
  fi
  cat "$cache"
}

# Succeeds when the emulator's help mentions an option such as -start or -noWindow.
supports_option() {
  grep -qiE -- "(^|[^A-Za-z0-9_-])$1([^A-Za-z0-9_]|\$)" <<< "$(emulator_help)"
}

# Runs hdc with the given arguments.
hdc_run() {
  "$(posix_path "${HOS_HDC:-hdc}")" "$@"
}

# Prints the connect keys hdc can see, one per line.
hdc_targets() {
  hdc_run list targets 2>/dev/null | tr -d '\r' | grep -vE '^[[:space:]]*$|\[Empty\]' || true
}

# Succeeds when the device behind a connect key reports a completed boot.
boot_completed() {
  [ "$(hdc_run -t "$1" shell param get bootevent.boot.completed 2>/dev/null | tr -d '\r[:space:]')" = "true" ]
}

# Enables KVM for the runner user, installs the emulator libraries and a render node (Linux runners).
prepare_linux() {
  group "KVM"
  echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' | sudo tee /etc/udev/rules.d/99-kvm4all.rules > /dev/null
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=kvm
  ls -l /dev/kvm >&2 || warn "/dev/kvm is missing: this runner has no hardware virtualization"
  endgroup

  group "Emulator libraries"
  local png=libpng16-16 glib=libglib2.0-0
  sudo apt-get update -qq
  # Ubuntu 24.04 renamed these two for the 64-bit time_t transition.
  if apt-cache show libpng16-16t64 > /dev/null 2>&1; then
    png=libpng16-16t64
    glib=libglib2.0-0t64
  fi
  sudo apt-get install -y -qq libatomic1 libpulse0 libegl1 libgbm1 libgl1 "$png" libfontconfig1 libfreetype6 \
    libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0 libxcb-xinerama0 \
    libxcb-xkb1 libsm6 libice6 libxkbcommon-x11-0 libxkbcommon0 "$glib" libgl1-mesa-dri libegl-mesa0 mesa-vulkan-drivers > /dev/null
  endgroup

  group "Render node"
  if ! ls /dev/dri/renderD* > /dev/null 2>&1; then
    # Runners have no GPU; vgem gives Mesa a render node so llvmpipe can stand in for one.
    sudo modprobe vgem 2> /dev/null \
      || { sudo apt-get install -y -qq "linux-modules-extra-$(uname -r)" > /dev/null 2>&1 && sudo modprobe vgem; } \
      || warn "could not load vgem; the emulator may fail to find a render node under /dev/dri"
  fi
  if ls /dev/dri/* > /dev/null 2>&1; then
    sudo chmod 666 /dev/dri/*
    ls -l /dev/dri >&2
  fi
  endgroup
}

# Reports whether a hypervisor is running and puts Mesa's software OpenGL next to Emulator.exe (Windows runners).
prepare_windows() {
  group "Hypervisor"
  powershell.exe -NoProfile -Command '
    $cs = Get-CimInstance Win32_ComputerSystem
    "HypervisorPresent: " + $cs.HypervisorPresent
    foreach ($f in "Microsoft-Hyper-V", "HypervisorPlatform", "VirtualMachinePlatform") {
      $s = Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue
      "{0}: {1}" -f $f, $(if ($s) { $s.State } else { "unknown" })
    }
    (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    "VirtualizationFirmwareEnabled: " + (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
  ' 2>&1 | tr -d '\r' >&2 || true
  if ! powershell.exe -NoProfile -Command '(Get-CimInstance Win32_ComputerSystem).HypervisorPresent' 2>/dev/null | tr -d '\r' | grep -qi true; then
    warn "No hypervisor is running on this runner; the emulator will most likely stop with 00801001 (Hyper-V not enabled)."
  fi
  endgroup

  if [ "${HOS_SOFTWARE_GL:-true}" = "false" ]; then
    return 0
  fi
  load_config
  [ -n "${HOS_EMULATOR:-}" ] || die "HOS_EMULATOR is not set; run hos-ci.sh install-toolchain first"
  group "Mesa llvmpipe (software OpenGL)"
  local dir="$EMU_HOME/mesa" archive emu_dir actual
  mkdir -p "$dir"
  archive="$dir/mesa.7z"
  fetch "$HOS_MESA_URL" "$archive" || die "download failed: $HOS_MESA_URL"
  actual="$(sha256_of "$archive")"
  [ "$actual" = "$HOS_MESA_SHA256" ] || die "Mesa checksum mismatch: expected $HOS_MESA_SHA256, got $actual"
  7z x -y -bd -o"$(native_path "$dir")" "$(native_path "$archive")" > /dev/null
  emu_dir="$(dirname "$(posix_path "$HOS_EMULATOR")")"
  [ -d "$emu_dir" ] || die "emulator folder not found: $emu_dir"
  # An opengl32.dll beside the executable wins over the system one, so only the emulator sees llvmpipe.
  cp "$dir/x64/opengl32.dll" "$dir/x64/libgallium_wgl.dll" "$emu_dir/"
  export_var GALLIUM_DRIVER llvmpipe
  export_var VK_DRIVER_FILES "$(native_path "$dir/x64/lvp_icd.x86_64.json")"
  export_var VK_ICD_FILENAMES "$(native_path "$dir/x64/lvp_icd.x86_64.json")"
  log "Mesa llvmpipe deployed to $emu_dir"
  endgroup
}

# Runs the host preparation for this OS.
cmd_prepare_host() {
  mkdir -p "$EMU_HOME"
  if is_windows; then
    prepare_windows
  elif [ "$(uname -s)" = "Linux" ]; then
    prepare_linux
  else
    log "No host preparation needed on $(uname -s)"
  fi
}

# Downloads and unpacks the system image, then exports HOS_IMAGE_ROOT, HOS_IMAGE_OS_VERSION and HOS_IMAGE_DEVICE_TYPE.
cmd_fetch_image() {
  load_config
  local root marker tmp archive actual pkg image_path rel dest platform api os_version leaf device_type
  root="$(image_root)"
  marker="$root/.hos-image-$HOS_IMAGE_SHA256"
  if [ -f "$marker" ]; then
    log "Image already unpacked under $root"
  else
    tmp="$EMU_HOME/image-download"
    rm -rf "$tmp"
    mkdir -p "$tmp/unpacked" "$root"
    archive="$tmp/image.zip"
    group "Download system image"
    log "$HOS_IMAGE_URL"
    fetch "$HOS_IMAGE_URL" "$archive" || die "image download failed: $HOS_IMAGE_URL"
    actual="$(sha256_of "$archive")"
    log "SHA-256 $actual ($(file_size "$archive") bytes)"
    [ "$actual" = "$HOS_IMAGE_SHA256" ] || die "image checksum mismatch: expected $HOS_IMAGE_SHA256, got $actual"
    if command -v 7z > /dev/null 2>&1; then
      7z x -y -bd -o"$(native_path "$tmp/unpacked")" "$(native_path "$archive")" > /dev/null
    else
      unzip -q "$archive" -d "$tmp/unpacked"
    fi
    rm -f "$archive"
    pkg="$(find "$tmp/unpacked" -maxdepth 2 -name sdk-pkg.json | head -1)"
    [ -n "$pkg" ] || die "the image archive has no sdk-pkg.json"
    image_path="$(json_string_value path "$pkg")"
    case "$image_path" in system-image,*) ;; *) die "unexpected image path in sdk-pkg.json: $image_path" ;; esac
    rel="${image_path//,//}"
    dest="$root/$rel"
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    mv "$(dirname "$pkg")" "$dest"
    rm -rf "$tmp"
    platform="$(json_string_value platformVersion "$dest/sdk-pkg.json")"
    api="$(json_string_value apiVersion "$dest/sdk-pkg.json")"
    printf 'HarmonyOS %s(%s)\n%s\n' "$platform" "$api" "$rel" > "$marker"
    endgroup
  fi
  os_version="$(sed -n 1p "$marker")"
  rel="$(sed -n 2p "$marker")"
  leaf="${rel##*/}"
  device_type="${leaf%%_*}"
  log "Image: $rel ($os_version, device type $device_type)"
  export_var HOS_IMAGE_ROOT "$root"
  export_var HOS_IMAGE_OS_VERSION "$os_version"
  export_var HOS_IMAGE_DEVICE_TYPE "$device_type"
}

# Accepts the emulator licence and creates a fresh instance from the unpacked image.
cmd_create() {
  local inst root
  inst="$(instance_root)"
  root="$(image_root)"
  [ -n "${HOS_IMAGE_OS_VERSION:-}" ] || die "run fetch-image first (HOS_IMAGE_OS_VERSION is not set)"
  mkdir -p "$inst"
  group "Create emulator $EMU_NAME"
  emu -license accept >&2 || warn "Emulator -license accept failed (emulators before 6.1.0 have no -license)"
  if [ -d "$inst/$EMU_NAME" ]; then
    emu -delete "$EMU_NAME" -instancePath "$(native_path "$inst")" -force >&2 || rm -rf "${inst:?}/$EMU_NAME"
  fi
  emu -create "$EMU_NAME" -deviceType "${HOS_IMAGE_DEVICE_TYPE:-phone}" -osVersion "$HOS_IMAGE_OS_VERSION" \
    -instancePath "$(native_path "$inst")" -imageRoot "$(native_path "$root")" \
    -memory "${HOS_EMULATOR_MEMORY_GB:-4}" -storage "${HOS_EMULATOR_STORAGE_GB:-8}" >&2 \
    || die "Emulator -create failed"
  emu -list -details >&2 || true
  endgroup
}

# Boots the instance in the background and records the launcher's PID.
cmd_start() {
  local inst root args
  inst="$(instance_root)"
  root="$(image_root)"
  mkdir -p "$LOG_DIR"
  if [ ! -d "$inst/$EMU_NAME" ]; then
    die "no emulator instance '$EMU_NAME' in $inst (found: $(ls "$inst" 2> /dev/null | tr '\n' ' ')); set HOS_EMULATOR_NAME or, for the self-hosted job, the HOS_SELF_HOSTED_EMULATOR variable"
  fi
  if supports_option -start; then
    args=(-start "$EMU_NAME" -instancePath "$(native_path "$inst")" -imageRoot "$(native_path "$root")")
  else
    args=(-hvd "$EMU_NAME" -path "$(native_path "$inst")" -imageRoot "$(native_path "$root")")
  fi
  case "${HOS_EMULATOR_HEADLESS:-auto}" in
    true) args+=(-noWindow) ;;
    auto) if supports_option -noWindow; then args+=(-noWindow); fi ;;
  esac
  log "Starting: Emulator ${args[*]}"
  local bin
  bin="$(posix_path "${HOS_EMULATOR:-Emulator}")"
  (exec "$bin" "${args[@]}" < /dev/null > "$LOG_DIR/emulator-console.log" 2>&1) &
  echo $! > "$PID_FILE"
}

# Succeeds while the launcher started by cmd_start is still running.
launcher_alive() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2> /dev/null
}

# Waits for the emulator to register with hdc and finish booting, then exports HOS_HDC_TARGET.
cmd_wait_boot() {
  local timeout="${HOS_BOOT_TIMEOUT:-900}" start now target targets last_tconn=0 warned_exit=0
  start="$(date +%s)"
  log "Waiting up to ${timeout}s for the emulator to boot"
  while true; do
    now="$(date +%s)"
    if [ "$warned_exit" = 0 ] && [ -f "$PID_FILE" ] && ! launcher_alive; then
      warned_exit=1
      warn "the emulator launcher exited after $((now - start))s; still waiting in case it detached"
      tail -40 "$LOG_DIR/emulator-console.log" >&2 2> /dev/null || true
    fi
    targets="$(hdc_targets)"
    if [ -z "$targets" ] && [ $((now - last_tconn)) -ge 15 ]; then
      hdc_run tconn "127.0.0.1:${HOS_HDC_PORT:-5555}" > /dev/null 2>&1 || true
      last_tconn="$now"
    fi
    target="$(grep -m1 -E '127\.0\.0\.1|localhost|emulator' <<< "$targets" || head -1 <<< "$targets")"
    if [ -n "$target" ] && boot_completed "$target"; then
      log "Booted in $((now - start))s as $target"
      export_var HOS_HDC_TARGET "$target"
      return 0
    fi
    if [ $((now - start)) -ge "$timeout" ]; then
      tail -60 "$LOG_DIR/emulator-console.log" >&2 2> /dev/null || true
      die "the emulator did not finish booting within ${timeout}s (hdc targets: ${targets:-none})"
    fi
    if [ $(((now - start) % 60)) -lt 5 ]; then
      log "... $((now - start))s, hdc targets: ${targets:-none}"
    fi
    sleep 5
  done
}

# Stops the instance and makes sure the launcher process is gone.
cmd_stop() {
  local i
  emu -stop "$EMU_NAME" >&2 || true
  for i in $(seq 1 30); do
    launcher_alive || break
    sleep 2
  done
  if launcher_alive; then
    kill "$(cat "$PID_FILE")" 2> /dev/null || true
  fi
  rm -f "$PID_FILE"
}

# Copies the console log, the instance logs and its config.ini into OUT_DIR.
cmd_collect_logs() {
  local out="${1:-emulator-logs}" inst log_path
  inst="$(instance_root)"
  mkdir -p "$out"
  cp -R "$LOG_DIR/." "$out/" 2> /dev/null || true
  if [ -d "$inst/$EMU_NAME" ]; then
    cp "$inst/$EMU_NAME/config.ini" "$out/" 2> /dev/null || true
    cp -R "$inst/$EMU_NAME/Log" "$out/instance-Log" 2> /dev/null || true
    log_path="$(sed -nE 's/^logPath=(.*)$/\1/p' "$inst/$EMU_NAME/config.ini" 2> /dev/null | tr -d '\r' | head -1)"
    if [ -n "$log_path" ] && [ -d "$(posix_path "$log_path")" ]; then
      cp -R "$(posix_path "$log_path")" "$out/emulator-logPath" 2> /dev/null || true
    fi
  fi
  log "Emulator logs copied to $out"
}

# Boots or reuses an emulator, runs the device tests and always collects logs and stops what it started.
cmd_run_tests() {
  local hap="${1:-library/build/default/outputs/ohosTest/library-ohosTest-unsigned.hap}" out="${2:-device-test-results}" started=0 status=0 target="" reuse=""
  mkdir -p "$out"
  if [ "${HOS_EMULATOR_REUSE:-false}" = "true" ]; then
    target="$(hdc_targets | head -1)"
    if [ -n "$target" ] && boot_completed "$target"; then
      reuse="$target"
    fi
  fi
  if [ -n "$reuse" ]; then
    log "Reusing the booted device $reuse"
    export HOS_HDC_TARGET="$reuse"
  else
    unset HOS_HDC_TARGET
    if [ "${HOS_EMULATOR_CREATE:-false}" = "true" ]; then
      cmd_create
    fi
    cmd_start
    started=1
    trap 'cmd_collect_logs "$out/emulator"; cmd_stop' EXIT
    cmd_wait_boot
  fi
  bash "$SCRIPT_DIR/device-tests.sh" run "$hap" "$out" || status=$?
  if [ "$started" = 1 ]; then
    trap - EXIT
    cmd_collect_logs "$out/emulator"
    cmd_stop
  fi
  return "$status"
}

# Dispatches to the command named by the first argument.
main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    prepare-host) cmd_prepare_host "$@" ;;
    fetch-image) cmd_fetch_image "$@" ;;
    create) cmd_create "$@" ;;
    start) cmd_start "$@" ;;
    wait-boot) cmd_wait_boot "$@" ;;
    stop) cmd_stop "$@" ;;
    collect-logs) cmd_collect_logs "$@" ;;
    run-tests) cmd_run_tests "$@" ;;
    *) die "usage: emulator.sh prepare-host|fetch-image|create|start|wait-boot|stop|collect-logs OUT_DIR|run-tests [HAP] [OUT_DIR]" ;;
  esac
}

main "$@"
