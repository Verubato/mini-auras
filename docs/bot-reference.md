# MiniAuras Bot Reference

Reference for answering MiniAuras support questions: what each feature does, where every
setting lives, and what the defaults, ranges and limits are. Everything here is derived from
the addon source (`src/Config/Defaults.lua`, `src/Config/Panels/`, `src/Config/Config.lua`,
`src/Locales/enUS.lua`, `src/Modules/`, `src/Core/`, `src/Api/V1.lua`).

Addon version 5.5.0. Supported interface versions: 120100 (patch 12.1) and 120007 (patch
12.0.7). Author: Verz. Discord: https://discord.gg/UruPTPHHxK. Website: https://verzaddons.com.

## Names and aliases

MiniAuras used to be called **MiniCC**. Any question about MiniCC is a question about
MiniAuras. The old name survives in several places:

- The slash commands `/minicc` and `/mcc` still open the settings window.
- The CurseForge page is still at `curseforge.com/wow/addons/minicc`.
- The public API global `MiniCCApi` is the same table as `MiniAurasApi`.
- Old MiniCC settings (the `MiniCCDB` saved variable) are imported automatically the first
  time MiniAuras runs. The release zip ships a small "MiniCC (settings bridge for MiniAuras)"
  folder whose only job is to load the old settings file; it draws nothing.
- Profile strings that start with `!MiniCC:2!` or `!MiniCC!` still import, and aura strings
  starting with `!MiniCCAuras:1!` still import into Custom Auras.

**Conflict: everything drawn twice.** If the real old MiniCC addon (not the bridge) is still
installed and enabled next to MiniAuras, both addons anchor icons onto the same frames and
every icon appears twice. MiniAuras detects this and shows a dialog titled "MiniAuras - Addon
Conflict". The fix: delete the MiniCC folder from the AddOns folder and reload. The old
settings have already been copied, so nothing is lost.

**Settings did not carry over.** If MiniAuras was first set up while the old MiniCC settings
were not loaded (bridge disabled or greyed out as out of date), it runs on defaults but
remembers this. If the old table appears on a later login it offers a one-time import dialog.
If the MiniCC folder is installed but never loads, MiniAuras prints a chat message telling the
user to enable it and tick "Load out of date AddOns", then reload, so the settings can import.

## Opening the settings

Slash commands: `/miniauras`, `/minia`, `/cc`, `/minicc`, `/mcc`. All toggle the same
standalone settings window (1000x690, centred). Note: `/minia` is registered but Blizzard's
own main-assist command can claim it first, so on some clients it may not reach MiniAuras;
`/miniauras` or `/cc` always work.

- `/miniauras test` toggles test mode (same as the **Test** button in the window title bar).
- `/miniauras debug` toggles cooldown debug logging. 12.0 clients only; does nothing on 12.1.
- `/rl` reloads the UI, registered only if no other addon already defines it.

The Interface > AddOns > MiniAuras entry is only a splash screen with the version and an
"Open Settings" button; all real configuration is in the standalone window.

**Test mode** draws fake icons on every enabled display so things can be positioned out of
combat. While testing, the Test button pulses and reads "Testing...". Screen-anchored displays
(Alerts, Healer, Enemy Kicks, Ally Kicks, screen-anchored custom aura groups, the Enemy
Cooldowns linear bar) become draggable during test mode. Stand-in party/raid and arena frames
are only created when no real frames are visible, so testing in a group shows icons where they
will actually be. Test mode stops automatically when combat starts. The World/Arena/Dungeons
and Raids/Battlegrounds sub-tabs on the CC, Raid Frame Auras and Friendly Cooldowns pages also
flip which of the two setting groups the test preview uses.

## The game version split (the most important fact)

Patch 12.1 removed addon access to aura data: the UnitAura APIs return secret values and the
only way to display auras is Blizzard's new AuraContainer system, where the engine does the
matching and the addon never sees the data. MiniAuras ships one codebase with two paths and
decides which to use **once, at load time**, from the client's interface number:
`interface >= 120100` means the 12.1 path ("aura container era"). This cannot change during a
session.

Consequences, exhaustively:

**Exists only on 12.1 (missing entirely on 12.0):**

- **Custom Auras** (the "Personal Auras" sidebar tab). Spell-ID aura filtering is the whole
  feature and only 12.1 has it.
- **Party Trinkets** as a standalone module and its "Trinkets" sidebar tab. (On 12.0 the
  Friendly Cooldowns tracker draws the trinket slot instead.)
- The **Spells** sub-tab of Raid Frame Auras (choosing tracked spells by ID) and its
  **Show important** toggle. Spell-ID filtering of raid frame auras is impossible on 12.0.
- **Pandemic** (refresh-window) highlighting on custom aura icons.
- Alerts **per-category glow tints** (Important / Defensive colour swatches).
- Alerts text-to-speech via **pre-recorded voice packs** (with a Channel option).
- Engine-side aura sounds (C_UnitAuras.AddAuraSound): this is how the healer CC sound, custom
  aura sounds, alert sounds and TTS clips fire on 12.1.
- Glow Type choices: Rotation Assist (Clockwise), Rotation Assist (Anti-clockwise),
  Ants (Anti-Clockwise), Twins, Mirror, Twins Mirror, Slot Glow, Static Pixel Border.
- Custom aura groups drawn as **bars** instead of icons (the game's aura containers drive the
  fill, and the 12.0 path has no equivalent).

**Exists only on 12.0 (removed on 12.1, config tabs hidden there):**

- **Friendly Cooldowns** tracker (infers cooldowns from aura data).
- **Enemy Cooldowns** tracker (same reason).
- **Precognition** module and its tab. On 12.1 the starter Custom Aura groups track
  Precognition and Nullifying Shroud instead, and the module is switched off.
- **CC Native Order** option under Misc (on 12.1 sorting happens inside the game's aura
  containers and the option would do nothing, so it is hidden).
- The **MiniCE** cooldown styler (its card on the Other Addons tab only appears on 12.0; on
  12.1 the game writes the countdown text itself, so there is nothing left to restyle).
  Masque skinning works on both versions.
- Alerts **Color by class** option and system-voice TTS with Voice, TTS Volume and TTS
  Speech Rate controls.
- Alerts **CENTER** grow direction (12.1 offers only LEFT and RIGHT; a saved CENTER renders
  as RIGHT there).
- `/miniauras debug`.
- Glow Type choices: Proc Glow, Rotation Assist (Anti-clockwise), Pixel Glow, Autocast Shine,
  Slot Glow.

**Exists on both versions** (sometimes with internal differences noted per module below):
CC, Pet CC, Healer, Portraits, Alerts, Nameplates, Raid Frame Auras, Ally Kicks, Enemy Kicks,
Misc, Profiles, Other Addons.

