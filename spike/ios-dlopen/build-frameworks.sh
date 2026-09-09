#!/usr/bin/env bash
# Builds the three spike frameworks with Xcode's clang directly (no nix, no
# CMake): BareA, BareB (Level 1 / 3) and SpikeUi (Level 2).
#
# usage: build-frameworks.sh <iphonesimulator|iphoneos> <out-dir>
#          [--mode dynamic_lookup|bundle_loader] [--app <path-to-linked-executable>]
#          [--no-fixup-chains | --fixup-chains]
# env:   QT_TARGET (static iOS qtbase prefix, headers), QT_HOST (host qtbase, moc/rcc)
set -euo pipefail

sdk=$1; out=$2; shift 2
mode=dynamic_lookup; app=""; nochains=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode=$2; shift 2 ;;
    --app) app=$2; shift 2 ;;
    --no-fixup-chains) nochains=1; shift ;;
    --fixup-chains) nochains=force; shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done
: "${QT_TARGET:?set QT_TARGET}" "${QT_HOST:?set QT_HOST}"

here=$(cd "$(dirname "$0")" && pwd)
min=17.0
case "$sdk" in
  iphonesimulator) target="arm64-apple-ios${min}-simulator"; platform=iPhoneSimulator ;;
  iphoneos)        target="arm64-apple-ios${min}";           platform=iPhoneOS ;;
  *) echo "sdk must be iphonesimulator or iphoneos" >&2; exit 1 ;;
esac
sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
cc=(xcrun --sdk "$sdk" clang -target "$target" -isysroot "$sysroot")
cxx=(xcrun --sdk "$sdk" clang++ -target "$target" -isysroot "$sysroot" -std=c++17 -stdlib=libc++)

obj="$out/obj"; rm -rf "$out"; mkdir -p "$obj"

# Linker flags under test.
link_flags=()
case "$mode" in
  dynamic_lookup)
    # MH_DYLIB, undefined symbols left for dyld's flat lookup at load time.
    link_flags+=(-dynamiclib -Wl,-undefined,dynamic_lookup) ;;
  bundle_loader)
    # MH_BUNDLE bound in two-level namespace against the executable's exports.
    [ -x "$app" ] || { echo "--mode bundle_loader needs --app <linked executable>" >&2; exit 1; }
    link_flags+=(-bundle -Wl,-bundle_loader,"$app") ;;
  *) echo "bad --mode $mode" >&2; exit 1 ;;
esac
[ "$nochains" = 1 ] && link_flags+=(-Wl,-no_fixup_chains)
[ "$nochains" = force ] && link_flags+=(-Wl,-fixup_chains)

mk_framework() { # name binary
  local name=$1 bin=$2 fw="$out/$name.framework"
  mkdir -p "$fw"
  cp "$bin" "$fw/$name"
  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>co.logos.spike.$name</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>$min</string>
</dict></plist>
EOF
}

link() { # name objs...
  local name=$1; shift
  local install_name=()
  [ "$mode" = dynamic_lookup ] && install_name=(-install_name "@rpath/$name.framework/$name")
  echo "==> link $name ($mode)"
  set -x
  "${cxx[@]}" "${link_flags[@]}" "${install_name[@]}" -Wl,-dead_strip -o "$obj/$name" "$@"
  set +x
  mk_framework "$name" "$obj/$name"
}

# --- BareA / BareB: C, no Qt, no protocol; lp_protocol_version undefined ---
for tag in A B; do
  "${cc[@]}" -O2 -fvisibility=hidden -DSPIKE_MODULE_TAG="\"$tag\"" -c "$here/bare/bare_module.c" -o "$obj/bare_$tag.o"
  link "Bare$tag" "$obj/bare_$tag.o"
done

# --- SpikeUi: QObject + moc + Q_PROPERTY + qrc, compiled against Qt headers, NO Qt linked ---
qtinc=(-F"$QT_TARGET/lib" -I"$QT_TARGET/lib/QtCore.framework/Headers" -DQT_NO_DEBUG -DQT_NO_KEYWORDS_UNUSED)
"$QT_HOST/libexec/moc" "$here/ui/SpikeUiModule.h" -o "$obj/moc_SpikeUiModule.cpp"
"$QT_HOST/libexec/rcc" --name spike "$here/ui/spike.qrc" -o "$obj/qrc_spike.cpp"
for f in "$here/ui/SpikeUiModule.cpp" "$obj/moc_SpikeUiModule.cpp" "$obj/qrc_spike.cpp"; do
  "${cxx[@]}" -O2 -fvisibility=hidden -fvisibility-inlines-hidden "${qtinc[@]}" -c "$f" -o "$obj/$(basename "${f%.cpp}").o"
done
link SpikeUi "$obj/SpikeUiModule.o" "$obj/moc_SpikeUiModule.o" "$obj/qrc_spike.o"

# Everything SpikeUi leaves undefined; run.sh intersects this with what the
# Qt archives define to get the list the app must pull in and export.
nm -u "$obj/SpikeUi" | sort > "$out/ui-undefined-all.txt"
echo "==> SpikeUi undefined symbols: $(wc -l < "$out/ui-undefined-all.txt")"

for n in BareA BareB SpikeUi; do
  echo "==> $n: $(stat -f%z "$out/$n.framework/$n") bytes; $(file -b "$out/$n.framework/$n" | cut -c1-80)"
  otool -l "$out/$n.framework/$n" | grep -E 'LC_DYLD_CHAINED_FIXUPS|LC_DYLD_INFO|LC_ID_DYLIB' | sort -u | tr '\n' ' '; echo
done
