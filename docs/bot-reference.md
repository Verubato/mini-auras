# MiniAuras Bot Reference

Reference for answering MiniAuras support questions: what each feature does, where every
setting lives, and what the defaults, ranges and limits are. Everything here is derived from
the addon source (`src/Config/Defaults.lua`, `src/Config/Panels/`, `src/Config/Config.lua`,
`src/Locales/enUS.lua`, `src/Modules/`, `src/Core/`, `src/Api/V1.lua`).

Addon version 5.34.0. Supported interface version: 120100 (patch 12.1). Author: Verz.
Discord: https://discord.gg/UruPTPHHxK. Website: https://verzaddons.com.

MiniAuras needs patch 12.1 or later. On 12.1 the game engine owns aura matching and display,
and addons cannot read aura data at all: MiniAuras sets up aura containers, filters and
engine-side sound registrations, and the game does the rest. That constraint is behind most
"why can't it do X" answers below, for example why a debuff cannot be tracked by spell ID on a
unit you can assist, and why a spell ID or a unit's class is never something the addon can
compare.

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
  starting with `!MiniCCAuras:1!` still import into Personal Auras.

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
- `/rl` reloads the UI, registered only if no other addon already defines it.

The window is built the first time it is asked for, and building it asks the client for keyboard
control, which combat refuses. So the first open of a session has to wait for the fight to end, and
a slash command in combat prints "The options window can't open during combat." instead. Once the
window exists it opens and closes in combat as normal.

The Interface > AddOns > MiniAuras entry is only a splash screen with the version and an
"Open Settings" button; all real configuration is in the standalone window. Since 5.15.0 the
addon list files MiniAuras under a **Mini** category, alongside the author's other addons.

**Test mode** draws fake icons on every enabled display so things can be positioned out of
combat. While testing, the Test button pulses and reads "Testing...". Screen-anchored displays
(Alerts, Healer, Enemy Kicks, Ally Kicks, screen-anchored personal aura groups) become draggable
during test mode. Since 5.19.0 a draggable container also opens a small position window when it
is clicked or when a drag ends, holding X and Y boxes with plus and minus buttons that step one
pixel at a time, for placements a drag cannot hit exactly. Clicking the same container again
closes it, and it closes on its own when test mode stops. Stand-in party/raid and arena frames are only created when no real frames are
visible, so testing in a group shows icons where they will actually be. Since 5.24.0 a stand-in is
sized from a real party frame rather than a fixed size: the first one on screen, else a frame
addon's own hidden ones, else Blizzard's, with Blizzard's standard (non-compact) party frames never
counted because they draw no auras. The arena stand-ins take the party size too. Each stand-in is
captioned with the module it previews unless **Show Test Labels** (Misc) is off. Test mode stops
automatically when combat starts. The World/Arena/Dungeons and Raids/Battlegrounds sub-tabs on
the CC and Important Auras pages also flip which of the two setting groups the test preview
uses. Since 5.16.0 that choice drives the "Enable in" check as well: previewing the
Raids/Battlegrounds tab from the open world asks whether the module is on for raids, so a
module switched off for the previewed context draws nothing. The zone still answers for
itself, so testing inside a battleground reads the Battlegrounds tick whichever tab is open.

## Settings window layout

Left sidebar, grouped under four headings. Bracketed names are the sidebar labels where they
differ from the page title.

**General:** Home, Personal Auras, Important Auras, Frame Auras, Alerts,
Nameplates, Portraits.

**Crowd Control:** CC, Pet CC, Healer, Trinkets (= Party Trinkets).

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

Player housing is the exception to all of it: a module carrying an "Enable in" row is off inside a
house, plot or neighbourhood whatever the checkboxes say (housing counted as a dungeon before
5.10.3). Test mode still previews there. Frame Auras has no such row and keeps drawing there. Its
missing buff mark reads a house as the open world, so the mark's "Instances only" switch holds it
back.

A module that "does not work" somewhere is usually just switched off for that content type.
Exceptions: Portraits and Party Trinkets have a single **Enabled** switch; Enemy Kicks is
enabled by role (see its section); Personal Auras has no module switch at all (each group has its
own Enabled toggle); Frame Auras has no content-type row either, and each of its parts carries its
own switch. Since 5.19.2 a module switched off is never set up at all, so it registers
no events and costs nothing, and switching it back on takes effect without a reload.

### Two setting groups per module

CC and Important Auras each keep two independent sets of appearance settings, shown as two
sub-tabs: **World/Arena/Dungeons** and **Raids/Battlegrounds**. The
raid set is used whenever you are in a raid group and not in arena (battlegrounds count,
because you are in a raid group there). Changing icon size on one tab does not change the
other.

### Anchoring

- **Screen-anchored displays** (Alerts bars, Healer, Enemy Kicks, Ally Kicks, screen-anchored
  personal aura groups) have a saved screen position and can be dragged while test mode is on
  (Ally Kicks instead uses its Lock position toggle; a selected personal aura group can be
  dragged without test mode).
- **Frame-attached displays** (CC, Pet CC, Important Auras, Frame Auras, Nameplate bars,
  Trinkets, frame/nameplate/arena-anchored personal aura groups) have an X/Y offset from the
  frame they hang off plus a **Grow** direction. Grow options vary by module:
  LEFT/RIGHT/CENTER/DOWN/UP for most frame-attached ones, LEFT/RIGHT/CENTER for nameplates,
  DOWN/UP for Ally Kicks, LEFT/RIGHT/CENTER for Alerts, LEFT/RIGHT/CENTER/LEFT_UP/RIGHT_UP for
  Frame Auras. Frame Auras offers no vertical grow: those wrap sideways on the live row and the
  preview cannot draw that, so the two would disagree the moment the icons filled a line.
- **Anchor** is a Frame Auras control and nothing else has one. It names which of the nine points
  of the unit frame the display hangs off (TOPLEFT, TOP, TOPRIGHT, LEFT, CENTER, RIGHT,
  BOTTOMLEFT, BOTTOM, BOTTOMRIGHT), and every other module pins its display to a corner the code
  chooses. The first icon sits on the Anchor point and the row grows away from it on both axes,
  so a row anchored to LEFT and growing LEFT sits outside the frame while the same anchor growing
  RIGHT runs back across it. The vertical half works the same way: LEFT_UP and RIGHT_UP stack a
  wrapped line upwards and so sit above the Anchor point, and LEFT, RIGHT, and CENTER stack
  downwards and sit below it. A row along the bottom edge of a frame therefore wants one of the
  two _UP grows, which is what both sides ship with. CENTER is the one grow that spreads both ways
  from the anchor rather than running off it. A row sitting on one of the three bottom points and
  stacking upwards is raised clear of the frame's power bar on top of its own Offset Y; a row that
  hangs below its anchor is already clear of the bar and takes no lift.

### Common icon options and ranges

Unless a module's table below says otherwise: Icon Size slider 10-100 px, Icon Padding
(spacing) 0-20 px default 2, Offset X/Y sliders -250 to 250 default 0. Frame Auras is the
exception on both: its offsets run -50 to 50, and the padding on its two aura rows 0-5
default 1, because a compact unit frame is small enough that a wider range would only ever
throw the row off the frame it belongs to. Frame-attached displays with a **Relative size** checkbox size icons as a percentage of the unit frame's
height instead of pixels (Icon Size (%) slider, 25-100). Most displays also share: Glow
icons, Reverse swipe (reverses the cooldown swipe animation), Show tooltips (spell tooltip on
hover), a Font Scale slider (0.5-2.0, step 0.05, default 1.0) for that module's countdown text,
and a colour rule.

Since 5.14.0 every slider in the settings window has its own hover tooltip explaining what it
does, so "what does this slider do" is answerable in the UI. The **Max Icons** one also says
the limit applies to each aura category on its own, which is why a unit showing defensives and
important buffs can show that many of each; the game no longer lets addons count auras, so one
shared limit across categories is not possible.

### Changing a look in combat

Icon size and style are baked into an icon when it is created, and while aura data is secret
(in combat, and out of combat inside M+, encounters and rated PvP) the game will not let an
existing icon be restyled. So a size or style change made then is stored and applied on its own
within a second of the restriction lifting, and since 5.19.0 the addon says so once in chat:
"Icon size and style changes will apply when combat ends." It is said once per fight, not once
per slider step, and test mode is exempt because it draws its own icons and shows the change
immediately.

A row that has no icons yet is the exception, since there is nothing on it to restyle. It takes a
new size straight away even while auras are secret, which is what lets a frame aura row built
during a reload in an arena come out the right size instead of waiting for the match to end.

Everything else, budgets, colours, positions, growth direction, and switching a module or a
category on or off, applies in combat as normal.

### Colouring rules

- **Dispel colours** (Healer): glow/border coloured by the debuff's dispel type
  (for example blue for magic).
- **Dispel colours + category tints** (Important Auras, where the switch is called **Colours**, and
  Nameplates, where since 5.19.0 it is the three-way **Icon colours** dropdown): CC icons take
  the dispel type's colour,
  which the game has no equivalent of for a buff, so defensive and important icons take the
  two colours picked for the module instead. Important Auras keeps its pair on a **Colours**
  sub-tab, Nameplates on its **Settings** sub-tab; both are module wide rather than per bar or
  per setting group. Turning it off, or picking None on nameplates, puts every icon back on a
  plain white glow, and nameplates can also pick Custom to use the two module colours without
  the dispel palette. On
  Nameplates, CC auras with no dispel type (stuns, disarms) keep the border too, coloured to
  match their glow, instead of showing glow only (since 5.10.2). Party and raid frame CC icons
  do the same (since 5.12.2), on the live icons and the previews.