## Settings window layout

Left sidebar, grouped under four headings. Bracketed names are the sidebar labels where they
differ from the page title.

**General:** Home, Personal Auras (= Custom Auras, 12.1 only), Group Auras (= Raid Frame
Auras), Alerts, Nameplates, Portraits, Friendly CDs, Enemy CDs, Precognition (last three
12.0 only).

**Crowd Control:** CC, Pet CC, Healer, Trinkets (= Party Trinkets, 12.1 only).

**Kicks:** Ally Kicks, Enemy Kicks.

**Other:** Misc (= Miscellaneous), Profiles, Other Addons (= Other Mini Addons).

The Home page shows the addon name, an "Important News" card describing the current patch
situation, and the Discord link.

## Concepts shared by most modules

### Enable per content type

Most modules have an "Enable in" row with five checkboxes: **World, Arena, Battlegrounds,
Dungeons, Raid**. Which one applies:

- Arena instance -> Arena.
- Battleground instance -> Battlegrounds.
- Any other instance -> Raid if you are in a raid group, otherwise Dungeons.
- Open world -> Raid if you are in a raid group, otherwise World.

A module that "does not work" somewhere is usually just switched off for that content type.
Exceptions: Portraits, Party Trinkets and Precognition have a single **Enabled** switch;
Enemy Kicks is enabled by role (see its section); Custom Auras has no module switch at all
(each group has its own Enabled toggle).

### Two setting groups per module

CC, Raid Frame Auras and Friendly Cooldowns each keep two independent sets of appearance
settings, shown as two sub-tabs: **World/Arena/Dungeons** and **Raids/Battlegrounds**. The
raid set is used whenever you are in a raid group and not in arena (battlegrounds count,
because you are in a raid group there). Changing icon size on one tab does not change the
other.

### Anchoring

- **Screen-anchored displays** (Alerts bars, Healer, Enemy Kicks, Ally Kicks, Precognition,
  Enemy Cooldowns linear bar, screen-anchored custom aura groups) have a saved screen
  position and can be dragged while test mode is on (Ally Kicks instead uses its Lock
  position toggle; a selected custom aura group can be dragged without test mode).
- **Frame-attached displays** (CC, Pet CC, Raid Frame Auras, Nameplate bars, Trinkets,
  Friendly Cooldowns, Enemy Cooldowns in Arena Frames mode, frame/nameplate/arena-anchored
  custom aura groups) have an X/Y offset from the frame they hang off plus a **Grow**
  direction. Grow options vary by module: LEFT/RIGHT/CENTER/DOWN/UP for most frame-attached
  ones, LEFT/RIGHT/CENTER for nameplates, DOWN/UP for Ally Kicks, LEFT/RIGHT (12.1) or
  LEFT/RIGHT/CENTER (12.0) for Alerts.

### Common icon options and ranges

Unless a module's table below says otherwise: Icon Size slider 10-100 px, Icon Padding
(spacing) 0-20 px default 2, Offset X/Y sliders -250 to 250 default 0. Frame-attached
displays with a **Relative size** checkbox size icons as a percentage of the unit frame's
height instead of pixels (Icon Size (%) slider, 25-100). Most displays also share: Glow
icons, Reverse swipe (reverses the cooldown swipe animation), Show tooltips (spell tooltip on
hover), and a colour rule.

### Colouring rules

- **Dispel colours** (CC, Pet CC, Healer, Raid Frame Auras): glow/border coloured by the
  debuff's dispel type (for example blue for magic).
- **Spell colours** (Nameplates): CC uses dispel-type colours, defensives are green.
- **Per-category tints** (Alerts on 12.1): a colour swatch each for Important (default red)
  and Defensive (default green). On 12.0 Alerts instead offers **Color by class**.
- **Flat colour** (Trinkets, Enemy Kicks, Precognition, Custom Auras): the user picks one
  colour for the glow and border, because these icons carry no category to derive one from.

### Glow Type (global, under Misc)

One glow style for the whole addon, default **Slot Glow**.

- 12.1 choices: Rotation Assist (Clockwise), Rotation Assist (Anti-clockwise),
  Ants (Anti-Clockwise), Twins, Mirror, Twins Mirror, Slot Glow, Static Pixel Border. Slot Glow
  and Static Pixel Border are static and use the least CPU; the animated ones keep animating
  icons that show no aura and cost CPU while idle (the 12.1 containers pre-create buttons and
  the addon cannot gate the animation per icon). A profile saved on 12.0 with a 12.0-only glow
  type renders as Slot Glow on 12.1.
- 12.0 choices: Proc Glow, Rotation Assist (Anti-clockwise), Pixel Glow, Autocast Shine, Twins,
  Mirror, Twins Mirror, Slot Glow, Static Pixel Border. Proc Glow uses the least CPU.
- Twins, Mirror and Twins Mirror keep their own colours, so the colour swatches do not tint
  them.

### Sounds

Fourteen sounds ship with the addon: AirHorn, AlertToastWarm, BubblePop, CheerfulHarp,
CinematicHit, ElectricalSpark, Error, NewNotification09, Notification18, Notification38,
Sonar, SuddenShock, WatchOut, WhooshSwing. A fifteenth, XiaYike, is offered only on Chinese
(zhCN/zhTW) clients. All are registered with LibSharedMedia, so any sound another addon
registers there is also selectable, and other addons can use MiniAuras's sounds. If a saved
sound comes from a media addon that was uninstalled, it falls back to Sonar. A media addon that
loads *after* MiniAuras is waited for instead: the aura stays silent for a second or so rather
than firing the fallback, then registers with the right file. Sound settings have an output
channel dropdown, Master or Sound Effects (SFX), default Master.

### Countdown text

- **Colour Countdown** (Misc, on by default): timer text is white above a minute, yellow
  under a minute, red in the last five seconds.
- **Milliseconds**: displays with a "Milliseconds" checkbox (CC, Pet CC via CC path,
  nameplate bars) show decimal seconds once the remaining time drops below the
  **Milliseconds Threshold** (Misc, 1-6 s, default 5).
- **Font Scale** (Misc, 0.5-1.5, step 0.05, default 1.0) scales the addon's text.
- **Disable Swipe** (Misc, off by default) removes the cooldown pie animation everywhere;
  timer text stays.

---

## Custom Auras / Personal Auras (12.1 only)

Sidebar: General > Personal Auras. Page title "Custom Auras". User-built "mini weak auras":
icons or bars (with optional sound) for buffs on allies and debuffs on enemies, or a sound on
its own with nothing drawn at all. This is the flagship 12.1 feature.

### Groups

