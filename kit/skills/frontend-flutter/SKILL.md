---
name: frontend-flutter
description: |
  OPTIONAL, stack-specific: Flutter. Flutter projects only; the generic principles live in the `frontend` skill.
---

# Flutter (stack-specific layer)

**Apply only when the project IS Flutter** — its `pubspec.yaml` depends on the SDK (`flutter: sdk: flutter`).
Otherwise do not use this skill: `frontend` and the project's own stack apply (see its Client stack order).

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "riverpod", "go_router", "pubspec", "widget test", "analysis_options", "flutter_test", "golden test", "platform channel", "dart isolate", "gen-l10n"

For generic frontend discipline, applies the `frontend` skill; this file only covers what Flutter adds. Every rule
below was checked against Flutter's own documentation (docs.flutter.dev, dart.dev) or the page of the package or
platform it names; the depth and the sources are in `references/`, which also say what was not checked. Not used in a project on another stack (delete it if needed).

## The project decides, not this file
- **Read before you write:** `pubspec.yaml` (the packages already chosen), `analysis_options.yaml` (the lint set and
  formatter width), `pubspec.lock`, and how `lib/` is already laid out. Follow them.
- **State management, routing, code generation and the lint set are the project's choice.** Flutter's own guidance
  names no single state approach ("the best choice … depends on the app's complexity, your team's preferences");
  built in are `setState`, `ValueNotifier`/`ChangeNotifier` and `InheritedWidget`. A package is added only when the
  user agrees, and recorded (`adr`). Never introduce a second state or routing approach beside the one in use.
- **A new project** asks once, the same way `frontend`'s Client stack step does: options and trade-offs, none marked
  recommended.

## Architecture (Flutter's architecture guide; its "strongly recommend" items)
- Two layers at least: **UI** (views + view models) and **data** (repositories + services). A repository is behind
  an abstract class, so tests can use a fake. **No logic in widgets** — a widget renders state and forwards events.
- **Unidirectional data flow** and **immutable models**; a model that crosses a layer is not mutated in place.
- **Dependencies are injected** into view models and repositories, not looked up from inside them. A domain layer
  only when the logic needs one (the guide marks it conditional). **Where there is one it is plain Dart: no file in
  it imports `package:flutter`**, and an architecture test reads its files and fails on such an import.
- Feature folders (`features/<name>/`) with view, view model and tests together, as `frontend` says.

## Widgets and rebuilds — the cost model
- **`const` constructors wherever possible**; Flutter short-circuits the rebuild of a `const` subtree.
- **Split by what changes:** keep `setState` (or the provider read) at the smallest subtree that needs it. A reusable
  piece of UI is a `StatelessWidget`, not a helper function returning a widget.
- **`build()` stays cheap:** no I/O, parsing or allocation-heavy work in it — it runs on every ancestor rebuild.
- **Long lists and grids use the lazy builders** (`ListView.builder` and friends), never a `Column` of every item.
- Animations: no `Opacity` inside an animation (`AnimatedOpacity`/`FadeInImage`), no clipping while animating, and no
  widget that forces a `saveLayer` without a reason. Detail: **`references/rebuilds-and-performance.md`**.

## Layout that adapts to the window
- **Decide by the window, never by the device type** ("phone"/"tablet" checks are wrong on foldables, split screen
  and desktop). Measure with **`MediaQuery.sizeOf`** (the whole window; cheaper than `MediaQuery.of`) or
  **`LayoutBuilder`** (the space this widget is given). Breakpoints come from the project's design system; the
  Material window classes are compact < 600 · medium 600–839 · expanded 840–1199 · large 1200–1599 · ≥ 1600 dp.
- **List and detail:** two panes side by side in an expanded window, a push to the detail in a compact one. **What
  the user selected and what they typed survive a change of window class** (a fold, a rotation, a resized window):
  that state lives above the two layouts, not inside either.
- **A foldable:** when `MediaQuery.displayFeatures` holds a hinge that separates the window, the panes split at the
  hinge and no content is laid out on it.
- **Do not lock orientation** — it is an accessibility problem. Keep scroll position across a layout change
  (`PageStorageKey`), and support mouse, trackpad and keyboard where the app runs on desktop or a large screen.
- Accessibility: tap targets 48×48 (Android) / 44×44 (iOS), every tappable labelled, text contrast checked, the UI
  usable at large text scales — tested, not eyeballed (`meetsGuideline`, below). Detail and the test:
  **`references/adaptive-and-accessible.md`**. The `a11y` skill holds the rules for every stack.

