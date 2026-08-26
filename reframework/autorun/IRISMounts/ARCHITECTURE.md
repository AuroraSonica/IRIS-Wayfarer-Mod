# I.R.I.S. Mount Engine modularisation

The field-verified Drake baseline is Git commit `d4728f1`, tagged
`drake-complete-2026-08-25`. The split begins after that point and must not
deliberately change mount behaviour while code is being moved.
The first full-restart-tested modularisation checkpoint is `08613bd` on
`refactor/iris-mount-engine`, also pushed to GitHub before the August update.
The neutral feature-namespace checkpoint is `ce7fecf`; Griffin and Drake were
both full-restart tested after that relocation.
The adapter-owned Griffin binding checkpoint is `a600ee2`; all Griffin and
Drake controls were field-tested before it was pushed.

## Current reality

`GriffinRideProbe - Iris.lua` is still the large runtime entry point, but
the code is not wholly monolithic. Six substantial shared systems now live
under `IRISMounts/core/`:

- `combat.lua`: shared mounted targeting, native hit transactions and combos;
- `downed.lua`: shared companion down/revive protection;
- `flight_animation.lua`: flight animation presentation;
- `orders.lua`: companion orders and combat leases;
- `stable.lua`: persistent companions, health and taming records;
- `ui.lua`: shared companion health/stamina, progress, blessing and rodeo HUD
  publication plus D2D rendering.

The old `IrisGriffin/` paths are compatibility loaders. A dual-name package
cache bridge ensures Reset Scripts reuses an already-loaded legacy instance
instead of registering the same globals/hooks twice. The implementations use
the neutral shared context, but still inherit many runtime globals; making
those dependencies explicit remains separate work.

The first profile and identity extraction seams now exist:

- `IRISMounts.context` owns the process-lifetime config/runtime tables, while
  `IrisGriffin.context` remains a compatibility alias;
- `IRISMounts.species.registry` resolves live names and saved species codes to
  declarative Griffin/Drake adapters and their proven capabilities.
- `IRISMounts.core.profiles` owns the unchanged 98-field compatibility schema,
  JSON profile capture/load/write and the complete application transaction;
- `IRISMounts.core.profile_migrations` owns the exact ordered legacy migration
  pipeline formerly embedded in the entry point.
- `IRISMounts.core.input` owns low-level keyboard/gamepad axis and button reads,
  deadzone handling and the shared menu-input gate. Legacy action handlers use
  compatibility aliases until the dispatcher moves;
- `IRISMounts.core.actions` resolves the active species adapter's declarative
  action meanings into HUD labels, including Griffin charge/carry/eat contexts
  and Drake attack variants. Its dispatcher now translates Drake X/Y/LT/RT
  edges into adapter action IDs and invokes the matching proven handler. The
  same module also resolves adapter-owned physical bindings without taking
  ownership of input edges or action eligibility;
- `IRISMounts.species.drake` now owns the exact authored nodes, clips, stages,
  combo data and camera parameters for all eight dispatched Drake combat
  actions. The runtime injects only the generic node/motion attack executors.
  Griffin's adapter now owns the bindings for dive bomb, dogfight, air gust,
  air press, loop/quick-rise, ground gust, ground attack, grab and eat. Their
  independent state machines deliberately retain their existing edge/hold
  state and guards; collapsing those overlapping readers into Drake's central
  dispatcher would change behaviour rather than merely split code.
- Mounted-combat stamina accounting now lives with `core/combat.lua`, while
  its shared gauge and the other companion HUDs live in `core/ui.lua`. This is
  an exact mechanical relocation pending a full-restart field test.

Reset Scripts deliberately refreshes stateless profile/input/action/species
modules while preserving `IRISMounts.context`, so edited adapter data cannot
remain trapped in Lua's module cache and the process-lifetime `C`/`S` tables are
not replaced. Stateful feature modules are deliberately cache-aliased rather
than refreshed because several install hooks or publish runtime globals.

