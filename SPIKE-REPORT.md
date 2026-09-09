# Spike: liblogos on mobile, web module round trip

Branch `spike/liblogos-mobile` on the forks `alexjba/logos-basecamp` (this
tree, `spike/liblogos-mobile/`) and `alexjba/logos-nix` (the cross
toolchains). 2026-09-09. Commit hashes at the end.

## Verdict

| Level | iPhone 16 Pro simulator (aarch64-ios-simulator) | iPad Air, signed device build (aarch64-ios) | Samsung SM-G990B (aarch64-android) |
|---|---|---|---|
| A. liblogos_core up in the app sandbox | **works** | **works** | **works** (APK, shared libs) |
| B. web page calls a native module through the core, gets its events | **works** | **works** | native half only (no WebView: iOS-only scope) |
| C. the page is a provider the host invokes by name | **works** | **works** | not attempted |

Everything liblogos_core links builds from source for iOS as static archives
under nix (Qt 6.11.1 static + RemoteObjects, Boost 1.89, OpenSSL 3.6.2, spdlog,
libsodium, nlohmann_json), and the whole thing links into one 27 MB
simulator app. `logos_host_qt` and the subprocess container compile and link
for iOS and are never selected.

Screenshot: `results/ios-sim-levels-abc.png`; consoles: `results/ios-sim-console.txt`,
`results/ios-device-ipad-console.txt` (team 8B5X2M6H2Y, devicectl; identical
output, core start 1 ms, 8 ms since main, app 26 848 KB).

## Android (Samsung SM-G990B, arm64-v8a, API 28 floor)

`nix run .#run-liblogos-android` (`nix/liblogos-android.nix`,
`nix/smoke-host-android.nix`): the same nine stages built with nixpkgs' own
Android cross stdenv as shared libraries, packaged by `mkQtAndroidApk`.
Console: `results/android-samsung-console.txt`; screen: `results/android-samsung-level-a.png`.

| | |
|---|---|
| `logos_core_start()` | 0 ms |
| core up from `main()` | 7 ms |
| native `counter.add(1,2)` in Local mode | 3, 0 ms |
| APK | 38 375 181 B (Qt Core/Gui/Widgets/Network/RemoteObjects + 5 Logos .so + spdlog, fmt, OpenSSL, libsodium, ICU 76 with a 32 MB `libicudata`) |
| `liblogos_core.so` / `liblogos_protocol.so` / `liblogos_qt_host.so` / `libpackage_manager_lib.so` / `liblgx.so` | 1.3 MB / 2.9 MB / 0.4 MB / 0.7 MB / 0.8 MB |

Android-specific findings:

