#!/usr/bin/env bash
# iOS dlopen spike runner. Mirrors nix/shell-preview-ios.nix's run-ios-sim /
# run-ios-device (same toolchain, same store stages) but configures the app
# with the spike switched on and the three frameworks embedded.
#
# usage: run.sh sim|device [--mode dynamic_lookup|bundle_loader] [--export all|list]
#                          [--no-fixup-chains | --fixup-chains] [--no-qt-patch] [--no-launch] [--device <udid>]
# env:   SPIKE_BASE   worktree whose nix stages are used (default: ~/Repos/agents/basecamp-ios-device;
#                     identical sources, keeps the stages cached while this worktree changes)
#        LOGOS_IOS_TEAM_ID  required for device
set -euo pipefail
export NIX_CONFIG="experimental-features = nix-command flakes"

kind=$1; shift
mode=dynamic_lookup; export_mode=all; nochains=""; qtpatch=1; launch=1; device="${LOGOS_IOS_DEVICE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode=$2; shift 2 ;;
    --export) export_mode=$2; shift 2 ;;
    --no-fixup-chains) nochains=--no-fixup-chains; shift ;;
    --fixup-chains) nochains=--fixup-chains; shift ;;
    --no-qt-patch) qtpatch=0; shift ;;
    --no-launch) launch=0; shift ;;
    --device) device=$2; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
base=${SPIKE_BASE:-$HOME/Repos/agents/basecamp-ios-device}
case "$kind" in
  sim)    sys=aarch64-ios-simulator; runner=run-ios-sim;    sdk=iphonesimulator ;;
  device) sys=aarch64-ios;           runner=run-ios-device; sdk=iphoneos ;;
  *) echo "sim|device" >&2; exit 1 ;;
esac

echo "==> nix stages from $base ($sys)"
mapfile -t stores < <(nix build "$base#packages.$sys.shell-preview-ios" "$base#packages.$sys.main-ui-plugin" \
  "$base#packages.$sys.design-system" "$base#packages.$sys.$runner" --no-link --print-out-paths 2>/dev/null)
stage=${stores[0]}; mainui=${stores[1]}; ds=${stores[2]}; runner_path=${stores[3]}
runner_script="$runner_path/bin/$runner"

toolchain=$(grep -o 'DCMAKE_TOOLCHAIN_FILE=[^ ]*' "$runner_script" | head -1 | cut -d= -f2)
cross_line=$(grep -m1 "CMAKE_OSX_SYSROOT" "$runner_script" | sed 's/ \\$//')
eval "cross_flags=($cross_line)"
scan_roots=$(grep -o '"-DBASECAMP_QML_SCAN_ROOTS=[^"]*"' "$runner_script" | head -1 | tr -d '"')
QT_TARGET=$(cd "$(dirname "$toolchain")/../../.." && pwd)
QT_HOST=$(grep -o 'DQT_HOST_PATH=[^ '"'"']*' "$runner_script" | head -1 | cut -d= -f2)
export QT_TARGET QT_HOST
# The runner's cmake (nix, 4.x); the system one may be too old for the Qt finalizers.
cmake_bin=$(grep -o '/nix/store/[a-z0-9]*-cmake-[^:"/]*/bin' "$runner_script" | head -1)
export PATH="$cmake_bin:$PATH"
echo "    cmake=$(command -v cmake) ($(cmake --version | head -1))"
echo "    QT_TARGET=$QT_TARGET"
echo "    QT_HOST=$QT_HOST"

build="${SPIKE_BUILD_DIR:-${TMPDIR:-/tmp}/spike-ios-dlopen/$kind-$mode-$export_mode${nochains:+-${nochains#--}}}"
mkdir -p "$build"
fws="$build/frameworks"
app_build="$build/app"
app="$app_build/Debug-$sdk/BasecampShellPreview.app"
exe="$app/BasecampShellPreview"
bundle_id=co.logos.basecamp.shellpreview

# Visibility-patched QtCore (see patch-visibility.py); keyed on the store path.
qt_export_archives=""
if [ "$qtpatch" = 1 ]; then
  patched="$build/../qt-exported/$(basename "$QT_TARGET")/libQt6CoreExported.a"
  if [ ! -f "$patched" ]; then
    mkdir -p "$(dirname "$patched")"
    python3 "$here/patch-visibility.py" "$QT_TARGET/lib/QtCore.framework/QtCore" "$patched"
  fi
  qt_export_archives="$patched"
fi

# Pass 1 frameworks (bundle_loader needs the linked app first; build with
# dynamic_lookup now, relink after the app exists).
fw_mode=$mode; [ "$mode" = bundle_loader ] && fw_mode=dynamic_lookup
"$here/build-frameworks.sh" "$sdk" "$fws" --mode "$fw_mode" $nochains

# Qt symbols SpikeUi needs = its undefined symbols that a Qt archive defines.
nm -gU "$QT_TARGET/lib/QtCore.framework/QtCore" 2>/dev/null | awk '{print $3}' | sort -u > "$fws/qtcore-defined.txt"
comm -12 "$fws/ui-undefined-all.txt" "$fws/qtcore-defined.txt" > "$fws/ui-undefined.txt"
echo "==> SpikeUi needs $(wc -l < "$fws/ui-undefined.txt" | tr -d ' ') QtCore symbols from the app"

