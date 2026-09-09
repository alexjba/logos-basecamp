# Spike: dlopen of protocol-free module frameworks on iOS

Branch `spike/ios-dlopen-bare-module` (fork `alexjba/logos-basecamp`), 2026-09-09. Commit b932e87 (report hash added in the follow-up commit).
Sources under `spike/ios-dlopen/`; host wiring in `shell-preview/platform/ios/app/CMakeLists.txt`
(`SPIKE_IOS_DLOPEN=ON`) and `shell-preview/src/main.cpp`. Raw per-run output in `spike/ios-dlopen/results/`.

## Verdict

| Level | Simulator (iPhone 16 Pro, iOS 18.2) | Device (iPad Air 4, team 8B5X2M6H2Y) |
|---|---|---|
| 1. Bare module, `lp_protocol_version` resolves upward into the app | **works** | **works** |
| 2. QObject + moc + `Q_PROPERTY` + qrc QML, all Qt resolved upward into static Qt | **works**, with one precondition (below) | **works**, same precondition |
| 3. Two frameworks with identical C ABI symbol names, RTLD_LOCAL, each reached through its own handle | **works** | **works** |

Every variant tried passed on both targets except the one that documents the precondition.
No dyld, AMFI or code-signing error occurred on the device in any run.

The precondition for Level 2: **logos-nix's static Qt exports nothing.** Qt is configured
with `reduce_exports` and, in a static build, `Q_CORE_EXPORT` expands to nothing, so Qt's whole
API is compiled `-fvisibility=hidden` (`nm -m QtCore` shows 16 851 `private external` symbols).
An app linking those archives has no Qt in its export trie, and the framework fails to load:

```
dlopen(.../BasecampShellPreview.app/Frameworks/SpikeUi.framework/SpikeUi, 0x0006):
  symbol not found in flat namespace '__ZN10QByteArray6_emptyE'
```
(`results/sim-dynamic_lookup-all-no-qt-patch.txt`; Levels 1 and 3 still pass in that run.)

The spike works around it without a Qt rebuild: `patch-visibility.py` clears `N_PEXT` on every
symbol in a copy of `QtCore.framework/QtCore` and the copy is linked ahead of the store one.
The production fix is to build Qt for iOS with `-DFEATURE_reduce_exports=OFF` in logos-nix
(one flag in the Qt derivation; both iOS targets), which yields the same object files the
patch fakes. Nothing else in the toolchain needed changing.

## What was built

- `bare/bare_module.c`: the full `logos_module_impl.h` export set in C, no Qt, no protocol;
  `whoami` calls `lp_protocol_version()` (undefined in the framework). Built twice as
  `BareA.framework` and `BareB.framework` (`-DSPIKE_MODULE_TAG`).
- `ui/`: `SpikeUiModule` (QObject, two `Q_PROPERTY`, three `Q_INVOKABLE`, three signals),
  moc'd with the host Qt's `moc`, plus `spike.qrc` -> `SpikeView.qml` via `rcc`. Compiled against
  the static iOS Qt headers, **no Qt archive on its link line**. `SpikeUi.framework`.
- `host/SpikeDlopen.cpp`, compiled into the nix-built static-Qt shell-preview app: defines the
  stand-in `lp_protocol_version()` (real logos-protocol was not linked into the host; it needs
  QtCore and a nix cross build, out of the time box), dlopens the three frameworks from
  `<App>.app/Frameworks/` with `RTLD_NOW | RTLD_LOCAL`, calls the C ABI, instantiates the QObject,
  reads/writes the property, connects a signal, invokes a method by name, and loads
  `qrc:/spike/SpikeView.qml` into a `QQuickWidget` docked under the shell. The QML binds to the
  object's properties, calls its invokables (a `Timer` bumps a counter through the framework's
  `qt_static_metacall`), and reports back through a signal the host receives.
- Frameworks are built with `xcrun clang` directly (`build-frameworks.sh`), not nix; the host app
  is the unchanged nix/Xcode pipeline (`run.sh` mirrors `run-ios-sim` / `run-ios-device`).

## Linker flags that worked

Framework side (all variants pass on sim and device):

| Variant | Flags | Output | Note |
|---|---|---|---|
| A (default) | `-dynamiclib -Wl,-undefined,dynamic_lookup -install_name @rpath/X.framework/X -Wl,-dead_strip` | MH_DYLIB, **opcode-based `LC_DYLD_INFO_ONLY`** (ld silently drops chained fixups) | ld-1267 prints `ld: warning: -undefined dynamic_lookup is deprecated on iOS` |
| B | A + `-Wl,-fixup_chains` | MH_DYLIB with `LC_DYLD_CHAINED_FIXUPS`, imports bound as `<flat-namespace>/sym` | same warning; loads fine on iOS 18 device |
| C | `-bundle -Wl,-bundle_loader,<linked app executable> -Wl,-dead_strip` | MH_BUNDLE, chained fixups, two-level: `bind <main-executable>/sym` | no warning; needs the app linked first (two-pass build); ld checks every symbol against the app's exports at link time |

`-no_fixup_chains` was never needed. Toolchain: Xcode 26.6, ld-1267, `-target arm64-apple-ios17.0[-simulator]`.

App side (Xcode generator, unchanged from the runner except):