No locomotion, flight physics or seating implementation has moved yet. Shared
combat and flight presentation now have neutral paths, while Drake combat
payloads live in its adapter. The signature-guarded migration pipeline remains
intact as one compatibility unit.

## Target layout

```text
autorun/
  IRISMounts.lua
  IRISMounts/
    context.lua
    core/
      runtime.lua
      animation.lua
      flight_animation.lua
      input.lua
      actions.lua
      profiles.lua
      mounting.lua
      seating.lua
      locomotion.lua
      flight.lua
      combat.lua
      downed.lua
      orders.lua
      stable.lua
      ui.lua
    species/
      griffin.lua
      drake.lua
      ox.lua
      chimera.lua
      garm.lua
```

Species files describe identity, capabilities, motions, seating and bindings.
They may provide narrow override hooks where game evidence requires one. They do
not receive copied mount engines.

## Compatibility contract

- Keep `GriffinRideProbe - Iris.lua` as the autorun entry point until the new
  entry point has survived an in-game smoke test.
- Keep `GriffinRideProbe (IRIS)` persistence filenames until feature parity;
  Aurora's tuned config, stable and species profiles must continue loading.
- Keep `_G.IrisGriffinBridge` until every consumer has migrated to a neutral
  bridge. Rename it only in a dedicated compatibility change.
- Keep one process-lifetime `C` table and one `S` table. Cached modules must
  never retain an abandoned context after Reset Scripts.
- Only one system may own mount translation/rotation at a time.
- Native grab remains the rider's logical attachment owner, and the root-motion
  theft fix remains centralised and reversible.

## Extraction sequence

1. **Context namespace** — make `IRISMounts.context` the state owner and retain
   `IrisGriffin.context` as an alias. Complete and smoke-tested.
2. **Species registry** — introduce declarative Griffin and Drake adapters, then
   route existing species/profile lookups through them without moving behaviour.
   Complete and smoke-tested.
3. **Profiles and capabilities** — extract save/load/migrations and replace
   scattered `ch257` checks with capabilities such as `flight` and
   `mounted_combat` where that is genuinely equivalent. Store/schema and exact
   migration-pipeline extraction implemented. Migration identity now resolves
   through the species registry; the ordered compatibility rules remain central.
4. **Input and HUD routing** — one binding dispatcher asks the active adapter
   which actions exist. Ground mounts then omit flight controls naturally.
   Low-level input reader and adapter-owned HUD/action-meaning resolver
   implemented and smoke-tested. Drake's central combat edge detector uses the
   shared dispatcher, and its byte-identical handler payloads now live behind an
   explicit factory in the Drake adapter. That relocation and the neutral
   feature namespace have passed full-restart field verification. Griffin's
   physical bindings now cross the adapter boundary while its proven,
   independently owned state machines stay in place; field verification of the
   binding pass has passed field verification.
5. **Mounting, seating and animation ownership** — move native grab, rider/pawn
   placement, motion leases and the root-motion law as an inseparable tested set.
6. **Locomotion and optional flight** — extract the single transform authority;
   flight becomes a capability module rather than a second engine.
7. **Existing feature modules** — move combat/downed/orders/stable/flap into the
   neutral namespace, retaining legacy loaders and replacing global dependencies
   with explicit context exports. Namespace relocation and Reset-safe cache
   bridging implemented as one exact mechanical batch; field verification and
   explicit dependency cleanup remain.
8. **Entrypoint cutover** — add `IRISMounts.lua`, turn the old filename into a
   guarded compatibility loader, smoke-test Reset Scripts and a full restart,
   then retire the old name only after parity.
9. **Ground mounts** — build Ox first on the proven engine. Investigate Chimera
   and Garm independently rather than assuming their controllers match Ox.

Every extraction gets its own compile check and in-game smoke test. The live game
folder is never a merge surface; parallel species work uses Git worktrees after
the adapter boundary exists.
