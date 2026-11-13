# -196

Run Windows apps and games on an Apple silicon Mac. -196 (technical name `minus196`) is a small
Mac app and command-line tool that manages Wine "bottles": separate little Windows installs
that your programs live in.

-196 is meant for anyone with an Apple silicon Mac. It is still early: so far it has been
tried on one Mac (see below), so reports from other machines are welcome.

Not affiliated with or endorsed by CodeWeavers, Apple, Valve or the Wine project. CrossOver is
a trademark of CodeWeavers.

## What it does

- Creates, duplicates and deletes bottles, each with its own Windows version and settings.
- Runs a program in a bottle and keeps a log for each run.
- Picks a graphics layer per bottle: Apple's D3DMetal (DirectX 11 and 12), DXMT (DirectX 10/11),
  DXVK, or Wine's own.
- Finds the programs installed in a bottle and shows them as tiles in the app.
- Per-program rules (graphics layer, environment variables, DLL overrides, extra arguments).

## What has been tried

On a MacBook Air (M5), macOS 27:

| Program | Result |
|---|---|
| Steam | installs, signs in, shop and library draw |
| The Binding of Isaac (OpenGL) | runs |
| Hollow Knight (DirectX 11, DXMT) | runs at a steady 60 fps |
| Control (DirectX 12, D3DMetal) | about 50 fps at Medium, no ray tracing; about 81 fps with DLSS switched on (bridged to Apple's MetalFX) |

Not tested or not done yet: sound, long play sessions, Gecko (web views), SDL (controllers),
GStreamer (video), winetricks, and `engine/build-engine.sh` as one uninterrupted
run (the engine was built step by step).

## What is in this repository, and what is not

In it: the Swift source for the app and the command-line tool, the scripts that build the
engine, two small patches to Wine, and a small start-up hook.

Not in it, and you have to get them yourself:

- **Wine.** The engine is built from the source CodeWeavers publishes under the LGPL
  (`crossover-sources-26.3.0.tar.gz` from their source page). No built Wine is included here.
- **Apple's D3DMetal.** It comes from Apple's Game Porting Toolkit, which you download with your
  own Apple account under Apple's licence. `engine/install-gptk.sh` installs it from the disk
  image you downloaded. Without it you still have DXMT, DXVK and Wine's own graphics.
- **DXMT, DXVK, MoltenVK, Wine Mono.** Built or downloaded from their own projects by the
  scripts in `engine/`.

The project must not be pointed at the Wine inside an installed CrossOver.app; build the
engine from source instead.

## Building

Needs Xcode, Rosetta, and Homebrew with `bison`, `pkg-config`, `mingw-w64`, `meson` and `ninja`.

The app and the tool:

    swift build
    swift test
    ./make-app.sh              # makes build/-196.app

The engine (unpack the CodeWeavers source first; pass the path of its `sources` folder, or set
`SRC`):

    engine/build-freetype.sh <sources>
    engine/build-gnutls.sh
    engine/build-moltenvk.sh
    engine/build-engine.sh <sources>
    engine/build-compat-hook.sh
    engine/build-dxvk.sh
    engine/build-dxmt.sh
    engine/install-mono.sh
    engine/install-gptk.sh <Game Porting Toolkit .dmg>     # optional

Read each script before running it: they were written for one machine and say at the top what
they expect. `build-engine.sh` applies `engine/patches/` to the Wine source before building;
`build-llvm15.sh` is a helper for the DXMT build.

Then tell -196 where the engine is:

    .build/debug/minus196 engine add engine/dist/cx-26.3
    .build/debug/minus196 doctor

## Command line

    minus196 doctor
    minus196 engine list | add <path> [--name NAME] | default <name>
    minus196 bottle list | info <name> | delete <name> | duplicate <name> <new-name>
    minus196 bottle create <name> [--arch win64|win32] [--winver win10] [--backend auto|d3dmetal|dxmt|dxvk|wined3d]
    minus196 bottle set <name> key=value...      keys: backend msync winver engine env.NAME dll.NAME
    minus196 run <bottle> <program> [--cwd DIR] [--wait] [--debug CHANNELS] [--dry-run] [-- args...]
    minus196 kill <bottle> [--force]
    minus196 env <bottle>

## Where things are kept

Everything lives in `~/Library/Application Support/minus196` (set `MINUS196_HOME` to change it):

    engines/<name>            a Wine install
    backends/gptk|dxmt|dxvk   graphics layers
    bottles/<name>/           bottle.json, prefix/ (a plain Wine prefix), logs/
    rules.json                per-program rules
    settings.json             default engine

## Safety notes

- **A bottle is not a sandbox.** Windows programs run as you and can read and change your
  files: every bottle has a `Z:` drive (the whole Mac) and a `Y:` drive (your home folder).
  Only run programs you trust.
- A `bottle.json` or `rules.json` from someone else can change how programs are started.
  Treat them like programs: don't use ones you don't trust.
- The app's "Install Steam" button downloads Valve's installer from Valve's server and runs
  it. Nothing else in the app or the tool uses the network; there is no telemetry.
- The build scripts download source code. LLVM and Wine Mono are checked against recorded
  checksums; DXMT is fetched by its release tag, and the nettle, Vulkan-Headers and cereal
  archives are ones you fetch yourself and are not checked.
- For Steam's built-in browser the engine adds `--in-process-gpu`, which removes one layer of
  that browser's own process separation. Without it Steam's windows stay blank.
- Each run's log keeps the full command line. Logs are in the bottle's `logs` folder and are
  never deleted automatically.

## Licence

See `LICENSE`. The files in `engine/patches/` change Wine and carry Wine's licence, the GNU
LGPL version 2.1 or later.
