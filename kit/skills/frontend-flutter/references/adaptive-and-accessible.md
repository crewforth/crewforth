# Adaptive layout and accessibility (Flutter)

Checked against https://docs.flutter.dev/ui/adaptive-responsive/general,
https://docs.flutter.dev/ui/adaptive-responsive/best-practices,
https://docs.flutter.dev/ui/accessibility-and-internationalization/accessibility,
https://docs.flutter.dev/ui/accessibility/accessibility-testing and the Material window size classes as Android's
documentation states them (2026-10-02); the foldable part against
https://api.flutter.dev/flutter/widgets/MediaQueryData/displayFeatures.html (2026-10-07).

## The three steps
1. **Abstract** the widgets that change with the space, and the data they share.
2. **Measure:** `MediaQuery.sizeOf(context)` for the whole window — cheaper than `MediaQuery.of`, which rebuilds on
   any change of the whole `MediaQueryData` — or `LayoutBuilder` for the space this widget is given (it hands you
   `BoxConstraints`, a range, not a size).
3. **Branch** on breakpoints. The project's design system names them; the Material window size classes are:

   | Class | Width |
   |:--|:--|
   | compact | < 600 dp |
   | medium | 600 – 839 dp |
   | expanded | 840 – 1199 dp |
   | large | 1200 – 1599 dp |
   | extra-large | ≥ 1600 dp |

   Material's own example: a bottom navigation bar below 600 dp, a navigation rail from 600 dp.

## What not to do
- **No device-type checks** ("is this a phone or a tablet") for a layout decision: a foldable, a split screen or a
  resizable desktop window breaks them. The window's size decides.
- **No orientation lock.** It is an accessibility problem; if a lock is truly required, read the physical size from
  the `Display` API, not `MediaQuery`, and support both portrait directions.
- Large widgets broken into smaller ones, so `const` instances can be reused across a resize.
- A list that keeps its layout across a rotation keeps its scroll position: `PageStorageKey`.
- Mouse, trackpad and keyboard shortcuts work where the app runs on desktop or a large screen.

## List and detail
- Expanded and wider: the list and the detail are two panes of one screen. Compact: the list is the screen and the
  detail is pushed over it. Medium is the design system's call.
- **The selection and any typed input are kept across a change of window class.** Hold them above the two layouts
  (the view model, or state owned by the widget that chooses the layout), so that going from two panes to one shows
  the detail that was selected, with the form as it was, and going back does not clear it. A `GlobalKey` or a
  `PageStorageKey` keeps a subtree's state only while its place in the tree allows it; state that must survive is
  not left to that.

## A foldable
- `MediaQuery.displayFeatures` (and `MediaQueryData.displayFeatures`) lists the areas of the display that hardware
  obstructs. The documentation says it is populated on Android only. A **hinge** and a **cutout** obstruct the
  display; a **fold** is a crease and does not. A hinge and a fold carry a state that tells the device's posture.
- When a hinge separates the window into two areas, **the panes split at the hinge**: one pane on each side, and
  nothing — no text, no control, no divider the user must touch — laid out on the hinge's bounds.
- A window with no such feature, or with a fold that obstructs nothing, is laid out by its width alone.

## Accessibility, tested
Rules (the `a11y` skill holds them for every stack): tap targets at least 48×48 on Android and 44×44 on iOS; a
label on every tappable; text contrast at least 4.5:1 (3:1 for large text, 18 pt and above); the UI legible and
usable at very large text and display scale.

The guideline test, in `flutter_test`:

```dart
testWidgets('meets the accessibility guidelines', (tester) async {
  final SemanticsHandle handle = tester.ensureSemantics();
  await tester.pumpWidget(const MyApp());
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
  handle.dispose();
});
```

Run it for every new screen.

## Widths, tested
- Every new screen reached from the app's navigation has a widget test at **one width of each window class the app
  supports**, for example 320 and 360 dp (compact, a small and a common phone), 700 dp (medium) and 1280 dp (large).
  Set the size with `tester.view.physicalSize` and `devicePixelRatio`, and reset both afterwards.
- One test **crosses a class boundary**: select an item and type into a form at one width, change the width to
  another class, and expect the same selection and the same input.
- The narrowest and the widest window alone are not enough: a layout can be right at both ends and wrong in a class
  between them.
