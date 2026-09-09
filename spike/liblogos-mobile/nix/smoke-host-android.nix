# The liblogos smoke host as an Android APK (pkgs.mkQtAndroidApk), plus
# run-liblogos-android: adb install + launch on the attached device.
{ pkgs, spike, src }:

let
  inherit (pkgs) lib;
  packageName = "co.logos.spike.liblogos";
  activity = "org.qtproject.qt.android.bindings.QtActivity";
  # Every prefix whose lib/*.so must travel in the APK beside liblogos_core.
  # getLib: nixpkgs' openssl/fmt/... default to their bin or dev output.
  libRoots = map lib.getLib (spike.all ++ [ pkgs.spdlog pkgs.fmt pkgs.openssl pkgs.libsodium pkgs.icu pkgs.zlib ]);
  includeRoots = spike.all ++ [ pkgs.boost pkgs.openssl pkgs.spdlog pkgs.nlohmann_json ];
  joined = l: lib.concatStringsSep ";" (map toString l);

  # An APK carries only lib<name>.so; nixpkgs' cross libraries are versioned
  # (libspdlog.so.1.17, libssl.so.3, libicuuc.so.76, ...) and the Logos
  # libraries reference those sonames. Flatten: copy under the unversioned
  # name, rewrite SONAME and every DT_NEEDED to match. Qt's own libraries
  # are androiddeployqt's business and are excluded.
  apkLibs = pkgs.pkgsBuildBuild.runCommand "liblogos-android-apk-libs" {
    nativeBuildInputs = [ pkgs.pkgsBuildBuild.patchelf ];
  } ''
    mkdir -p $out/lib
    for root in ${lib.concatStringsSep " " (map toString libRoots)}; do
      for f in "$root"/lib/lib*.so*; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        case "$name" in libQt6*|*.a|*.la) continue ;; esac
        stem="''${name%%.so*}"
        # Android ships private libicu*/libssl/libcrypto of its own; a
        # DT_NEEDED by the same name resolves to those (seen on the SM-G990B:
        # "cannot locate symbol _ZN6icu_7613UnicodeString8doAppend..."), so
        # give ours unmistakable names.
        case "$stem" in libicu*|libssl|libcrypto) stem="''${stem}_lg" ;; esac
        base="$stem.so"
        [ -L "$f" ] && continue
        cp "$f" "$out/lib/$base"
        chmod u+w "$out/lib/$base"
        patchelf --set-soname "$base" "$out/lib/$base"
      done
    done
    for l in $out/lib/*.so; do
      for n in $(patchelf --print-needed "$l"); do
        stem="''${n%%.so*}"
        case "$stem" in libicu*|libssl|libcrypto) stem="''${stem}_lg" ;; esac
        [ "$n" = "$stem.so" ] || patchelf --replace-needed "$n" "$stem.so" "$l"
      done
    done
    ls -la $out/lib
  '';

  apk = (pkgs.mkQtAndroidApk {
    pname = "liblogos-smoke-android";
    version = "0.1.0";
    inherit src packageName;
    target = "LiblogosSmoke";
    qtModules = with pkgs.qt6; [ qtbase qtremoteobjects ];
    buildInputs = libRoots ++ [ apkLibs ];
    cmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DQT_ADDITIONAL_PACKAGES_PREFIX_PATH=${pkgs.qt6.qtremoteobjects}"
      "-DLOGOS_LIB_ROOTS=${apkLibs}"
      "-DLOGOS_INCLUDE_ROOTS=${joined includeRoots}"
    ];
    meta.description = "liblogos_core smoke host, packaged as an Android APK";
  }).overrideAttrs (old: {
    setSourceRoot = "sourceRoot=$(echo */spike/liblogos-mobile/host/android)";
    gradleFlags = (old.gradleFlags or [ ]) ++ [ "--stacktrace" ];
  });
  apkFile = "${apk}/${apk.apkName}";
  adb = "${pkgs.androidPkgs.androidsdk}/bin/adb";

  runner = pkgs.buildPackages.writeShellScriptBin "run-liblogos-android" ''
    set -euo pipefail
    adb=${adb}; apk=${apkFile}; pkg=${packageName}
    export ANDROID_SERIAL="''${ANDROID_SERIAL:-$("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')}"
    echo "run-liblogos-android: installing $apk on $ANDROID_SERIAL ($(du -k "$apk" | cut -f1) KB)"
    "$adb" install -r "$apk" >/dev/null || { "$adb" uninstall "$pkg" >/dev/null; "$adb" install -r "$apk"; }
    "$adb" logcat -c || true
    "$adb" shell am start -W -n "$pkg/${activity}" >/dev/null
    pid=$("$adb" shell pidof "$pkg" | tr -d '\r')
    echo "run-liblogos-android: $pkg pid $pid; console follows (Ctrl-C to stop)"
    "$adb" logcat --pid="$pid" -v raw '*:V' | grep --line-buffered -E '^\[smoke\]|^\[qt\] .*(warning|error|fatal|Fatal)|LEVEL|libc|DEBUG|FATAL'
  '';
in
{
  liblogos-smoke-android = apk;
  run-liblogos-android = runner;
}
