# The liblogos smoke host: its pure half as a static archive
# (pkgs.mkIosCmakeStage) plus run-liblogos-ios-sim / run-liblogos-ios-device,
# the impure Xcode-generator link and simctl / devicectl step. Same shape as
# nix/shell-preview-ios.nix.
{ pkgs, spike, src }:

let
  inherit (pkgs) lib;
  buildPkgs = pkgs.pkgsBuildBuild;
  appleSdk = pkgs.qt6.qtbase.appleSdk;

  libRoots = spike.all ++ [ pkgs.boost pkgs.openssl pkgs.spdlog ];
  includeRoots = spike.all ++ [ pkgs.boost pkgs.openssl pkgs.spdlog pkgs.nlohmann_json ];
  joined = l: lib.concatStringsSep ";" (map toString l);

  stage = pkgs.mkIosCmakeStage {
    pname = "liblogos-smoke-host-ios";
    version = "0.1.0";
    inherit src;
    sourceDir = "spike/liblogos-mobile/host/stage";
    buildInputs = libRoots;
    cmakeFlags = [
      "-DCMAKE_FIND_ROOT_PATH=${joined libRoots}"
      "-DLOGOS_IOS_LIB_ROOTS=${joined libRoots}"
      "-DLOGOS_IOS_INCLUDE_ROOTS=${joined includeRoots}"
    ];
  };

  buildApp = ''
    ${pkgs.xcodeWrapper.versionGate}

    app_src=${src}/spike/liblogos-mobile/host/app
    bundle_id=co.logos.spike.liblogos
    build_dir="''${LOGOS_IOS_SMOKE_BUILD_DIR:-''${TMPDIR:-/tmp}/liblogos-smoke-ios/$(basename ${stage})}"
    app="$build_dir/Debug-${appleSdk}/LiblogosSmoke.app"

    configure_app() {
      mkdir -p "$build_dir"
      echo "==> configure ($build_dir)"
      cmake -S "$app_src" -B "$build_dir" -G Xcode \
        -DCMAKE_TOOLCHAIN_FILE=${pkgs.logosQtCrossToolchainFile} \
        ${lib.escapeShellArgs pkgs.logosQtCrossCmakeFlags} \
        "-DCMAKE_PREFIX_PATH=${stage}" \
        "-DCMAKE_FIND_ROOT_PATH=${stage};${joined libRoots}" \
        "$@"
    }

    xcodebuild_app() {
      echo "==> xcodebuild (${appleSdk}; full log: $build_dir/xcodebuild.log)"
      rm -rf "$app"
      set +e
      xcodebuild -project "$build_dir/LiblogosSmokeIos.xcodeproj" -target LiblogosSmoke \
        -configuration Debug -sdk ${appleSdk} -arch arm64 "$@" \
        build 2>&1 | tee "$build_dir/xcodebuild.log" | grep -E '^\*\*|error:|warning: .*ld'
      xcode_status=''${PIPESTATUS[0]}
      set -e
      if [ "$xcode_status" -ne 0 ]; then
        echo "xcodebuild failed; see $build_dir/xcodebuild.log" >&2
        exit 1
      fi
      [ -d "$app" ] || { echo "xcodebuild produced no $app" >&2; exit 1; }
      echo "==> app: $app ($(du -sk "$app" | cut -f1) KB; executable $(stat -f %z "$app/LiblogosSmoke") bytes)"
    }
  '';

  runSim = buildPkgs.writeShellApplication {
    name = "run-liblogos-ios-sim";
    runtimeInputs = [ buildPkgs.cmake pkgs.xcodeWrapper ];
    text = ''
      ${buildApp}
      configure_app -DSPIKE_IOS_DEVELOPMENT_TEAM=
      xcodebuild_app CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=

      udid="''${LOGOS_IOS_SIM:-$(xcrun simctl list devices booted | grep -o -m1 '[0-9A-F-]\{36\}' || true)}"
      if [ -z "$udid" ]; then
        udid=$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -o '[0-9A-F-]\{36\}')
        echo "==> no simulator booted; booting $udid"
        xcrun simctl boot "$udid"
      fi
      open -a Simulator --args -CurrentDeviceUDID "$udid"
      xcrun simctl bootstatus "$udid" -b >/dev/null

      echo "==> install + launch on $udid (console attached)"
      xcrun simctl install "$udid" "$app"
      xcrun simctl launch --console-pty "$udid" "$bundle_id" "$@"
    '';
  };

  runDevice = buildPkgs.writeShellApplication {
    name = "run-liblogos-ios-device";
    runtimeInputs = [ buildPkgs.cmake pkgs.xcodeWrapper ];
    text = ''
      device="''${LOGOS_IOS_DEVICE:-}"
      team="''${LOGOS_IOS_TEAM_ID:-}"
      [ -n "$team" ] || { echo "LOGOS_IOS_TEAM_ID is unset" >&2; exit 1; }
      [ -n "$device" ] || { echo "LOGOS_IOS_DEVICE is unset (xcrun devicectl list devices)" >&2; exit 1; }
      ${buildApp}
      configure_app "-DSPIKE_IOS_DEVELOPMENT_TEAM=$team"
      xcodebuild_app -allowProvisioningUpdates
      echo "==> install + launch on $device (console attached)"
      xcrun devicectl device install app --device "$device" "$app"
      xcrun devicectl device process launch --activate --console --terminate-existing \
        --device "$device" "$bundle_id" "$@"
    '';
  };
in
{
  liblogos-smoke-host-ios = stage;
}
// lib.optionalAttrs (appleSdk == "iphonesimulator") { run-liblogos-ios-sim = runSim; }
// lib.optionalAttrs (appleSdk == "iphoneos") { run-liblogos-ios-device = runDevice; }