The page shows a grid of group tiles plus a leading `+` tile ("New Group"). Click a tile to
edit that group in the editor below ("Selected Aura"); click empty grid space to deselect.
Tiles are dragged to reorder (order is cosmetic only). A disabled group's tile is
desaturated. While a group is selected, its icons are shown on screen and can be dragged into
place without test mode. There is no module-wide on/off switch: each group has its own
**Enabled** toggle, and with zero groups the module does nothing.

Editor header: the group's icon (click to open the icon picker), **Name**, **Enabled**,
**Duplicate** (copy lands next to the original, named "<name> copy", and is selected), and
**Delete** (confirmed; there is no undo).

**Icon picker** ("Choose an Icon"): browses the same list as Blizzard's macro UI (roughly
40,000 icons). **Reset** clears the choice; an empty icon means the group borrows the icon of
the first spell in its list (question mark if there is none).

**Import/Export**: the **Import/Export** button exports the selected group (or all groups if
none is selected); **Export All** always exports everything. Strings start with
`!MiniAuras:Auras:1!` (deflated CBOR, Base64). Old `!MiniCCAuras:1!` strings also import.
Strings from a newer MiniAuras version are refused. Imported groups get fresh IDs and are
normalised/sanitised, so a bad string cannot corrupt settings.

### Starter groups

A new profile is seeded once with three groups, in a row 300 px above screen centre, 50 px
apart, all with glow and border on:

| Group | Spell | Sound | Tint |
|---|---|---|---|
| Precog (Precognition) | 377362 | ElectricalSpark on apply | none (white) |
| Shroud (Nullifying Shroud) | 378464 | none | purple (0.64, 0.21, 0.93) |
| PI (Power Infusion) | 10060 | BubblePop on apply | gold (1, 0.82, 0) |

Seeding happens once per profile (a SeededDefaults flag), so deleting them is permanent, and
a profile that predates them gains them on the next load.

### Trigger tab

- **Unit** (what the group watches, and what it anchors to; the anchor is derived from the
  unit, never chosen separately):
  - **Self** - the player. Screen-anchored.
  - **My Pet** - your pet. Screen-anchored.
  - **Tank** / **Healer** - the first group member in roster order holding that role
    (includes you). Screen-anchored.
  - **Other DPS** - the first DAMAGER in roster order that is not you. Screen-anchored.
  - **Unit Frames** - one copy of the group on every party/raid frame (including frames from
    external frame providers).
  - **Arena Frames** - one copy per enemy arena frame. Debuffs only.
  - **Friendly Target** / **Enemy Target** - your target; only shows while the target is on
    that side. Screen-anchored.
  - **Friendly Nameplates** / **Enemy Nameplates** - one copy on every matching nameplate.
  - (Groups saved before the split with old units target/focus/targettarget/nameplate are
    migrated to the matching target or nameplate choice; focus no longer exists as a choice.)
- **Display**: **Icons**, **Bars** or **Sound only**. First on the row, because it decides
  what the rest of the row may offer (see Sound only below). Icons and bars are the two drawn
  shapes; see the Appearance and Layout tabs.
- **Aura Type**: **Buff** or **Debuff**. The dropdown is hidden when the unit allows only one
  type, and for a Sound only group, which does not care. Target and nameplate units allow only
  the type matching their side (buffs on friendly, debuffs on enemy); Arena Frames allows only
  debuffs.
- **Type**: **Spell IDs** or **Aura filters** (the two tracking modes). Hidden for a Sound only
  group, which is always Spell IDs.

**The spell-ID rule (why some combinations are refused).** The game only honours a spell-ID
filter for helpful auras on units you can assist, and for harmful auras on units you cannot;
anywhere else the ID list is silently ignored and the group would match everything. So in
Spell IDs mode, debuffs cannot be tracked on Self, My Pet or Unit Frames (all always
assistable), and the editor says so in red: "Debuffs cannot be tracked on yourself or your
pet." / "Debuffs cannot be tracked on group members." Switching to Aura filters mode makes
debuffs on those units legal, because filter strings apply regardless of side. Yellow
caveats: "Buffs are only shown while the unit is friendly." / "Debuffs are only shown while
the unit is hostile." for the target and nameplate choices.

**Sound only lifts the rule entirely.** The restriction is about what can be DRAWN: the rule
applies to the filters a container uses to decide which auras to show. A sound is registered
per spell ID against a unit and is not filtered that way at all, so a Sound only group can
watch either aura type on any unit - including debuffs on yourself, your pet and your party
frames, which no drawn group can do. Neither the Aura Type nor the tracking mode dropdown is
shown for one, and none of the red refusals or yellow caveats apply.

**Spell IDs mode:**

- **Add a spell**: a picker box ("Spell ID / name") with live suggestions; type an ID or a
  name, pick with mouse or arrow keys + Enter.
- **Record**: captures the spells you cast (your casts only; the button toggles to "Stop")
  and lists them as "Recorded Casts" (up to 40 remembered, newest first, 12 shown). Clicking
  one adds it and stops recording. Tooltip warning: the recorded ID is the ID of the cast,
  which is often not the ID of the aura it applies. Recording stops automatically when the
  config window closes.
- A group holds at most **100 spells** ("A group can hold at most 100 spells."), no
  duplicates. Each added spell is automatically expanded to every spell ID sharing its name,
  because the aura the game applies is often not the spellbook ID.
- A Spell IDs group with an empty list shows nothing (the empty list itself is the reason).

**Aura filters mode** replaces the spell list with a grid of the engine's own filter
components. Each cycles through three states: off (grey dot), required (green +), forbidden
(red -):

| UI label | Engine component |
|---|---|
| Applied by me | PLAYER |
| Raid relevant | RAID |
| Dispellable | DISPELLABLE |
| Dispellable by me | RAID_PLAYER_DISPELLABLE |
| Cancelable | CANCELABLE |
| Crowd control | CROWD_CONTROL |
| Important | IMPORTANT |
| Major defensive | BIG_DEFENSIVE |
| External defensive | EXTERNAL_DEFENSIVE |

### Filters tab

Applies in both tracking modes:

- **Cast by**: Anyone / Me / Anyone else.
- Aura flag tri-states (off / required / forbidden), same three-state control:

| UI label | Engine flag |
|---|---|
| From me or my pet | isFromPlayerOrPlayerPet |
| Cast by a boss | isBossAura |
| Stealable | isStealable |
| Priority aura | isPriorityAura |
| I could apply it | canApplyAura |

