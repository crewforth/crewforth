# Motion

Loaded from `frontend-design` when a change animates something. Stack-neutral; the React Native and Flutter skills
add their own APIs on top of these rules.

## Should it move at all?
- Something the user sees a hundred times a day (a menu, a tab switch, typing) should feel instant: no animation,
  or under 100 ms.
- Motion earns its place by explaining something: where an element came from, where it went, what changed. If it
  only decorates, drop it.
- The cheapest tool first: no motion, then a CSS transition, then a keyframe, then a library. A library is for
  physics, gestures or orchestration the platform cannot do.

## How it moves
- Animate `transform` and `opacity` only. Width, height, top, left, margin and padding force layout on every frame.
- Never `scale(0)`: start from about `0.95` together with `opacity: 0`, so the element grows into place instead
  of appearing from a point.
- Set `transform-origin` to where the element comes from: a menu opens from its trigger, not from its own centre.

| Element | Duration |
|---|---|
| button press, toggle | 100–160 ms |
| tooltip | 125–200 ms |
| dropdown, popover | 150–250 ms |
| modal, sheet, drawer | 200–500 ms (larger travels longer) |

| Situation | Easing |
|---|---|
| something entering or leaving | `ease-out` (fast start, gentle stop) |
| something moving on screen from one place to another | `ease-in-out` |
| a press, a spring back | a short spring or a strong custom `ease-out` |
| anything on UI | never `ease-in`: it feels slow to respond |

## Interruption and exit
- An animation the user can interrupt (opening then closing a menu quickly) must reverse from where it is, not
  jump to the end and start over. Transitions do this; keyframes do not.
- Exit is usually faster than entry, about two thirds of its duration.
- Never block input while something animates.

## Respect the user
- `prefers-reduced-motion: reduce`: remove movement across the screen and parallax; keep opacity changes and keep
  the state change itself.
- Hover effects only under `@media (hover: hover)`.

## Gestures (drag, swipe, sheets)
- A drag follows the finger from the first pixel and can be grabbed again mid-animation.
- On release, hand the finger's velocity to the animation that finishes the gesture, so it does not stop and
  restart.
- The path back is the path out: a sheet dragged down returns the way it came.
- Past a boundary, resist (rubber-band) instead of stopping dead, and spring back.

## Never ship
`transition: all` · `ease-in` on UI · `scale(0)` · animated `width`/`height`/`top`/`left` · an animation that
ignores reduced motion · motion on an action repeated all day.