- The ring those colours are painted onto is the addon's own art since 5.33.3, redrawn from the
  client's debuff overlay so it reads smooth at icon sizes instead of pixelated. There is
  nothing to configure about it.
- **Icon colours** (CC, Pet CC, since 5.34.0): the same three-way dropdown as Nameplates,
  replacing the old boolean **Dispel colours** tick. **Dispel colours**, the default, paints
  each crowd control icon in the game's colour for its dispel type. **Custom** drops the dispel
  palette and uses a single **CC colour** swatch instead, shown on the page only in this mode.
  **None** leaves the icons uncoloured, drawing neither the glow tint nor the border ring. A
  profile saved before 5.34.0 reads back as Dispel colours where the tick was on, and Custom
  where it was off.
- **Per-category tints** (Alerts): a colour swatch each for Important and Defensive, with no
  dispel colouring to share the switch with. They colour whichever ring is drawn, so they need
  **Glow icons** or **Show border** on; with both off the two swatches are hidden, having
  nothing left to tint. **Show border** (since 5.16.0) is for keeping the colouring with the
  glow switched off: it draws nothing while the glow is on, since two rings in the same colour
  around one icon only smudge each other.
- Every pair defaults to red (1, 0.2, 0.2) for Important and green (0.2, 1, 0.2) for
  Defensive. Class colouring is not on offer anywhere, because a unit's class is not something
  the addon can read from an aura container.
- **Flat colour** (Trinkets, Enemy Kicks, Personal Auras): the user picks one colour for the
  glow and border, because these icons carry no category to derive one from. Personal Auras
  carries a second, independent **Text colour** for its countdown, stack count and bar spell
  name; see its Appearance tab.

### Glow Type (global, under Misc)

One glow style for the whole addon, default **Slot Glow**. Since 5.20.0 the full list is just
**Slot Glow** and **Static Pixel Border**, and the settings page says so under the dropdown.

- The animated styles (Rotation Assist Clockwise and Anti-clockwise, Ants, Twins, Mirror,
  Twins Mirror) were removed in 5.20.0 because they cost FPS. An aura container pre-creates far
  more buttons than it ever shows, a looping animation is evaluated every frame even on a hidden
  button, and 12.1 leaves no way to gate an animation per icon, so the cost could not be limited
  to icons anyone can see.
- A profile holding one of the removed styles renders as Slot Glow, with the saved value left
  alone. Nothing else in the profile changes.

### Font (global, under Misc, since 5.17.0)