team_flag=(-DBASECAMP_IOS_DEVELOPMENT_TEAM=)
sign_flags=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
if [ "$kind" = device ]; then
  : "${LOGOS_IOS_TEAM_ID:?LOGOS_IOS_TEAM_ID required for device}"
  team_flag=("-DBASECAMP_IOS_DEVELOPMENT_TEAM=$LOGOS_IOS_TEAM_ID")
  sign_flags=(-allowProvisioningUpdates)
fi

configure() {
  echo "==> configure ($app_build)"
  cmake -S "$repo/shell-preview/platform/ios/app" -B "$app_build" -G Xcode \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" "${cross_flags[@]}" \
    "-DCMAKE_PREFIX_PATH=$stage;$mainui;$ds" "-DCMAKE_FIND_ROOT_PATH=$stage;$mainui;$ds" \
    "$scan_roots" "-DBASECAMP_FIXTURE=$repo/shell-preview/fixtures/shell-fixture.json" \
    -DSPIKE_IOS_DLOPEN=ON "-DSPIKE_FRAMEWORKS_DIR=$fws" \
    "-DSPIKE_QT_EXPORT_ARCHIVES=$qt_export_archives" "-DSPIKE_UNDEFINED_SYMBOLS=$fws/ui-undefined.txt" \
    "-DSPIKE_EXPORT_MODE=$export_mode" "${team_flag[@]}" > "$build/configure.log" 2>&1 \
    || { tail -30 "$build/configure.log"; exit 1; }
}
xcodebuild_app() {
  echo "==> xcodebuild ($sdk; log $build/xcodebuild.log)"
  rm -rf "$app"
  set +e
  xcodebuild -project "$app_build/BasecampShellPreviewIos.xcodeproj" -target BasecampShellPreview \
    -configuration Debug -sdk "$sdk" -arch arm64 "$@" build > "$build/xcodebuild.log" 2>&1
  st=$?
  set -e
  grep -E '^\*\*|error:|warning: .*ld|ld: ' "$build/xcodebuild.log" | head -40 || true
  [ "$st" -eq 0 ] || { echo "xcodebuild failed; see $build/xcodebuild.log" >&2; exit 1; }
}

configure
xcodebuild_app "${sign_flags[@]}"

if [ "$mode" = bundle_loader ]; then
  echo "==> pass 2: relink frameworks with -bundle_loader against $exe"
  "$here/build-frameworks.sh" "$sdk" "$fws" --mode bundle_loader --app "$exe" $nochains
  xcodebuild_app "${sign_flags[@]}"
fi

# ---- measurements ----
{
  echo "mode=$mode export=$export_mode fixup_chains=${nochains:-default} qt_patch=$qtpatch sdk=$sdk"
  echo "app exe bytes: $(stat -f%z "$exe")"
  echo "app bundle bytes: $(du -sk "$app" | cut -f1)K"
  for n in BareA BareB SpikeUi; do
    echo "$n bytes: $(stat -f%z "$app/Frameworks/$n.framework/$n")  $(codesign -dv "$app/Frameworks/$n.framework" 2>&1 | grep -E 'TeamIdentifier|Signature' | tr '\n' ' ')"
  done
  echo "exported symbols (nm -gU): $(nm -gU "$exe" | wc -l | tr -d ' ')"
  echo "export trie: $(otool -l "$exe" | grep -A3 LC_DYLD_EXPORTS_TRIE | grep datasize)"
  echo "chained fixups: $(otool -l "$exe" | grep -A3 LC_DYLD_CHAINED_FIXUPS | grep datasize)"
  echo "app codesign: $(codesign -dvv "$exe" 2>&1 | grep -E 'TeamIdentifier|Authority=Apple Dev' | tr '\n' ' ')"
} | tee "$build/measurements.txt"

[ "$launch" = 1 ] || exit 0

log="$build/launch.log"
echo "==> launch (console captured to $log for 25 s)"
if [ "$kind" = sim ]; then
  udid=$(xcrun simctl list devices booted | grep -o -m1 '[0-9A-F-]\{36\}')
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  xcrun simctl install "$udid" "$app"
  set +e
  timeout 25 xcrun simctl launch --console-pty "$udid" "$bundle_id" > "$log" 2>&1
  set -e
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
else
  [ -n "$device" ] || device=$(xcrun devicectl list devices --hide-headers 2>/dev/null | grep -oE '[0-9A-F-]{36} +(available \(paired\)|connected)' | head -1 | cut -d' ' -f1)
  xcrun devicectl device install app --device "$device" "$app"
  set +e
  timeout 25 xcrun devicectl device process launch --console --terminate-existing --device "$device" "$bundle_id" > "$log" 2>&1
  set -e
fi
grep -E '\[spike\]|SPIKE RESULT|dyld|Library not loaded|Symbol not found|code signature|qFatal' "$log" || { echo "no spike output; log:"; tail -40 "$log"; }