- `-Wl,-u,<sym>` for each of the 26 QtCore symbols `SpikeUi` leaves undefined (`nm -u` of the
  framework intersected with `nm -gU` of QtCore): pulls the archive members in and keeps them
  through the existing `-dead_strip`. `_lp_protocol_version` is `__attribute__((visibility("default"), used))`.
- visibility-patched `libQt6CoreExported.a` passed as a link *option* so it precedes every library.
- `SPIKE_EXPORT_MODE=list`: `-Wl,-exported_symbols_list,<26 Qt symbols + _lp_protocol_version>`.
  Without it the app exports every default-visibility global that made it in.

Packaging and signing (device): frameworks are shallow iOS frameworks (`X.framework/X` +
`Info.plist` with `CFBundleIdentifier`, `CFBundlePackageType=FMWK`, `MinimumOSVersion`),
embedded via CMake `XCODE_EMBED_FRAMEWORKS` + `XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY`, which
signs each with the app's identity (`Apple Development: Alexandru Jbanca`, TeamIdentifier
8B5X2M6H2Y, automatic signing via `-allowProvisioningUpdates`). Library validation accepted them;
no entitlement changes.

## Measurements (device, iphoneos, Debug host / release Qt)

| Build | App executable | Exports (`nm -gU`) | Export trie | Frameworks |
|---|---|---|---|---|
| baseline shell-preview (no spike) | 45 769 392 B | 830 | 38 744 B | none |
| spike, export=all (every global exported) | 46 677 040 B (+908 KB) | 8 694 | 431 504 B | BareA/BareB 85 632 B each, SpikeUi 90 016 B (signed) |
| spike, export=list (26 Qt symbols + `lp_*`) | 45 834 032 B (+65 KB) | 27 | 976 B | same |

App bundle: 44 760 K -> 45 072 K with the three frameworks (`Frameworks/` is 248 K).
The +65 KB in `list` mode is the spike host code and the 26 `-u`-forced QtCore members. The
extra +843 KB in `all` mode is the export trie (+393 KB) plus code that `-dead_strip` had to keep
only because it was exported (exports are dead-strip roots in an executable). So Qt symbol
export does bloat the executable when unconstrained (11x the trie), and an exported-symbols
list computed from the module set removes it entirely.

dlopen time (`RTLD_NOW | RTLD_LOCAL`, `QElapsedTimer` around the call, first launch after install):

| | BareA (first dlopen in process) | BareB | SpikeUi (runs qrc static initializer) |
|---|---|---|---|
| simulator | 4.7 to 4.9 ms | 4.1 to 4.7 ms | 4.5 to 4.9 ms |
| iPad Air 4 | 9.8 to 33 ms | 6.2 to 6.6 ms | 6.2 to 7.6 ms |

The first dlopen pays dyld's warm-up; subsequent images cost 6 to 7 ms on the device.
Loading the QML from the framework's qrc into the app engine: 8 ms sim, 14 ms device.

Isolation (Level 3): `dlsym(handleA, "logos_module_dispatch") != dlsym(handleB, ...)`, each
returns its own tag, and `dlsym(RTLD_DEFAULT, "logos_module_dispatch")` is NULL, so RTLD_LOCAL
keeps the identical C ABI names out of the global namespace.

## Recommendation

The ADR 0006 shape is viable on iOS as specified: one protocol-free embedded framework per
module, dlopened with RTLD_LOCAL, `lp_*` and Qt bound upward into the app image. Conditions:

1. Build Qt for iOS with `reduce_exports` off (logos-nix). Without it Level 2 cannot work at all.
2. Prefer variant B (`-undefined dynamic_lookup` + `-fixup_chains`) for the module link: no
   dependency on a linked app at module build time, modern fixup format. The deprecation
   warning is real; if Apple removes flat lookup, variant C (`-bundle_loader`, two-level against
   the app) is proven and keeps loader semantics but forces "link the app before the modules"
   and a per-app link of each module. A stub `.tbd` of the app's exports would remove that
   ordering and is the thing to try if C ever becomes mandatory.
3. Generate the app's `-exported_symbols_list` (plus `-u`) from the union of the bundled
   modules' undefined symbols at shell build; do not export everything.
4. Host stand-in caveat: `lp_protocol_version` here is a one-line function in the app, not
   logos-protocol. The linking mechanics are identical for the real library (it is a static
   archive in the app with default-visibility `LP_API` symbols, unlike Qt), but a follow-up
   should link the real protocol into the shell host once it cross-builds.

No fallback (static registration table) is needed.

## Reproduce

```
cd ~/Repos/agents/spike-ios-dlopen
./spike/ios-dlopen/run.sh sim [--fixup-chains] [--export list] [--mode bundle_loader] [--no-qt-patch]
LOGOS_IOS_TEAM_ID=8B5X2M6H2Y ./spike/ios-dlopen/run.sh device --device 5E8DA01B-5B74-5EFB-B9B1-42E9C4707FAB --export list --fixup-chains
```
`run.sh` takes the nix stages from `~/Repos/agents/basecamp-ios-device` (same sources) so the
store paths stay cached, uses the runner's nix cmake (Homebrew's 3.26 rejects the Qt finalizers
with "Impossible to link target ... WHOLE_ARCHIVE"), captures 25 s of console and prints the
`SPIKE RESULT` line. Build dirs: `$TMPDIR/spike-ios-dlopen/<kind>-<mode>-<export>[-fixup-chains]`.