| Problem | Verbatim | Fix |
|---|---|---|
| **`LogosModeConfig` is an inline static, one copy per image.** With a shared `liblogos_protocol.so`, `LogosModeConfig::setMode(Local)` in the app sets the app's copy; every `LogosAPI` inside the protocol library stayed in Remote mode and the first run went through QtRemoteObjects local sockets in-process (it still worked: `counter.add` = 3 in 16 ms, and a warning storm: `It is recommended to use 'localabstract' over 'local' on Android.`) | `RemoteTransportHost: Created registry host with URL: "local:logos_counter_8aeaeef9d439"` right after `LogosModeConfig: Mode set to "Local"` | call the C ABI setter `lp_set_mode("local")`, which runs inside the protocol image. Not an issue on iOS (one static image). The mode storage should not be header-inline |
| spdlog: nixpkgs links no `-llog` for the Android sink | `ld.lld: error: undefined symbol: __android_log_write` | `NIX_LDFLAGS=-llog` (logos-nix Android overlay) |
| Boost b2 for Android at this pin | `ld.lld: error: unable to find library -lrt` | Boost's CMake build, static + PIC (same tarball as iOS) |
| qtremoteobjects for Android: repc | `Failed to find the host tool "Qt6::repc". It is part of the Qt6RemoteObjectsTools package` | `Qt6RemoteObjectsTools_DIR` in the module and the host prefix in `QT_ADDITIONAL_HOST_PACKAGES_PREFIX_PATH` (overlay); consumers also need `QT_ADDITIONAL_PACKAGES_PREFIX_PATH` (Qt6Config: `Failed to find required Qt component "RemoteObjects"`) |
| lgx: `pkg_check_modules(libsodium)` yields a bare `-lsodium` under cross | `ld.lld: error: unable to find library -lsodium` | no pkg-config in that stage; `find_library` links the absolute path |
| `logos_host_qt`: bionic has `<execinfo.h>` only from API 33 | `logos_host.cpp:148:21: error: no member named 'backtrace' in the global namespace` | patch: `LOGOS_HOST_NO_BACKTRACE` below API 33 (compiled, never selected) |
| APK packaging accepts only `lib*.so`; nixpkgs' cross libs are versioned | `The file name of external library .../libspdlog.so.1.17 must begin with "lib" and end with the suffix ".so".` | `apkLibs`: copy under the unversioned name, `patchelf --set-soname` / `--replace-needed` |
| Android ships private `libicu*`, `libssl`, `libcrypto`; a same-named DT_NEEDED resolves to those | `java.lang.UnsatisfiedLinkError: dlopen failed: cannot locate symbol "_ZN6icu_7613UnicodeString8doAppend..." referenced by ".../libicui18n.so"` | rename ours `lib<name>_lg.so` (soname + needed) |
| `pkgs.openssl` / `pkgs.fmt` default to their `bin`/`dev` outputs | `mkQtAndroidApk: these DT_NEEDED sonames are neither in the APK nor provided by Android at API 28: libcrypto.so libfmt.so libssl.so` | `lib.getLib` |
| gradle `:packageDebug` fails intermittently | `IncrementalSplitterRunnable` with no message; the identical derivation succeeded on retry | retry |

## Measurements (simulator, Debug host / release archives)

| | |
|---|---|
| `logos_core_start()` (empty modules dir, persistence in `Application Support/Logos/LiblogosSmoke/logos`) | 1 ms |
| core up, from `main()` (includes QApplication + window) | 6 to 16 ms |
| protocol version | 0.9.0, ABI major 0 |
| native `LogosAPIClient` -> counter.add(1,2) in Local mode | 3, < 1 ms |
| page -> native -> page round trip for `counter.add` | < 1 ms native side; page shows 3 |
| `LiblogosSmoke.app` | 26 828 KB; executable 27 450 720 B (Qt Core/Gui/Widgets/Network/RemoteObjects + qios + liblogos closure) |
| `liblogos_core.a` alone | 1 071 240 B |

## What was built

