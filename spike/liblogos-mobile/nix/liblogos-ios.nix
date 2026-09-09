# liblogos_core and everything it links, as static archives for one iOS
# package set (pkgsIosSimulator or pkgsIos from logos-nix). One
# pkgs.mkIosCmakeStage per repo, in dependency order, mirroring each repo's
# own nix/default.nix flags. Sources are the flake inputs plus the patches
# under ../patches (each one listed in ../SPIKE-REPORT.md).
{
  pkgs,
  # Source trees (flake inputs' outPath).
  srcs, # { protocol, pluginQt, package, module, processStats, containerSubprocess, moduleLoaderQt, packageManager, liblogos }
  # Build-platform packages whose outputs are platform-neutral: header-only
  # libraries and INTERFACE-only CMake packages.
  native, # { cppSdk, qtSdk, logosContainer, logosModuleLoader, cppSemver }
}:

let
  inherit (pkgs) lib;
  buildPkgs = pkgs.pkgsBuildBuild;
  patchDir = ../patches;

  patched =
    name: src: patches:
    buildPkgs.applyPatches {
      inherit name src patches;
    };

  # An iOS sysroot puts find_package in root-only mode; every input has to be
  # a root, not just a prefix.
  roots = inputs: "-DCMAKE_FIND_ROOT_PATH=${lib.concatStringsSep ";" (map toString inputs)}";

  thirdParty = [
    pkgs.boost
    pkgs.openssl
    pkgs.spdlog
    pkgs.nlohmann_json
  ];

  protocol = pkgs.mkIosCmakeStage {
    pname = "logos-protocol-ios";
    version = "0.1.0";
    src = patched "logos-protocol" srcs.protocol [ "${patchDir}/logos-protocol-optional-shared.patch" ];
    sourceDir = "cpp";
    buildInputs = thirdParty;
    cmakeFlags = [
      (roots thirdParty)
      "-DOPENSSL_ROOT_DIR=${pkgs.openssl}"
      "-DLOGOS_PROTOCOL_BUILD_SHARED=OFF"
    ];
  };

  qtHost = pkgs.mkIosCmakeStage {
    pname = "logos-qt-host-ios";
    version = "0.1.0";
    src = patched "logos-plugin-qt" srcs.pluginQt [ "${patchDir}/logos-plugin-qt-optional-shared.patch" ];
    sourceDir = "cpp";
    buildInputs = thirdParty ++ [ protocol ];
    cmakeFlags = [
      (roots (thirdParty ++ [ protocol ]))
      "-DOPENSSL_ROOT_DIR=${pkgs.openssl}"
      "-DLOGOS_PROTOCOL_ROOT=${protocol}"
      "-DLOGOS_QT_HOST_BUILD_SHARED=OFF"
    ];
  };

  # lgx C ABI as liblgx.a; CoreFoundation stands in for ICU.
  lgx = pkgs.mkIosCmakeStage {
    pname = "logos-package-ios";
    version = "0.1.0";
    src = patched "logos-package" srcs.package [ "${patchDir}/logos-package-ios-static.patch" ];
    buildInputs = [
      pkgs.libsodium
      pkgs.nlohmann_json
      native.cppSemver
    ];
    cmakeFlags = [
      (roots [ pkgs.libsodium pkgs.nlohmann_json native.cppSemver ])
      "-DLGX_STATIC_CABI=ON"
      "-DLGX_UNICODE_COREFOUNDATION=ON"
      "-DLGX_BUILD_TESTS=OFF"
    ];
    # Same shape as logos-package's own nix/lib.nix: lgx.h beside the
    # archive, and the cpp-semver header that include/logos/semver.hpp
    # includes.
    postInstall = ''
      cp ../src/lgx.h $out/include/
      cp -r ${native.cppSemver}/include/semver $out/include/
    '';
  };

  logosModule = pkgs.mkIosCmakeStage {
    pname = "logos-module-ios";
    version = "0.1.0";
    src = patched "logos-module" srcs.module [ "${patchDir}/logos-module-no-cli-on-ios.patch" ];
    buildInputs = [ lgx ];
    cmakeFlags = [
      (roots [ lgx ])
      "-DLOGOS_PACKAGE_ROOT=${lgx}"
    ];
  };

  processStats = pkgs.mkIosCmakeStage {
    pname = "process-stats-ios";
    version = "0.1.0";
    src = srcs.processStats;
    buildInputs = [ pkgs.nlohmann_json ];
    # process_stats.cpp already guards its libproc/mach code with
    # `defined(__APPLE__) && !defined(__IOS__)`, but nothing defines __IOS__
    # (the SDK spells it TARGET_OS_IPHONE), so the stage supplies it; the
    # iOS build takes the "unsupported platform" branch (empty stats).
    cmakeFlags = [
      (roots [ pkgs.nlohmann_json ])
      "-DPROCESS_STATS_BUILD_TESTS=OFF"
      "-DCMAKE_CXX_FLAGS=-D__IOS__=1"
    ];
  };

  # The subprocess container compiles (Boost.Process) but is never selected on
  # iOS; liblogos_core links its factory regardless.
  containerSubprocess = pkgs.mkIosCmakeStage {
    pname = "logos-container-subprocess-ios";
    version = "0.1.0";
    src = patched "logos-container-subprocess" srcs.containerSubprocess [ "${patchDir}/logos-container-subprocess-tests-option.patch" ];
    buildInputs = thirdParty ++ [ native.logosContainer ];
    cmakeFlags = [
      (roots (thirdParty ++ [ native.logosContainer ]))
      "-DLOGOS_CONTAINER_ROOT=${native.logosContainer}"
      "-DLOGOS_BUILD_TESTS=OFF"
    ];
  };

  moduleLoaderQtInputs = thirdParty ++ [
    protocol
    qtHost
    logosModule
    native.cppSdk
    native.qtSdk
    native.logosContainer
    native.logosModuleLoader
    pkgs.cli11
  ];
  moduleLoaderQt = pkgs.mkIosCmakeStage {
    pname = "logos-module-loader-qt-ios";
    version = "0.1.0";
    src = patched "logos-module-loader-qt" srcs.moduleLoaderQt [ "${patchDir}/logos-module-loader-qt-ios.patch" ];
    buildInputs = moduleLoaderQtInputs;
    cmakeFlags = [
      (roots moduleLoaderQtInputs)
      "-DOPENSSL_ROOT_DIR=${pkgs.openssl}"
      "-DLOGOS_CPP_SDK_ROOT=${native.cppSdk}"
      "-DLOGOS_PROTOCOL_ROOT=${protocol}"
      "-DLOGOS_QT_SDK_ROOT=${native.qtSdk}"
      "-DLOGOS_MODULE_ROOT=${logosModule}"
      "-DLOGOS_CONTAINER_ROOT=${native.logosContainer}"
      "-DLOGOS_MODULE_LOADER_ROOT=${native.logosModuleLoader}"
      # The native logos-qt-sdk config HINTS at the native logos-qt-host; the
      # _DIR cache entry wins over the hint.
      "-Dlogos-qt-host_DIR=${qtHost}/lib/cmake/logos-qt-host"
      "-DLOGOS_BUILD_TESTS=OFF"
    ];
  };

  packageManager = pkgs.mkIosCmakeStage {
    pname = "logos-package-manager-ios";
    version = "1.0.0-dev";
    src = patched "logos-package-manager" srcs.packageManager [ "${patchDir}/logos-package-manager-static.patch" ];
    buildInputs = [ lgx pkgs.nlohmann_json ];
    cmakeFlags = [
      (roots [ lgx pkgs.nlohmann_json ])
      "-DLGX_ROOT=${lgx}"
      "-DLGPM_STATIC_LIB=ON"
    ];
    # liblogos looks for lgx beside package_manager_lib (its nix/lib.nix
    # stages the dylib there); stage the archive the same way.
    postInstall = ''
      cp ${lgx}/lib/liblgx.a $out/lib/
      cp ${lgx}/include/lgx.h $out/include/
    '';
  };

  liblogosInputs = moduleLoaderQtInputs ++ [
    processStats
    containerSubprocess
    moduleLoaderQt
    packageManager
    lgx
  ];
  liblogos = pkgs.mkIosCmakeStage {
    pname = "logos-liblogos-ios";
    version = "0.1.0";
    src = patched "logos-liblogos" srcs.liblogos [ "${patchDir}/logos-liblogos-static-core.patch" ];
    buildInputs = liblogosInputs;
    cmakeFlags = [
      (roots liblogosInputs)
      "-DOPENSSL_ROOT_DIR=${pkgs.openssl}"
      "-DLOGOS_CPP_SDK_ROOT=${native.cppSdk}"
      "-DLOGOS_PROTOCOL_ROOT=${protocol}"
      "-DLOGOS_QT_HOST_ROOT=${qtHost}"
      "-DLOGOS_MODULE_ROOT=${logosModule}"
      "-DPROCESS_STATS_ROOT=${processStats}"
      "-DLOGOS_CONTAINER_ROOT=${native.logosContainer}"
      "-DLOGOS_MODULE_LOADER_ROOT=${native.logosModuleLoader}"
      "-DLOGOS_PACKAGE_MANAGER_ROOT=${packageManager}"
      "-Dlogos-qt-host_DIR=${qtHost}/lib/cmake/logos-qt-host"
      "-DLOGOS_CORE_STATIC=ON"
      "-DLOGOS_BUILD_TESTS=OFF"
      # logos_core includes logos_module_loader/*.h but never links the
      # logos_module_loader interface target that carries the include dir;
      # native builds get it from nix's cc-wrapper (NIX_CFLAGS_COMPILE), which
      # Xcode's clang has no equivalent of.
      "-DCMAKE_CXX_FLAGS=-I${native.logosModuleLoader}/include"
    ];
  };
in
{
  inherit
    protocol
    qtHost
    lgx
    logosModule
    processStats
    containerSubprocess
    moduleLoaderQt
    packageManager
    liblogos
    ;
  # Everything the smoke host links, in one CMAKE_PREFIX_PATH-able list.
  all = liblogosInputs ++ [ liblogos pkgs.libsodium ];
}
