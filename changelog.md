# Changelog

## 4.4.3

Fixed friendly CDs randomly triggering in the prep room.

## 4.4.2

Fixed enemy CDs randomly triggering in the prep room.

## 4.4.1

- Fix for lingering borders.

## 4.4.0

- Removed important buff from nameplate and friendly indicator because it's causing too much lag.

## 4.3.0

- The precog/nullifying shroud module is back.
- You can now show at most 1 important/offensive icon on alerts, nameplates, and raid frames.
- These features won't work as well as before, but it's better than nothing.

## 4.2.0

Made the nameplate config more generic so you can combine CC and Defensives easier.

## 4.1.0

Renamed combined nameplate mode to defensive and allowed it to be enabled independently of the CC nameplate option.

## 4.0.0

Removed all important aura usage now that it's gone from the game.

## 3.25.0

- Icons now fade if the parent frame fades (e.g. if unit is out of range.).
- Added new option to show CC icons on the pet frame.
- Added EQoL portrait support.
- Fixed tabs underline not always showing.
- Shortened Russian "Healer in CC" text.

## 3.24.0

Updated LibCustomGlow to version 24 (latest).

## 3.23.0

Added support for new Nullifying Shroud 3s duration to the precog tracker.

## 3.22.0

- Added new relative size option to scale icons using a percentage of the parent frame.
- Fixed warlock kick not showing when using a pet.
- Fixed kick icon not showing when dueling party members.

## 3.21.0

- Added new glow type "Slot glow".
- Added new option to the alert module to split offensives and defensives to separate bars.
- Another fix for guardian druid's barkskin not tracking.

## 3.20.0

- Updated Beserker Shout to 5 seconds.
- Added EllesmereUI portraits support.
- Added desaturate enemy cooldown icons feature.
- Added API for addons to register their frames.
- Fixed mind control causing friendly cooldowns icons to change to the enemy's cooldowns.

## 3.19.0

- Added new "Split" mode for enemy cooldowns.
- Added "Always Show" feature for enemy cooldown icons.
- Fixed guardian druid barkskin not tracking.
- Added grow up option.

## 3.18.0

- Added Warrior Beserker Roar.
- Better Survival of the Fittest tracking.
- Fixed ElvUI error when portraits are disabled.

## 3.17.1

- Potential fix for lingering kick CC icon.
- Fix for hunter wall sometimes not tracking.
- Fixed enemy Shaman Burrow tracking at start of arena.
- Fix for sometimes showing wrong friendly cooldown icons.

## 3.17.0

- Fixed kicks showing on portraits when portrait module is disabled.
- Memory optimisations.
- Kick icon colour now honours spell colours option.

## 3.16.0

- Added new feature to show interrupts on nameplates/portraits/raid frames.
- Added Warrior Spell Reflect tracking.
- Added Monk Revival/Restoral tracking (pvp only).
- Added Shaman Burrow tracking (pvp only).
- Added Priest Fade/Phase Shift tracking (pvp only).
- Added Emerald Communion tracking (pvp only).
- Potential fix for glows persisting through screen loads.
- Fixed friendly cooldowns not showing in test mode.
- Fixed Grounding Totem causing some other enemy CD spells to go on cooldown (e.g. Doomwinds).
- Fixed Adrenaline Rush causing enemy CD Evasion to go on cooldown.

## 3.15.2

- Potential fix for glows persisting through reloads.
- Fix for cooldowns and auras showing on Valeera/NPCs.

## 3.15.1

Fixed Touch of Karma not tracking for the local player.

## 3.15.0

- Added Midnight Simple Unit Frames support.
- Added Touch of Karma tracking.
- Exclude Nether Ward in PvE contexts.
- Fixed IBF and Anti-Magic Shell triggering Vampiric Blood.
- Exclude NPCs from showing cooldowns (e.g. Valeera in Delves).
- Added option to manually select the config language.
- Improved FR translations.

## 3.14.0

- Added Regenerative Heartwood talent for rdruid.

## 3.13.0

- Excluded pvp spells (Grounding Totem, Time Stop) from showing in PvE contexts.
- Added Roar of Sacrifice and Exhilaration tracking.
- Improved Shadow Blades tracking.
- Hunter Turtle false positives fixes.

## 3.12.0