**Caster caveat:** any caster-dependent filter (Cast by other than Anyone, the "From me or my
pet" flag, or a required/forbidden "Applied by me" component) needs the game to attribute the
aura's caster, which it cannot do for a group member in another instance or phase. Rather
than showing wrong results, the group shows nothing on that unit until they are visible
again.

### Appearance tab

Empty for a **Sound only** group, which draws nothing: the tab shows "Sound only auras don't
have an appearance." and no controls. **Display** itself lives on the Trigger tab.

| Setting | Values / range | Default |
|---|---|---|
| Bar Texture | any shipped/LibSharedMedia bar texture (bars only) | Blizzard Raid Bar |
| Glow icons | on/off (icons only) | off (starter groups: on) |
| Show border | on/off | off (starter groups: on) |
| Reverse swipe | on/off (icons only) | on |
| Hide swipe | on/off (icons only) | off |
| Hide numbers | on/off (icons only); drops the countdown text | off |
| Show tooltips | on/off | off |
| Spell name | on/off (bars only) | on |
| Pandemic | on/off | off |
| Colour (glow/border tint, or the bar's fill) | colour swatch | white |
| Pandemic colour | colour swatch | red (1, 0.1, 0.1) |

**Display** (on the Trigger tab) decides the shape of the whole group. A **Bars** group draws a
horizontal bar per aura: the spell icon at the left, the spell name and the countdown inside the fill, and the
fill draining as the aura runs out. Stacks, dispel colouring and the pandemic reveal work on
both shapes; the glow does not (the styles are drawn for a square, so the option is hidden for
bars). The shape is baked into a display when it is built, so switching it swaps the group onto
a different set of frames, and a switch made while the game is hiding aura data (inside an
arena) may not show until the match ends.

**Pandemic** highlights an aura during its refresh window (where re-casting adds the
remaining time on top). The game decides the window per spell, and only your own re-castable
effects have one.

### Layout tab

Empty for a **Sound only** group, for the same reason: the tab shows "Sound only auras don't
have a position." and no controls.

| Setting | Values / range | Default |
|---|---|---|
| Order | Oldest first / Longest remaining first / Shortest remaining first | Oldest first |
| Grow | LEFT / RIGHT / CENTER / DOWN / UP | CENTER |
| Offset X / Offset Y | typed number boxes, clamped to -2000..2000 | screen groups: 0 / 220 above centre; nameplate groups: 0 / 40 above the plate; unit frame and arena frame copies: 0 / 0 |
| Icon Size | 10-200 (icons only) | 40 |
| Bar Height | 8-50 (bars only) | 20 |
| Bar Width | 40-250 (bars only) | 150 |
| Icon Padding | 0-50 | 2 |

Dragging the icons or bars on screen writes the same values the Offset X/Y boxes edit, and the
boxes update when the drag ends.

### Sounds tab

Only shown for Spell IDs groups (the engine registers sounds per spell ID, which a filter
group does not have). Three independent sound pickers, each any shipped/LibSharedMedia sound
or "(None)" (default None): **When applied**, **When it gains a stack**, **When removed**;
plus one **Channel** (Master / Sound Effects) for all three. Sounds are played engine-side,
so they fire even though the addon cannot read the aura.

For a **Sound only** group this tab is the whole feature. Such a group needs spells and at
least one sound to do anything; with neither it simply does nothing, and the editor says
nothing about it (an unfinished group is not a misconfigured one). Sound only groups on the
**Unit Frames** unit follow the roster rather than the frames on screen, so they work with the
party frames hidden and cover you as well as your group; the target and nameplate choices
still only fire while the unit is on the side the choice names.

### Limits

- Max 100 spells per group.
- Max 40 icons or bars shown per group; 3 preview stand-ins while positioning.
- Icon size 10-200, bar height 8-50, bar width 40-250, spacing 0-50, offsets typed up to
  +/-2000.

---

## Group Auras / Raid Frame Auras

Sidebar: General > Group Auras. Page title "Raid Frame Auras". Shows auras on party and raid
frames. On 12.1 the tracked helpful auras are chosen by spell ID from a curated list (so
anything can be tracked, including spells the game never flags); on 12.0 there is no Spells
tab and the categories come from the game's flags.

Enable in (defaults): World on, Arena on, Battlegrounds on, Dungeons on, Raid off.

Two setting groups (World/Arena/Dungeons and Raids/Battlegrounds sub-tabs):

| Setting | Range | Default (W/A/D) | Default (Raids/BGs) |
|---|---|---|---|
| Exclude self | on/off | off | off |
| Glow icons | on/off | on | on |
| Dispel colours | on/off | on | on |
| Reverse swipe | on/off | on | on |
| Show tooltips | on/off | off | off |
| Show important (12.1 only) | on/off | on | on |
| Show defensives | on/off | on | on |
| Show CC | on/off | off | on |
| Show interrupts | on/off | on | on |
| Relative size / Icon Size (%) | 25-100 % | 75 | 65 |
| Icon Size | 10-100 px | 30 | 25 |
| Max Icons | 1-5 | 3 | 3 |
| Icon Padding | 0-20 | 2 | 2 |
| Grow | LEFT/RIGHT/CENTER/DOWN/UP | CENTER | CENTER |
| Offset X / Y | -250..250 | 0 / 0 | 0 / 0 |

- "Show important" shows buffs Blizzard flags as important (for example offensive
  cooldowns); the toggle only exists on 12.1.
- "Show interrupts" shows an icon when a friendly unit gets interrupted.

**Spells sub-tab (12.1 only).** "Specify which spells are shown on raid frames." A sidebar of
sections: one per class, then General (classless spells such as PvP gem effects), then
Custom. Each spell is a checkbox with its icon and ID. Some curated spells ship switched off
and are an explicit opt-in. Custom IDs are added in the Custom section via the "Add spell ID"
box and removed with the cross button. Only differences from the curated list are saved, so
an updated curated list still reaches existing profiles.

---

## Alerts

Sidebar: General > Alerts. A movable screen bar showing enemy defensive spells and important
spells (for example offensive cooldowns, Precognition) as they are used, with optional sound
and text-to-speech. It reads enemy nameplates, so alerts require enemy nameplates to be
active; on 12.1 the important category is read from Blizzard's nameplate buff lists across
every active enemy. In arena, the bars reset when a new round's preparation room starts.

Enable in (defaults): World on, Arena on, Battlegrounds off, Dungeons off, Raid off.

**Settings sub-tab:**

| Setting | Range | Default |
|---|---|---|
| Show icons | on/off | on |
| Show Defensives | on/off | on |
| Show Important | on/off | on |
| Split bars | on/off | off |
| Show tooltips | on/off | off |
| Glow icons | on/off | on |
| Reverse swipe | on/off | on |
| Important colour (12.1 only) | swatch | red (1, 0.2, 0.2) |
| Defensive colour (12.1 only) | swatch | green (0.2, 1, 0.2) |
| Color by class (12.0 only) | on/off | on |
| Grow | 12.1: LEFT/RIGHT; 12.0: LEFT/RIGHT/CENTER | CENTER (shown/behaves as RIGHT on 12.1) |
| Icon Size | 10-100 | 50 |
| Max Icons | 1-10 | 8 |
| Icon Padding | 0-20 | 2 |

Positions (dragged in test mode): combined bar centred, 150 px below the top of the screen.
**Split bars** gives important spells their own separately movable bar: defensives default
220 px left of centre, important 220 px right, same height.

**Sound Alerts sub-tab:** "Plays a sound when an enemy presses an important or defensive
spell." Separate opt-in per category: **Important Spells** (default file AirHorn, off) and
**Defensive Spells** (default file AlertToastWarm, off), sharing one **Channel** (default
Master).

**TTS (Text-to-speech) sub-tab:**

- On **12.1**: "On this game version, text-to-speech uses pre-recorded voice packs." A
  **Voice pack** dropdown, a **Channel** dropdown (Master/SFX), and per-category
  **Important** and **Defensive** announce toggles (both off by default). Eight packs ship:
  Amy, Anna Su, David, Elise, Emma, Grampa Werthers, Jason Chen, Theo Silk. Amy, Anna Su and
  Jason Chen are Mandarin voices offered only on zhCN/zhTW clients. Default pack: David.
  Other addons can register packs via the API. The clips are baked OGG files registered
  engine-side per spell ID; after updating the addon a full client restart (not just a
  reload) is needed before new audio files can play.
- On **12.0**: system text-to-speech. **Voice** dropdown (the OS voices), **TTS Volume**
  (0-100, default 100), **TTS Speech Rate** (-5 to 5, default 0), and the same two announce
  toggles. Known limitation shown on the page: important-spell TTS does not work for Mages,
  Evokers, Demon Hunters, Hunters, and Shadow Priests (a Blizzard API limitation).

---

## Nameplates

Sidebar: General > Nameplates. Shows CC, defensive and important spells on nameplates. Works
alongside nameplate addons such as BetterBlizzPlates (BBP), Platynator and Plater.

Enable in (defaults): all five on (World, Arena, Battlegrounds, Dungeons, Raid).

**Settings sub-tab:**

| Setting | Default | Notes |
|---|---|---|
| Ignore Enemy Pets | on | no auras on enemy pet nameplates |
| Ignore Friendly Pets | on | no auras on friendly pet nameplates |
| Scale with Nameplate | on | icons follow the plate's scale; keep on if the target plate is a different size (for example via BBP) |
| Anchor to Health Bar | off | anchor icons to the plate's health bar instead of the plate frame; turn on if another addon (for example BetterBlizzPlates) changes plate width or height |

**Four independently configured bars**, each its own sub-tab: Enemy - Bar 1, Enemy - Bar 2,
Friendly - Bar 1, Friendly - Bar 2. Per bar:

| Setting | Range | Enemy Bar 1 default | Enemy Bar 2 default | Friendly bars default |
|---|---|---|---|---|
| Enabled | on/off | on | on | off |
| Show CC | on/off | on | off | Bar 1 on, Bar 2 off |
| Show Defensives | on/off | off | on | Bar 1 off, Bar 2 on |
| Show Important | on/off | off | on | Bar 1 off, Bar 2 on |
| Glow icons | on/off | on | on | on |
| Reverse swipe | on/off | on | on | on |
| Spell colours | on/off | on | on | on |
| Show tooltips | on/off | off | off | off |
| Milliseconds | on/off | on | on | on |
| Icon Size | 10-60 | 35 | 35 | 35 |
| Max Icons | 1-8 | 5 | 5 | 5 |
| Grow | LEFT/RIGHT/CENTER | LEFT | RIGHT | Bar 1 LEFT, Bar 2 RIGHT |
| Icon Padding | 0-20 | 2 | 2 | 2 |
| Offset X / Y | -250..250 | 0 / 0 | 0 / 0 | 0 / 0 |

An interrupt (kick) icon is shown on bars that have Show CC enabled. 12.1 differences: each
enabled category on a bar gets the bar's full Max Icons budget (no dynamic split between
categories), and "Spell colours" maps to dispel-type colouring.

Related global option: **Configure Blizzard Nameplates** (Misc, on by default) disables
Blizzard's own CC display and BigDebuffs on nameplates while MiniAuras nameplates are in use,
so the same auras are not drawn twice.

---

## Portraits

Sidebar: General > Portraits. Shows CC, defensives and other important spells on the player,
target and focus portraits. Both game versions.

Settings: **Enabled** (single switch, applies everywhere, default on) and **Reverse swipe**
(default on). Nothing else.

Supported portrait providers: Blizzard frames, ElvUI, TPerl, UUF (Unhalted Unit Frames),
MSUF, Ellesmere UI Unit Frames, EnhancedQoL.

---

## CC (crowd control on party/raid frames)

Sidebar: Crowd Control > CC. Shows CC icons on party/raid frames.

Enable in (defaults): World on, Arena on, Battlegrounds off, Dungeons on, Raid off.

Two setting groups (World/Arena/Dungeons and Raids/Battlegrounds sub-tabs):

| Setting | Range | Default (W/A/D) | Default (Raids/BGs) |
|---|---|---|---|
| Exclude self | on/off | off | off |
| Glow icons | on/off | on | on |
| Dispel colours | on/off | on | on |
| Reverse swipe | on/off | on | on |
| Show tooltips | on/off | off | off |
| Milliseconds | on/off | off | off |
| Relative size / Icon Size (%) | 25-100 % | 80 | 50 |
| Icon Size | 10-100 px | 32 | 20 |
| Max Icons | 1-5 | 3 | 3 |
| Icon Padding | 0-20 | 2 | 2 |
| Grow | LEFT/RIGHT/CENTER/DOWN/UP | RIGHT | CENTER |
| Offset X / Y | -250..250 | 2 / 0 | 2 / 0 |

Ordering: MiniAuras shows the most recently applied CC first. On 12.0 only, the **CC Native
Order** option under Misc switches to Blizzard's default CC priority, which usually shows the
first CC applied. The option does not exist on 12.1 (sorting happens inside the game's aura
containers there).

---

## Pet CC

Sidebar: Crowd Control > Pet CC. The same CC icons on party/raid **pet** frames.

Enable in (defaults): all five off.

One setting group (no raid split):

| Setting | Range | Default |
|---|---|---|
| Show on pet unit frame | on/off | off |
| Glow icons | on/off | on |
| Dispel colours | on/off | on |
| Reverse swipe | on/off | on |
| Show tooltips | on/off | off |
| Relative size / Icon Size (%) | 25-100 % | 50 |
| Icon Size | 10-100 px | 20 |
| Max Icons | 1-5 | 3 |
| Icon Padding | 0-20 | 2 |
| Grow | LEFT/RIGHT/CENTER/DOWN/UP | RIGHT |
| Offset X / Y | -250..250 | 0 / 0 |

**Show on pet unit frame** additionally puts a CC container next to your own pet's unit frame
(Blizzard PetFrame or a supported unit-frame addon's pet frame), on top of the party/raid pet
frames.

---

## Healer (healer in CC warning)

Sidebar: Crowd Control > Healer. A separate screen region that shows CC icons and a
"Healer in CC!" warning when your group's healer is crowd controlled, with an optional sound.

Enable in (defaults): World on, Arena on, Battlegrounds off, Dungeons on, Raid off.

| Setting | Range | Default |
|---|---|---|
| Show icons | on/off | on |
| Glow icons | on/off | on |
| Warning text | on/off | on |
| Reverse swipe | on/off | on |
| Dispel colours | on/off | on |
| Show tooltips | on/off | off |
| Sound | on/off + sound dropdown | on, Sonar, Master channel |
| Icon Size | 10-100 | 50 |
| Text Size | 10-100 | 32 |
| Icon Padding | 0-20 | 2 |

Position: centred, 220 px below the top of the screen; draggable in test mode. On 12.1 the
sound plays engine-side (registered per known CC spell against the healer), so it works
despite the aura lockdown.

---

## Party Trinkets (12.1 only)

Sidebar: Crowd Control > Trinkets. Shows party members' PvP trinket cooldowns next to their
party frames. On 12.0 this is not a separate module; the Friendly Cooldowns tracker draws the
trinket slot instead. Trinket data comes from the C_PvP API, not auras, which is why this
survives the 12.1 lockdown.

| Setting | Range | Default |
|---|---|---|
| Enabled | on/off (single switch, everywhere) | on |
| Exclude self | on/off | off |
| Show border | on/off | off |
| Colour | swatch | white |
| Icon Size | 10-100 | 40 |
| Offset X / Y | -200..200 | -2 / 0 (icon hangs left of the frame) |

Stated limitations (shown on the page): only works inside arena, and it cannot see a trinket
used in the starting room.

---

## Ally Kicks (ally kick tracker)

Sidebar: Kicks > Ally Kicks. A list of bars showing recent interrupts by your group, newest
first, for coordinating interrupt rotations in dungeons and Mythic+. Blizzard hides who
kicked inside Mythic+, so a row cannot count down the kicker's real cooldown; every row
simply lasts 15 seconds.

Enable in (defaults): Dungeons on; World, Arena, Battlegrounds, Raid off.

| Setting | Range | Default |
|---|---|---|
| Lock position | on/off | off (unlocked: bars can be dragged; locking also lets the mouse click through them) |
| Show self | on/off | on (pins a bar for your own interrupt at the top, counting down to ready) |
| Grow | DOWN / UP | DOWN |
| Bar Texture | LibSharedMedia statusbar list | Blizzard Raid Bar |
| Bar Width | 60-400 | 260 |
| Bar Height | 8-60 | 35 |
| Bar Padding | 0-20 | 2 |
| Max Bars | 1-10 | 5 |

Default position: 620 px left and 160 px above screen centre.

---

## Enemy Kicks (enemy kick tracker)

Sidebar: Kicks > Enemy Kicks. Shows enemy interrupt cooldowns in arena (arena only; the
icons only appear inside arena matches).

**Enabled by role, not by content type.** "Enable if you are": **Healer** (default on),
**Caster** (default on), **Any** (default off, enables regardless of spec). Whether your spec
counts as healer or caster comes from the addon's spec data; if your spec cannot be read the
module assumes enabled.

Since patch 12.0.5 the game no longer identifies who interrupted, so the tracker shows a
generic kick icon (the rogue Kick spell's icon) timed with the **shortest known interrupt
cooldown on the enemy team** (15 s fallback until the opponents' specs are known).

| Setting | Range | Default |
|---|---|---|
| Show border | on/off | off |
| Colour | swatch | white |
| Icon Size | 20-120 | 50 |
| Icon Padding | 0-20 | 2 |

Position: centred, 200 px below screen centre; draggable in test mode.

---

## Friendly Cooldowns (12.0 only)

Sidebar: General > Friendly CDs. "Shows PvP trinket and friendly defensive cooldowns on
party/raid frames." It infers cooldown usage by watching the buffs teammates apply, which is
impossible on 12.1; the module and its tab do not exist there.

Enable in (defaults): World on, Arena on, Battlegrounds off, Dungeons on, Raid off.

Two setting groups (World/Arena/Dungeons and Raids/Battlegrounds sub-tabs):

| Setting | Range | Default (W/A/D) | Default (Raids/BGs) |
|---|---|---|---|
| Exclude self | on/off | off | off |
| Show tooltips | on/off | on | on |
| Reverse swipe | on/off | on | on |
| Trinket (show trinket slot) | on/off | on | on |
| Desaturate on cooldown | on/off | off | off |
| Predictive | on/off | on | on |
| Relative size / Icon Size (%) | 25-100 % | 100 | 50 |
| Icon Size | 10-100 | 40 | 20 |
| Max Icons | 1-10 | 10 | 5 |
| Rows (horizontal grows) | 1-3 | 1 | 1 |
| Columns (vertical grows) | 1-10 | 1 | 1 |
| Icon Spacing | 0-20 | 2 | 2 |
| Grow | LEFT/RIGHT/CENTER/DOWN/UP | LEFT | CENTER |
| Offset X / Y | -250..250 | -2 / 0 | -2 / 0 |

**Predictive**: while a cooldown's buff is active, the icon glows and shows a countdown
before the cooldown timer is committed.

**Spells sub-tab**: every trackable spell, grouped by class in a sidebar, each with a
checkbox to stop tracking it.

Known 12.0.5+ limitations (from the addon's own notices): friendly externals no longer track
in raids and battlegrounds, and predictive glows are less reliable; tracking still works
mostly fine in arena and dungeons. Supports multiple spell charges (for example 2x Pain
Suppression).

---

## Enemy Cooldowns (12.0 only)

Sidebar: General > Enemy CDs. "Shows enemy arena opponent defensive cooldowns after their
buffs expire." Gone on 12.1 for the same reason as Friendly Cooldowns.

Enabled: a single **Enabled** checkbox meaning "in arena" (defaults: on in arena only).

**Settings sub-tab:**

| Setting | Range | Default |
|---|---|---|
| Show tooltips | on/off | off |
| Reverse swipe | on/off | on |
| Always show cooldowns | on/off | off (shows every cooldown for the enemy's spec, faded at 0.6 opacity while off cooldown, opaque while active) |
| Desaturate on cooldown | on/off | off |
| Icon Size | 10-100 | 40 |
| Icon Spacing | 0-20 | 2 |
| Layout Mode | Arena Frames / Linear Bar | Linear Bar |
| Grow (Arena Frames mode) | LEFT/RIGHT/CENTER | RIGHT |
| Offset X / Y (Arena Frames mode) | -200..200 | 58 / 0 |
| Entry Spacing (Arena Frames mode) | 0-50 | 4 (vertical gap between each enemy's row) |

Arena Frames mode anchors icons next to each enemy's arena frame; Linear Bar shows all
cooldowns in one combined bar (default position: centred, 100 px below screen centre). The
Arena Frames Anchoring controls only appear in Arena Frames mode.

**Spells sub-tab**: trackable enemy cooldowns grouped by class, each with a checkbox.

---

## Precognition (12.0 only)

Sidebar: General > Precognition. Shows a large icon in the middle of the screen when you gain
Precognition, and also tracks Preservation Evoker's Nullifying Shroud. On 12.1 the module is
switched off and its tab removed; the starter Custom Aura groups track the same two spells
(377362 and 378464) instead.

How it works on 12.0 (stated on the page): it cannot filter by spell ID, so it triggers on
any 4-second "important" self buff (3 seconds for Shroud). Another self buff with the same
shape can therefore trigger it by accident.

| Setting | Range | Default |
|---|---|---|
| Enabled | on/off (single switch) | on |
| Glow icons | on/off | on |
| Show border | on/off | on |
| Colour | swatch | white |
| Icon Size | 20-120 | 70 |

Position: centred, 70 px above screen centre. The stored settings include a sound (off,
ElectricalSpark), but no sound control is reachable in the UI on 12.0, so do not point users
at one.

---

## Miscellaneous (Misc tab, global settings)

These apply addon-wide. All except Language override are part of the profile.

| Setting | Values / range | Default |
|---|---|---|
| Language override | Auto (client language) or a shipped locale | Auto; changing prompts a UI reload |
| Configure Blizzard Nameplates | on/off | on (disables Blizzard's CC and BigDebuffs on nameplates when MiniAuras nameplates are used) |
| CC Native Order (12.0 only) | on/off | off (see CC module) |
| Disable Swipe | on/off | off |
| Fade With Parent | on/off | on (icons fade with the unit frame they are attached to, for example out-of-range dimming) |
| Colour Countdown | on/off | on |
| Glow Type | see "Glow Type" above | Slot Glow |
| Font Scale | 0.5-1.5, step 0.05 | 1.0 |
| Milliseconds Threshold | 1-6 seconds | 5 |

Shipped languages: English, German (deDE), Spanish (esES and esMX), French (frFR), Italian
(itIT), Korean (koKR), Portuguese-Brazil (ptBR), Russian (ruRU), Chinese simplified (zhCN)
and traditional (zhTW).

---

## Profiles

Sidebar: Other > Profiles.

- **Active Profile** dropdown plus **New**, **Rename**, **Clone**, **Delete** (confirmed;
  the last remaining profile cannot be deleted), **Reset** (resets the active profile to
  factory defaults, confirmed), and **Import/Export**.
- A profile contains: all module settings plus the Misc options Glow Type, Font Scale,
  Configure Blizzard Nameplates, CC Native Order, Disable Swipe, Colour Countdown and Fade
  With Parent. Not in the profile: Language override and the Auto-Switch rules.
- **Import/Export**: export produces a string starting with `!MiniAuras:1!` (deflated CBOR,
  Base64). Import needs a profile name and creates a new profile, then switches to it. Old
  MiniCC strings (`!MiniCC:2!` and the older `!MiniCC!`) also import.
- **Auto-Switch**: one profile choice per specialization ("(none)" to leave it alone). Rules
  are stored per character (name-realm), and switching happens on spec change and on entering
  the world. This is how a healer spec and a DPS spec can run completely different layouts.

On new releases, migrations can queue release notes which appear once in a
"MiniAuras - What's New?" dialog.

---

## Other Mini Addons tab

Sidebar: Other > Other Addons. Cards linking to the author's other addons (clicking shows a
copyable CurseForge URL): FrameSort, MiniMarkers, MiniOvershields, MiniPressRelease,
MiniArenaDebuffs, MiniKillingBlow, MiniMeter, MiniQueueTimer, MiniTabTarget,
MiniCombatNotifier, MiniResourceDisplay, MiniFader, plus https://verzaddons.com. A second
section, "Other addons to customize MiniAuras further", offers Masque (icon skinning) on both
versions, and MiniCE (cooldown text styling) on 12.0 only: on 12.1 the countdown text is
written by the game, so a cooldown styler has nothing to reach.

### Masque

Icons register under the Masque addon group **MiniCC**, in sub-groups named CC, Healer CC,
Alerts, Nameplates, Friendly Indicators, Custom Auras and (12.0 only) Precognition. The names
are the same on both versions, so a skin picked on one carries over to the other.

On 12.1 a skin is applied when an icon is created, so **reload after changing a skin** for it
to reach icons that already exist. Some displays stay unskinned by design: custom aura groups
drawn as bars, the round portrait icons (the skin would fight their own mask), and any button
whose size the game keeps secret, which covers nameplate icons. If Masque itself errors while
skinning, the display drops skinning for that sub-group for the rest of the session and prints
one chat warning naming it, rather than losing the icons.

---

## Supported addons and environment

**Party/raid unit frames** (built-in providers): Blizzard raid and party frames, ElvUI,
Grid2, Plexus, VuhDo, Cell (including Cell spotlight frames), Shadowed Unit Frames, TPerl,
Danders Frames (when enabled it replaces the Blizzard frames as the source), EnhancedQoL,
Buzzard Frames, NDui, GW2 UI, MSUF. Other addons can add their own frames through the public
API (see below). There is also a power-user path: saved variables named `Anchor1`,
`Anchor2`, ... holding global frame names are picked up as extra anchors.

**Arena frames**: sArena Reloaded (preferred when loaded), ElvUI arena frames, then
Blizzard's CompactArenaFrame.

**Portraits**: Blizzard, ElvUI, TPerl, UUF, MSUF, Ellesmere UI Unit Frames, EnhancedQoL.

**Nameplate addons**: MiniAuras draws on the game's nameplates, so it works alongside
BetterBlizzPlates, Platynator, Plater and similar. For plates resized by another addon, see
the Nameplates options Scale with Nameplate and Anchor to Health Bar.

**FrameSort**: listed as an optional dependency; MiniAuras rebuilds its frame-attached
displays when frames are re-sorted.

## Public API (for addon authors)

Global `MiniAurasApi.v1`, also reachable as `MiniCCApi.v1` (same table):

- `RegisterFrameProvider(provider)`: adds unit frames from another addon; they receive the
  same icons, cooldowns and glows as built-in sources (and Custom Auras "Unit Frames" groups
  land on them too). The provider needs a unique `Name` and a `GetFrames()` returning an
  array of frames, and may supply `RegisterRefreshFrames(cb)` so it can tell MiniAuras when
  its frame list changes.
- `RegisterVoicePack(pack)`: adds a TTS voice pack to the alerts Voice dropdown. Needs a
  unique, stable `Name`, a `Path` to a folder of OGG clips named exactly like the shipped
  packs (one per Important/Defensive spell name plus PreviewVoice.ogg, PreviewImportant.ogg,
  PreviewDefensive.ogg), and optionally `Locales` (list of client locales; omitted = offered
  everywhere). Returns false if the spec is unusable or the name is taken.
- `RegisterPredictedCallback(fn)` and `RegisterMatchedCallback(fn)`: fire when a friendly
  cooldown is predicted (buff detected) and when it is committed (buff ended, timer started).
  These belong to the Friendly Cooldowns tracker, so they only do anything on 12.0.

## Troubleshooting, by symptom

**"Nothing shows at all" / "module X does nothing".** First check the module's "Enable in"
row for the content type the user is in; most modules default off in battlegrounds and
raids, Alerts is also off in dungeons, Pet CC is off everywhere, Ally Kicks is on only in
dungeons. Remember: a battleground uses the Battlegrounds toggle and the Raids/Battlegrounds
setting group; the open world while in a raid group uses the Raid toggle. Then use test mode
(`/miniauras test`) to confirm the display exists and is on screen.

**"That setting/tab doesn't exist for me."** Check the game version split. On 12.1 there is
no Friendly CDs, Enemy CDs or Precognition tab, no CC Native Order, no MiniCE card, no class
colouring or system-voice TTS in Alerts, and no CENTER grow for Alerts. On 12.0 there is no
Personal Auras (Custom Auras) tab, no Trinkets tab, no Spells sub-tab or Show important on
Raid Frame Auras, no pandemic option, and no voice packs. The glow type list also differs.

**"Icons are drawn twice."** Either the old MiniCC addon is still installed alongside
MiniAuras (delete the MiniCC folder from AddOns and reload; settings are already copied), or
another addon draws the same auras. For doubled nameplate auras, make sure Configure
Blizzard Nameplates (Misc) is on, or disable the other addon's aura display.

**"A custom aura group shows nothing."** Usual causes: (1) it is in Spell IDs mode with an
empty spell list; (2) the spell ID added is the cast ID, not the aura the cast applies (the
Record button records cast IDs; find the aura's ID instead); (3) it is a Debuff group on
Self, My Pet or Unit Frames in Spell IDs mode, which the game forbids (switch to Aura
filters mode); (4) a caster filter (Cast by, From me or my pet, Applied by me) with the unit
in another instance or phase, where the game cannot attribute casters, so the group hides
until they return; (5) the group's unit names a side and the unit is currently on the other
side (buffs show only while friendly, debuffs only while hostile); (6) the group's own
Enabled toggle is off.

**"My starter Precog/Shroud/PI groups are gone."** Deleting them is permanent; they
are seeded only once per profile. Recreate them by hand, import them from someone else, or
reset the profile to defaults (Profiles > Reset).

**"Custom aura sound doesn't play."** The Sounds tab only exists for groups in Spell IDs
mode; filter-mode groups cannot have sounds (sounds register per spell ID engine-side). Also
check the trigger's sound is not "(None)" and check the chosen output channel's volume.
After an addon update, new audio files need a full client restart, not just a reload.

**"TTS voices missing / TTS not working."** On 12.1 TTS uses the shipped voice packs; Amy,
Anna Su and Jason Chen only appear on Chinese clients. On 12.0 important-spell TTS cannot
work for Mages, Evokers, Demon Hunters, Hunters and Shadow Priests (game limitation). Both
announce toggles default off.

**"Alerts don't show anything."** Alerts are read from enemy nameplates, so enemy nameplates
must be enabled in the game. Check Show icons, Show Defensives and Show Important, and the
Enable in row (off by default in battlegrounds, dungeons and raids). In arena the bars clear
during the preparation room.

**"Icons are not on my unit frame addon's frames."** Check the supported list above. If the
addon is not there, its author can add support with
`MiniAurasApi.v1:RegisterFrameProvider`. Sorting addons and frame addons that swap frames
are re-detected automatically.

**"Nameplate icons are the wrong size or position with BBP/Plater/etc."** Try
**Anchor to Health Bar** (for addons that change plate width/height) and check
**Scale with Nameplate** (for a differently sized target plate).

**"Trinket tracker shows nothing."** Party Trinkets only works inside arena, and it cannot
see trinkets used in the starting room. On 12.0 there is no Trinkets tab; the trinket icon
is part of Friendly Cooldowns (its "Trinket" checkbox).

**"Enemy kick tracker missing."** It only shows inside arena, and only if your role matches
its enable settings (Healer and Caster on by default; tick "Any" to force it for every
spec). Since 12.0.5 it cannot name the kicker: one generic icon with the enemy team's
shortest kick cooldown is expected behaviour.

**"Ally kick bars don't count down correctly in M+."** Expected: Blizzard hides who kicked
inside Mythic+, so rows last a flat 15 seconds. Only your own row ("Show self") shows a real
cooldown.

**"Bars/icons can't be moved."** Screen-anchored displays are dragged while test mode is on
(`/miniauras test` or the Test button). Ally Kicks bars are dragged while "Lock position" is
off. A custom aura group is dragged while it is selected in the editor (or in test mode),
and can also be positioned exactly with its Offset X/Y boxes.

**"Masque skin didn't apply / only some icons changed."** On 12.1 a skin is applied as each
icon is created, so reload after picking one. Bars, portrait icons and nameplate icons are
never skinned (see the Masque section). If a chat warning says Masque could not skin a group,
that group runs unskinned until the next reload.

**"High CPU usage."** Set Glow Type (Misc) to Slot Glow on 12.1 or Proc Glow on 12.0. The
animated glow styles keep animating idle icons.

**"Settings reset / different on this character."** Profiles are account-wide but
Auto-Switch rules are per character and per spec; check Profiles > Auto-Switch and the
active profile name. Switching specs can silently switch profiles if rules are set.

**"Language is wrong."** Misc > Language override; "Auto (client language)" follows the
game client. Changing it asks to reload the UI.
