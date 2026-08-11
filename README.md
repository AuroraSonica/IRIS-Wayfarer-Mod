# I.R.I.S. — The Wayfarer Mod

**Immersive Rearing & Interaction System** for Dragon's Dogma 2 — a fully-native
(Lua + asset paks, zero exe patching) life-sim layer over the wilds of Vermund:
tame the creatures, ride them, breed them, and build a home to keep them at.

Built by **AuroraSonica**, co-architected with Iris (Claude).

## What's in the mod

- **Taming** — peaceful courtship rituals (the hand, the hunt, the howl) and
  combat tames (beat it down, carry it to a campfire, tend it by the fire).
  Griffin taming is a full canon scene: kill an ox as an offering and court the
  wild griffin that answers.
- **The Stable** — every tamed soul is a persistent companion with a name, a
  gender, and rolled **IVs** (HP / ATK / DEF / SPD / SIZE / LUCK, Pokémon-style
  genes) — breed toward better ones.
- **Mounts** — the flying griffin mount (native flight nodes, waypoint travel,
  aerial combat), the wild-horse mount, and Wyrmfeeding: feed a bonded wolf
  Wyrmslife Crystals at a camp and it grows into a rideable dire mount.
- **Wild variants** — wild horses, puma/panther packs, the Unicorn and Pegasus.
- **Homestead** — buy a plot with a deed, raise a house, furnish it, farm crops,
  cut wood, mount weapons on the wall, milk the ox and collect the eggs.

## Repository layout

| Path | What it is |
|---|---|
| `reframework/autorun/` | The mod code — the distributable Luas, at install paths |
| `dev/autorun/` | R&D instrumentation (perf probe, flight recorder, tapes) — NOT part of an install |
| `reframework/data/IRIS/` | Runtime-required data (house blueprints) |
| `packages/` | Latest Fluffy Mod Manager release zips (asset paks travel inside) |
| `tools/iris_pak/` | Pak build/packaging scripts (REtool-based; see comments) |
| `tools/AnimalAtlas/` | Creature motion atlases — verified clip ids per species |
| `profile-backup/` | Aurora's save-state (the stable of souls, the homestead) |
| `sync_from_live.ps1` | Copies the LIVE game files into this repo for commit |

## Install (for a fresh machine)

1. Install [REFramework](https://github.com/praydog/REFramework) for DD2.
2. Copy `reframework/autorun/*` and `reframework/data/*` into the game's
   `reframework/` folder.
3. Install the zips in `packages/` with Fluffy Mod Manager (they carry the
   asset paks — meshes, textures, audio banks, motion lists).
4. Optional: restore `profile-backup/*` into `reframework/data/` to bring back
   an existing stable + homestead.

## Development rules (the short version)

- The **live game folder is the source of truth** — edit there, then run
  `sync_from_live.ps1` and commit here. Never edit repo files directly, and
  never `git init` the live folder.
- Commit **only after in-game verification**.
- Parse-check every Lua before reload: `luac.exe -p <file>`.
- Never guess a DD2 clip id — grep `tools/AnimalAtlas/` by name.
- Asset paks are built compressed (REtool) — a raw-served `.mdf2` is a CTD.
