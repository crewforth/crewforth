# Building from a design

Loaded from `frontend` when the task is to match a design: a Figma file, a mock, a screenshot, "make it look like
this".

## Before starting
- Look at the tools this session has before saying a design tool is not available: a Figma or design connector
  may be attached. If none is, ask for exported frames or the values; never guess them from a low-resolution image.
- Prefer the design's variable and style names (`color/surface/raised`, `space/16`) over the raw values: they map to
  the project's tokens, the raw values only approximate them.
- Save the assets the design uses into the project. Links from a design tool expire.

## Values → tokens
- Map each design value to the project's token. When there is no exact token, use the nearest one and list it as
  rounded: "padding 18 → 16 (space-4)".
- Never add a token only to hit a number from the design. When rounding would move something by more than 2 px or
  change a colour step, ask instead of choosing.

## Scope
Build the states the frames show. A state the design does not show (error, empty, loading, long text) is built from
the project's existing pattern and listed as "not in the design".

## Check
Compare side by side at each width the design gives, and report a fidelity table:

| Element | Matches | Rounded | Deviates (why) |
|---|---|---|---|

Then two lists: **Unwired** (shown in the design, not connected to data or behaviour yet) and **Missing states**.