One font face for every piece of text the addon draws: countdowns, stack counts, bar spell
names, the healer warning text and the test-mode captions. Default **Game Default**, which is
not a face of its own - each piece of text keeps whatever the game gives it, which is not one
font (countdowns come from the game's number font, names from its normal one).

- The list comes from LibSharedMedia, so it holds the client's own fonts plus whatever font
  packs and other addons have registered. Nothing is registered by MiniAuras itself.
- A font whose media addon has not loaded yet resolves to nothing rather than to a stand-in,
  so the text keeps the game font for a second or so and swaps once the addon registers it.
  The same applies to a font from an addon that has since been uninstalled.
- Fonts the client cannot draw with are left out of the list. LibSharedMedia also hides fonts
  that do not declare support for Korean, Russian or Chinese on those clients, so the list is
  already free of faces that would render the game's own text as boxes.
- Changing it takes effect immediately, with one exception: while aura data is secret (in
  combat, and also out of combat inside M+, encounters and rated PvP) the aura icons cannot be
  restyled, so their text swaps within a second of the restriction lifting. Text that is not
  drawn on an aura icon changes straight away.

### Sounds

Fourteen sounds ship with the addon: AirHorn, AlertToastWarm, BubblePop, CheerfulHarp,
CinematicHit, ElectricalSpark, Error, NewNotification09, Notification18, Notification38,
Sonar, SuddenShock, WatchOut, WhooshSwing. A fifteenth, XiaYike, is offered only on Chinese
(zhCN/zhTW) clients. All are registered with LibSharedMedia, so any sound another addon
registers there is also selectable, and other addons can use MiniAuras's sounds. Each row in a
sound list names the addon its file came from in parentheses, since several packs ship
different sounds under the same name. LibSharedMedia also carries entries registered as a sound
kit id rather than a file; the game's aura sound registration takes a file path and refuses a
number, so those are left out of the lists entirely. If a saved sound comes from a media addon
that was uninstalled, it falls back to Sonar. A media addon that loads *after* MiniAuras is
waited for instead: the aura stays silent for a second or so rather than firing the fallback,
then registers with the right file. Alert sounds play the default until that addon arrives and
then switch to the file it brought. Sound settings have an output channel dropdown: Master,
Sound Effects (SFX), Music, Ambience, or Dialog, default Master. Aura sounds work everywhere,
but the game blocks the registration call while you are in combat inside instanced PvE, so a
sound first wanted mid-pull in a dungeon, raid, delve, or scenario starts working once that
pull ends.

### Countdown text

- **Colour Countdown** (Misc, off by default): timer text is coloured by the time remaining.
  Each of the three bands has its own swatch under **Countdown Colours** (Misc, since 5.11.0),
  defaulting to red in the last five seconds, yellow under a minute, and white above. A
  personal aura group with **Colour text** on ignores this and keeps its own text colour.
- **Milliseconds**: displays with a "Milliseconds" checkbox (CC, Pet CC via CC path,
  nameplate bars, Personal Auras) show decimal seconds once the remaining time drops below the
  **Milliseconds Threshold** (Misc, 1-6 s, default 5).
- **Font Scale** (0.5-2.0, step 0.05, default 1.0) scales one module's countdown
  text without touching its icon size. It is a per-module slider on its own page rather than one
  global value: Pet CC, Healer (labelled **Icon Text Scale** there, so it is not confused with
  the warning line's **Text Size**), Nameplates, Alerts, Portraits, Party Trinkets, Ally Kicks,
  and Enemy Kicks. CC and Important Auras carry one per sub-tab, beside that tab's Icon Padding.
  Frame Auras carries one per row and Personal Auras one per group.
- **Font** (Misc, since 5.17.0) sets the face that text is drawn in; see "Font" above.
- **Disable Swipe** (Misc, off by default) removes the cooldown pie animation everywhere;
  timer text stays. The swipe is drawn at 70% black since 5.21.0, a little lighter than before,
  so the icon art stays readable underneath it.
- **Disable Numbers** (Misc, off by default, since 5.23.0) is the other half of that pair: it
  drops the countdown text on every aura icon and leaves the swipe drawn. It also overrides a
  module's own numbers switch, such as the one on each Frame Auras row. Two things keep their
  text: a personal aura group whose Display is **Text only**, where the countdown is all there is
  to draw, and the Ally Kicks bars, which run their own clock rather than an icon's. It changes
  how an icon is built, so in combat it lands within a second of the fight ending; see "Changing
  a look in combat".
- **Zoom Icons** (Misc, on by default) crops the silver border Blizzard bakes into spell icon
  art, so the icon sits flush inside the addon's own border. Turning it off shows the stock
  art with its border. The crop is applied as an icon's frame is built and the frames are
  pooled, so the option prompts for a UI reload; icons already on screen keep the old crop
  until then. It does not touch portrait icons, whose inset is there to fit the portrait's
  shape, or icons skinned by Masque, where the skin owns the crop.

---

## Personal Auras

Sidebar: General > Personal Auras. Page title "Personal Auras". User-built "mini weak auras":
icons, bars or a piece of the game's own proc art (with optional sound) for buffs on allies and
debuffs on enemies, or a sound on its own with nothing drawn at all.

### Groups

The page shows a grid of group tiles plus a leading `+` tile ("New Personal Aura"). Click a tile to
edit that group in the editor below ("Selected Aura"); click empty grid space to deselect.
Nothing is selected when the page opens, and the editor only exists while something is: until
then the lower half reads "Click an aura above to change its settings." (since 5.14.0), or
"No groups yet. Click + to track your first buff." beside the `+` tile on an empty grid.
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

A new profile is seeded once with two groups, both centred 80 px above screen centre with glow
and border on. Up to 5.15.0 they were seeded in a row 300 px above centre, 50 px apart:

| Group | Spell | Sound | Tint |
|---|---|---|---|
| Precog (Precognition) | 377362 | ElectricalSpark on apply | none (white) |
| Shroud (Nullifying Shroud) | 378464 | none | purple (0.64, 0.21, 0.93) |

Seeding happens once per profile (a SeededDefaults flag), so deleting them is permanent, and
a profile that predates them gains them on the next load.

A third starter group, **PI** (Power Infusion, 10060, BubblePop on apply, gold), shipped up to
5.13.0 and was dropped in 5.14.0. Profiles that already have it keep it, since seeding never
runs twice; only profiles created from 5.14.0 on go without. A profile upgrading from a
pre-12.1 version still gains one, because the migration that builds the starter groups from
the old Precognition module's settings is frozen at what that release shipped.

### Trigger tab

- **Unit** (what the group watches, and what it anchors to; the anchor is derived from the
  unit, never chosen separately):
  - **Self** - the player. Screen-anchored.
  - **My Pet** - your pet. Screen-anchored.
  - **Tank** / **Healer** - the first group member in roster order holding that role
    (includes you). Screen-anchored.
  - **Other DPS** - the first DAMAGER in roster order that is not you. Screen-anchored.
  - **Raid Frames** - one copy of the group on every party/raid frame (including frames from
    external frame providers).
  - **Arena Frames** - one copy per enemy arena frame. Debuffs only.
  - **Friendly Target** / **Enemy Target** - your target; only shows while the target is on
    that side. Screen-anchored.
  - **Friendly Focus** / **Enemy Focus** - your focus; only shows while the focus is on that
    side. Screen-anchored.
  - **Friendly Nameplates** / **Enemy Nameplates** - one copy on every matching nameplate.
    These copies follow the plate's scale while the Nameplates option Scale with Nameplate is
    on. Every other unit choice always draws at absolute pixel size.
  - (Groups saved with the older unit focus are migrated to the matching focus choice; target,
    targettarget, and nameplate still migrate to the matching target or nameplate choice.)
- **Display**: **Icons**, **Bars**, **Texture**, **Text only** or **Sound only**. First on the row,
  because it decides what the rest of the row may offer (see Sound only below). The first four are
  the drawn shapes; see the Appearance and Layout tabs.
- **Aura Type**: **Buff** or **Debuff**. The dropdown is hidden when the unit allows only one
  type, and for a Sound only group, which does not care. Target, focus, and nameplate units
  allow only the type matching their side (buffs on friendly, debuffs on enemy); Arena Frames
  allows only debuffs.
- **Type**: **Spell IDs** or **Aura filters** (the two tracking modes). Hidden for a Sound only
  group, which is always Spell IDs.
- **Show when**: **Always** (the default), **In combat** or **Out of combat**. On a row of its own
  under the four above, since those already fill the width. The whole group is held back while the
  player's combat state does not match, its sounds included. Test mode ignores it, so a preview
  always draws. Groups saved before this option have no field and read as Always.

**The spell-ID rule (why some combinations are refused).** The game only honours a spell-ID
filter for helpful auras on units you can assist, and for harmful auras on units you cannot;
anywhere else the ID list is silently ignored and the group would match everything. So in
Spell IDs mode, debuffs cannot be tracked on Self, My Pet or Raid Frames (all always
assistable), and the editor says so in red: "Debuffs cannot be tracked on yourself or your
pet." / "Debuffs cannot be tracked on group members." Switching to Aura filters mode makes
debuffs on those units legal, because filter strings apply regardless of side. Yellow
caveats: "Buffs are only shown while the unit is friendly." / "Debuffs are only shown while
the unit is hostile." for the target, focus, and nameplate choices.

**Spells listed in red** (since 5.13.0). A tracked spell whose own aura lands on the other
side to the group's Aura Type is drawn red in the spell list, with a line under it saying
"Spells shown in red are buffs, which don't work on enemy units." or "Spells shown in red are
debuffs, which don't work on friendly units." It is a warning, not a refusal: the spell stays
in the list. The check comes from the client's own flag for the spell, so a spell the client
says nothing about is never marked.

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
- A group holds at most **200 spells** ("A group can hold at most 200 spells."), no
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
have an appearance." and no controls. **Display** itself lives on the Trigger tab. A **Texture**
group shows its own short set of controls instead of the ones below: **Select Texture** with a
preview beside it, **Additive**, **Mirror**, **Desaturate**, and the **Colour** swatch, which
tints the art. A **Text only** group drops the five switches that are about an icon's art and
swipe (Reverse swipe, Hide swipe, Hide numbers, Centre stacks, Custom icon) and keeps the rest.
Everything else here belongs to icons and bars.

| Setting | Values / range | Default |
|---|---|---|
| Bar Texture | any shipped/LibSharedMedia bar texture (bars only) | Blizzard Raid Bar |
| Glow icons | on/off (icons only) | off (starter groups: on) |
| Show border | on/off | off (starter groups: on) |
| Reverse swipe | on/off (icons only) | on |
| Hide swipe | on/off (icons only) | off |
| Hide numbers | on/off (icons only); drops the countdown text | off |
| Centre stacks | on/off (icons only); the stack count replaces the countdown | off |
| Show tooltips | on/off | off |
| Spell name | on/off (bars only) | on |
| Custom icon | on/off (icons and bars only); draws the group's own icon over each spell's art | off |
| Pandemic | on/off | off |
| Milliseconds | on/off | off |
| Colour (glow/border tint, or the bar's fill) | colour swatch | white |
| Pandemic colour | colour swatch | red (1, 0.1, 0.1) |
| Colour text | on/off | off |
| Text colour | colour swatch | white |

**Display** (on the Trigger tab) decides the shape of the whole group. A **Bars** group draws a
horizontal bar per aura: the spell icon at the left, the spell name and the countdown inside the fill, and the
fill draining as the aura runs out. Stacks, dispel colouring and the pandemic reveal work on
icons and bars; the glow does not (the styles are drawn for a square, so the option is hidden for
bars). The shape is baked into a display when it is built, so switching it swaps the group onto
a different set of frames, and a switch made while the game is hiding aura data (inside an
arena) may not show until the match ends.

**Text only** (since 5.23.0) is the icon shape with the art and the swipe left out, so the
countdown is all that is drawn. It keeps the glow, the border, the tooltip, the pandemic reveal
and the group's own **Colour text**, and it takes the Layout tab's icon controls, **Icon Size**
included. The countdown is never dropped: the group's **Hide numbers** and **Centre stacks** are
hidden for it, and the global **Disable Numbers** in Misc leaves it alone, because a text-only
group with no text would show nothing at all. Masque skins nothing here, since there is no icon
art for a skin to fit.

**Texture** (since 5.15.0) draws one piece of art while any tracked aura is up, instead of an
icon per aura. It is decoration hung beside a unit rather than a row of squares, so it carries
none of the icon chrome: no countdown, no stack count, no cooldown swipe, no glow, no border, no
pandemic reveal, no tooltip (the art stands for the whole group rather than for one aura), and no
Masque skinning. One picture however many auras match, so **Max Icons** does not apply and the
preview is a single stand-in. Which aura is up is secret on 12.1, so art that changed per spell
could not be chosen anyway: the group is the picture, and the game showing it is what says a
tracked aura is there.

Texture controls, on the Appearance tab:

| Setting | Values / range | Default |
|---|---|---|
| Select Texture | opens the texture browser; a preview sits beside the button | Maelstrom Weapon |
| Additive | on/off; adds the art's colour to what is behind it, which is what the game's overlay art expects | on |
| Mirror | on/off; flips the art left to right (applied before the rotation) | off |
| Desaturate | on/off; draws the art in grey | off |
| Colour | swatch; tints the art | white |

**Texture browser** ("Choose a Texture"): a grid of the game's proc overlay art (Backlash, Brain
Freeze, Maelstrom Weapon, Rime and so on, 21 pieces), each drawn over black because that is what
the art was made for, with a **Search** box narrowing the list as it is typed and a count at the
bottom. The list is deliberately short, and the **Texture path** box below the grid is the way out
of it: typing any texture path the client has, or an atlas name, uses that instead, including a
file another addon ships. **Reset** clears the art, and a texture group with no art draws nothing
(it counts as still being built, like a spell list with nothing in it). A build that never shipped
one of the listed files drops it from the browser rather than offering an empty square.

**Pandemic** highlights an aura during its refresh window (where re-casting adds the
remaining time on top). The game decides the window per spell, and only your own re-castable
effects have one.

**Centre stacks** (since 5.12.0) puts the stack count in the middle of the icon and drops the
countdown text it stands in for, for auras watched by how many stacks are up rather than how
long is left. Icons only: a bar draws its countdown at the end of the fill, where the count
never sits. The game still decides when a count is drawn at all, so an aura that never stacks
shows no text either way.

**Colour text** (since 5.12.0) applies the group's **Text colour** to the countdown, the stack
count and a bar's spell name. It also replaces the global **Colour Countdown** ramp for that
group, so one group can hold a fixed colour while the rest of the addon colours by time
remaining. With it off every text keeps its default white and the global setting applies as
normal. The swatch holds the colour either way, so it can be picked before the toggle is on.

### Layout tab

Empty for a **Sound only** group, for the same reason: the tab shows "Sound only auras don't
have a position." and no controls.

| Setting | Values / range | Default |
|---|---|---|
| Order | Oldest first / Longest remaining first / Shortest remaining first | Oldest first |
| Grow | LEFT / RIGHT / CENTER / DOWN / UP | CENTER |
| Strata | Automatic / BACKGROUND / LOW / MEDIUM / HIGH / DIALOG / FULLSCREEN / FULLSCREEN_DIALOG | Automatic |
| Offset X / Offset Y | typed number boxes, clamped to -2000..2000 | screen groups: 0 / 220 above centre; nameplate groups: 0 / 40 above the plate; unit frame and arena frame copies: 0 / 0 |
| Icon Size | 10-200 (icons only) | 40 |
| Bar Height | 8-50 (bars only) | 20 |
| Bar Width | 40-250 (bars only) | 150 |
| Texture Width / Texture Height | 8-400 (texture only) | 64 / 64 |
| Rotation | 0-359 degrees clockwise (texture only) | 0 |
| Opacity (%) | 0-100 % (texture only) | 100 |
| Icon Padding | 0-50 | 2 |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 |

A **Texture** group keeps only Texture Width, Texture Height, Rotation, Opacity, Strata and the
offsets: one picture has no order to sort into, no direction to grow in, no spacing between
copies, and no text to scale, so those four controls are hidden and the row closes up around them.

Dragging the icons or bars on screen writes the same values the Offset X/Y boxes edit, and the
boxes update when the drag ends.

**Font Scale** (since 5.14.0) scales this group's countdown, stack count and bar spell name
rather than setting a point size: every text on an icon or bar is measured off that shape.
Hidden for a Sound only group along with the rest of the tab.

**Strata** is the layer the group draws in, for a group that has to sit over or under something
else on screen. Automatic uses the layer of whatever the group hangs off, which is UIParent's
MEDIUM for a screen group and the plate's or unit frame's own layer for a copy on a frame; that
is what every group did before the setting existed. TOOLTIP is not offered, because a group
there would cover the tooltips its own icons raise.

### Sounds tab

Only shown for Spell IDs groups (the engine registers sounds per spell ID, which a filter
group does not have). Three independent sound pickers, each any shipped/LibSharedMedia sound
or "(None)" (default None): **When applied**, **When it gains a stack**, **When removed**;
plus one **Channel** (Master / SFX / Music / Ambience / Dialog) for all three. Sounds are
played engine-side, so they fire even though the addon cannot read the aura.

For a **Sound only** group this tab is the whole feature. Such a group needs spells and at
least one sound to do anything; with neither it simply does nothing, and the editor says
nothing about it (an unfinished group is not a misconfigured one). Sound only groups on the
**Raid Frames** unit follow the roster rather than the frames on screen, so they work with the
party frames hidden and cover you as well as your group; the target, focus, and nameplate
choices still only fire while the unit is on the side the choice names.

### Limits

- Max 200 spells per group.
- Max 40 icons or bars shown per group; 3 preview stand-ins while positioning. A texture group
  draws exactly one picture, with one stand-in.
- Icon size 10-200, bar height 8-50, bar width 40-250, texture width/height 8-400, rotation
  0-359, opacity 0-100 %, spacing 0-50, font scale 0.5-2.0, offsets typed up to +/-2000.

---

## Important Auras

Sidebar: General > Important Auras. Shows auras on party and raid
frames. The tracked helpful auras are chosen by spell ID from a curated list, so anything can
be tracked, including spells the game never flags.

Enable in (defaults): World on, Arena on, Battlegrounds on, Dungeons on, Raid off.

Two setting groups (World/Arena/Dungeons and Raids/Battlegrounds sub-tabs):

| Setting | Range | Default (W/A/D) | Default (Raids/BGs) |
|---|---|---|---|
| Exclude self | on/off | off | off |
| Glow icons | on/off | on | on |
| Colours | on/off | on | on |
| Reverse swipe | on/off | on | on |
| Show tooltips | on/off | off | off |
| Show important | on/off | on | on |
| Show defensives | on/off | on | on |
| Show CC | on/off | off | on |
| Show interrupts | on/off | off | on |
| Relative size / Icon Size (%) | 25-100 % | 75 | 65 |
| Icon Size | 10-100 px | 20 (30 before 5.16.0) | 20 (25 before 5.23.0) |
| Max Icons | 1-5 | 3 | 3 |
| Icon Padding | 0-20 | 2 | 2 |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 | 1.0 |
| Grow | LEFT/RIGHT/CENTER/DOWN/UP | CENTER | CENTER |
| Offset X / Y | -250..250 | 0 / 0 | 0 / 0 |

- "Show important" shows the curated important buffs (for example offensive cooldowns). It and
  "Show defensives" pick which curated lists reach the display rather than switching a display
  off, because a curated spell can belong to both categories; with both off nothing helpful is
  shown.
- Defensives and importants are drawn by separate aura groups, so each can take its own colour
  and each gets the full **Max Icons** budget. With both categories on and Max Icons at 3, a
  frame can show up to three of each rather than three in total. CC has always had its own
  budget on top.
- "Show interrupts" shows an icon when a friendly unit gets interrupted.

**Colours sub-tab.** Two swatches, **Important** (default red) and **Defensive** (default
green), applying to both setting groups. They only take effect while the **Colours** checkbox
is on for the setting group in question; see "Colouring rules" above. A spell added by hand in the Spells
sub-tab's Custom section belongs to neither category, so it is drawn with the importants and
takes the Important colour.

**Spells sub-tab.** "Specify which spells are shown on raid frames." A sidebar of
sections: one per class, then General (classless spells such as PvP gem effects), then
Custom. Each spell is a checkbox with its icon and ID. Some curated spells ship switched off
and are an explicit opt-in. Custom spells are added in the Custom section via the "Add a spell"
picker, which suggests up to eight matches as you type a name and still takes a whole id nothing
matched. They are removed with the cross button. Only differences from the curated list are saved,
so an updated curated list still reaches existing profiles.

---

## Frame Auras

Sidebar: General > Frame Auras. Draws the auras on Blizzard's own party and raid frames, in place
of the ones the game puts there. Separate from Important Auras, which adds a row of tracked CC and
defensive icons on top of whatever else is on a frame; this one **replaces** what Blizzard draws.

No "Enable in" row: these stand in for frames the game draws everywhere, so they are on or off
everywhere. Four sub-tabs. The first three each carry their own switch, and **all three ship switched off**; Spells is the buff whitelist the Buffs tab filters against.

A fourth part, the target and focus rows, is built but held back and has no sub-tab: it needs the
icon cap to sit on the aura container rather than on each group inside it, which arrives in 12.1.5.

**Buffs sub-tab.** Replaces the buff row on the party and raid frames, shipping in the bottom right
corner growing left and wrapping upward. The Anchor, Grow, and Offset X/Y controls move it
anywhere on or around the frame. Blizzard's **compact** frames only, since those are the ones the
cvar below controls; a player on the standard (non-compact) party frames sees no change here, and
none at all if DandersFrames has replaced the compact frames outright. Switching it on remembers the `raidFramesDisplayBuffs` cvar and sets it to 0;
switching it off puts the remembered value back. The cvar is only written when the switch actually moves, so a player who
turned Blizzard's buffs off themselves never gets them handed back. The write waits for combat to
end, because flipping it makes the client rebuild the raid frames.

- Icon size 15-50 (percent of the frame's own height, default 35), max icons 1-9 (default 6),
  icons per row 1-6 (default 3), icon padding 0-5 (default 1), font scale 0.5-2.0 (default 1.0).
- **Filtered** (on) - show only the spells ticked on the Spells tab. Off shows every buff that gets
  past the other filters.
- **Mine** (on) - only the buffs you cast yourself.
- **Under 1min** (off) - only buffs whose whole duration is under a minute, which drops raid buffs
  and flasks.
- **Important** / **Defensives** - let those two flagged categories into the row. Both off by
  default, because the Important Auras page already draws its own row of them and two rows showing
  the same icon is the thing this avoids. Done by negating the game's own filter token
  (`!IMPORTANT`, `!BIG_DEFENSIVE`, `!EXTERNAL_DEFENSIVE`), which is the only filter weighed on
  every unit.
- **Show numbers** (off) - the countdown text on this row alone. The cooldown swipe stays either
  way, and the global **Disable Numbers** in Misc still takes the text off everywhere.
- **Centre stacks** (off) - draws the stack count in the middle of the icon at countdown size,
  which takes the countdown's place whatever **Show numbers** is set to.
- **Reverse swipe** (on) - reverses the direction of the cooldown swipe animation.
- **Pandemic glow** (on) plus a **Glow colour** (green, 0.1/0.9/0.3) - lights a heal-over-time up as
  its refresh window opens. Which spells carry it is fixed (Lifebloom), not a per-spell setting: the
  reveal is registered on a button when the engine builds it.

**Debuffs sub-tab.** Replaces the debuff row, shipping in the bottom left corner growing right and
wrapping upward, and carrying the same Anchor, Grow, and Offset X/Y controls as the buff row.
Drives `raidFramesDisplayDebuffs` the same way the buff side drives its own cvar. The row is
ordered by the game itself, because an aura's spell id is secret and nothing can reorder a group
once it has rendered. The game's own boss and role auras lead the row, drawn 40% larger than
the rest of it and capped at two icons on their own budget. There is no switch to hold the group
itself back: a debuff like Unstable Affliction has to be seen before anything else on the frame.
Crowd control is the one thing the **Crowd control** switch reaches there too: with the switch off, a
boss or role flagged crowd control debuff is kept off the row like any other, and with it on the
switch also opens a group of its own behind the lead group.

- Icon size 15-50 (percent of the frame's height, default 35), max icons 1-9 (default 2), icons per
  row 1-6 (default 3), icon padding 0-5 (default 1), font scale 0.5-2.0 (default 1.0).
- **Dispellable by me** (on) and **Dispellable by raid** (off) - only the debuffs your own spec, or
  respectively somebody in the group, can dispel. Mutually exclusive in the config UI: ticking one
  clears the other, and switching the active one off leaves both off rather than turning the other
  on, which is the state where neither narrows the row. A hand-edited save or an imported profile
  can still carry both true; the raid half, being the superset, is the one that then narrows the
  row. Either switch exempts the crowd control group behind the lead group, since a spec's
  inability to dispel a stun is not a reason to hide it.
- **Under 1min** (on) - only debuffs whose whole duration is under a minute. Setting a bound at all
  also drops the debuffs that never run out.
- **Crowd control** (off) - gives crowd control a group of its own behind the boss and role auras,
  drawn 40% larger than the rest of the row and capped at two icons on its own budget, and lets
  a crowd control debuff into the boss and role group ahead of it. Off by default for the same reason
  as the two on the Buffs tab.
- **Dispel colours** (on) - rings every group on the row in the game's colour for its dispel
  type. A debuff the game gives no type at all, such as a physical stun, is ringed too, in the
  game's untyped colour, which is red.
- **Show numbers** (off) - as on the Buffs tab.
- **Centre stacks** (off) - as on the Buffs tab.
- **Reverse swipe** (on) - as on the Buffs tab.

**Font Scale** on either tab scales that row's countdown and stack count, and the target and focus
rows carry the same slider on their own tab once that part is switched on.

The Under 1min switch is about the row rather than a category of it, so a stun that has run past
a minute is dropped exactly as a debuff would be. The boss and role partition at the head of the
row always narrows it, whatever that switch is set to.

**Missing Buff sub-tab.** Marks a party or raid frame whose member is missing the group buff your
class brings (Mark of the Wild, Blessing of the Bronze, Arcane Intellect, Power Word: Fortitude,
Skyfury, and Battle Shout). The mark is the buff's own icon, drained of colour, shipping in the
frame's top right corner. Unlike the two rows above it, this also reaches the standard party
frames, since it adds a mark rather than replacing anything. A class that brings no group buff
sees a line saying so and nothing to configure.

- **Instances only** (on) - only marks a frame inside an instance, where a missing group buff costs
  something. A house counts as the open world.
- Icon size 15-50 (percent of the frame's height, default 35), plus the same Anchor and Offset X/Y
  controls the two rows carry. No Grow: one mark per frame has nothing to run in.

The held-back target and focus part has icon size 12-40 px (default 22), max icons 1-12 (default
6), icons per row 1-12 (default 6), and font scale 0.5-2.0 (default 1.0).

**Spells sub-tab.** The buff whitelist the Buffs tab's **Filtered** switch draws from; with that
switch off, every buff reaches the corner. A sidebar of sections, one per class that has tracked
heal-over-time or shield spells, then Custom. Each spell is a checkbox with its icon. Custom spells
are added in the Custom section via the same "Add a spell" picker Important Auras uses, and removed
with the cross button. Only differences from the curated list are saved, so an updated curated list
still reaches existing profiles.

Since 5.26.0 a row is built on every compact frame the client has, shown or not, so it is already
there when a frame appears. The crowd control group at the head of the debuff row is the one part
held back: it is only given a budget while the unit is visible, because out of sight the game
stops weighing the crowd control token and the group would fill with unrelated debuffs.

**Test mode.** The Test button previews all three parts at once. The preview follows the category
switches: turning crowd control on puts a stun at the head of the debuff row, drawn 40% larger
and ringed the way the live one would be, and turning it off takes it back out, so each switch
visibly does something. On 12.1 an aura container is
engine-driven and cannot be handed fake auras, so the preview is a separate row of stand-in icons
drawn in the same corner at the same size, with the live row hidden behind it. Only a switched-on
part previews anything. Outside a group it draws on the stand-in party frames test mode puts up.
This row carries no caption of its own, since it draws inside a frame that already has one.

Icons here go through the same rendering as every other module, so the global Miscellaneous
settings (font, icon zoom, cooldown swipe, countdown colours) and Masque skins apply. The Masque
sub-group is called "Frame Auras".

---

## Alerts

Sidebar: General > Alerts. A movable screen bar showing enemy defensive spells and important
spells (for example offensive cooldowns, Precognition) as they are used, with optional sound
and text-to-speech. It reads enemy nameplates, so alerts require enemy nameplates to be
active, except in 2v2 and 3v3, where since 5.19.0 it reads the arena unit tokens instead and
needs no plates at all; bigger brackets and everywhere else stay on nameplates. Since 5.19.0
alerts are only tracked on other players, so an NPC's nameplate never gets a bar. The important category is read from Blizzard's nameplate buff lists across every
active enemy. In arena, the bars reset when a new round's preparation room starts.

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
| Show border | on/off (since 5.16.0) | off |
| Reverse swipe | on/off | on |
| Class colours | on/off (since 5.19.0) | on |
| Important colour | swatch (applies while Glow icons or Show border is on, and while Class colours is off) | red (1, 0.2, 0.2) |
| Defensive colour | swatch (applies while Glow icons or Show border is on, and while Class colours is off) | green (0.2, 1, 0.2) |
| Grow | LEFT / RIGHT / CENTER (since 5.27.0) | CENTER (RIGHT before 5.27.0) |
| Icon Size | 10-100 | 50 |
| Max Icons | 1-10 | 8 |
| Icon Padding | 0-20 | 4 (2 before 5.16.0) |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 |

**CENTER** (since 5.27.0) splits the row either side of the anchor instead of running it off
one edge, and is the new default. The dropdown shows it as **CENTER-ish**, in English whatever
the client language, since LEFT and RIGHT show their raw values beside it. The name is hedged
because the alignment is not pixel perfect, which the tooltip beside the control says too. A
profile still on RIGHT, the old default, is moved onto it on upgrade, while anyone who picked
LEFT keeps their choice. It applies to the arena bars only, because a centred row on nameplates
would shift across the screen every time a plate appeared or left. A profile holding UP or DOWN
from an older version reads back as RIGHT, because the row is horizontal.

**Class colours** (on by default) tints every icon in the owner's class colour instead of the
two category colours, which is what makes a row readable at a glance in an arena. It needs the
client to name the enemy's class: on a nameplate that is read directly, and on an arena token,
where the class itself is secret, it comes from the opponent's specialisation once the client
reports it. Where neither answers, the icon keeps the category colour. The two colour swatches
are ignored while it is on.

Positions (dragged in test mode): combined bar centred, 150 px below the top of the screen.
**Split bars** gives important spells their own separately movable bar: defensives default
220 px left of centre, important 220 px right, same height.

**Sound Alerts sub-tab:** "Plays a sound when an enemy presses an important or defensive
spell." Separate opt-in per category: **Important Spells** (default file AirHorn, off) and
**Defensive Spells** (default file AlertToastWarm, off), sharing one **Channel** (default
Master).

**TTS (Text-to-speech) sub-tab:** text-to-speech uses pre-recorded voice packs. A **Voice
pack** dropdown, a **Channel** dropdown (Master/SFX/Music/Ambience/Dialog), and three
per-category announce toggles, **Important**, **Defensive** and **Enemy Debuffs** (all off by
default; Enemy Debuffs covers big enemy cooldowns that land on you or your party rather than
on the caster). Eleven spells ship in that category: Deathmark, Kingsbane, Feral Frenzy,
Bloodshed, Dark Simulacrum, Duel, Sharpen Blade, Havoc, Colossus Smash since 5.18.0,
Scorpid Venom, the first venom of the hunter's Chimaeral Sting, and Goremaw's Bite. The
English packs shorten five of them, announcing Colossus Smash as just "Smash", Dark
Simulacrum as just "Simulacrum", Sharpen Blade as just "Sharpen", Scorpid Venom as just
"Sting", and Goremaw's Bite as just "Goremaw". Duel is respelled "Dual", which changes
only how the voices pronounce it. Five packs ship: David, Elise, Emma, Grampa Werthers, Theo Silk. Default pack: David.
Other addons can register packs via the API, and the localized voices are separate addons that
do exactly that: "MiniAuras - Chinese Voice Pack" (folder MiniAurasVoicePackChinese; Amy,
Anna Su, Jason Chen, on zhCN/zhTW), "MiniAuras - Korean Voice Pack" (folder
MiniAurasVoicePackKorean; Hyuk, Rosa Oh, on koKR), "MiniAuras - French Voice Pack" (folder
MiniAurasVoicePackFrench; Nicolas, Adina, on frFR), and "MiniAuras - Spanish Voice Pack"
(folder MiniAurasVoicePackSpanish; Miguel, Kate, on esES/esMX). The Mandarin three shipped
inside MiniAuras itself until they moved out; the clips are unchanged and a saved voice comes
back once that addon is installed. The clips are baked
OGG files registered engine-side per spell ID; after updating the addon a full client restart
(not just a reload) is needed before new audio files can play.

Since 5.14.0 the five shipped packs say a short name for around fifty spells players never
call by their full name, so Incarnation: Tree of Life is announced as "Incarn", Aspect of the
Turtle as "Turtle" and Life Cocoon as "Cocoon". Nothing is configurable about it, and spells
that share a nickname share the announcement: eight personal defensives (Shield Wall, Astral
Shift, Fortifying Brew and the like) are all called "Wall", and the four druid Incarnations
plus Celestial Alignment are all "Incarn". Each spell still has its own clip and its own row
on the Spells sub-tab, so they can be muted separately. The Mandarin voice pack announces the
full localized name instead; the Korean one shortens on a list of its own.

**Spells sub-tab:** "Choose which spells text-to-speech announces. The sound alerts
are not affected. A category still needs its switch on the TTS tab." It governs the spoken
announcements only, never the Sound Alerts tab's own sounds. A colour-coded sidebar of the
three categories (Important red, Defensive green, Enemy Debuffs purple) and, for the selected
one, every spell that ships a voice clip as a checkbox in two columns, sorted by name, with
**All** and **None** buttons above them. Ticking a spell on plays its clip in the selected
voice pack, so the row is its own preview; unticking and the **All** button stay silent. The
list scrolls, with the bar on its right. The tab is an opt-out list: almost every spell starts
on, unticking one stops that announcement and leaves the rest alone, and clips added in later
updates are announced without being ticked. The exception is the fourteen spells in
`AuraCategoryIds.TtsDefaultOff` (Ice Barrier, Innervate, Demon Spikes and the like), which
ship unticked because they land often enough to drown out everything else; ticking one stores
an explicit `false`. A spell with several IDs (talent
variants like Ascendance or Metamorphosis) is one row that writes all of them. Muting is
per-category, so Deathmark can be silenced as an enemy debuff and kept as an important spell.
The choices are stored as `TTS.<category>.MutedSpellIds`.

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
| Scale with Nameplate | on | icons follow the plate's scale, including personal aura groups anchored to a nameplate; keep on if the target plate is a different size (for example via BBP) |
| Anchor to Health Bar | off | anchor icons to the plate's health bar instead of the plate frame; turn on if another addon (for example BetterBlizzPlates) changes plate width or height |
| Configure Blizzard Nameplates | on | disables Blizzard's own CC display and BigDebuffs on nameplates while MiniAuras nameplates are in use, so the same auras are not drawn twice; stored globally rather than per module, and carried in the profile |
| Important colour | red (1, 0.2, 0.2) | tint for important icons on every bar whose Icon colours is Dispel colours or Custom |
| Defensive colour | green (0.2, 1, 0.2) | the same for defensive icons |
| Font Scale | 1.0 | 0.5-2.0, step 0.05; sizes the countdown text on all four bars |

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
| Icon colours | None / Dispel colours / Custom (since 5.19.0) | Dispel colours | Dispel colours | Dispel colours |
| Show tooltips | on/off | off | off | off |
| Milliseconds | on/off | on | on | on |
| Icon Size | 10-60 | 35 | 35 | 35 |
| Max Icons | 1-8 | 5 | 5 | 5 |
| Grow | LEFT/RIGHT/CENTER | LEFT | RIGHT | Bar 1 LEFT, Bar 2 RIGHT |
| Icon Padding | 0-20 | 2 | 2 | 2 |
| Offset X / Y | -250..250 | 0 / 0 | 0 / 0 | 0 / 0 |

An interrupt (kick) icon is shown on bars that have Show CC enabled. Each enabled category on a
bar gets the bar's full Max Icons budget, with no dynamic split between categories.

**Icon colours** is per bar and replaced the old "Spell colours" tick in 5.19.0, with three
choices. **Dispel colours**, the default and what the tick used to mean, paints each icon in
the game's own colour for its dispel type, with the module-wide important and defensive colours
from the Settings sub-tab for the rest, so a category reads the same on whichever bar it lands.
**Custom** drops the dispel palette and uses those two colours only. **None** leaves the icons
untinted. A profile saved before 5.19.0 reads back as Dispel colours where the tick was on, and
None where it was off.

Nameplate bars are not limited to the addon's curated spell lists: they show everything the
game itself flags for the category, so a new spec's CC turns up without waiting for an addon
update. That is the opposite of Important Auras, whose helpful side can only show what is on its
list. It also means a nameplate bar can show a mob or boss ability that no PvP list mentions.
Disarm is the one exception and stays list-driven, since the game has no flag for it.

**Mind control and other side changes.** A unit that changes team keeps its plate, so the
enemy and friendly bars have to swap over on it. Before 5.21.0 the icons a mind controlled unit
was already showing stuck on its plate. Since 5.21.0 the plate is released and redrawn from the
side the unit is on now, and the check runs on the events that announce the change rather than
waiting for the next poll, so a flip costs about a frame of wrong icons instead of a quarter of
a second.

A mind controlled unit keeps its aura icons. The game reports that unit's own auras through the
control, so the bars stay right. What it does not do is keep the alert sounds and text to speech,
which are matched by spell alone and would announce whatever landed on the player driving. Those
go quiet for as long as the mind control lasts and come back on their own when it ends.

Related global option: **Configure Blizzard Nameplates** (Nameplates > Settings, on by default) disables
Blizzard's own CC display and BigDebuffs on nameplates while MiniAuras nameplates are in use,
so the same auras are not drawn twice.

---

## Portraits

Sidebar: General > Portraits. Shows CC, defensives and other important spells on the player,
target, focus and pet portraits.

Settings: **Enabled** (single switch, applies everywhere, default on), **Reverse swipe**
(default on), and **Font Scale** (0.5-2.0, step 0.05, default 1.0).

**Extra buffs** (since 5.19.0) is a searchable spell list under the settings, and the buffs
ticked there are shown on the player's own portrait, under every flagged category. It exists
because the game flags only the auras it considers notable, and anything unflagged can never
appear otherwise. Buffs only, and the player only: on 12.1 a spell-id filter is skipped for
harmful auras on a unit you can assist, so the same layer aimed at debuffs would match every
debuff on you. Nothing is ticked by default.

One icon each for five categories: important, external defensive, big defensive, disarm and
CC. Like nameplates, portraits show everything the game flags rather than only the addon's
curated lists, so they can surface a spell that no other display lists. Disarm is again the
exception and stays list-driven.

Supported portrait providers: Blizzard frames, ElvUI, TPerl, UUF (Unhalted Unit Frames),
MSUF, Ellesmere UI Unit Frames, EnhancedQoL, Shadowed Unit Frames. Every provider covers the
pet portrait except ElvUI and TPerl, which cover player, target and focus only.

Since 5.6.1 the icons draw underneath the unit frame's border art rather than over it, so a
frame whose border overlaps the portrait clips them at its edge. That is intended. The pet
portrait is the exception and keeps its icons inside the portrait instead: its mask hangs off
the portrait rather than carrying a size of its own, and dropping the portrait a layer blacked
out the pet frame's border art (fixed in 5.9.0).

---

## CC (crowd control on party/raid frames)

Sidebar: Crowd Control > CC. Shows CC icons on party/raid frames.

Enable in (defaults): World on, Arena on, Battlegrounds off, Dungeons on, Raid off.

Two setting groups (World/Arena/Dungeons and Raids/Battlegrounds sub-tabs):

| Setting | Range | Default (W/A/D) | Default (Raids/BGs) |
|---|---|---|---|
| Exclude self | on/off | off | off |
| Glow icons | on/off | on | on |
| Icon colours | None / Dispel colours / Custom (since 5.34.0) | Dispel colours | Dispel colours |
| Reverse swipe | on/off | on | on |
| Show tooltips | on/off | off | off |
| Milliseconds | on/off | off | off |
| Relative size / Icon Size (%) | 25-100 % | 80 | 50 |
| Icon Size | 10-100 px | 32 | 20 |
| Max Icons | 1-5 | 3 | 3 |
| Icon Padding | 0-20 | 2 | 2 |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 | 1.0 |
| Grow | LEFT/RIGHT/CENTER/DOWN/UP | RIGHT | CENTER |
| Offset X / Y | -250..250 | 2 / 0 | 2 / 0 |
| CC colour | swatch (since 5.19.0, shown while Icon colours is Custom) | white | white |

**CC colour** sets the glow and border colour for crowd control icons, for players who want
one colour rather than the game's dispel palette. The swatch is only on the page while
**Icon colours** is Custom; with Dispel colours picked, the game's own colour for the aura's
school wins instead, and with None picked there is nothing to colour.

Ordering: CC icons are shown oldest applied first. Sorting happens inside the game's aura
containers, so there is no option to change it.

---

## Pet CC

Sidebar: Crowd Control > Pet CC. The same CC icons on party/raid **pet** frames.

Enable in (defaults): all five off.

One setting group (no raid split):

| Setting | Range | Default |
|---|---|---|
| Show on pet unit frame | on/off | off |
| Glow icons | on/off | on |
| Icon colours | None / Dispel colours / Custom (since 5.34.0) | Dispel colours |
| Reverse swipe | on/off | on |
| Show tooltips | on/off | off |
| Relative size / Icon Size (%) | 25-100 % | 50 |
| Icon Size | 10-100 px | 20 |
| Max Icons | 1-5 | 3 |
| Icon Padding | 0-20 | 2 |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 |
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
| Text colour | swatch (since 5.23.0) | red (1, 0.1, 0.1) |
| Reverse swipe | on/off | on |
| Dispel colours | on/off | on |
| Show tooltips | on/off | off |
| Sound | on/off + sound dropdown | on, Sonar, Master channel |
| Icon Size | 10-100 | 50 |
| Max Icons | 1-5 (since 5.19.0) | 5 |
| Text Size | 10-100 | 32 |
| Icon Padding | 0-20 | 2 |
| Icon Text Scale | 0.5-2.0, step 0.05 | 1.0 |

**Max Icons** caps how many CC icons each healer shows at once. It stops at five because the
displays are built with five icon slots, so a higher number would have nothing to draw into.

**Text Size** is the point size of the "Healer in CC!" line alone. The countdown on the CC icons
follows **Icon Text Scale** instead, which is this module's copy of the per-module Font Scale.

**Text colour** paints the "Healer in CC!" line. The swatch is only on the page while **Warning
text** is on, since with the line switched off there is nothing for it to colour.

Position: centred, 220 px below the top of the screen; draggable in test mode. The sound plays
engine-side, registered per known CC spell against the healer, so it works even though the
addon cannot read the aura.

---

## Party Trinkets

Sidebar: Crowd Control > Trinkets. Shows party members' PvP trinket cooldowns next to their
party frames. Trinket data comes from the C_PvP API, not from auras.

| Setting | Range | Default |
|---|---|---|
| Enabled | on/off (single switch, everywhere) | on |
| Exclude self | on/off | off |
| Show border | on/off | off |
| Colour | swatch | white |
| Icon Size | 10-100 | 40 |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 |
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
| Font Scale | 0.5-2.0, step 0.05 | 1.0 |

Default position: 620 px left and 160 px above screen centre. Since 5.18.0 the saved
position pins the edge the rows grow away from (the top edge growing down, the bottom edge
growing up), so the list lengthens away from where it was dropped. Older saved positions are
migrated, so nothing moves on upgrade.

With "Show self" on, your own interrupt is drawn as the pinned row only, never also as a
history row below it. The tracker cannot ask who kicked (the interrupter is hidden), so it
matches your own cast by timing: an interrupt recorded within half a second of your own
landing is taken to be yours.

---

## Enemy Kicks (enemy kick tracker)

Sidebar: Kicks > Enemy Kicks. Shows enemy interrupt cooldowns in arena (arena only; the
icons only appear inside arena matches).

**Enabled by role, not by content type.** "Enable if you are": **Healer** (default on),
**Caster** (default on), **Any** (default off, enables regardless of spec). Whether your spec
counts as healer or caster comes from the addon's spec data; if your spec cannot be read the
module assumes enabled.

The game does not identify who interrupted, so the tracker shows a generic kick icon (the
rogue Kick spell's icon) timed with the **shortest known interrupt cooldown on the enemy
team** (15 s fallback until the opponents' specs are known).

| Setting | Range | Default |
|---|---|---|
| Show border | on/off | off |
| Colour | swatch | white |
| Icon Size | 20-120 | 50 |
| Icon Padding | 0-20 | 2 |
| Font Scale | 0.5-2.0, step 0.05 | 1.0 |

Position: centred, 200 px below screen centre; draggable in test mode.

---

## Miscellaneous (Misc tab, global settings)

These apply addon-wide. All except Language override, Milliseconds Threshold, Show Test Labels,
and Debug Mode are part of the profile.

| Setting | Values / range | Default |
|---|---|---|
| Language override | Auto (client language) or a shipped locale | Auto; changing prompts a UI reload |
| Disable Swipe | on/off | off |
| Disable Numbers | on/off (since 5.23.0) | off (drops the countdown text on every aura icon; the swipe stays) |
| Show Test Labels | on/off (since 5.24.0) | on (names each module above its test icons; turn it off when the names crowd each other) |
| Debug Mode | on/off (since 5.30.0) | on (prints extra chat messages to help track down problems) |
| Zoom Icons | on/off | on (crops the baked silver border off icon art; changing it prompts a UI reload) |
| Fade With Parent | on/off | on (icons fade with the unit frame they are attached to, for example out-of-range dimming) |
| Colour Countdown | on/off | off |
| Countdown Colours | three swatches: Under 5s, Under 1m, Above 1m | red (1, 0, 0), yellow (1, 0.8, 0), white (1, 1, 1) |
| Glow Type | see "Glow Type" above | Slot Glow |
| Font | Game Default, or any LibSharedMedia font | Game Default |
| Milliseconds Threshold | 1-6 seconds | 5 |

**Disable Numbers** and **Disable Swipe** are a pair: one drops the countdown text and keeps the
pie, the other drops the pie and keeps the text. Disable Numbers wins over a module's own numbers
switch, such as the one on each Frame Auras row. It leaves two things alone: a personal aura group
whose Display is **Text only**, where the countdown is the whole display, and the Ally Kicks bars,
which draw their own clock rather than an icon's.

Shipped languages: English, German (deDE), Spanish (esES and esMX), French (frFR), Italian
(itIT), Korean (koKR), Portuguese-Brazil (ptBR), Russian (ruRU), Chinese simplified (zhCN)
and traditional (zhTW).

---

## Profiles

Sidebar: Other > Profiles.

- **Active Profile** dropdown plus **New**, **Rename**, **Clone**, **Delete** (confirmed;
  the last remaining profile cannot be deleted), **Reset** (resets the active profile to
  factory defaults, confirmed), and **Import/Export**.
- A profile contains: all module settings plus Configure Blizzard Nameplates and the Misc
  options Glow Type, Font, Disable Swipe, Disable Numbers, Zoom Icons, Colour Countdown,
  Countdown Colours and Fade With Parent. Not in the profile: Language override, Milliseconds
  Threshold, Show Test Labels, Debug Mode, and the Auto-Switch rules.
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
section, "Other addons to customize MiniAuras further", offers one card: Masque (icon
skinning).

### Masque

Icons register under the Masque addon group **MiniAuras**, in sub-groups named Crowd Control,
Healer Crowd Control, Alerts, Nameplates, Important Auras, Frame Auras, Personal Auras,
Trinkets, and Enemy Kicks.

The addon group used to be MiniCC, and several sub-groups carried older module names. Masque
stores a skin choice against the group name, so a skin picked before the rename stays on the old
group and the renamed one falls back to the default. Pick the skin again on the new group.

Each sub-group name is also the `MiniCCModule` tag MiniAuras writes on the container frames,
which other addons read to find them, so those values changed with the group names.

A skin is applied when an icon is created, so **reload after changing a skin** for it
to reach icons that already exist. Some displays stay unskinned by design: personal aura groups
drawn as bars, as a texture or as text only, the round portrait icons (the skin would fight their
own mask), and any button whose size the game keeps secret, which covers nameplate icons. If Masque itself errors while
skinning, the display drops skinning for that sub-group for the rest of the session and prints
one chat warning naming it, rather than losing the icons.

---

## Supported addons and environment

**Party/raid unit frames** (built-in providers): Blizzard raid and party frames, ElvUI,
Grid2, Plexus, VuhDo, Cell (including Cell spotlight frames), Shadowed Unit Frames, TPerl,
Danders Frames (when enabled it replaces the Blizzard frames as the source), EnhancedQoL,
Buzzard Frames, NDui, GW2 UI, UUF (Unhalted Unit Frames, including its pinned-name
frames, which get their own icons on top of the raid frame for the same unit). Other addons
can add their own frames through the public
API (see below). There is also a power-user path: saved variables named `Anchor1`,
`Anchor2`, ... holding global frame names are picked up as extra anchors.

**Arena frames**: sArena Reloaded (preferred when loaded), ElvUI arena frames, then
Blizzard's CompactArenaFrame.

**Portraits**: Blizzard, ElvUI, TPerl, UUF, MSUF, Ellesmere UI Unit Frames, EnhancedQoL,
Shadowed Unit Frames.

**Nameplate addons**: MiniAuras draws on the game's nameplates, so it works alongside
BetterBlizzPlates, Platynator, Plater and similar. For plates resized by another addon, see
the Nameplates options Scale with Nameplate and Anchor to Health Bar.

**FrameSort**: listed as an optional dependency; MiniAuras rebuilds its frame-attached
displays when frames are re-sorted.

## Public API (for addon authors)

Global `MiniAurasApi.v1`, also reachable as `MiniCCApi.v1` (same table):

- `RegisterFrameProvider(provider)`: adds unit frames from another addon; they receive the
  same icons, cooldowns and glows as built-in sources (and Personal Auras "Raid Frames" groups
  land on them too). The provider needs a unique `Name` and a `GetFrames()` returning an
  array of frames, and may supply `RegisterRefreshFrames(cb)` so it can tell MiniAuras when
  its frame list changes.
- `RegisterVoicePack(pack)`: adds a TTS voice pack to the alerts Voice pack dropdown. Needs a
  unique, stable `Name`, a `Path` to a folder of OGG clips named exactly like the shipped
  packs (one per Important, Defensive and enemy-debuff spell name, plus PreviewVoice.ogg,
  PreviewImportant.ogg, PreviewDefensive.ogg and PreviewEnemyDebuff.ogg), and optionally
  `Locales` (list of client locales; omitted = offered everywhere). Returns false if the spec
  is unusable or the name is taken.
- `RegisterPredictedCallback(fn)` and `RegisterMatchedCallback(fn)`: **deprecated no-ops.**
  They accept a callback and never call it. Each prints one chat warning naming itself the
  first time it is used, so the calling addon's author can find and drop the call. They stay
  only so an addon written against them still loads.

## Troubleshooting, by symptom

**"The addon does not appear in my list" (macOS and Linux).** Zips up to and including 5.21.0
were built with the folder separators the Windows tools write, which Windows unzippers read
correctly but macOS and Linux ones do not. Extracting one there gives a single folder holding
about 1300 files with names like `MiniAuras\Core\Config.lua` instead of the `MiniAuras` and
`MiniCC` folders. Fixed in 5.21.1. The fix: delete whatever the bad extract left in AddOns,
then download 5.21.1 or later. Which extractors trip on it varies, so a user who saw it once
should not assume a different tool will help; the new zip is the reliable answer.

**"I changed the icon size and nothing happened."** Almost always combat, or an instance where
aura data stays secret (M+, an encounter, rated PvP). The new size lands within a second of that
lifting; see "Changing a look in combat". The addon says this in chat once per fight since
5.19.0. If it persists out of combat, check the module is enabled for the content type.

**"Nothing shows at all" / "module X does nothing".** First check the module's "Enable in"
row for the content type the user is in; most modules default off in battlegrounds and
raids, Alerts is also off in dungeons, Pet CC is off everywhere, Ally Kicks is on only in
dungeons. Remember: a battleground uses the Battlegrounds toggle and the Raids/Battlegrounds
setting group; the open world while in a raid group uses the Raid toggle. Then use test mode
(`/miniauras test`) to confirm the display exists and is on screen. Since 5.16.0 test mode
answers "Enable in" for the context being previewed, so a module drawing nothing there is a
module switched off for that context rather than a broken display.

**"The settings window won't open in combat."** Expected on the first open of a session. Building
the window asks the client for keyboard control, which combat refuses, so the slash command prints
"The options window can't open during combat." and the window opens once the fight ends. After that
it opens and closes in combat like any other window. Before 5.23.0 the same attempt threw an error
instead.

**"That setting/tab doesn't exist for me."** The sidebar is the one listed under "Settings
window layout"; anything not on it is not part of the addon. Cooldown tracking, both friendly
and enemy, cannot exist on 12.1, because it worked by reading ally and enemy aura data.

**"Icons are drawn twice."** Either the old MiniCC addon is still installed alongside
MiniAuras (delete the MiniCC folder from AddOns and reload; settings are already copied), or
another addon draws the same auras. For doubled nameplate auras, make sure Configure
Blizzard Nameplates (Misc) is on, or disable the other addon's aura display. On party and raid
frames, a defensive or important buff showing twice is the Frame Auras **Important** or
**Defensives** switch turned on next to the Important Auras row that already draws it; both ship off
for that reason.

**"The personal aura settings are missing" / "there is nothing under the grid."** The editor
only appears once a group is selected. Click one of the aura tiles at the top of the page and
its settings open below; clicking empty grid space closes them again. Since 5.14.0 the page
says so in place of the editor.

**"A personal aura group shows nothing."** Usual causes: (1) it is in Spell IDs mode with an
empty spell list; (2) the spell ID added is the cast ID, not the aura the cast applies (the
Record button records cast IDs; find the aura's ID instead); (3) it is a Debuff group on
Self, My Pet or Raid Frames in Spell IDs mode, which the game forbids (switch to Aura
filters mode); (4) a caster filter (Cast by, From me or my pet, Applied by me) with the unit
in another instance or phase, where the game cannot attribute casters, so the group hides
until they return; (5) the group's unit names a side and the unit is currently on the other
side (buffs show only while friendly, debuffs only while hostile); (6) the group's own
Enabled toggle is off; (7) it is a Texture group whose art was cleared with the browser's
Reset button, so there is nothing to draw; (8) its **Show when** is In combat or Out of combat and
the player is in the other state, which holds the whole group back, sounds included.

**"A personal aura tracking a permanent buff never shows."** Fixed in 5.15.0, where a spell-ID
group no longer hides an aura that runs forever. On an older version the group works for timed
auras and stays blank for permanent ones; update the addon.

**"A texture aura shows nothing / shows a black box."** Nothing drawn usually means the art was
cleared (Reset in the texture browser); pick one again. A black box means **Additive** is off:
the game's overlay art is drawn on black and needs additive blending to read, so leave it on
unless the picked texture is a normal image. Texture groups draw one picture whatever is up, and
they carry no countdown, stack count, glow, border or tooltip by design.

**"A personal aura's countdown text disappeared."** Either **Hide numbers** or **Centre
stacks** is on for that group (Appearance tab), or its **Display** is set to Texture, which
draws art with no text at all, or **Disable Numbers** (Misc) is on, which drops the countdown on
every aura icon in the addon. Centre stacks deliberately swaps the countdown
for the stack count, so a group tracking an aura that never stacks shows no text at all with
it on. A group whose Display is **Text only** is the one that never loses its countdown.

**"Colour Countdown does nothing on one personal aura group."** That group has **Colour text**
on, which replaces the by-time ramp with its own **Text colour**. Turn Colour text off to put
the group back on the global setting. The reverse case, a group whose text ignores its
**Text colour**, is the same switch left off.

**"My starter Precog/Shroud groups are gone."** Deleting them is permanent; they
are seeded only once per profile. Recreate them by hand, import them from someone else, or
reset the profile to defaults (Profiles > Reset).

**"My PI starter group is gone after updating."** The Power Infusion starter shipped up to
5.13.0 and is no longer seeded from 5.14.0 on, but an existing profile keeps the one it
already has: an update never removes it. A profile that lost it was either reset or created
fresh on 5.14.0. Recreate it by hand as a Self group tracking 10060.

**"Personal aura sound doesn't play."** The Sounds tab only exists for groups in Spell IDs
mode; filter-mode groups cannot have sounds (sounds register per spell ID engine-side). Also
check the trigger's sound is not "(None)" and check the chosen output channel's volume.
After an addon update, new audio files need a full client restart, not just a reload.

**"TTS voices missing / TTS not working."** All three announce toggles default off. After an
addon update, new clips need a full client restart, not just a reload. The Mandarin, Korean, French
and Spanish voices are separate addons and only appear on the clients they are spoken for:
"MiniAuras - Chinese Voice Pack", "MiniAuras - Korean Voice Pack", "MiniAuras - French Voice Pack"
and "MiniAuras - Spanish Voice Pack", all on CurseForge. A saved Mandarin voice falls back to David
until the Chinese pack is installed, which is what a player who updated from 5.22.0 or earlier will
see. Korean, French and Spanish players are pointed at their pack once in the What's New dialog on
the login after updating.

**"One particular spell is never announced."** Fourteen of the spells that land most often
(Ice Barrier, Innervate, Demon Spikes, Blazing Barrier and the like) ship unticked on the TTS
Spells tab, so they are silent until switched on there. Everything else is announced unless it
was unticked.

**"The voice says the wrong name" / "two spells sound the same".** Since 5.14.0 the English
packs announce around fifty long spells by their short name, and a few nicknames are shared:
eight personal defensives are all called "Wall", and the four druid Incarnations plus
Celestial Alignment are all "Incarn". The announcement is still the right spell, and the Spells sub-tab
still lists and mutes each one separately. There is no setting to hear the full name, though
the Mandarin voice pack announces the full localized name.

**"Group frames show CC but no buffs."** Show Important and Show Defensives choose which
spells reach the display, so with both off nothing helpful is shown at all. Check both, and
check the Spells sub-tab in case the spell in question was unticked there.

**"Group frames show more icons than Max Icons."** Expected. Each category has its own budget:
CC, defensives and importants can each fill Max Icons. There is no way to cap the row as a
whole, because the addon cannot count what an aura container is showing.

**"CC and important icons are different sizes in a battleground."** Fixed in 5.23.0. A battleground
reads the Raids/Battlegrounds setting group, and an icon built before the switch could not be
resized while aura data stayed secret, so the match ran with a mix of both sizes. CC and Important
Auras now keep a display per setting group, so the right size is ready when the switch happens.

**"Frame Auras does nothing."** All three parts ship switched off, so start with the Enable switch
on the Buffs, Debuffs or Missing Buff tab. The buff and debuff rows replace Blizzard's **compact**
party and raid frames only: a player on the standard party frames sees no change from them, and
neither row draws at all while DandersFrames has replaced the compact frames. The missing buff mark
is the one part that also reaches the standard party frames.

**"Blizzard's own buffs are still there" / "they came back on their own."** Switching a row on sets
the matching cvar (`raidFramesDisplayBuffs`, `raidFramesDisplayDebuffs`) to 0, and switching it off
puts back the value it found. The write waits for combat to end, because flipping it makes the
client rebuild the raid frames, so a switch thrown mid-fight lands when the fight does. A player who
had already turned Blizzard's row off themselves never gets it handed back.

**"The frame aura buff row is empty."** Both **Filtered** and **Mine** ship on, so the row starts as
your own tracked heal-over-times and shields. Turn Filtered off for every buff the other switches
allow, and add the spell in Frame Auras > Spells > Custom to keep the whitelist.

**"The missing buff mark never shows."** **Instances only** ships on, so the mark waits for an
instance and treats a house as the open world. A class that brings no group buff (anything but
druid, evoker, mage, priest, shaman, and warrior) has nothing to mark, and its Missing Buff tab
says so. Mage and warrior were missing from that list before 5.25.0, and the mark did not show
inside an arena at all.

**"The Important/Defensive colour does nothing."** The pair only applies while the module's
colour setting asks for it: **Colours** for Important Auras, and on Nameplates an **Icon colours**
of Dispel colours or Custom for the bar in question, not None. On Alerts it also needs **Class
colours** off, since that tints by the owner's class instead. CC icons ignore the pair either
way and take the game's dispel type colour. Neither swatch reaches the Frame Auras rows: their own
Dispel colours switch rings every group on the debuff row, and a debuff the game gives no type at
all is ringed in the untyped red. CC and Pet CC have no such pair: their own **CC colour** swatch
is gated by their own **Icon colours** dropdown instead, and only for Custom, not Dispel colours
or None.

**"A spell shows on nameplates or portraits but not on group frames."** Expected. Nameplates
and portraits show whatever the game flags; group frames can only show spells on their
curated list. Add the spell ID in Important Auras > Spells > Custom.

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
see trinkets used in the starting room.

**"Enemy kick tracker missing."** It only shows inside arena, and only if your role matches
its enable settings (Healer and Caster on by default; tick "Any" to force it for every
spec). It cannot name the kicker: one generic icon with the enemy team's shortest kick
cooldown is expected behaviour.

**"Ally kick bars don't count down correctly in M+."** Expected: Blizzard hides who kicked
inside Mythic+, so rows last a flat 15 seconds. Only your own row ("Show self") shows a real
cooldown.

**"Bars/icons can't be moved."** Screen-anchored displays are dragged while test mode is on
(`/miniauras test` or the Test button). Ally Kicks bars are dragged while "Lock position" is
off. A personal aura group is dragged while it is selected in the editor (or in test mode),
and can also be positioned exactly with its Offset X/Y boxes.

**"Masque skin didn't apply / only some icons changed."** A skin is applied as each icon is
created, so reload after picking one. Bars, portrait icons and nameplate icons are never
skinned (see the Masque section). If a chat warning says Masque could not skin a group, that
group runs unskinned until the next reload.

**"High CPU usage."** The animated glow styles were the usual cause and were removed in
5.20.0, so a user still seeing it on 5.20.0 or later is not hitting that. Since 5.19.2 a module
switched off is not set up at all and costs nothing, so switching off modules that are not
wanted is the next thing to try.

**"My font isn't in the list."** The list is whatever LibSharedMedia holds, so the font needs
a media addon (or font pack) that registers it, loaded and enabled. Two things also remove a
font from the list: one the client refuses to draw with, and, on Korean, Russian and Chinese
clients, one that does not declare support for that language.

**"Settings reset / different on this character."** Profiles are account-wide but
Auto-Switch rules are per character and per spec; check Profiles > Auto-Switch and the
active profile name. Switching specs can silently switch profiles if rules are set.

**"Language is wrong."** Misc > Language override; "Auto (client language)" follows the
game client. Changing it asks to reload the UI.
