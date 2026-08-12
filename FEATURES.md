# I.R.I.S. — The Wayfarer Mod · Full Feature Inventory

**Immersive Rearing & Interaction System** for Dragon's Dogma 2.
A fully-native (Lua + asset paks, zero exe patching) life-sim layer over the wilds of Vermund:
tame the creatures, ride them, breed them, and build a home to keep them at.

Built by **AuroraSonica**, co-architected with Iris (Claude).

> Inventory compiled 2026-08-12 by reading every module in the install set, the git history,
> the asset paks and the project memory bank. Statuses are reconciled **pessimistically** —
> where the code and the field notes disagree, the field notes win.

### Status legend

| Tag | Meaning |
|---|---|
| ✅ **Shipped** | Built and confirmed working in-game |
| ⚠️ **Awaiting test** | Code is in and complete, but nobody has verified it in a real session |
| 🔶 **Partial** | Works, with a known gap, an open bug, or off by default |
| 📋 **Planned** | Designed, not built |
| ⛔ **Closed** | Tried and walled. **Do not promise these** — listed so they're never re-litigated |

---

# PART 1 — TAMING

The heart of the mod. Every creature is *earned*, never captured, and no two rites are identical.

### The Wayfarer's Sense ✅
Press **K** and the world dims while every tameable creature within 80m lights up with a floating
label: species name, distance, and what kind of tame it needs (*tameable · tameable pet ·
tameable pack-beast · tameable mount · combat tame*). Creatures you've already tamed glow green
and show their pet name. The Arisen plays a searching gesture as the pulse goes out.
It's honest about what it sees — an ox already harnessed to a cart reads *"yoked to its cart"*.
The same pulse marks harvestable timber and minable stone.

## 1.1 The wolf courtship — the peaceful path ✅

Sheathe your weapon, hold **N** near a wild wolf, and it takes your measure. **Three of four
trials are drawn at random each attempt**, with the Hunt always spliced in — so no two tames run
the same order.

| Trial | What happens |
|---|---|
| **The Circle** ✅ | It stalks a ring around you. Keep your eyes on it and stay calm; turn away or rush it and the moment breaks. |
| **The Charge** ✅ | It paces, growls, coils — then backs off a long way, wheels, and charges at full speed, skidding to a halt in your face. Flinch and you fail. |
| **The Stare-down** ✅ | It plants itself and holds your gaze. Raise your hand and meet its eyes for five seconds without breaking. |
| **The Howl** ✅ | It sits and howls at you — and you howl back. Hold **H** and your Arisen throws their head back and roars, whatever your vocation. |
| **The Hunt** ✅ | It's hungry and wants proof. A deer breaks from cover (marked green); kill it, carry the carcass to the wolf and *set it down*. It feeds — your hunt speaks for you. If there's no live prey around, the game quietly conjures a doe out of your line of sight so the trial can always run. |
| **The Pact** ✅ | It walks the last steps to you, lies down, and you hold your hand out one final time. The Arisen strokes its head, it howls for you, and the bond seals. |

**Failure is a setback, not a reset** ✅ — press too close and it startles, warns you, then walks
away, but it *remembers most of your patience*, so the next visit starts further along. Fail twice,
or fail inside its personal space, and it turns on you and won't speak to you for a while
(*"IT REMEMBERS — your failure stands between you"*). Familiarity persists between sessions.

**The taming shield** ✅ — the moment you flag a creature, your pawns stop attacking it and it
cannot be killed. The shield drops the instant *you* strike it, which is what converts a courtship
into a combat tame. **The pack holds** ✅ — court one wolf and the rest of the pack stop, hold,
and watch (40m radius).

**Line-of-sight gating** ✅ — you can't court an animal through a wall. (The fix for courting rats
through a cellar floor.)

**Seal-heal** ✅ — every tame, by every route, is healed to full HP the moment the pact seals.

## 1.2 The combat tame ✅

Flag a hostile creature, then strike it yourself — allies pile in, but it cannot die. Beat it to the
floor and it **yields**, lying beaten and waiting (default two-minute recovery window).

**Carry it to the campfire** ✅ — pick a beaten creature up onto your shoulders. A marker points you
to the nearest campsite you know; the recovery timer freezes while you carry it. Pitch camp, set it
down by the fire, sit with it while the bond fills, lay out **real meat from your pack**, and offer
your hand. It's yours by the fire rather than by the sword.
*Deliberately gated on a made camp* — a camping kit is required; the no-kit shortcut and the
anywhere-dominance finish were both removed as too cheap. **Cats get a feline skin of the rite**
(THE SIT and THE KNEEL instead of the howl).

## 1.3 Small creatures — the patience ✅

Small wildlife is never chased down; it has to come to you.

- Hold **N** and stand perfectly still at a distance while it decides about you. Push closer and it bolts.
- When it trusts you, drop a **real herb from your pouch** on the ground (Greenwarish, Pitywort, Morningtide, Syrupwort…). It comes, eats, and you hold the palm out until it finishes.
- Your weapon is forced away for the whole courtship — steel scares small things.

**The falconry call** ✅ — for birds there's an extra beat. Press **H** and the Arisen raises a hand
to their mouth; the whistle carries across the field and the bird takes wing and lands on your
outstretched arm. Draw steel and it flutters down to wait on the ground instead. Arm and head angles
are slider-tunable and the Arisen's head can auto-track the incoming bird.
**Ground critters skip the whistle** ✅ — rabbits, rats and chickens go straight from the patience
to the food drop. Chickens can't fly, by explicit design.

**Per-species behaviour** ✅ — a crow scavenges, a bird eats and preens, **a bat never lands and eats
on the wing**, a rat is an omnivore that'll take spoiled fruit, a rabbit grooms itself, a hen pecks
and shuffles instead of eating. Each has its own idle repertoire, bathing/grooming flourishes and
food hints. *(The bat was rebuilt to never stop flying after three of them died.)*

## 1.4 The Yoke Rite — ox taming ⚠️

An ox isn't broken, it's won. Hold **N** near a pasture ox to make the offer, then walk to it slowly
and stand still while it takes your measure. When it abides you, drop something green from your pack
and let it eat. Then it starts wandering and **you have to walk at its side, keeping pace**, until it
slows, stands, and accepts your open palm — and lows for you, deep and content.

