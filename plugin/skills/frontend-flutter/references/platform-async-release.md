# Isolates, platform channels, navigation, text and release (Flutter)

Checked against https://docs.flutter.dev/perf/isolates, https://docs.flutter.dev/platform-integration/platform-channels,
https://docs.flutter.dev/ui/navigation,
https://docs.flutter.dev/ui/accessibility-and-internationalization/internationalization,
https://docs.flutter.dev/testing/overview, https://docs.flutter.dev/testing/integration-tests,
https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html, https://docs.flutter.dev/deployment/obfuscate,
https://dart.dev/tools/dart-format and https://dart.dev/tools/pub/private-files (2026-10-02).

## Isolates
- The one hard rule: use an isolate when a computation makes the UI jank — when it takes longer than the gap between
  two frames. Typical: decoding or parsing a large file, image/audio/video work, a large local query.
- One-off work: `Isolate.run(() => …)` or `compute(fn, message)`. A long-lived worker: `Isolate.spawn` with a
  `ReceivePort` / `SendPort` pair.
- A spawned isolate has no `rootBundle` and does no widget or UI work. Plugins can be used there through
  `BackgroundIsolateBinaryMessenger.ensureInitialized(RootIsolateToken.instance!)` (sending works; unsolicited
  messages from the host do not arrive).
- The web has no isolates. `compute` still compiles there and runs on the main thread.

## Platform channels
- `MethodChannel` (calls), `EventChannel` (streams), `BasicMessageChannel` (messages); all asynchronous, encoded by
  `StandardMessageCodec` (booleans, numbers, strings, typed byte lists, lists, maps, null).
- The Dart side catches `PlatformException` (the platform returned an error) and `MissingPluginException` (no
  implementation on this platform) and decides what the UI shows — the `frontend` rule of explicit error paths.
- The native handler runs on the platform's main thread (Android: the UI thread; iOS: the main thread).
- Prefer `pigeon`: the messages are generated and typed, so the two sides cannot drift on a method name.
- Render by capability: a feature a platform lacks is not offered there.

## Navigation
- `Navigator` push/pop for a simple stack. An app with deep links, the web, or several navigators uses a routing
  package that parses the path (the project's own; `go_router` is the one Flutter's docs name).
- Named routes (`routes:` with `pushNamed`) are not recommended: their deep-link behaviour cannot be customised and
  the browser's forward button does not work with them.

## Text and locales
- No user-facing text is written inline. An app in more than one language uses `gen-l10n` (below). An app in one
  language may keep every text in one central file of constants instead: one place to read, review and later move
  to ARB files.
- `String.toUpperCase()` "uses the language independent Unicode mapping and thus only works in some languages"
  (api.dart.dev, 2026-10-07), and `toLowerCase()` likewise: under them Turkish `i` gives `I` and `I` gives `i`,
  where the language has `İ` and `ı`. Text is cased by one helper of the project that takes the locale and handles
  the letters its languages need; nothing calls the two methods on user-facing text directly.
- `FontFeature.tabularFigures()` (`TextStyle.fontFeatures`) asks the font for figures of one width, so amounts in a
  column line up and a changing number does not shift the text beside it. It does nothing in a font without them.
- `flutter_localizations` and `intl` in `pubspec.yaml`, `generate: true` under `flutter:`, an `l10n.yaml` with
  `arb-dir`, `template-arb-file`, `output-localization-file`. `flutter gen-l10n` (or `flutter pub get` / `run`)
  generates `AppLocalizations`.
- Placeholders, plurals and selects are ICU messages in the ARB file (`{count, plural, =0{…} other{…}}`), never
  strings glued together in Dart. `MaterialApp` gets `localizationsDelegates` and `supportedLocales`.

## Tests
- Unit (logic, dependencies faked), widget (one widget's look and interaction), integration (`integration_test/`, the
  `integration_test` SDK package as a dev dependency, `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`,
  `flutter test integration_test`). Confidence and maintenance cost both rise from unit to integration; a well-tested
  app has many unit and widget tests and enough integration tests for its important flows.
- Golden files: `matchesGoldenFile('goldens/x.png')`, refreshed with `flutter test --update-goldens`. The default
  test font (Ahem) draws boxes; custom fonts render differently across platforms and Flutter versions, so goldens are
  produced and compared on one platform, with fonts loaded first (`flutter_test_config.dart`).
- One place, in practice: a container image pinned by digest, with the Flutter version pinned, in CI. A golden that
  changed is regenerated there (a CI job that uploads the new files, or the same image run by hand) and reviewed as
  an image diff. `--update-goldens` on a developer's own machine produces files CI then fails.

## Release
- `flutter build <target> --obfuscate --split-debug-info=<dir>` on the targets that support it (Android, iOS, macOS,
  Linux, Windows; not the web). Keep the symbols: `flutter symbolize -i <trace> -d <symbols>` reads a stack trace
  back. Code that matches on type names (`runtimeType.toString()`) breaks under obfuscation.
- Obfuscation renames symbols; it does not encrypt and does not stop reverse engineering. **A secret does not ship in
  the app**, whatever the build flags.
- An application commits `pubspec.lock` (a library package does not): transitive upgrades become visible changes.
- `dart format` rewrites files by default; in CI and in the DoD use `dart format --set-exit-if-changed .` (exit 1
  when anything would change). The line width is the project's `formatter` setting in `analysis_options.yaml`.

## A feature closed by a build flag
A feature that must not reach the store yet (it waits for a review, a consent text, a legal check) is closed in code
by a compile-time flag: `const bool.fromEnvironment('NAME')`, set with `--dart-define=NAME=true`. The compiler drops
the closed branch. That keeps it out of an ordinary build; it does not keep it out of a store build that someone
runs with the flag. **The store build itself refuses the flag**, in the build system of each platform, before
anything is compiled:

- **Android (Gradle):** a task the release bundle depends on reads the project properties the Flutter Gradle plugin
  is handed — `dart-defines` and `extra-front-end-options` — and fails the build when a closed flag is among them.
- **iOS (Xcode):** a Run Script build phase, placed first in the app target, reads the build settings `DART_DEFINES`
  and `EXTRA_FRONT_END_OPTIONS` and fails a release archive the same way (a line that starts with `error:` shows
  among Xcode's build errors).

The ways round a check that only looks for `NAME=true`, each of which the check closes:
- **The defines are encoded.** They arrive as one value: entries separated by commas, each the base64 of
  `NAME=value`. The check decodes every entry; an entry it cannot decode fails the build.
- **Any value sets it.** The flag's name fails the build whatever follows the `=`, and so does the name anywhere
  inside another entry.
- **The front end's own options.** A define can be passed to the Dart front end directly (`-DNAME=…`), and other
  options replace what is compiled. A store build is given no front-end options at all; one that is, fails.
- **Only the store artifact is checked** — the release app bundle and the release archive. A debug or profile
  build, and a release build for one's own device, may carry the flag.
- A test in the project pins the check: it runs it with the flag, with the flag encoded, with a front-end option,
  and with none, and expects three failures and one pass.

Not from Flutter's documentation: the property and setting names above are what the Flutter tool hands to Gradle
and Xcode, read from a project that does this. They are not a documented contract, so the project's test also fails
when a Flutter upgrade renames them, instead of the check passing because it reads nothing.