## Off the main isolate, across the platform boundary
- **Work that would take longer than a frame** (decoding a large file, heavy parsing, image work) goes to an isolate:
  `Isolate.run` / `compute` for one-off work, `Isolate.spawn` + ports for a long-lived worker. Spawned isolates have
  no `rootBundle` and no UI. On the web there are no isolates: `compute` keeps it compiling and runs on the main thread.
- **Platform channels** (`MethodChannel`, `EventChannel`) are asynchronous; the Dart side handles
  `PlatformException` and `MissingPluginException` explicitly, and the native handler runs on the platform's main
  thread. Prefer generated, typed messages (`pigeon`) over string-matched method names. Detail:
  **`references/platform-async-release.md`**.

## Navigation, text, data
- Navigation: the project's router. Named routes are not recommended by Flutter (no custom deep-link handling, no
  browser forward button); a page-backed route is deep-linkable, a pageless one is not.
- **No user-facing text is written inline in a widget, in any app.** An app in more than one language uses
  `gen-l10n` (ARB files, `AppLocalizations.of(context)`), plurals and placeholders in ICU form — never concatenated;
  the `i18n-integrity` skill checks the files. An app in one language may keep every text in one central file instead.
- **Changing case follows the language.** Dart's `toUpperCase()` / `toLowerCase()` use the language-independent
  mapping (Turkish `i` becomes `I`, not `İ`), so text is cased through one helper that takes the locale.
- Money is never a `double`; dates carry their time zone or are date-only on purpose (the `frontend` rules apply).
  **Amounts and other numbers that line up are drawn with `FontFeature.tabularFigures()`**, so digits keep one width.

## Tests (the `testing` skill owns the strategy)
- Many **unit** and **widget** tests (`flutter_test`), and enough **integration** tests (`integration_test/`, the
  binding initialised) for the important flows. Tests use fakes of the repositories and services (the guide's
  recommendation), which is why those sit behind abstract classes.
- **Golden tests** (`matchesGoldenFile`) only where pixels are the contract, fonts loaded first. **They are generated
  and compared in one place, a pinned container in CI**; `flutter test --update-goldens` is not run on a developer's
  machine, whose rendering differs.
- **Every new screen reached from the app's navigation gets a widget test at one width of each window class** the
  app supports (for example 320, 360, 700 and 1280 dp), **and a test that crosses a class boundary and finds the
  selection and the typed input still there.** Plus the a11y guideline test.

## If the app holds sensitive data (apply only then)
Financial, health or identity data, or anything the user would not want read off a lost phone or a backup:
- **The local database is encrypted**, and its **key lives in the platform's secure store** (Keychain, Keystore),
  never in the database's own directory, in preferences or in the code.
- **The database and the key's files are kept out of the operating system's backup and device transfer**, on both
  platforms.
- **Every network call goes through a transport bound to its own allowed host or hosts.** A call that leaves that
  list is refused: it throws before anything is sent, and a test makes such a call and expects the throw. One
  transport for the whole app or one per service are both this rule; a call made outside any transport is not.
- **In an app that shows ads, no ad is drawn in a window where a sensitive screen is visible** — in a two-pane
  layout that is the whole window, not the pane.
How, and what was checked: **`references/sensitive-data.md`**.

## Performance and release
- **Measure in profile mode on a real device** (`flutter run --profile`); debug mode is not indicative and profile
  mode does not run on an emulator or simulator. Frame budget: about 16 ms at 60 Hz, 8 ms at 120 Hz.
- Release: `--obfuscate --split-debug-info=<dir>` where the target supports it, the symbols kept for `flutter
  symbolize`. Obfuscation is not encryption: **no secret ships in the app**. An app commits its `pubspec.lock`.
- **A feature closed by a build flag stays closed in the store build:** the store build fails when it is handed
  that flag, on Android and on iOS. Detail: **`references/platform-async-release.md`**.
- Logging: `debugPrint` prints in release mode too unless it sits behind a debug check or an assert; log through the
  project's logger (the `observability` skill).

## DoD (in addition to the generic `frontend` DoD)
- `dart format --set-exit-if-changed .` exits 0 · `flutter analyze` clean (0 issues, the project's lint set) ·
  `flutter test` green — one run after the last edit, reported with its exit code and counts.
- No widget holds business logic; no device-type or orientation check decides a layout.
- The a11y guideline test passes on every new screen; each window class the app supports is tested at one width,
  and state survives a change of class.
- No user-facing text inline; the domain layer (if any) imports no `package:flutter`.
- Works across the project's target platform matrix (Android / iOS / web / desktop as declared).