Stage chain (`nix/liblogos-ios.nix`, one `pkgs.mkIosCmakeStage` per repo,
mirroring each repo's own `nix/default.nix` flags), in dependency order:

1. logos-protocol (static archive only; plain, qt_local, qt_remote, mock transports)
2. logos-plugin-qt -> `liblogos_qt_host.a`
3. logos-package -> `liblgx.a` (C ABI as a static archive; CoreFoundation instead of ICU)
4. logos-module -> `liblogos_module.a`
5. process-stats
6. logos-container-subprocess (Boost.Process; compiled, never selected)
7. logos-module-loader-qt -> `liblogos_module_loader_qt.a` + `logos_host_qt` (linked, not installed)
8. logos-package-manager -> `libpackage_manager_lib.a`
9. logos-liblogos -> `liblogos_core.a`

Platform-neutral inputs taken from the build platform unchanged: logos-cpp-sdk,
logos-qt-sdk, logos-container, logos-module-loader (all INTERFACE-only CMake
packages), nlohmann_json, cli11, cpp-semver.

Third-party tail (`logos-nix/nix/ios/third-party.nix`, on Xcode's clang):
spdlog 1.17 (CMake), OpenSSL 3.6.2 (`Configure iossimulator-arm64-xcrun` /
`ios64-xcrun`), Boost 1.89 (its own CMake build from the GitHub `-cmake`
tarball: process, filesystem, system, asio, dll, uuid), libsodium (autotools),
Qt RemoteObjects (new module in the iOS overlay, repc from the host Qt).

Smoke host (`host/`): a QApplication with a QPlainTextEdit log on top and a
`WKWebView` on the bottom 45 % of the screen; `nix run
.#packages.aarch64-ios-simulator.run-liblogos-ios-sim` does the Xcode link,
install and launch, the same shape as the Shell preview runner.

## Dependency tail: what did not work, and the fix

| Problem | Verbatim | Fix |
|---|---|---|
| nixpkgs' own iOS cross stdenv does not build at this pin | `compiler-rt-arm64-apple-ios> ln: failed to create symbolic link './lib': File exists` (and it targets `macOS-SDK-14.4`) | every archive is built on Xcode's clang (`xcodeClang.mkDerivation`), like Qt already was |
| Boost release tarball has no CMake | `CMake Error: The source directory ".../boost_1_89_0" does not appear to contain CMakeLists.txt.` | fetch `boost-1.89.0-cmake.tar.xz` from GitHub |
| Boost.Process v2 shell parser | `libs/process/src/shell.cpp:107:15: error: 'wordexp' is unavailable: not available on iOS` | `substituteInPlace`: take its existing OpenBSD/Android `ENOTSUP` branch on `__APPLE__` (iOS-only set) |
| Boost.DLL headers not installed by Boost's CMake even when listed | `qt_plugin_format_loader.cpp:3:10: fatal error: 'boost/dll/runtime_symbol_info.hpp' file not found` | copy `libs/dll/include` in postInstall |
| Boost.Uuid needed by liblogos | `module_manager.cpp:29:10: fatal error: 'boost/uuid/uuid.hpp' file not found` | add `uuid` to `BOOST_INCLUDE_LIBRARIES` |
| OpenSSL built for the device platform in the simulator set | `ld: building for 'iOS-simulator', but linking in object file (.../libssl.a[3](libssl-lib-d1_lib.o)) built for 'iOS'` | `-mios-simulator-version-min=17` (not `-mios-version-min`) |
| libsodium, OpenSSL: nix's cmake/ninja hooks ran on non-CMake builds | `ninja: error: loading 'build.ninja': No such file or directory` | `dontUseCmakeConfigure`, `dontUseNinjaBuild`, `dontUseNinjaInstall` |
| ICU (lgx) has no iOS build here | | `LGX_UNICODE_COREFOUNDATION`: `CFStringNormalize` / `CFStringLowercase` (patch, see below). ICU 76 cross-builds with a host build tree; not attempted in the time box |
| process-stats expects a macro nothing defines | `process_stats.cpp:12:10: fatal error: 'libproc.h' file not found` (source guards on `!defined(__IOS__)`) | stage passes `-D__IOS__=1`; the source should use `TARGET_OS_IPHONE` |
| liblogos includes `logos_module_loader/*.h` but never links the interface target that carries the include dir; native builds get it from nix's cc-wrapper | `composite_module_loader.h:6:10: fatal error: 'logos_module_loader/module_format_loader.h' file not found` | stage passes `-I` |
| `logos_host_qt` on iOS: Qt6::Core's link options set the entry point to `_qt_main_wrapper`, provided only by the qios platform plugin | `Undefined symbols for architecture arm64: "_qt_main_wrapper"` | 8-line `ios_entry_stub.cpp` in the module-loader-qt patch; the binary is not installed |
| package-manager, liblogos look for `liblgx` and `lgx.h` beside `package_manager_lib` (their nix/lib.nix stages the dylib there) | `lgx not found in .../logos-package-manager-ios-1.0.0-dev/lib` | postInstall copies |
| static Qt plugin: moc emits `qt_static_plugin_X()` only under `QT_STATICPLUGIN` | `Undefined symbols: "qt_static_plugin_CounterModule()"` | define it in the stage |

## Patches (all under `patches/`, applied with `applyPatches`)

| Repo | File | Why |
|---|---|---|
| logos-protocol | `cpp/CMakeLists.txt` | `LOGOS_PROTOCOL_BUILD_SHARED` (default ON) gates `logos_protocol_shared`: a dylib on iOS is a second Qt |
| logos-plugin-qt | `cpp/CMakeLists.txt` | `LOGOS_QT_HOST_BUILD_SHARED` (default ON), same reason |
| logos-package | `CMakeLists.txt`, `src/core/path_normalizer.cpp` | `LGX_STATIC_CABI` (the `lgx.h` C ABI as `liblgx.a`), `LGX_UNICODE_COREFOUNDATION` (CoreFoundation NFC/lowercase instead of ICU), no `lgx` CLI on iOS |
| logos-module | `CMakeLists.txt` | no `lm` CLI on iOS (an executable in the install tree) |
| logos-container-subprocess | `CMakeLists.txt` | `LOGOS_BUILD_TESTS` option: tests were unconditional and fall back to `FetchContent` |
| logos-module-loader-qt | `CMakeLists.txt`, `src/CMakeLists.txt`, `src/host/ios_entry_stub.cpp` (new) | `LOGOS_BUILD_TESTS`; `logos_host_qt` links on iOS but is not installed |
| logos-package-manager | `CMakeLists.txt` | `LGPM_STATIC_LIB`; skip the `install_name_tool` block for a static lib; no `lgpm` CLI on iOS |
| logos-liblogos | `src/CMakeLists.txt` | `LOGOS_CORE_STATIC`: `logos_core` as STATIC, `package_manager_lib`/`lgx_lib` imported as STATIC, link `logos-qt-host::logos_qt_host` instead of `_shared` |
| Boost (nix, not a repo) | `libs/process/src/shell.cpp` | wordexp unavailable on iOS |

The module-loader-qt patch also carries the Android `backtrace` guard in
`src/host/logos_host.cpp` (added after the iOS runs; iOS is unaffected).

No source patch to logos-liblogos's C++, logos-protocol's C++, or Qt.

## Level B and C: shapes and mechanics

Host side (`host/src/`): `CounterModule` is a QObject + `PluginInterface`
compiled as a **static Qt plugin** (`Q_PLUGIN_METADATA`, `QT_STATICPLUGIN`,
`Q_IMPORT_PLUGIN` in main.cpp) and found through
`QPluginLoader::staticInstances()`; the host registers it with
`LogosAPI("counter").getProvider()->registerObject("counter", module)` in
`LogosMode::Local`, which publishes a `ModuleProxy` in `PluginRegistry`. This
is the static-table fallback: **ModuleManager never sees the module** (no
`.lgx`, no metadata, `logos_core_get_known_modules()` is empty). Throwaway.

Tokens: **ambient**. No capability_module is loaded (nothing is installed), so
the host mints one token per caller identity (`QUuid`) and installs it on both
sides: `provider->saveToken("web", tok)` on the counter's `ModuleProxy`, and
`TokenManager` of the `"web"` `LogosAPI` gets `saveToken("counter", tok)`. The
page receives the token in a `TokenMessage` and presents it on every
`CallMessage`; the relay writes the presented token into the token store
before dialling, so `LogosAPIClient` uses it rather than minting one through
`requestModule`. The real `requestModule` flow was not run.

Messages (JSON, one per WebKit request; field names are
`implementations/plain/rpc_message.h` + `json_mapping.cpp`, plus `type`
because the channel has no framing):

```
page -> native  {"type":"call","id":1,"authToken":"<tok>","object":"counter","method":"add","args":[1,2]}
native -> page  {"type":"result","id":1,"ok":true,"value":3}
page -> native  {"type":"subscribe","object":"counter","event":"valueChanged"}
native -> page  {"type":"event","object":"counter","event":"valueChanged","data":[1]}
native -> page  {"type":"token","authToken":"","moduleName":"counter","token":"<tok>"}
native -> page  {"type":"call","id":1,"authToken":"","object":"webpage","method":"upper","args":["hello from native"]}   (Level C)
page -> native  {"type":"result","id":1,"ok":true,"value":"HELLO FROM NATIVE"}
page -> native  {"type":"provide","object":"webpage","methods":["upper"]}      (spike-only: announce)
```

Channel: **not `WKScriptMessageHandler`**. Deserialising a script message
creates a `JSContext` in the app process and JavaScriptCore traps:

```
EXC_BREAKPOINT (SIGTRAP)
JavaScriptCore  JSC::sanitizeStackForVM(JSC::VM&) +404
JavaScriptCore  JSC::VM::VM(...) / -[JSVirtualMachine init] / -[JSContext init]
WebKit          API::SharedJSContext::ensureContext()
WebKit          API::SerializedScriptValue::deserialize(WebCore::SerializedScriptValue&)
WebKit          ScriptMessageHandlerDelegate::didPostMessage(...)
```

Cause: Qt's iOS run-loop integration runs `main()` on a separate stack and
lowers `RLIMIT_STACK` to that stack's size while it runs
(`qioseventdispatcher.mm`, `updateStackLimit`); WTF sizes the main thread's
stack bounds from the limit and asserts the SP is inside. Tried and rejected:
`QtRunLoopIntegrationStackSize` 921600 (same trap),
`QtRunLoopIntegrationDisableSeparateStack` (Qt then crashes in
`-[QIOSViewController initWithWindow:]` because the scene connects before
`QGuiApplication` exists). What works: a custom URL scheme
(`WKURLSchemeHandler`, `logos://host`): the page is served from it, posts each
message with `fetch("/msg", {method:"POST", body})` and receives native ->
page messages as a JSON array on a `fetch("/inbox")` long-poll. No
JavaScriptCore runs in the app process; `evaluateJavaScript` is not used
either. This is the shape slice 28 should assume for iOS.

Level C provider: `WebPageProvider` (a `PluginInterface` QObject registered
as `"webpage"`) forwards each `Q_INVOKABLE` to the page and **waits for the
page's `ResultMessage` in a nested `QEventLoop`** (5 s timeout), because
`QtProviderObject` dispatches synchronously by method name. It works on the
simulator (0 ms). A real Web container needs the async provider path
(`logos_async_dispatch.h` / `LogosAsyncResult`) instead of a nested loop, and
a way to declare the page's methods to the meta-object system (here the
method list is fixed in C++).

## Recommendation

- **Slice 32 (liblogos on mobile):** go. The whole core stack is buildable as
  static archives on the existing nix iOS pipeline with nine small CMake
  option patches (shared-target and CLI/test gates) and no C++ patch to the
  core; core start is 1 ms. Upstream the options as they are
  (`LOGOS_CORE_STATIC`, `LGX_STATIC_CABI`, `LOGOS_*_BUILD_SHARED`, test
  gates), fix the two latent build bugs (process-stats `__IOS__`, liblogos's
  missing `logos_module_loader` link), and decide ICU (cross-build it, or keep
  the CoreFoundation normaliser under an option; both are small). Keep
  `logos_host_qt` and the subprocess container compiled but unselected; the
  in-process container for Local mode is the missing piece (this spike
  registers modules directly with `LogosAPIProvider` and bypasses
  `ModuleManager`).
- **Slice 25 (web container, desktop):** the message shapes are the plain
  transport's, one-to-one, with a `type` discriminator; nothing in the
  protocol had to change to drive it from JSON. Build the desktop container on
  the same `CallMessage`/`ResultMessage`/`SubscribeMessage`/`EventMessage`
  JSON and the same ambient-token handoff, then swap the handoff for
  `requestModule` once capability_module loads in-process.
- **Slice 28 (web container, mobile):** on iOS, budget for the URL-scheme
  channel rather than `WKScriptMessageHandler` while Qt owns `main()`'s stack
  (or fix the stack-limit interaction in Qt's iOS dispatcher and re-test);
  for the page-as-provider direction, require the async provider path before
  any real module depends on a web provider.

## Commits

- logos-basecamp fork, branch `spike/liblogos-mobile` (this tree): see `git log`; the flake's `logos-nix` input points at the fork branch below.
- logos-nix fork, branch `spike/liblogos-mobile`: `840c4e9` (iOS third-party tail, qtremoteobjects for iOS and Android, Android spdlog/Boost/cli11 overrides).

## Environment

Xcode 26.6, iOS simulator runtime 18.x on iPhone 16 Pro
(40696C9C-F8EE-483F-83FF-AFA89CCC5FE7), Qt 6.11.1 static (logos-nix fork),
nixpkgs pin of logos-nix's cross set (`nixpkgs-windows`).
