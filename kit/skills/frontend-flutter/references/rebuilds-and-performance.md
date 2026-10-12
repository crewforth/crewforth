# Rebuilds and performance (Flutter)

Checked against https://docs.flutter.dev/perf/best-practices, https://docs.flutter.dev/testing/build-modes and
https://docs.flutter.dev/ui/adaptive-responsive/best-practices (2026-10-02).

## Where a rebuild stops
- `setState()` on a `State` rebuilds every descendant. The walk stops where it meets **the same child instance** as
  the previous frame — which is what a `const` widget, or a child passed in from outside, gives it. So:
  - put `setState` (or the narrowest provider/listenable read) on the smallest subtree that changes;
  - pass a static subtree as `child` to `AnimatedBuilder` and friends, instead of building it inside the builder;
  - make a reusable piece of UI a `StatelessWidget`: a helper method that returns widgets is rebuilt with its parent.
- `build()` can run on every ancestor rebuild. Nothing slow in it: no parsing, no I/O, no sorting of a large list.
- Do not override `operator ==` on a widget unless it is a leaf; it turns rebuild comparisons quadratic.

## Painting
- `saveLayer` allocates an off-screen buffer. Widgets that can trigger it: `ShaderMask`, `ColorFilter`, a `Chip`
  with a non-opaque disabled colour, a `Text` with an overflow shader. Look for it with the "checkerboard off-screen
  layers" option in DevTools before blaming anything else.
- `Opacity` only when needed: animate with `AnimatedOpacity`, fade images with `FadeInImage`, or paint with a
  semi-transparent colour.
- Clipping is cheaper than `Opacity` (it does not call `saveLayer` unless `Clip.antiAliasWithSaveLayer` is asked for)
  but still costs: prefer `borderRadius`, and clip before an animation rather than during it.

## Layout
- Long lists and grids: the lazy builders (`ListView.builder`, `GridView.builder`) build only what is visible.
  A `Column` or a `ListView(children: …)` builds every child up front.
- Intrinsic passes (sizing every cell to the largest, for example) poll all children. Give cells a fixed size, or pick
  an anchor cell. DevTools' "Track layouts" option labels them `'<type> intrinsics'`.
- Build strings in a loop with `StringBuffer`, not `+`.

## Measuring, not guessing
- Measure in **profile mode on a real device**: `flutter run --profile`. Debug mode is not indicative, and profile
  mode does not run on an emulator or simulator.
- Budget: build and render run on separate threads, about 16 ms each per frame at 60 Hz; under 8 ms in total is the
  target at 120 Hz. Going below the budget is still worth it: it saves battery and heat.
- A performance claim in a PR carries the profile-mode numbers it is based on (the `performance` skill).
