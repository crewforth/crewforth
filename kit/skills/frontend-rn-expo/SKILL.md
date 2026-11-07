---
name: frontend-rn-expo
description: |
  OPTIONAL, stack-specific: React Native + Expo (prebuild). Mobile RN projects only; the generic principles
  live in the `frontend` skill.
---

# React Native + Expo (stack-specific layer)

**Apply only when the project IS React Native / Expo** — its `package.json` depends on `react-native` or `expo`.
Otherwise do not use this skill: `frontend` and the project's own stack apply (see its Client stack order).

<!-- routing-eval reads the next line; why it sits in the body: AGENT_TEMPLATE.md -->
Trigger phrases: "expo", "react native", "native bridge", "expo router", "rn screen", "prebuild"

For generic frontend discipline, applies the `frontend` skill; this file only covers the RN+Expo-specific additions.
Not used in web/desktop projects (delete it if needed).

## RN + Expo specifics
- **Navigation:** expo-router (file-based) or react-navigation — follow whichever the project uses.
- **Lists:** `FlatList`/`FlashList` + `keyExtractor`; virtualization for heavy lists.
- **Native bridge:** only when needed; the JS side is **typed**, error paths are explicit (what the UI does if native rejects).
  Via Expo prebuild / config plugin; mind the platform difference (iOS/Android).
- **Render by capability:** do **not** promise in the UI a capability the device lacks; show it conditionally.
- **Assets:** image size/resolution, `expo-image` cache, splash/icon prebuild compatibility.
- **Motion and gestures:** the rules in `frontend-design/references/motion.md` (a drag can be grabbed again
  mid-animation, release velocity carries into the finish, rubber-band at the bounds) on top of the project's
  gesture and animation library.

## DoD (in addition to the generic `frontend` DoD)
- Works across the target iOS/Android version matrix; native bridge error paths are tested.
