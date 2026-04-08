# Changelog

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

## 2.37.0

Added EQoL support.

## 2.36.0

Fixed auras that increase in duration (e.g. combustion, avatar) not being tracked properly.

## 2.35.0

- Some future proofing.
- ClassicFrames portrait compatibility fix.

## 2.34.1

- Possible fix for icons lingering.
- Added disable swipe animation option.

## 2.34.0

- Vertical tabs instead of horizontal to make the config UI smaller.
- Fixed weird drag snapping issue.
- Added option to use the default CC order from Blizzard.
- Added option (default enabled) to disable the Blizzard CC from nameplates to avoid duplicate icons.

## 2.33.0

Added TPerl party frames support.

## 2.32.2

Performance improvement.

## 2.32.1

Fixed unordered results sometimes coming back from Blizzard's API causing the latest CC/Defensive/Important icon not overriding the current one.

## 2.32.0

- Added Cell support.
- Reset the config screen to the middle each time it opens.
- Fixed portrait test icon being overridden by hots/auras.

## 2.31.0

Added names to icon frames for MiniCE to use.

## 2.30.1

- Renamed Indicator module to Auras.
- Profile import fix for older profile strings.

## 2.30.0

- New user interface.
- Pet portrait border fix.

## 2.29.0

- Improved trinket cooldown tracking. Credit to Mvq for notifying me of the new API.
- Added new glow type.
- Added TPerl portrait support.
- Healer in CC for BGs now only checks for healers within 40 yards.

## 2.28.3

- Fixed alerts not picking up defensives.
- Credit to DK-姜世离 for discovering this one.

## 2.28.2

Fixed ElvUI portrait frame level error with 2d portraits.

## 2.28.1

Fixed TTS voice and speech rate options being lost on reload.

## 2.28.0

Added option to scale icons with nameplates.

## 2.27.0

- Converted "CDs" module to "Indicator" and added "Show CC" option.
- Fixed icons showing underneath Plexus frames.
- Some minor config UI tweaks.
- Fixed warrior avatar proc showing in the precog region.

## 2.26.0

- Fixed error happening with ElvUI when portraits are disabled.
- Changed "Everywhere" to "World" for the Enabled options across all modules.
- Added max icons slider to the alerts module.
- Some default icon size changes.

## 2.25.0

- Added ElvUI portrait support.
- Fixed icons showing above the map.
- Fixed alerts sometimes not enabling properly.

## 2.24.2

- Fixed "Include Defensives" option not working in the Alerts module.
- Target/focus mode now works in the world (not just BGs).

## 2.24.1

Fixed swipe animation being too large on portraits.

## 2.24.0

- Alerts module now works in BGs and the world.
- Potential fix for Masque integration issue with weird big icons and borders.

## 2.23.3

Fixed an issue where casting polymorph on a non-target frame (i.e. focus or mouseover) wouldn't show the CC icon.

## 2.23.2

Various test mode bug fixes.

## 2.23.1

- Fix for party trinkets spam resetting.

## 2.23.0

- Added CC icons on party/raid pet frames (disabled by default).
- Added precognition guesser module that shows when you get precog.
- Added profile import/export feature.

## 2.22.0

- Added voice dropdown selection.
- Added option to enable/disable alert icons (so you can just have audio alerts on).
- Added icon padding option.
- Added show important and defensive checkboxes for friendly CDs.
- Added Masque integration.

## 2.21.0

- Added alerts sound effects.
- Added text-to-speech for alerts (i.e. GladiatorloSA).
- Added locale translations.
- Portrait draw layer fixes.
- Added max icons slider to CC module.
- Various performance fixes.

## 2.20.0

- Added max icons sliders to CC and Important nameplate sections.
- Nameplate colour by spell category and dispel type options.
- Fixed trinket cooldowns in test mode.
- Added dispel colour for non-glow borders.
- Fixed friendly CDs not disabling in raids.
- Fixed upgrading from very old versions causing errors.

## 2.19.4

- Fixed trinkets since the new Blizzard API change.
- Some glow performance fixes.

## 2.19.3

Glow icons performance fix in test mode.

## 2.19.2

- Removed 'action button glow' that doesn't support secrets.
- Fixed combined nameplate with 1 max icon to show latest CC applied.
- Fixed polymorph showing in alerts.

## 2.19.1

Logic bug fix for showing important harmful spells.

## 2.19.0

- Added glow icon type dropdown.
- Added font scale slider.
- Removed 12.0.0 prepatch code.
- Grid2 and DandersFrames fixes.
- Fixed Nameplates not properly disabling when unchecking 'Always'.

## 2.18.1

Fix for upgrading from an old version.

## 2.18.0

- Added max icons slider for Friendly CDs module.
- Fixed portraits being slightly too big.
- Config UI changes to add more enable buttons for instance types.
- Fixed healer in CC sometimes showing double icons.
- Some internal refactoring to make the addon easier to support.
