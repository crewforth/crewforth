# Studio recordings

Re-records the Studio pictures after a change to the panel:

| File | Where it is shown | What it shows |
|:--|:--|:--|
| `assets/studio-panels.gif` | the Studio page | the panel in use: the graph and an agent's inspector, the Timeline, the List, a request answered in the approval dock, the New session panel |
| `assets/studio-graph.png` | the Studio page | the Graph view of the finished session |
| `site/media/crewforth-hero.mp4` | the front page, and the README by its own copy | two scenes of the overview video: the Studio scene (40.4 s – 47.8 s), and the version and skill count the install scene prints (8.8 s – 12.2 s). Every other frame and the sound are left as they were |

```bash
bash packaging/studio-record/record.sh                    # the two pictures, and the take the video uses
python3 packaging/studio-record/scene.py --video OLD.mp4 --film <take> --out NEW.mp4   # the scene in the video
node packaging/studio-record/install-render.mjs --out <dir> --was "3.0.0,39" --now "3.1.0,40"
python3 packaging/studio-record/install_scene.py --video OLD.mp4 --drawn <dir> --out NEW.mp4   # the numbers the install scene prints
```

The file names stay the same, so the site picks up a new recording without an edit.

## What `record.sh` does

1. `fixture.mjs` writes a synthetic transcript tree: four demo projects, their sessions, twelve agents and a
   workflow. Every project, path, session id and sentence is invented. The projects themselves are created under
   `/Users/Shared/dev`, because the panel reads each project's `.claude/VERSION` from its working directory and shows
   a path under `/Users/<name>` as `~/…`. The transcripts go to `/Users/Shared/.claude/projects` for the same
   reason: the panel shows where a transcript is, and a root under the user's home would put the user's name in the
   picture. `record.sh` refuses such a root. The fixture deletes only directories it marked itself.
2. The panel runs from `kit/studio/` in isolation: its own projects root, runtime directory, temp directory, token
   and machine name, and a version feed given as a `data:` URL, so it reads nothing from the network.
3. The `claude` on the panel's PATH is `standin-claude.mjs`. Its `agents --json` lists the fixture's sessions, so
   the sessions open on the machine doing the recording never appear. A session the panel starts is played from a
   script, and its tool call goes through the panel's real approval hook: the dock in the picture is the product's
   own, waiting on the product's own gate. No model is called.
4. `grow.mjs` replays the hero session step by step while `shoot.mjs` films the Graph. `stage.mjs` drives a headless
   Chrome with a throwaway profile over the DevTools protocol (`cdp.mjs`), so no automation banner and no other
   window can reach a frame.
5. `tour.mjs` uses the panel on the finished fixture. Each beat states what must be true after it, and the take
   stops if it is not: a click that did nothing looks like a click that worked until the film is assembled.
6. After every beat, and at the end of each take, the page's text is searched for this machine's home directory,
   user name and host name. A take that shows one of them fails.
7. The last frame of the replay is kept as the still, and ffmpeg encodes the tour as a GIF at 1600 px wide, 10 fps
   and 128 colours.

The version shown on the demo projects and in the header is the repository's `VERSION`. Set `VERSION_SHOWN` to
record another one.

## What `scene.py` does

The overview video's source page is not in the repository, so the scene is not rendered again: the new take is put
inside the Studio card of the existing video, frame by frame, with the card's own fade and push-in, and the result
is encoded once with the sound copied. Before writing anything it measures the old video's fade against its model
of the scene and stops if they disagree, which is also how the frame offset of a copy with leading frames is found
(`--offset`). `--check` runs that measurement alone.

After it, compare the two files where they must not differ. For the 3.1.0 recording, frames outside the scene read
SSIM 0.9997 against the old file, and the audio stream's bytes are identical.

## What `install_scene.py` does

The install scene prints the version and the number of skills, and both go out of date. The video's source page is
not in the repository, so the lines are not rendered again: `install-render.mjs` draws the two numbers in the
repository's JetBrains Mono, laid out as that page lays them out, and says where each character is.
`install_scene.py` then rewrites only the characters that differ, on the frames the lines are on screen, at the
weight each line has on each frame, and encodes the picture once with the sound copied. The new text has to be as
long as the old: a longer number would move what follows it.

Before writing it measures two things on the input and stops if either is off: the moment the first line appears
against its model of the scene (which is also how a copy's frame offset is found), and how closely its drawing of
the old numbers matches the video's own.

## Requirements

macOS, Node 22, ffmpeg and Google Chrome; `scene.py` and `install_scene.py` also need Python 3 with numpy and Pillow. No model session is
started and no tokens are spent. Working files go to `$TMPDIR/crewforth-studio-record` (`CREW_RECORD_TMP` moves
them). The panel listens on port 7802 (`CREW_RECORD_PORT`).

This directory is not part of the npm package or the plugin.