- Icons now stay in sync Danders Frames when they are sorted.
- Removed 12.0.1 code.
- Added tracking for Grounding Totem.
- Now tracking kicks on channelled spells.
- Inspector UnitGUID error fix.
- Added Timeless Magic evoker talent to fix Time Dilation not tracking.
- Fixed pvp talents applying in pve instances.
- Various other cooldown tracking bug fixes and improvements.

## 3.11.0

- 12.0.5 support and fixes for cooldown tracking.
- Added spell charges support.
- Various bug fixes.

## 3.10.0

- 12.0.5 improvements for cooldown tracking.
- Nameplate fix for duels of players from the same faction.
- Voidform and Dispersion Archon talents added.
- Chrysalis Mistweaver monk talent change for 12.0.5.
- Added decimals support to CC icons for 12.0.5.
- Fixed Nullifying Shroud causing Time Stop to trigger on enemy cooldowns.

## 3.9.0

- Added enemy cooldown tracking.
- Fixed bug with mind control interfering with cooldown tracking.
- Linux/Wine TTS compatibility fix.
- 12.0.5 compatibility fix.

## 3.8.0

- Added GW2 UI support.
- Fixed SetPropagateKeyboardInput error when closing options window.
- Ignore minion nameplates.
- Linux compatilibty for default TTS voice.
- Added important news about the upcoming CD tracking nerf.
- Renamed Chinese sound effect file that was causing issues with OneDrive/GDrive/file syncing software.
- Fixed player inspection errors happening in battlegrounds.
- Added API for other addons to consume for notifications on CDs being used.

## 3.7.0

- Added friendly cooldown glows when aura is active.
- Added Sacred Duty talent for Prot Paladins.
- Fixed tracking issue when Bubbling while already having Forbearance.

## 3.6.0

- Raid settings now trigger in open world when in a raid group.
- Added Time Stop for evokers.
- Added NDui support.
- Added show tooltips to nameplates.
- Fixed Warlock Nether Ward not always showing.

## 3.5.1

Fixed wrong instance settings being used in arena.

## 3.5.0

- Added profile system.
- UI rework to utilise tabs instead of scrolling.
- Added mising Guardian Spirit +2 second duration talent.
- Added cell spotlight frame support.
- Added desaturated icon support for friendly cooldowns.
- Raid settings now trigger in open world when in a raid group.
- Nicer UI for the other addons screen.

## 3.4.0

- Added VuhDo and Buzzard Frames support.
- Friendly cooldowns spells tab layout change.
- Added columns option when growing icons down.
- Fixed mage counter spell to be 20 seconds (was 24).

## 3.3.2

Regression fix that was causing tracking inaccuracies.

## 3.3.1

Blizzard party frames strata fix for friendly cooldowns.

## 3.3.0

- Added Spells selection screens so you can select which spells are tracked.
- Added Doomwinds, Ascendance, Netherward, and Metamorphosis (Vengeance).
- Added grow down direction option.
- Added separate icon padding option for the friendly cooldown tracking module.
- Fixed 'IsPet' secret bug in raids.
- Various performance improvements.

## 3.2.1

Fixed critical Friendly CDs bug where the 'Exclude Self' option was preventing externals being tracked properly.

## 3.2.0

- Fixed import profile causing an error.
- Fixed issue where the 'Exclude Self' option was not working and caused players to see other team members talents on themselves in arena.
- Fixed Friendly CD icons showing above other frames.
- Added Unhalted Unit Frames support for portraits.
- Added Threat Plates support.
- Enraged Regeneration fixes.
- Added more tooltips support.
- Shadow Blades tracking fix for rogues with 4-set.

## 3.1.0

- PvP trinket now shows on the top right when growing from the left, and top left when growing from the right.
- Added options for the Friendly CDs module to show/hide defensive spells and trinket.
- Split the enable in PvE option into Dungeons and Raid to allow for more customization.
- Fixed Fortifying Brew not tracking for Brewmaster Monk.
- Fixed Avenging Wrath and Senitel not tracking for Prot Paladin.
- Fixed Ice Block and Ice Cold not working properly for Mages.
- Fixed issue where the 'Exclude Self' option was not working and caused players to see other team members talents on themselves in arena.
- Added support for default Blizzard party frames.
- Added option to hide healer in CC icons.

## 3.0.0

Added friendly cooldown guessing module.