- Only pasture oxen; an ox harnessed to a cart is off limits (ownership is asked of the cart's own AI, not guessed from the name).
- Arming is deliberate so it never sabotages the griffin's ox-offering hunt.
- **It can be failed** ⚠️ — per-stage patience timers (Measure 25s, Offering 60s, Yoke 20s, Palm 30s), walking 40m away abandons it instantly, and a failed rite locks that ox out for two minutes. The offering must physically land within 6m to count.
- Hardened over 11 review rounds; not yet field-signed-off.

## 1.5 The griffin — three routes

### Route 1: The ox offering ✅ (Act One) / 🔶 (Act Two)

**Act One — the offering** is described in the notes as *"routine"* after many field runs, and is
Aurora's favourite tame: *"how much I like this taming method, it feels natural and cool."*

Kill an ox in the open where a wild griffin hunts and leave the body. The wind carries the scent —
she stirs, circles, banks, lines up and **stoops on the kill**, narrated card by card as she actually
behaves, with a marker tracking her across the sky. She eats her fill, then looks back at you, and
you stand before her with weapon sheathed and hold out your hand.

- Carries a **Law of Worthiness**: it must be *your* kill, an ox you saw alive nearby, witnessed by the griffin. Cart oxen are excluded by identity.
- 🔶 A live rat is hidden under the carcass — a dead ox isn't a valid predation target for her native AI, so a tiny live prey body makes her author the line-up and the stoop for real.
- If she refuses long enough the rite stands down gracefully and that carcass is refused for a minute, so a retry needs a fresh kill.

**Act Two — the rodeo** 🔶 is in progress. She shrieks, turns away and lies down; you climb on and
she rises and circles. A timed duel follows: a warning tell rears up before each buck and you hold
**N/LT** to cling. Between bucks you strike her to wear down her will, but attacking costs grip —
greed puts you on the ground. Break her and she lands, lowers her head, and you seal the pact.
*Palm → shriek → lie-down → climb → takeoff all reach the field. The buck waves and the final pact
are designed but not fully built. A known bug: a griffin seized mid-stoop performs the lie-down
floating in mid-air — fix awaiting test.*

An **anti-slam guard** keeps her airborne so a landing can't cheaply shed you, and a **grip aid**
(stamina never drains while clinging) is available as a toggle.

### Route 2: The egg heist ✅ / incubation ⚠️

Find a nest, steal an egg and run. **Carrying it enrages every wild griffin in the sky** and they
come hunting the thief. The egg is desperately fragile — a drop, a throw, a roll, a blow, even
*jumping* while holding it will shatter it. Get it to a campfire and set it down gently.

- **Roost warden** — camps inside a nest's shadow refuse to shelter it (*"NO SANCTUARY HERE"*), and the mod also puts out native campsites built too near a roost.
- **Nest clutches** 🔶 — nests hold 0–3 eggs and re-roll a fresh clutch after ~5 in-game hours, so the heist is repeatable rather than one-shot.
- **Live egg world** 🔶 (off by default) — real nest bowls grow at surveyed roost sites worldwide, so the heist is something you can go looking for anywhere. Nests are visual props; you can't stand on the rims.
- **Incubation** ⚠️ — an egg by the fire warms over ~7 in-game days and tells you how long is left. Pick it up and the warmth fades; incubation pauses until you settle it again. It survives saves and is sanity-checked against the in-game clock, so rolling back to an older save rolls the egg back too.
- **Hatching** ⚠️ — a tiny griffin joins your stable, small and loud and yours, and grows to full size over the following in-game days. It must reach 75% of full size before it's rideable.

### Route 3: The truce tame 📋
Fight *beside* a griffin already battling a wrecked oxcart caravan and win her trust by taking her
side rather than feeding her. Designed in full, every dependency verified present, **not started**.
*(Rule: valid targets = her enemy list minus your party. Don't despawn the caravan — it belongs to
another mod.)*

## 1.6 Wyrmfeeding — the Wyrm's Rite ⚠️

Feed **Wyrmslife Crystals** to a bonded beast at a campfire and draconic vitality swells it beyond
its natural frame. A prompt floats over your companion; accept and it takes the crystals from your
hand with a howl while deep dragon-red light wraps its body. Rest by the fire and **by morning it has
grown** — far enough, and a small companion becomes something you can ride (mount line at 1.85×).

Needs a lit campfire, your active companion nearby, and 3+ crystals. A hatchling is refused —
*"the hatchling grows on its own clock."* Growth eases in over an in-game day and saves with the
companion.
⚠️ **Advise feeding small species only** — the follow-driver's spacing doesn't scale with body size,
shoulder-perching a wyrm-grown critter is comedy, and griffin-sized species are untested.

## 1.7 Companion critters

- **Gender on every tame** ✅ — rolled when you begin courting, so you know in advance. Shown with ♀/♂ on the courtship marker, the naming card, the stable list and the nameplate. Locked forever once tamed.
- **The naming card** ✅ — *"Name the female Bat who chose you"* fades up and you type its name straight onto the screen. The world pauses and every other mod hotkey stands down while you type.
- **Floating nameplates** ✅ — name + gender symbol above your companions, so a field of identical animals still tells you which one is yours. Reads the live stable record, so renames land instantly.
- **Shoulder perch** ✅ — **L3** near a small tame and it hops up, shrunk to a sensible size, looking around, crying and grooming as you travel. A bat roosts upright rather than hanging; a rat climbs you rather than leaping.
- **Pick it up and carry it** ✅ — **E/RT** and it settles against your chest; a rabbit rides belly-up with its own held-animal idle, head in one hand and rump in the other. *(Fixes from 08-05 for set-down float are awaiting a re-test.)*

## 1.8 The scout drone ✅

Send your perched bird out and **take direct control of it**. The camera goes with the bird; you fly
it to scout ahead — left stick steers, shoulder buttons climb and dive, **B** soars. Control returns
after 30s or on recall, and it flies home to your shoulder.

| Ability | Key | Effect |
|---|---|---|
| **Ping** | P / △ | Sonar sweep marking hostiles red, wildlife green, collectibles gold |
| **Caw** | C / □ | Draws a nearby enemy's attention toward the bird and away from you |
| **Collect** | F / ✕ | Pecks up loose items; the bird carries the haul back and reports what it took |
| **Dive-steal** | dive | A crow folds its wings, drops on an unsuspecting target and comes up with something pilfered |
| **Panic** | Backspace / L3+R3 | Force-restores control no matter what state anything is in |

**Crow vision** ✅ — the screen takes on its sight: a violet cast with boosted clarity and contrast.
Fully tunable or off.
**Ears at the bird** ✅ — you hear the world from the bird's position, not the Arisen's. *(This needed
solving at the engine level — the sound listener rides the camera but computes falloff at the body.)*
**The caw echo-ghost** ✅ — an invisible donor crow is spawned beside you to carry the sound, because
creature-bank sounds only ring from their own species.

**Ground scout** ⚠️ — critters scout on foot. A rabbit holds **B** to **burrow**, tunnelling underground
and leaving a trail of upturned earth and dust on the surface, then bursting out to ambush. A rat
dashes instead and can **pickpocket** — darting to its mark, rummaging, and slipping back with
something lifted. *(The rat is the professional thief; better odds than the crow.)*
*Built across several batches, the drive/burrow/mound layer is untested and the mound mesh path is a
diagnosed guess.*

## 1.9 Ritual music

- **In-game theme** 🔶 — a chosen battle theme plays for the length of a rite and stops when it ends. Off by default; only a handful of the game's music groups can be hijacked. A *"play anywhere"* switch frees it from the boss-arena distance limit.
- **Iris Ritual Music (custom score)** 🔶 — original music written for the taming rituals, playing over a muted vanilla soundtrack, moving between segments as the ritual progresses and tearing down cleanly on success, failure, death or reload. Ships as its own Wwise bank and **replaces nothing in the base game**. *(Stopping is done by segmenting — 17 crossfaded 4s segments — because no engine stop call is reachable.)*
  ⚠️ **Ship gate**: an unresolved `AK::WriteBytesCount` CTD was overridden to allow testing. If a crash appears, pull the music patch first.

---

# PART 2 — THE STABLE & BLOODLINES

## 2.1 The Stable Screen ✅

Press **O** (or hold the pad's View/Back for ~0.7s) and a full in-game panel opens over the world:
a gold-hairlined smoke-dark card titled **THE STABLE**, drawn with the mod's own serif face.
**It's a game screen, not a REFramework debug window** — navigated entirely with keyboard or pad,
and **the world pauses** while it's open.

- **Roster** ✅ — every bonded creature by name, with ♀/♂, its species in brackets, and an **[Out]** or **[Home]** tag. The one currently summoned is tinted green. The list scrolls to keep the cursor centred; the cursor wraps.
- **Detail pane** ✅ — name, sex, species, and a status line: *With You Now · Living At The Homestead · Selected — Not Summoned · Resting In The Stable*. Hatchlings and wyrm-grown creatures are labelled as such.
- **CONDITION** ✅ — a health bar that runs green → amber → red, with exact numbers.
- **Actions** ✅ — Summon/Dismiss (**Enter/A**), Rename (**R/X**), Send home or call back (**H/D-pad ►**), Release (**Delete/Y**). A control legend runs along the bottom and a result banner reports what happened.
- **Release uses the game's own Yes/No dialog** ✅ — *"Release ⟨name⟩ forever? The bond will be gone for good."* with *Release them* / *Keep them*. One press; the dialog carries the warning.
- **Released creatures stay in the world** ✅ — a creature released while out keeps its body and its size, becomes a friendly wild thing again, and wanders off: *"⟨name⟩ belongs to the world again. Farewell."*
- **Full controller support** ⚠️ and **pad presses don't leak into the game** ⚠️ — A no longer makes you jump, the D-pad no longer barks orders at your pawns.
- Every key rebindable via `IrisStableUI.json`; UI-scale slider 0.6–1.6×.

## 2.2 Bloodlines — the IV system ⚠️

Every creature carries **six inborn genes** — HP, ATK, DEF, SPD, **SIZE** and LUCK — each rolled 1–30,
Pokémon-style. Shown in the stable under **BLOODLINE** as colour-coded bars out of 30, so you can see
at a glance whether a tame rolled well. Genes are rolled once and never change.

- **Size described in words** ✅ — *A Wee Runt · On The Small Side · True To Its Kind · Larger Than Most · A Towering Specimen.*
- High attack makes its hits land harder; **high luck doubles farm produce**; the size gene visibly makes a creature runty or towering.
- **Wild Blood** ⚠️ — every wild animal of a tameable kind (rabbits, rats, bats, crows, chickens, wolves, big cats, griffins, drakes, chimeras, garm, pasture oxen) **quietly rolls its genes the first time you see it**, within 150m. You start noticing genuinely big and small individuals in the wild and can scout for a good one before you commit.
- **The one you scouted is the one you tamed** ⚠️ — carried rolls come with the creature into your stable. The unusually large griffin you picked out of the sky *stays* large. *(Carried rolls deliberately skip the luck blessing — "what you saw is what you tame.")*
- **Respects other systems** ✅ — the sweep leaves alone harnessed oxen, your active companion, dead bodies, and anything another mod has already resized (Bestiary/Apex variants, wild horses, wyrm-grown pets).
- 🔶 **Known gap**: horses and unicorns are excluded, because the wild-horses module re-asserts their scale at 60Hz — the gene has to be woven into that module instead.
- 📋 **Breeding** is designed (offspring inherit 3 random parent IVs and roll the rest; egg-layers lay eggs rather than gestate) but **not built**.

## 2.3 Customize — dyeing your companion ✅

Press **C** with a companion out and the camera swings round to frame it, the world freezes with no
menu banner or dim, and a carved-wood colour menu slides in on the **left third** so the creature
stays fully visible on the right.

- **Body parts found automatically** ✅ — All, Wings, Head, Body, Legs, Arms, Tail, Other, worked out from the creature's own mesh. Parts you've already coloured are starred with a swatch.
- **17 named presets** ✅ — Natural, Black, Grey, White, Brown, Tan, Rust, Red, Ember, Gold, Green, Teal, Blue, Indigo, Purple, Pink, Bone.
- **Advanced RGB sliders** ✅ up to 2.00 for colours brighter than any preset.
- **Live preview, orbit and zoom** ✅ — judge the colour on the real model from every angle.
- **Apply / Revert confirmation** ✅ and **colours saved per creature** ✅ — a dyed companion stays dyed across summons.
- **Portrait camera** ✅ — frames each species properly, from a rabbit under a metre to a griffin at 7.5m.

## 2.4 Companion care

- **Downed instead of dead** ✅ — at zero health she collapses into her own death animation with an on-screen rescue countdown (30s default). If you're riding her, she throws you off first. Each species uses its own verified collapse clip.
- **Revive** ✅ — hold **B/R** within 2.5m; the Arisen kneels and a hold-bar fills.
- **Timeout benches her, it doesn't kill her** ✅ — if you can't reach her in time the body is dismissed and she recovers in the stable. ⚠️ *This path previously **deleted** the companion permanently while printing a message promising a bench — it cost Aurora a horse. The fix is in but not marked field-verified.*
- **Drowning is permanent** 🔶 — a downed body in water gets a much shorter, far more serious fuse. Can be switched off. *The underlying water-detection API is an unverified guess that fails safe to "not water".*
- **Resting heals your whole roster** ✅ — an inn, home or completed camp rest heals *every* companion, not just the one standing next to you. Camp rest requires a real deployed camp plus a time jump, so benches and oxcart travel aren't free heals.
- **Benched companions heal themselves** ✅ — 1 HP/sec while dismissed, 10%/min while parked after a downing, computed from a timestamp rather than polled.
- **The companion damage model** ✅ — a native griffin body carries a boss stat sheet (~105,000 HP), so ordinary hits would never move the bar. Damage is re-scaled through a declared *effective* pool (7,000 for the griffin) while still subtracting from real HP, so the bar reads like a creature you can actually lose. The horse gets the opposite treatment — incoming damage scaled to 25%, because a cyclops hits for ~249 against a 250 HP horse and would one-shot her.

---

# PART 3 — MOUNTS & FLIGHT

## 3.1 The griffin — the flying mount ✅

Walk up on foot and pull **RT** within a few metres, or climb her and press **L3**. *Species profiles
gate this: pet-tier creatures (rabbits, birds, wolves) follow and fight but are never ridden.*

### Flight
| Action | Input | Notes |
|---|---|---|
| **Take off / land** | R3 | One button. On the ground she beats her wings and lifts; in the air she runs a real descent — landing start, descent loop, touchdown — instead of dropping like a stone. A second press mid-descent aborts and climbs out. Landing refuses with no floor below her. |
| **Ascend / descend** | RB / LB (hold) | |
| **Soar** | B (hold) | A faster sprint-glide with her wings locked out, easing in and out over ~1s rather than snapping. |
| **Directional soaring** ⚠️ | stick while soaring | She **banks into turns, tucks into a dive and noses up** as you steer. It reads as a bird flying rather than a model sliding through the air. |
| **Loop the Loop** ✅ | A / ✕ / Space | A genuine barrel loop — a real authored flight manoeuvre, not a scripted arc — and you *and your pawn* stay on her back through the whole thing. |
| **Jump** ✅ | Space (grounded) | Crouch, launch, wingbeat at the apex, land — including a longer fall loop off a ledge. |

**Ground clearance** ✅ keeps her from scraping terrain, standing down during dogfights, landings and
take-off so it can't fight those moves for control. **Edge guard** ✅ tests the floor ahead of each
ground step and refuses moves that would walk her off a drop. **Fall immunity** ✅ — a healthy winged
companion doesn't plummet from ordinary descents (direct hits and explosions still hurt fully).
**Dismount safety** ✅ — you can only step off near the ground.
⚠️ **No sliding backwards** — she has no reverse-walk animation, so she now turns instead of
moonwalking. *(08-08 polish batch, awaiting test.)*
🔶 **Open bug**: losing altitude after a Loop-the-Loop while soaring — reported 08-12, not yet investigated.

### Aerial combat
- **Dive Bomb** ✅ (**X/□**) — a committed vertical plunge: she folds, drops straight down until the ground is under her, slams with an area burst, and recovers into flight. Driven by the actual floor beneath her, so it always connects.
- **Dogfight pass** ✅ (**R2/Y**) — lock a flying enemy and rip a diving pass through it in full 3D, tracking its altitude rather than the ground, then climb out still airborne. Two styles: her native Gale dive, or the older beak-rush charge. Can also **pounce** grounded foes with a swooping dash-and-skid.
- **Lightning strike ring** ✅ (**LT**) — her real native levin magic: a ring of bolts drops on the locked enemy, each dealing heavy damage in a radius. Field-verified. Overlapping bolts never multiply damage on one target.
- **Aerial wing-thunder gale** ✅ (**H** airborne) — her real aerial gale attack with blowback and damage at the impact beat.
- **Wing gust** ✅ (**H** grounded, hold) — she winds up, holds a roaring wing blast, then releases, knocking everything in front of her backwards. Civilians and pawns are never flung.
- **Stomp and peck** ✅ (**J** grounded) — alternates a double talon stomp and a beak peck, staggering the target. *Deliberately kept small after full blowback read as "a massive hit away".*
- **Target lock marker** ✅ — paints itself over the enemy your next attack will home in on, in the air and on the ground. **She turns to face what you locked** ✅ at a natural turning rate rather than snapping.
- 🔶 **Live combat window** — for the duration of an attack her body is briefly woken so the move carries real movement and real hitboxes instead of playing on the spot. On by default, but this is an active, unfinished system — five systems have to release together and the last is documented unverified. Expect inconsistency.

### Predation
- **Snatch, carry, drop and throw** ✅ (**Y/△**) — fly over a creature and she catches it in her talons, hauls it to carry altitude and flies off with it dangling. Drop it (real fall damage, scaled to height) or throw it. Bosses and anything player-faction are excluded; very large creatures hang deeper so they don't clip her chest. Corpses can be grabbed too.
- **Landing to eat a kill** ✅ — land while carrying and she puts the body down in front of her and eats it, positioned at her beak (or between her talons for ox-sized prey). A bone pile is left where it lay.
- **Send her off to feed** ✅ — give the Eat order while dismounted and she flies to a nearby carcass and feeds under her own power, then returns.

### Riding
- **Three cameras on one key** ✅ (**V**) — the game's default view, an angled 3/4 chase camera, and **a true first-person view from her skull** with free-look, invert-Y and yaw/pitch limits.
- **Cinematic loop camera** ✅ — when she performs a manoeuvre the camera can break away and film it: a fixed sweep or a tracking shot, from a filming angle and distance you choose. Has a hard floor so it never films from below ground.
- **Renamed button prompts** ✅ — the game's own prompts are rewritten to say what they do while mounted: *Ascend, Descend, Loop the Loop, Grab, Dive Bomb, Soar*, with separate sets for grounded (*Take Off, Gale, Sprint, Charge*) and while carrying prey (*Drop, Throw*). Every label is editable.
- **Hand-drawn extra prompts** ⚠️ — the riding context hides some native prompts, so the mod draws its own B / R3 / L3 / LT / RB lines, lighting up white while you hold the button like the native UI.
- **Mount health bar** ✅ — top-left, in the game's own style, hidden during pause/map/photo mode. *(Top-left specifically so it never sits over your own HP or the map.)*
- **Flight audio** ✅ — a takeoff cry, a soar sound, a wingbeat loop timed to the flap interval, and a wind rush that rises while soaring.
- **Live hand IK grip** ✅ — the Arisen's hands are magnetised onto grip points on her scruff by a live two-bone IK solve, with a full set of additive limb trims (thigh, knee, ankle, arm, elbow, per axis, mirrored) applied after the pose write so the legs and arms sit around her body properly.
- **Your pawn rides along** ✅ — she runs over, leaps aboard behind you and rides with you, including through loops. She approaches from behind so she grabs the body rather than the head, arcs into a jump instead of teleporting, and her cling grunt is muted.
- **Fall shield** ✅ — while mounted, the *rider's* own fall damage is scaled to 15%, so riding off a big drop doesn't nearly kill you as well as the horse.
- **Climbing your own tame costs no stamina** ✅. **She stops being treated as a monster** ✅ — boss battle music stops, guards stop raising the alarm, and bystanders and pawns can't hold a grudge.
- 🔶 **"Capture your riding pose"** — the button exists and runs, but the whole rider-steadying arc it belongs to was **closed after twelve rounds**. Treat it as a dev-panel experiment, not a fix for mount pose. See ⛔ below.

## 3.2 The wild horse — the ground mount ✅

### The Horse Tame — a five-stage rite ✅
Wild horses flee on sight, so getting close is the game. Hold **N** within palm range (works to 9m,
targets the horse under your camera) and the rite runs **THE PALM → THE OFFERING → the rodeo →
THE PACT → naming**, each with a coloured card and a charge bar.

- **THE PALM** — hold **N** from between 2.5m and 9m; a 3-second charge fills. Step too close and a red **TOO CLOSE** card warns you before it shies. 1.2s of crowding aborts.
- **THE OFFERING** — drop Greenwarish, Morningtide or Syrupwort on the ground; it walks over, lowers its head and eats through a real eat-start/loop/end. The item is consumed. Carry no herbs and the card tells you which would do.
- **The rodeo** — a **grip-vs-break duel**. FRENZY phases throw real bucking and violent spins while you hold **LT/Space** to keep your grip; a rest phase lets it walk itself down while you *let go* to recover. Two bars show your grip draining and its spirit breaking. **Grip only recovers while released** — holding on through the breather recovers nothing. Break it and it stands blown; lose your grip and you are **THROWN** and it bolts.
- **THE PACT** — hold **N** within 4.5m of the broken horse, then christen the mare or stallion who chose you. A tamed unicorn keeps its unicorn identity in the stable record.
- Walk 14m away mid-rite and it bolts. You can bail out or abandon at any time and it's released, restored, and bolts as a failed tame should.
- Ritual music claims the shared taming mode and releases it by any exit route.

### Riding ✅
- **Mount** with **E/RT** beside her — a mount-up vault animation into a riding pose. 🔶 **You must mount from the SIDE**; nose and tail presses are refused (*"walk to her SIDE first"*) because they produced broken boarding animations.
- **Mirrored vault** ✅ — the animation flips to match the side you approach from, generated once against your real skeleton.
- **Three gaits** ✅ — Up arrow / left stick to ride, **Shift or B** to gallop, **Ctrl** or a light stick tilt to walk, Left/Right to steer. Easing in and out of speed rather than snapping.
- **Weighted steering** ✅ — a base turn rate, a steering lag so it feels heavy rather than instant, and a falloff so a flat gallop turns wider than a standstill.
- **Ballistic jump** ✅ (**Space/A** at a canter or better) — she gathers, pushes off and flies a real parabola: take-off clip, airborne loop, landing clip, landing thud. A ledge probe casts from the jump's own apex so the rise starts *before* a ledge face.
- **Real ground behaviour** ✅ — steps up small ledges (to 1m), glues to slopes going down, and genuinely falls off cliffs rather than parachuting.
- **Hoof kick** ⚠️ (**X/□**) — she plants, rears her weight back and fires both hind legs, **auto-aiming** by swinging her rear round to point at an enemy within 6m first. The impact casts a real native shockwave shell that damages and launches. *Damage and sound verified; the launch look and knockback were the top item on the NEXT list. Party members are shielded for 1.5s after each cast.*
- **Dedicated chase camera** ✅ — cures the native camera shake; distance, height, side offset, look-ahead, look-up, smoothing and inversion all tunable. Also fixed the occlusion fade and muffled audio.
- **Seat fit + CAPTURE** ✅ — ride until your seat looks exactly right, press CAPTURE, and every future mount reproduces it. Plus **leg trims** for the straddle, mirrored, live, cleared on dismount. *(This is the template Aurora cites for porting mounts onto other non-climbing creatures.)*
- **Dismount that puts you beside the horse** ✅ — at proper terrain height, not snapped back to where you first mounted, with a short damage grace and a 2.5s re-mount window so you can actually walk away.
- **Emergency dismount recovery** ✅ — go down over water or mid-air and you're put back at the last solid ground the ride passed over.
- **A boss grab takes priority** ✅ — an ogre or cyclops grabbing you mid-ride quietly releases the saddle so the grab plays properly.
- **Hit reactions** ✅, **horse voice** ✅ (snorts at take-off, thuds on landing, screams when it bucks you, whinnies at a blessing, alerts when it kicks), **mounted button prompts** ✅ (RT Dismount, X Kick, B Gallop, Y Blessing on a unicorn).
- **You cannot mount a downed horse** ✅. **Stranded-horse cleanup on load** ✅ — a script reload can't leave you on a phantom horse or leave horses permanently invincible.
- ⚠️ **Mounted combat** — the mount is kept mortal every tick while ridden, and you can opt in to being a valid target yourself so bosses actually engage. Default keeps the rider untargetable.

🔶 **Open**: a native "thief" action still steals roughly **2 in 6 mounts** (rider ends up on the ground
at head/tail). The seat *frame* was proven identical on first and remount, so the problem is on the
rider-pose side. Mount pose consistency is not solved.

## 3.3 The drake — the second flying mount ⚠️

Ride a drake with its own species-tuned takeoff, cruise flap, ascend/descend and landing.
**In flight you are seated on its back rather than clinging to it** (the v12 air-phase root seat,
field-proven to kill the knocking). v12b adds an anchor-height slider and a seat-owned chase camera
— built, awaiting test after residue of fade-to-black, camera shake and a walking-camera close-up.

**Known gaps**: a drake death mid-air releases the rider at altitude; specials-while-seated untested;
the LoopTheLoop / Gale / WindRush buttons still fire *griffin* nodes on a drake and T-pose her.
📋 Its own combat kit (bite, tail cleave, breath, hover attacks) is catalogued but **not wired**, and
hold-B soar plus the Furious-Charge ground gallop are the named next builds.

## 3.4 Planned mounts 📋
- **Wolf / panther / puma as mounts** — after the Wyrm's Rite only; otherwise a companion like the rabbit. The horse costume-rig, warp sync and camera bridge are creature-agnostic, so this is a port, not an invention.
- **Ox, Garm, Chimera, Lesser Dragon, Dragon** — the flying-mount profile minus flight. Ox native climb is already proven and the Lesser Dragon / Dragon atlases exist, so the clip work is near-free.
- **A proper animated dismount** — a "someday" item.

## 3.5 Companion orders & the whistle

- **Follow, Stay, Come, Attack, Eat** ✅ — each with its own assignable key. Ordering **Stay** mid-fight makes her disengage and stand down, purging the grudges the fight created so guards and pawns stop reacting to her.
- **The whistle** 🔶 (**G**) — she answers with a cinematic fly-in: she appears overhead, glides down and lands on a floor-tested spot, rather than teleporting.
  ⚠️ **Two live defects**: whistling a **non-flier** (rat, rabbit, ox) starts a cinematic descent from 12m overhead, because the whistle's call site isn't gated on flight capability; and when nothing is out, the whistle silently *mints a new body* rather than refusing. A proper whistle upgrade (gesture + randomised sound + calling an out companion) is 📋 designed.
- **Unleash** 🔶 — turn her loose and her native monster brain takes over: she flies, swoops and snatches prey by herself while your party stays protected. Off by default. **Hard ceiling**: her native AI engages beautifully but *will not fly across a gap to a lone ground target* — it fights in place.
- **Screech throttle** ✅ — a tamed griffin screeches constantly when idle, which gets maddening fast. This rate-limits her idle voice while leaving wings, footsteps and breathing untouched, and **suspends itself entirely while you're mounted** so flight sounds always play in full. Ships pre-configured; a LEARN mode histograms her sounds if you want different ones.

## 3.6 Multi-companion 🔶
Stage 0 (a `companions_live` registry that defuses the teardown crash) is shipped and verified.
Stage 1's premise was **disproved** — native navigation will not drive a tamed monster at all, so
following has to stay a driven stepper. Stage 2 (two puppet-driven bodies changing motion in the same
frame) is the untested make-or-break. **True simultaneous companions are not available yet.**
📋 Natural-looking following (obstacle steering, arrival easing, a follow slot beside you rather than
a straight line at your exact position) is the revised direction. *No water guard exists for driven
companions — named as the weakest link.*

---

# PART 4 — THE WILD WORLD

## 4.1 Wild horses ✅
A configurable share of the wild deer across Vermund and Battahl (**25% by default**) are quietly
replaced with full-sized horses — new body, new coat material, bigger frame. Real deer are untouched
and the decision is made once per body at spawn.

- **Real equine gaits** 🔶 — walk, trot and gallop with custom animation, mapped onto whatever the AI asks for. Running speed follows the animation, so the speed slider genuinely changes travel speed. ⛔ **Open crash suspect**: this and the jump/buck pack both register a custom motlist as a dynamic bank on a live converted horse, and the 08-08 crashes landed ~0.8s after exactly that. Both default **on**. Turning both off is the safe mode *and* the bisect.
- **38-event custom horse audio** ✅ — hoofbeats, snorts, nickers, neighs, pain and death cries. Every inherited deer sound is silenced so you never hear a bleat out of a horse, and real deer elsewhere keep all of theirs.
- **Gait-matched hoofbeats** ✅ — a four-beat walk, two-beat trot, three-beat gallop, timed off the animation itself, so a horse crossing in front of you sounds physically right.
- **Idle chatter** ✅ — snorts, nickers and neighs at random intervals, muted when dead, paused, or in photo mode.
- **Hurt and death reactions** ✅, driven by real HP changes; a corpse falls completely silent.
- **Horses are tough** ✅ — roughly 4× a normal animal's punishment (1000 effective HP vs 250), so chasing one down is a real pursuit rather than an accident.
- 🔶 **Grazing and ritual animations** (gather, horn thrust, a 362-frame graze) require the **Horse Ritual Pack**. **Jump and buck** ⚠️ require the **Horse Jump Pack**.

## 4.2 The Unicorn 🔶

A rare white unicorn among the wild horses — **5% of horses, so ~1.25% of deer spawns, at night by
default**. She's a true horse underneath, so she can be tamed, ridden and stabled like any other.
Field-confirmed in-game 08-11/08-12.

- ✅ **Glow, tuned in five parts** — a rim glow lighting her outline, a full-surface body glow, a separate horn-and-mane glow, and an eye glow ranging from natural brown to soft cyan. Changes repaint every live unicorn instantly. *(Body glow past ~0.4 washes the coat to a white silhouette; the panel warns in-line.)*
- ✅ **Iridescent shimmer** — the glow slowly cycles hues while her coat stays white, giving a living, opalescent look.
- ⚠️ **The horn and split mane** are a separate mesh behind an **off-by-default** flag (`unicorn_mesh_enabled`), because requesting a resource the engine can't serve is an *instant crash*, not a nil return. **Out of the box you get the glow, the recolour and the eye tint on a plain horse body.** The current build (v1.8, with real doe eyeballs transplanted) is awaiting a mod swap + restart.
- ⚠️ **Sparkle on the horn** — auto-bolts itself by measuring the live skeleton, tinted to match her glow. Still reported drifting on some elements.
- ⚠️ **Tougher than horses** — her own larger health pool (1000 default), with the bar rescaled to show it.
- ⚠️ **Unicorn bounty** — killing rather than taming one pays a real prize (10,000 EXP default). Re-routed 08-12, not re-tested.

### The Horn-Light Blessing ⚠️
Stand near your unicorn and hold the cast key — or press **Y/△ from the saddle** — and she lowers her
horn, gathers light, and thrusts it into the ground. A **healing circle** blooms where she strikes and
pulses healing into you, your pawns and any unicorn standing in it over several seconds (8s, a pulse
every half-second, 8% max HP each). Two-minute cooldown per unicorn. Pawn healing confirmed 08-12.
⚠️ The first ridden cast worked but crashed 11s later; the fix is in and untested.
🔶 The ring is currently a **hostile-red mage telegraph** and Aurora wants pink or green.

## 4.3 Puma and panther packs ✅
Wolf packs can turn out to be big cats instead — **33% of packs, of which half are panthers**. The
whole pack rolls together, so you meet a pack of cats rather than a mixed bag. Combat verified.
**Panthers are near-black** across body, head and fur with hot amber eyes that glow in the dark —
done live on each animal, no texture mod required.

⚠️ **21-clip custom cat vocals** (growl, alert snarl, attack roar, hurt, death, purr) with
context-aware picking — sprinting or wounded cats roar, moving cats snarl, idle cats growl — plus
ambient rumbling and purring so you often hear a big cat before you see it.
⛔ **Needs a field re-check before it's sold**: an earlier note records vocals verified 07-21, but the
*more recent* record says the suppression filter looks for `_vo` while every sound file is `_aud`, so
suppression never arms and **cats bark like wolves**. Two-line fix, unconfirmed either way.

⚠️ **Summoned wolves stay wolves** — a tamed wolf summoned from the stable is no longer caught by the
cat roll and arriving as a panther. *(Fixed after Shadow the wolf came back a panther.)*

## 4.4 The Pegasus 🔶
A winged horse on the griffin chassis. **v0.1 is in the game and animates** — a recognisable pegasus,
ridden at ~0.4 scale — but wears the griffin's textures through pegasus UVs, and the wing edges are
chewed by an alpha-to-coverage material bug. v0.2 (deformation fixes) collapsed in-game and v0.1 is
the known-good rollback. The module is a **dev harness behind a hard "Arm" gate** — nothing happens
automatically, and arming without the pak can crash the game. **Do not promise a finished pegasus.**

## 4.5 Monster guard ✅
Aggressive monsters are kept away from your homestead: any that would spawn inside a 120m ring around
a plot are born far away instead, and any that wander in are walked 300m off the property. Griffins,
wildlife and anything you've tamed are exempt — **your family is never touched.** Surveyed griffin
nests get their own 50m protection from non-griffin bosses.
*Deliberately relocates rather than deletes — destroying live monsters caused delayed crashes, and
blocking spawns hung loading screens. All guards stand down entirely during loading.*

---

# PART 5 — THE HOMESTEAD

## 5.1 Buy a plot ✅
**Seven hand-picked plots** stand empty across Vermund with a signpost at the door-front: South
Central Vermund Riverside, South Central Vermund Main Road, North East Vermund Crossroad, Borderland
Campground Gate, Melve Waterfall, North Central Vermund, and Arboreal Ruins.

Examine the sign, read the runes, and **a real Dragon's Dogma dialogue box** offers you the land for
**20,000 G**. Confirm twice and the deed is yours — the sign changes to a construction marker and your
gold is deducted for real. The signpost is a genuine in-world location sign, reading *"Land for Sale"*
and then *"Under Construction"*.

## 5.2 Build the house ✅
Buying doesn't hand you a house — it unlocks a **construction site**. Standing on your land, a two-bar
amber gauge tracks **Stone ×60 / Timber ×25**. A **stone quarry spawns just off the corner of your
plot** so you're not sent on a field trip. When both bars fill: *"Materials ready! Examine the sign."*

Confirm *Begin construction* and your Arisen **puts the tools down, winds up and hammers away while
the house rises around you**, with a *Raising the house* progress bar. When the last beam lands she
plays a finishing flourish and a green card reads *"Your house is complete!"* Controls are locked for
the scene and always restored, even if the scripts are reset mid-build.

- **Streams in and out as you travel** ✅ — walk within ~120m and the house appears; past ~175m it packs away. **Fast spawn** ✅ probes the ground and watches the world stop shifting, so it goes up the instant the terrain is genuinely settled (typically 5–9s) rather than on a fixed stopwatch. *(This exists because building during world streaming crashed the game.)*
- **Grass is cleared from under the house** ✅ and grows back if you sell up or unload the mod.
- **Ground reach** ✅ — after each build, pieces left hanging over a slope are quietly stretched down to meet the terrain, so the downhill side doesn't float. Roof planks meant to hover are left alone and the door is never touched.
- **Solid walls and a working door** ✅ — every piece gets its **real mesh collision**, so you walk on and around the actual shapes rather than invisible boxes. Seven door gimmicks to choose from, with yaw, slide, depth, height and swing limit sliders and a live "apply fit" button. The door snaps quietly shut once you've walked away.
- **Survives a script reset** ✅ — the mod finds an orphaned house and **re-adopts** its pieces, collision, hidden grass and door instead of building a duplicate through it.
- **Sell up** ✅ — one button tears the house down, **sells every furnishing back at half price with an itemised receipt**, refunds 10,000 G, and puts the plot back on the market with a fresh sign. The whole buy-build loop is repeatable.
- **Teleport to any plot** ✅, **plot state at a glance** ✅ (*FOR SALE · CONSTRUCTION: gathering · OWNED, not built · BUILT*), and everything **persists** ✅ in universal coordinates so it survives the game's shifting render origin.

## 5.3 The house catalogue

**Eleven building kits ship as blueprints**, each a real Dragon's Dogma building rebuilt piece by
piece and read from disk at load, so new kits appear without a code change.

| Kit | Status |
|---|---|
| **FARMHOUSE COMPLETE** (the plot default) | ✅ verified end-to-end |
| Vernworth farmhouse (12-piece original + 47-piece full capture) | ✅ |
| **Ox Stable** and **Hay Barn** | ✅ both built perfectly on their first in-game test (08-12) |
| Eini's home (shell + interior, ivy + door dressing) | 🔶 |
| **Field Shelter** | ⚠️ first build came out half-skeletal; root-caused (its west half is baked into a neighbouring map chunk) and regenerated 9→16 pieces, not yet eyeballed |
| **Eini's Home v2** (282 pieces) | ⚠️ generated 08-12, no test build |
| **Vernworth Mansion** (231 pieces, multi-storey) | ⚠️ generated 08-12, no test build |
| **Flamebearer Barracks / Conference Hall** (Battahl stone halls) | ⚠️ generated 08-12, no test build |

⚠️ Outbuildings and city kits are **panel-button builds only** — they're not yet in the player-facing
buy/gather/build flow, and **only one building may stand at a time**.
⛔ Don't run CURATE on the city kits — exclusions are global by mesh id and would break the farmhouse.
⛔ Battahl's carved-into-the-mountain homes proved uncapturable.

**📋 Multi-building homesteads** (barn + stable + house on one plot) — pick an outbuilding from a shop
menu, drive a wireframe footprint ghost into place, gather its materials, and raise it beside the
house. A full plan exists and survived an adversarial review (22 issues, 6 blockers folded in), but
**implementation has not started** — today's forge refuses a second building outright.

### Author tools ✅
**CHECK → SPAWN → SAVE** grades ground strictly (flatness, cliffs, scenery in the footprint), drops a
preview house to eyeball, and saves that exact transform as a named plot. **Nudge a standing house**
with X/Y/Z and rotation sliders. **Build a terrace pad** — a grid of stone floor tiles just above the
highest bump, so a house can anchor to a flat top on a hillside. **KIT DIFF / COMPOSITE GROUPS**
dumps every structural piece within 45m of any real building in the world with its world transform —
this is how the outbuildings and city kits were made. **CURATE** unticks the boulders, bridges and
stray tables from a kit.

## 5.4 Furnishing ✅

Press **Numpad ✱** within 35m of a built homestead and the world freezes into a **full-screen shop**
with every furnishing you can buy, your gold in the corner, and categories you page with LB/RB.
A hint whispers *"Press [Numpad ✱] to decorate"* on arrival, re-arming only once you've gone 25m away.

- **Live preview** ✅ — the highlighted piece appears in front of you a moment later, framed by the camera. You shop by looking at the real object.
- **Drive it into place** ✅ — press A to lock it in and the controls become the item's: move with stick/WASD, spin with LT/RT, tilt with hold-X + d-pad, scale with hold-X + triggers, raise with hold-Y. A again places it; B unlocks. *(Two-stage lock exists because pieces were easy to lose while browsing.)*
- **Buy with the game's own dialog** ✅ — *"Place the X here? N G"*. Gold leaves only on a confirmed place.
- **Forever** ✅ — position, rotation, tilt and scale are remembered against the plot and come back every visit.
- **Move a placed piece for free** ✅ from the PLACED list, and **sell one back for half** ✅.
- **Placement stays on your land** ✅ (25m from centre).
- **Precise editing** ✅ — yaw/pitch/roll, independent width/height/depth stretch, and X/Y/Z nudges, even on a currently-despawned piece.
- **Curate your own catalog** ✅ — hide, rename, reprice or re-file any row, and invent your own categories.
- **Furniture can't be broken** ✅ — crates, barrels and friends are made invincible on spawn. *(Born from "I just destroyed the windows I bought".)*

## 5.5 The weapon wall mount ✅
Buy a **Weapon Plaque** (1200 G) from the furnishing shop. Walk up with a weapon equipped and the
prompt reads **"B Mount"** — the weapon comes off your back and into the plaque's keeping. **It
genuinely leaves your inventory**, it isn't copied. Press again and it reads **"B Take"**: you get it
back with the game's normal acquisition popup, **still at +3 or wherever you had it**, and it
re-equips itself. Enhancement level and Dragonforging survive the round trip.

**Self-test** ✅ — one click grants a spare axe, upgrades it, round-trips it and cleans up, proving
store-and-return works in *your* save before you trust it with a real weapon.
⚠️ **Displaying the weapon on the plaque** — the mesh is captured off your body at the moment you
mount it, so the rack shows your actual sword. Position/angle/size are tunable and remembered. Code is
present, not recorded as field-verified; a weapon you've never equipped may mount with no display.

## 5.6 Home life
- **Sit in any chair — the game's own prompt** ✅ — walk up to a chair, stool or tavern bench and DD2 itself offers *"B Sit"*, with a real *"A Get Up"*. Works on furniture you placed **and on vanilla furniture out in the world**, verified game-wide on tavern stools. Every seat-shaped thing within 12m gets one (up to 8 at once), so a furnished room is sittable everywhere and your pawn can use a chair you're nowhere near.
  *(This works by hiding a real, meshless seat gimmick inside the chair so the game owns the whole interaction. See the note about which file it lives in, below.)*
- **Real cooking animation** ✅ at the pot — the game's genuine stir start/loop/finish, timed so a cancelled recipe never plays it.
- **Panic release** ✅ — **F8** instantly detaches you from any pose and hands your controls back, even if the feature is off and even if the mod has lost track of what you're stuck in. Runs on its own always-on tick precisely so it works when everything else is disabled.
- **Poses always let go** ✅ — release on movement, on a second press, at a hard 25-second deadline, and on script reset. The timer can never be conditional. *(Written after being trapped in a chair with no exit.)*
- **Dangerous objects are never offered** ✅ — Godsbane doors, ordinary doors and locks, oxcarts and ballistae are excluded by name.
- ⛔ **The furniture "jack" interaction path** (sit/lie/ring/lean in your own placed furniture) is **off by default and labelled experimental** — after ~8 rounds of fixes it still froze the player out of their own character, once costing a save reload. The native-seat route replaced it and works.

## 5.7 Your pawn at home ⚠️

At the homestead your pawn stops trailing you and **goes about her own business**: she walks to a
chair and sits in it, waters your crop beds, stirs the cooking pot, and wanders to a bed. She picks
whatever you have actually built rather than following a fixed script.
**Off by default**, because it drives your pawn. She only idles within 45m of a saved plot, and
*"To Me!"* always overrides.

- ⚠️ **Pawn watering actually counts** — the day is stamped, the soil goes dark and it saves, exactly as if you'd done it. Uses the game's real watering-can animation and ends when the animation ends, not on a timer.
- ⚠️ **Pawn sits in your chairs** — using the same hidden seat that makes chairs sittable for you. *(A waiting pawn will never do this on her own — DD2's idle AI only runs while following, which is the entire reason this module exists.)*
- ⚠️ **Teach her the way around the house** — walk the route yourself, press *add a point* at each corner, and she'll follow that chain into the middle of the homestead. **Stored relative to the house, so the same route works at every plot you ever build.**
- ✅ **Tune what she does** — per-activity frequency weights (set one to zero to switch it off), dwell times, pose hold, repeat penalty. **Stop** means stop — it thaws her immediately, switches idling off and hands her back.
- 📋 **Lying on a bed** — the animation id is deliberately left blank rather than guessed, so for now she stands at the bed.

### IRIS Walk — the mod's own pawn walker ✅
Deliberately standalone so I.R.I.S. never requires the author's other AI mod.
- **She walks, she doesn't run** ✅ — a stroll across your camp, not a sprint, however far the target.
- **Obstacle steering** ✅ — physics probes feel ahead and steer around walls, furniture and **houses you built at runtime, which the game's own navigation data has never heard of**. Cliffs are refused outright.
- **Through the door** ✅ — when start and destination are on opposite sides of a wall, the route is planned via the doorway. Forged doors count as passable even when shut.
- **Stay mode** ✅ — she holds her ground so she can actually use chairs and props. By default she's told *nothing at all* (the follow target is simply dropped) because every pawn order is an audible bark.
- **Your orders always win** ✅ — any native command (To Me, Go, Help, Wait) makes I.R.I.S. back off for 90 seconds rather than argue with you.
- ⛔ Cross-map A* over the game's baked road network is built but **switched off** — the graph knows nothing about runtime-built homesteads, so its routes run straight through your walls.

---

# PART 6 — FARMING

## 6.1 The garden ✅
- **Till a bed with the hoe** ✅ — equip the I.R.I.S. Hoe and swing. Turned soil appears a step ahead, grass and weeds are cleared, and that soil is a permanent bed. Swinging at an empty bed levels it back over. A **green/amber/red ground ring** previews exactly what the swing will do. Refused indoors or under a roof (detected by casting upward, so it covers every interior). Within 30m of a built plot.
- **The tend button** ✅ — one context key (**E** / **B**) does whatever the spot needs: sow an empty bed, water a thirsty one, pick a ripe one, cook at your pot, milk a cow. A floating label names the one action available, exactly like the game's own prompts. **You must be facing it**, so a cookpot beside a bed no longer steals the press.
- **Sow from a native-looking menu** ✅ — the game's own dialog box: pick a category (Herbs, Fruit, Flowers, Vegetables), then the seed, with your count beside each name. Only seeds you own are offered; if you own one kind, the category step is skipped.
- **21 plantable crops** ✅ — Harspud, Greenwarish, Pitywort, Morningtide, Goldthistle, Syrupwort Leaf; apples, grapes, quince, figs, cranberries, raspberries, blueberries, strawberries; Sunbloom, Noonbloom, Moonglow, Grandpetal; and three custom vegetables — **potato, pepper and carrot**. Each has its own seed item and its own ripening time (2–5 watered days).
- **Water once per in-game day** ✅ — your character sheathes her weapon and plays a full watering animation (**she brings her own can**), and the soil visibly darkens partway through the pour. Water again the same day and it just tells you it's done.
- **Growth in in-game days, not a stopwatch** ✅ — sleeping, resting or camping moves your farm forward. A day only counts if the bed was watered during it.
- **Drought, wilting and death** ✅ — miss a day and nothing grows; the plant visibly droops and shrinks. Two dry days running and it's wilting, four and it **dies outright**, returning the bed to bare soil.
- **Harvest grade depends on how you tended it** ✅ — water every single day and you get the **RIPENED** fruit, two or three of them (four for a herb or flower). Miss a day and you get the plain item in smaller numbers. Let it wilt and you get a **ROTTEN** one, or a single poor pick.
- **The game's own gather prompt works too** ✅ — walk up to a ripe plant and use the ordinary prompt any bush shows. It plays the normal picking animation but pays your farm's *graded* harvest. You can't double-dip, and **an immature plant simply has no prompt** — no shortcutting the farm by picking a day-one sprout.
- **Crops grow visibly** ✅ — a small green seedling, then growth, and only near ripeness does the real plant appear and swell, so a two-day-old apple bed never looks like a finished tree.
- **Custom soil-bed mesh** ✅ — a purpose-made patch of turned earth shipped with the mod, not a borrowed prop. It probes the ground at four corners and **tilts to lie along the slope** instead of floating at one end and burying the other.
- **Beds snap into neat rows** ✅ — till near an existing bed and the new one inherits its angle, grid, height and manual lift, so patches butt into a continuous row. Get the first bed right and the whole row follows.
- **Rain waters the whole farm for free** ✅ — stand at your plot while it's raining and every bed drinks.
- **Uproot** ✅ behind a yes/no confirm. **Pawns picking your crops is optional** ✅.
- **Seeds from your own crops** ✅ — combining two of a harvested crop yields two of its seed through the game's normal crafting menu, so a farm sustains itself. (12 recipes.)

## 6.2 Animals and cooking
- 🔶 **Milk your cows and collect eggs** — walk up to an ox-cow or a chicken and a prompt offers **Milk** or **Collect egg**. Your character plays the chore animation, the animal holds still and calls out, and you get milk or an egg. Once per animal per in-game day; after that the label reads *"Milked today"* in quiet grey. **Bulls and roosters are deliberately excluded.** Works away from a plot too — the cow is the requirement, not the address. *(The egg chain fired in the field; the animal hold, its vocal call and the ox standing up to be milked are built but untested.)*
- 🔶 **Cook at your homestead cookpot** — press tend at a placed Cooking pot and a recipe menu opens showing what you can make and what you're missing. Your character stirs, and the dish appears in your pack. Ships **three custom dishes** — Vegetable Stew (pepper + carrot + potato), Berry Tart (2 blueberries + egg) and Omelette (2 eggs + milk) — plus the three standard meat conversions. *Menu confirmed working; the stirring animation is a stand-in (driving the pot's own animation crashed the game); berry tart and omelette were awaiting verification.*

## 6.3 Land tools
- **Plot name banner** ✅ — walking into one of your plots fades a name banner up in the corner and out again, exactly like the game announcing a region. Re-arms when you leave, so it greets you rather than nags.
- **Your plots on the world map** ✅ — amber house markers with the plot's name as the label.
- **Plot surveyor** ✅ — press SURVEY anywhere and it probes a 14m grid under your feet and tells you plainly whether the spot is **GOOD / SLOPED / EDGE / ROOFED**. Mark candidates, list them with distances, warp to one, or dismiss it. Candidates show as green markers on the big map.
- **Prospector** ✅ — switch it on and the mod quietly samples ground as you travel, marking flat, roofless, empty patches far from your existing plots. It sweeps a wide fan and uses a long downward cast, **so a lap on the griffin collects a whole corridor of candidates.**
- ⚠️ **Wake-drift guard** — sleeping in a homestead bed used to hand you to the game's own wake spot, sometimes a region away. Now you wake at your own bedside with the time correctly advanced.
- **Everything persists** ✅ — every bed's position, angle, crop, days grown, watering state and height nudge, plus your seed bag and which animals you've collected from today.

---

# PART 7 — WOODCUTTING & MINING ✅

*Described in the notes as feature-complete and verified.*

- **The Woodcutter's Axe and the Pickaxe** ✅ — genuine equippable two-handed weapon items you buy from a shop. Nothing vanilla is replaced; their look is applied at runtime by borrowing the game's own tool meshes. The pickaxe is **deliberately weak in combat** so it reads as a tool.
- **Chop the game's destructible trees** ✅ — the tree takes damage, shakes, and finally falls with the game's own break effect and crash sound, paying **Timber**.
- **WILD TREES — the whole forest is choppable** ✅ — ordinary scenery trees, not just special ones. Three chops and the tree vanishes in a burst of debris. **Felled scenery regrows** after ~10 minutes so the forest isn't permanently clear-cut.
- **WILD ROCKS — rocky scenery is a minable vein** ✅ — four strikes on a boulder or cliff face pays **Stone**, and the rock stays where it is. **You're working a vein, not smashing a piñata** — a worked vein is spent for 6m for ~10 minutes, so a stack of boulders can't be farmed forever from one spot.
- **Stone and Timber as real inventory items** ✅ with their own painted icons. These are the currency for homestead building.
- **A real woodcutter's chop** ✅ — not a warrior's vertical ground slam but a proper horizontal swing, cycling three animations so repeated chopping doesn't look identical, ending cleanly into idle. The pickaxe uses the game's overhead slam as its mining stroke.
- **Both attack buttons do the work swing** ✅ — you don't have to remember which one chops.
- **A tool is not a weapon** ✅ — combat skills are locked out while a tool is in hand, running attacks are blocked (*"moving attack blocked — stand still to swing"*), and **the swing stays planted** so your feet don't drag you off target.
- **Auto-gather bow** ✅ — on a break, your character plays the game's pick-up-and-gather animation and the materials land in your hands during it rather than silently appearing.
- **Chop effects and sounds** ✅ — chips and dust at the contact point, separate for wood and stone, with a real chopping sound and the game's tree-crash noise even out in scenery forest.
- **Per-tool hold tuner** ✅ — rotation, hand offset and size sliders per tool, saved across sessions.
- ⚠️ **Homestead quarry** — buying/building the plot plants a cluster of real minable rocks beside your homestead, renewing with the next in-game day. *(Quarry v2 built, not signed off.)*
- 🔶 **Rock Sense** — minable veins within 45m wear a grey *"Minable Stone"* label. **Off by default**: on big composite outcrops the marker floats over the rock's average centre, sometimes metres off the mass or out over water.
- **Timber and stone in the Wayfarer's Sense** ✅.

### Author tools ✅
A **breakable census** (60m sweep listing every breakable object and flagging unrecognised classes, for
discovering new tree/rock types in a new region), a **tree aim probe**, a **weapon ID probe**, a
**tool mesh auditioner** stepping through 53 held-tool prefabs with a label book, a **sound sniffer**
(arm for 10s, whack a barrel, get every sound the game fired with replay buttons and *set as chop /
set as fell*), a **chip effect lab**, an **icon lab**, and **give-tool buttons**.

---

# PART 8 — INTERFACE & INFRASTRUCTURE

## 8.1 The prompt bar ✅
**The game's own on-screen button hints say what I.R.I.S. will do.** Instead of *"B Dash"* you read
*"B Cook"* at the cook pot, *"B Sow" / "B Water" / "B Harvest"* at a farm plot, *"B Take" / "B Mount"*
at the weapon plaque. **It looks like part of the game, not like a mod overlay.**

- **Only one action fires, and it's the nearest** ✅ — if a cook pot, a bed and a plaque sit close together, only the closest is offered and only that one fires. Modules must *ask who won* before acting.
- **I.R.I.S. steps aside for the game's own prompt** ✅ — if DD2 is offering its own interact (a chair, a chest, an NPC), every I.R.I.S. action stands down completely.
- ⚠️ **Native world prompt frame** — the prompt can also be drawn as the game's real world-space interaction button, floating over the object it belongs to.
- 🔶 **Constraint worth knowing**: the mod can only relabel a button the game is *already* offering. Where DD2 withholds B, no label appears and the mod's own floating world label is the fallback — the native one **cannot be forced back**.

## 8.2 The font system ✅
**One shared serif face for the whole mod** — ritual cards, the Grip/Break gauges, creature HUD,
names and world markers, the customize screen, woodcutting labels, the homestead loading line.
*Deliberate scope law: REFramework config panels keep the plain imgui look, so a REF panel still reads
as a REF panel.*

- **Pick your own face** ✅ — a dropdown switches live between an auto ladder and eight named faces, no restart.
- **Text size slider + automatic resolution scaling** ✅ — authored for 1080p and scaled up on 1440p/4K, plus a manual 0.6×–2.0× multiplier.
- **Drop shadow** ✅ so labels stay readable over bright terrain, snow and sky.
- **The ritual card banner** ✅ — an antique-gold hairline over smoky leather, title in a meaning-carrying colour (**amber = act now, green = good, red = danger**) with a parchment subtitle, fading in over a quarter second. Width tracks the text, clamped between 22% and 78% of screen width.
- **Live 3-second preview** ✅ to A/B a face on the real surfaces without starting a tame.
- **Graceful degradation** ✅ — without the d2d plugin, text still appears, just in the plain built-in face rather than vanishing.
- **Per-surface override** ✅ — the griffin's fake button prompts wear the face closest to DD2's own menu font so they blend with the real UI.

## 8.3 The input gate ✅
`000IrisInputGate.lua` loads first so it exists before any hotkey module. Every I.R.I.S. hotkey reads
through it, so typing anywhere — a REFramework text box, a RiftSpeak chat prompt, or an in-world
naming card — **stands every mod hotkey down at once**. Typing a creature name can't summon a griffin.

- Deliberate exceptions read the keyboard ungated so rebinding remains possible, and an abandoned rebind can never deadlock hotkeys for the session.
- A one-line console escape hatch (`_G.IrisInputGateOff = true`) disables the gate if it ever blocks something it shouldn't.
- ⚠️ The gate itself is recorded as awaiting in-game test, though later modules already depend on it. *(Three I.R.I.S. files shipped a misspelled flag, which meant the typing guard had literally never fired once until it was found.)*

## 8.4 Minimap markers ⚠️
Homestead plots show on the round minimap, with the game's house glyph for owned plots and a custom
plot-sign icon for those still for sale. **I.R.I.S. markers only take slots the game left unused**,
are capped at eight, shown nearest-first, and handed back clean before the game's own refresh — so
vanilla markers always win and yours simply drop off in a busy area.
*Explicitly written as a dormant, isolated implementation "until it has survived streaming" — an
earlier minimap attempt was rolled back after a crash.*

## 8.5 Crash guards ✅
Airbags on native code paths for which the project holds **actual crash dumps**. Guard 1 catches the
ogre victim-selection access violation (an ogre picking its next victim by gender reads a character
that no longer exists) — with the guard it just picks someone else and you never notice. A panel line
reports how many crashes the airbag has actually absorbed this session.
⛔ **Standing law: airbags are main-thread only.** A second airbag for the AI decision evaluator was
built, armed, and **killed the process outright** ~10s after mount — no exception, no dump — because
that method runs on a worker thread. Removed permanently.

## 8.6 The dev tier ✅
Five R&D instruments, deliberately **split out of the install set**: a per-script CPU profiler
(`!IrisPerfProbe`, loading as script #1 so it can wrap every later callback), a flight recorder black
box that snapshots what the mod was doing every second and archives it after a CTD, a pawn observer
that watches what the game itself does to pawns so the walker can crib it, and a damage tape that
captures real hit parameters off the player (the source of the horse kick's blow values).

---

# PART 9 — REQUIREMENTS, DEPENDENCIES & LIMITATIONS

**These belong in your writeup — they're the things a player will hit and blame the mod for.**

### Hard requirements
| Requirement | Why |
|---|---|
| **REFramework** for DD2 | The whole mod is Lua scripts |
| **reframework-d2d plugin** | Every styled surface (ritual cards, gauges, Stable Screen, Customize, mount HP bar, world markers). Without it the mod still runs — text falls back to the engine's plain bitmap face |
| **EnemySpawner** (another author's mod) | **The only genuine code dependency.** It is the spawn path for taming quarry, hunt deer, summoned companions, homestead residents and every test spawn. It degrades honestly (*"critter spawn failed: EnemySpawner unavailable"*) rather than crashing, but every summon-shaped feature is dead without it |
| **The IRIS asset pak** via Fluffy Mod Manager | 61 MB, ~92–96 files. Meshes, textures, motion lists, Wwise banks and icons |
| **Content Editor bundles** | The custom items: Stone, Timber, Woodaxe, Pickaxe, Hoe, seeds, vegetables, milk, egg, dishes, and the 12 seed recipes |
| **A font file** in `reframework/fonts/` | The default face is a bundled `.ttf` |

### Optional packs
- **IRIS Horse Jump Pack** — gallop-jump, landing recovery and buck. Without it, those moves silently do nothing.
- **IRIS Horse Ritual Pack** — the gather, horn thrust and long graze used by the unicorn ritual.
- **IRIS Unicorn pak** — the horn and split mane. Without it, the unicorn is coat-and-glow only.
- **IRIS Pegasus pak** — dev harness only.

### ⚠️ Limitations to state plainly
1. **There is no per-save-slot storage.** One install = **one stable, one farm, one set of homesteads**, shared across every save file and every character. Two playthroughs will see each other's animals and gardens. This is a hard engine limitation, not an oversight — no reliable per-slot store exists.
2. **No localisation.** Every player-facing string is a hardcoded English literal, and card text must be **ASCII only** because d2d silently substitutes on non-ASCII glyphs.
3. **NG+ is not really handled.** Three guards exist for a rewound clock (farming day stamps, egg incubation timestamps, a rebuilt-world watch), but the stable, farm and homesteads simply persist across an NG+ transition unchanged.
4. **A missing asset pak is a crash, not a warning.** Requesting a resource the engine can't serve is an *instant CTD*. This is why every custom-asset feature (the unicorn horn, the pegasus) is behind an off-by-default flag you only tick once the pak is confirmed installed.
5. **Fluffy renumbers the whole patch chain** whenever any mod is toggled, and the engine resolves duplicate paths by highest patch number — so **which build of an asset wins is decided by unrelated mods.** Paks must be identified by hash.
6. **Performance**: DD2 is hard CPU-bound. Mod Lua is roughly 4.5–8 ms of a 24–47 ms frame; with native→Lua transition cost and GC, mods own about **25–35% of the frame**. I.R.I.S. mitigates with throttled ticks, distance culls (residents 90m/130m, furniture 120m/175m, houses 120m/175m), staggered arming and pause/photo gates.
7. **Uninstalling**: removing the Lua files leaves a clean game — script-reset handlers restore grass, collision, invincibility flags and rider state. **Removing the pak while the Lua still runs is the dangerous direction.**
8. **The bundled font's licence** needs clearing before any public release. The always-safe fallback is LinLibertine (OFL). One face in the ladder is a Windows system font and will be missing on Proton/Steam Deck.

### Compatibility posture ✅
**Depend, or reimplement — never patch.** Techniques are read from other mods and rewritten inline
rather than depended on (the griffin's shell/damage kit is proven by Bestiary's Griffin moveset but
reimplemented; the camera-controller trick was learned from Puppeteer and rewritten; Nick's gimmick
and sound recipes are copied, never called).
Positive interop guards exist too: Wild Blood skips any body already resized by another mod so
**Bestiary/Apex variants are never re-sized**, and the wild-cats module *adopts* the older
randomiser's shared state key so the two never double-hook.

---

# PART 10 — ⛔ CLOSED ROUTES — DO NOT PROMISE

Listed so they're never re-litigated, and so nothing here ends up in a feature list by accident.

| Route | Verdict |
|---|---|
| **A fixed griffin seat / rider steadying** | Closed by Aurora after **twelve rounds in one day**. Every config key is forced false at load. The shipped ride is the plain native climb. There were always two problems and freezing the pose only addressed one — the native climb's *attach solver* drags a rigid body. **Don't offer "one more idea".** |
| **Drake held travel nodes for flight** | Retired 08-12. Held travel nodes flicker the player's climb state natively and nothing can intercept it — getter pin, setter veto and camera veto all failed. Replaced by nodeless flight. |
| **Launching enemies with synthetic damage** | Walled and re-proven twice. Synthetic DamageInfo cannot launch, and capture-and-replay of a real launch packet is **permanently closed** — the engine re-validates against live collision and applies nothing. Only working recipes: a hybrid ragdoll+ballistic-arc blowback, or casting a real native shell. |
| **Shipping a modified character prefab** | Character prefabs **cannot be shipped modified at all** in DD2 — not at new identities (never ready / CTD), not as overrides (a byte-identical override silently kills all doe spawns). |
| **Climbable horses** (prefab swap, runtime graft, ox chassis) | All three dead. The costume rig replaced them. The ox-chassis rebuild worked technically but was frozen on Aurora's call — its ceiling was "doe motion wearing a horse suit". |
| **Lying down on a bed** | The bed's Sleep state is not a legal entry point; calling it is a hard CTD. Beds already carry the game's own Sleep prompt, so the mod stands off. |
| **Cooking at world/house cookpots** | Settled with clean evidence: the gate is **camp context**, not emptiness. The pot takes the meat and its own enable check still says no. |
| **A 9th camp dish** | Proven impossible by disassembly — the menu is 8 hardcoded item ids unrolled in the exe. *(Correcting a common premise: camp cooking produces no item; it deletes the meat and grants a party buff.)* |
| **Caw aggro** (making an enemy attack the puppeted bird) | No hate write of any kind works — it fails enemy target validation. Tried across five escalating designs including real damage. |
| **Native navigation driving a tamed monster** | Disproved with measurements. Following must stay a driven stepper. |
| **Spline-extruded walls and fences** | Forged spline prefabs never rendered and crashed the game on approach. The same shapes are now built from ordinary pieces. |
| **Resizing a placed building** | Render meshes scale; the grafted collision doesn't follow, so a resized building would be walk-through. |
| **Air press** (airborne wing slam) | Retired as a clip-replay dead end; the aerial gale replaced it. |
| **Target health bar over the enemy** | Retired 08-06 — *"I don't really like it anymore."* Still switchable on. |
| **Relabelling the on-foot HUD while a tool is in hand** | Disabled after crashing three times. The prompt panel rebuilds exactly when tools hit something. Only a rewrite hooking the HUD's own update could revive it. |
| **Deleting a downed companion** | A hazard, not a feature — `delete_griffin` erases the soul, and it once killed a companion on a downed timeout. Any release/delete UI must sit behind a permanent-action confirmation. |

---

# PART 11 — ROADMAP 📋

**Near-term / designed with dependencies proven**
- **Breeding** — offspring inherit 3 random parent IVs and roll the rest; egg-layers lay eggs rather than gestate. The exact line it replaces is identified.
- **The whistle upgrade** — call a companion that's already out, with a proper gesture and a randomised whistle sound. Fixes the non-flier bug. The gesture and the donor-body sound trick already exist in the bird rite and just need porting.
- **MARK phase 2** — your pawns hunt the enemy the bird marked from the air. The marker ships; the pawn focus recipe is proven elsewhere.
- **Pet dog commands on tamed wolves** — sit, lie, observe, follow. The native command controller is already in use.
- **Petting and feeding animations.**
- **Editing what the 8 camp dishes do** — described as a five-minute win; Content Editor already ships the parameter editor, staged but not installed.
- **Custom food items with real buffs** — fully supported today, nothing built.

**Bigger arcs**
- **Multi-building homesteads** — the BUILD menu, footprint ghost and per-building gather stage. Plan reviewed, blockers folded in, needs a multi-building forge refactor first.
- **The griffin truce tame.**
- **Per-species critter abilities** — a locked design roster: rat pickpockets, spider venom bite, pig converts rotten food into rare ingredients, goat carries a stash and climbs cliffs, boar charges and tumbles, hen lays an egg each rest, rooster crows when hostiles approach, doe calms nearby wildlife so it won't flee, stag as a fast fragile light mount. Only the bird scout and rabbit burrow have code.
- **Wolf / panther / puma mounts** after the Wyrm's Rite; then ox, garm, chimera, dragons.
- **Stable screen redesign** — per-creature summon/dismiss toggles and an orders row. Blocked on the multi-companion architecture.
- **One unified I.R.I.S. player window** — Stable, Companion, Taming, Eggs & Nests and Settings tabs, with probes and tuning sliders hidden behind a developer-mode toggle. Architecture agreed (`_G.IrisUI` section registry), not built. Aurora's stated intent: *"all this other UI should be gone eventually."*
- **I.R.I.S. in the game's own Options menu** — a custom "Mods" tab is proven as a route, but **nothing is wired into any live I.R.I.S. file yet**; the next step is a registry API.
- **Slim-down refactor** — cutting the 36,000-line ride file to shipping-only features and splitting it into modules. A −7,323-line cut landed but is unverified; flight/flap code has already moved to `IrisGriffin/*.lua`.

---

# APPENDIX A — Control reference

### Taming & companions
| Key | Action |
|---|---|
| **N** (hold) | The hand — arm a courtship, hold the palm out, seal the pact, start the Yoke Rite, cling during the griffin rodeo |
| **H** | Howl back at a wolf; whistle a courted bird to your arm; wing gust while mounted |
| **K** | Wayfarer's Sense |
| **E / RT** | Grab and carry a beaten creature or a pet; the Wyrm's Rite prompt at a camp; the farm tend button; mount a horse |
| **L3** | Shoulder-perch a critter / set it down; mount or dismount a griffin |
| **J / R3** | Launch or recall your scout |
| **P / C / F** | Scout ping / caw / collect |
| **Backspace** or **L3+R3** | Scout panic — always returns control |
| **Enter / Esc** | Seal or cancel a naming card |

### Riding the griffin
| Key | Action |
|---|---|
| **RT** | Mount from the ground · **L3** dismount |
| **R3** | Take off / land |
| **RB / LB** | Ascend / descend · **B** soar |
| **A / Space** | Loop the Loop (airborne) · jump (grounded) |
| **X / G** | Dive Bomb · **Y / R2** dogfight pass |
| **LT** | Lightning ring · **H** gale · **J** stomp & peck |
| **Y / T** | Grab prey |
| **V** | Cycle camera · **C** Customize · **G** whistle |

### Riding the horse
**↑ / left stick** ride · **Shift / B** gallop · **Ctrl** walk · **← →** steer · **Space / A** jump ·
**X / □** hoof kick · **Y / △** unicorn blessing · **LT / Space** grip during the rodeo · **RT / E** dismount

### Screens
**O** Stable Screen (or hold pad View) · **C** Customize · **Numpad ✱** furnishing shop ·
**F8** panic release from any pose

---

# APPENDIX B — What ships in the asset paks

| Pak | Contents |
|---|---|
| `IRIS_00_griffin_egg` | Griffin egg + nest bowl meshes, four broken-shell variants, ALBD/NRRA texture pairs |
| `IRIS_01_wild_horses` | Horse mesh + material on the doe chassis, body textures, `horse_locomotion.motlist` (the field-proven walk/trot/gallop), **2 Wwise banks + 9 sound resource files** (38 horse sounds) |
| `IRIS_02_wild_cats` | Puma/panther mesh on the redwolf chassis, 7 textures (body, pattern mask, eye, fur), **2 Wwise banks + 6 sound resource files** (21 cat vocals) |
| `IRIS_04_woodcutting` | Four painted inventory icons (pickaxe, woodaxe, stone, timber), two tool models, two weapon prefabs |
| `IRIS_05_ritual_music` | The custom taming score — 2 Wwise banks + 5 sound resource files |
| `IRIS_06_farmland` | The tilled soil bed mesh + material + texture |
| `IRIS_07_wallrack` | The weapon wall plaque mesh + textures |
| `IRIS_08_unicorn` | Unicorn mesh (body/horn/mane submeshes, 5-material table) + body texture |
| `IRIS_09_pegasus` | Pegasus mesh only — **no material, no textures** (hence the colour scrambling) |
| Horse Jump Pack | Gallop-jump, landing recovery, buck motlist |
| Horse Ritual Pack | Head-lower gather, horn thrust, long graze motlist |

Plus **~100 house-piece prefabs generated at runtime** by the one-time FORGE PREFABS press, and
**90 imported pose/animation JSONs** in `reframework/data/Animations/` (the falconry arm, the whistle
gesture, the mirrored mount-up vault, the alternative mining swing, riding poses, petting).

---

# APPENDIX C — Things worth fixing before a public release

Found while compiling this. None of these are features; they're distribution gaps.

1. **`Interactables.lua` (58 KB) and `InteractButton.lua` (176 KB) have never been committed.** `sync_from_live.ps1` copies only `*Iris*.lua` and `Griffin*.lua`, and neither filename matches. Several features credited above — *sit in any chair*, the jack path, ringing bells, the furniture inspector, *dangerous objects are never offered* — live in those two files. **A fresh install from the repo would not have them.**
2. **11 of 15 custom item icons are loose files, not in any pak** — carrot, pepper, potato, seedbag, hoe, milk, egg, berrytart, omelette, vegstew and the plot-sign. Only pickaxe, woodaxe, stone and timber ship. Same for the working front door prefab (`sm51_439_01_door.pfb`) and the third tool weapon prefab. They work on your machine by accident of loose loading, which the pak builder itself flags as a hazard.
3. **The furnishing shop's catalog isn't tracked** — `furnish_catalog_draft.json` (66 KB) and `furnish_paths.json` (43 KB) aren't in the repo, so **the shop would open empty on a clean install.**
4. **Runtime data files aren't in the install set** — the 26 creature clip atlases (tracked only under a non-install path, and two are missing entirely), the ritual music manifest, the egg-world and nest-survey data, the griffin routes and the unicorn warm list. The 90 animation JSONs aren't tracked at all, and features graded shipped above (the falconry call, the mirrored vault) cannot work without them.
5. **`IRIS_03_baby_bundle.pak` is RiftSpeak content** (baby bundle meshes in three variants + a bassinet) riding inside the IRIS asset multipak, advertised as an IRIS asset.
6. **The bundled font's licence** needs clearing before upload.
7. **`MEMORY.md`'s own index is stale in at least two places** — it calls the Epona-seat port "ACTIVE, P1 awaiting test" when the note itself opens with "CLOSED BY AURORA", and calls the wild-cats module "awaiting in-game test" when the body records combat and vocals verified. Read statuses from note bodies, not the index.
