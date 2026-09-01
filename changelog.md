# Changelog

## 5.33.0

- Added focus unit to personal auras.
- Added position (anchor, x/y pos) to frame auras.
- Fixed missing dispel border on some CC/debuff spells.

## 5.32.0

- The frame auras Dispellable switch is now two switches, Dispellable by me and Dispellable by raid, and the raid one shows every debuff somebody in the group can take off.

## 5.31.1

- Crowd control and boss debuffs at the head of the frame aura debuff row are now drawn 40% larger, up from 25%.
- The frame auras Dispellable switch no longer hides crowd control debuffs your own spec cannot dispel.

## 5.31.0

- Fixed regular debuffs not getting dispel border.

## 5.30.1

- UI improvements.
- Fixed tracking for Incarnation: Chosen of Elune and Celestial Alignment.

## 5.30.0

- Scale with Nameplate now also scales personal aura groups anchored to a nameplate.
- Each module now has a separate font scale option and the misc tab global font scale option has been removed.
- Added a Custom Icon switch to the personal aura groups to show your selected display icon instead of the spell icon.
- Added a Debug Mode switch to the Miscellaneous tab, which prints extra messages in chat to help track down problems.
- Added the evoker Dream Breath echo copy to frame auras, listed as Echo Breath.
- Added Guardian of Ancient Kings to the paladin defensive auras, on by default.
- Added Goremaw's Bite to the enemy debuff announcements.
- Fixed frame auras still showing crowd control when the option is disabled.

## 5.29.0

- Added a text size slider and a centre stacks switch to frame auras.
- Moved the corner stack count flush into the icon's bottom right corner.

## 5.28.0

- Various fixes around sound alerts to work better with media from other addons.

## 5.27.0

- Fixed a bug with icons per row not working in arena.
- Added a CENTER-ish grow direction to the alerts bars.
- Added support for bigger priority debuffs (e.g. Unstable Affliction).

## 5.26.0

- Added more default spells to the frame auras module, thanks to Rennar for finding them.
- Added Havoc and Chimaeral Sting's Scorpid Venom to the enemy debuff announcements.
- Changed minimum frame aura size from 25% to 15%.
- The stack count text is now drawn slightly larger.
- Potential fix for personal sound auras that randomly stopped working.
- Fixed important auras showing in BGs when they are disabled.

## 5.25.0

- Upgraded spell picker for Frame Auras and Important Auras panels so you can search by name.
- Priority debuffs now show as bigger icons.
- Added the missing buff mark for mages and warriors, covering Arcane Intellect and Battle Shout.
- Fixed the missing buff mark never showing inside an arena.

## 5.24.0

- Added a Show Test Labels option to the misc tab.
- Fixed frame aura buffs hiding certain buffs such as earth shield in combat.

## 5.23.0

- Added new Frame Auras module to replace Blizzard's and fix the overlap issue.
- Added a "Show when" option to a personal aura's trigger, to show or hide it in combat.
- Added a "Text only" display to personal auras, drawing the countdown with no icon.
- Added a colour picker for the Healer Crowd Control warning text.
- Added a Disable Numbers option to the misc tab.
- Added Duel and Sharpen Blade to the enemy debuff announcements.
- Renamed "Group Auras" to "Important Auras".
- Renamed the "Unit Frames" unit on a personal aura's trigger to "Raid Frames".
- Renamed the Masque group from "MiniCC" to "MiniAuras", and its sub-groups to the current module names. Masque saves a skin against the group name, so pick your skins again.
- Fixed crowd control and important aura icons showing at mixed sizes in battlegrounds.
- Fixed the options window erroring when it was opened for the first time in combat.

## 5.22.0

- Added Dark Simulacrum to the enemy debuff announcements, spoken as just "Simulacrum".

## 5.21.2

- Fixed profile auto switching, spec detection, and the interrupt tracker breaking on 12.1.
- Fixed the grow direction being ignored when personal auras were shown in test mode.

## 5.21.1

- Fixed the download extracting as flat files on macOS and Linux instead of the proper folder structure.

## 5.21.0

- Improved first load time performance.
- Fixed nameplate icons sticking when a unit was mind controlled or otherwise changed sides.
- Lightened the cooldown swipe a little.

## 5.20.0

- Removed animated glows entirely as they were causing FPS issues.

## 5.19.4

- Fixed the interrupt lockout icon throwing an error and then sticking on screen.

## 5.19.3

- Fixed the coloured countdown text showing one second less than the plain text.

## 5.19.2

- Fixed personal auras flashing off and back on when you cross from one area to another.
- Fixed personal auras disappearing for a moment when you mount up.
- Fixed the Colossus Smash announcement never firing because it watched the wrong spell id.
- Modules you have switched off are no longer set up at all, so they cost nothing.

## 5.19.1

- Fixed the alert bars filling with unrelated buffs at the start of an arena round.

## 5.19.0

- Alert icons can be coloured by the enemy's class.
- Added an icon colouring dropdown to nameplates, and a colour picker for CC.
- Added a max icons slider to the healer CC module.
- Added an extra buffs list to the portraits module so you can show unflagged auras on your own portrait.
- Test mode containers can now be placed exactly with a new X/Y offset popup.
- Changing icon size or style in combat now says it will apply once combat ends.
- Fixed containers not attaching to ElvUI.
- Fixed an error when the countdown text was secret.
- Various performance improvements.

## 5.18.0

- Added Colossus Smash to the enemy debuff announcements.
- Fixed the Feral Frenzy announcement never firing because it watched the wrong spell id.
- Added font text preview in the dropdown.
- The ally kick tracker font now scales with the font scale option in the misc tab.
- Ally kick tracker now grows downwards instead of from the middle.
- Fixed party trinkets sometimes not anchoring properly to EUI frames.

## 5.17.0

- Added a Font option in the miscellaneous settings, setting the font for every piece of text the addon draws. The list comes from LibSharedMedia, so any font your media addons offer is there.

## 5.16.1

- Fixed an error, and aura sounds going quiet, when a unit frame addon asked MiniAuras to refresh its frames.

## 5.16.0

- Added a border option to the alert icons so you can disable glows but keep the border.
- Fixed test mode showing a module that is switched off for the context being previewed.
- Some default setting changes for new profiles.

## 5.15.0

- Added a Texture display style to personal auras, drawing one of the game's own proc textures while a tracked aura is up.
- Added Unhalted Unit Frames as a party and raid frame provider.
- Added Shadowed Unit Frames as a portrait provider.
- Added Bloodshed to the enemy debuff announcements.
- Fixed personal auras tracking a spell with a permanent duration not showing.

## 5.14.2

- Fixed regression from 5.14.1 where personal auras stopped working after changing a zone.

## 5.14.1

- Workaround for garbage auras showing on zone transfers (need Blizzard for a proper fix).
- Some performance improvements, mostly around nameplates.

## 5.14.0

- Added ability to configure the text size in personal auras.
- Shortened TTS spells, e.g. "Aspect of the Turtle" is now just "Turtle".
- Removed the Power Infusion personal aura from the ones a new profile starts with. Existing profiles keep theirs.

## 5.13.0

- Added warning when using a buff/debuff that won't work on that unit type in personal auras.

## 5.12.2

- Fixed party and raid frame CC icons not showing a border when the CC is undispelable.

## 5.12.1

- Fixed a hitch when a media addon loads, where its sounds and bar textures rebuilt the lists once per entry instead of once for the whole set.
- The personal auras page now says that a sound only aura can watch either aura type on any unit.

## 5.12.0

- Added a Centre stacks option to personal auras, showing the stack count in the middle of the icon in place of the countdown.
- Added a Colour text option to personal auras, which colours the countdown, stack count, and bar spell name.

## 5.11.0

- Fixed mind controlled units showing another player's buffs on alerts and nameplates.
- Added countdown colour pickers in the Misc tab.
- Fixed crowd control containers showing junk icons for units out of range.
- Made the tab controls in the settings window easier to see.

## 5.10.3

- Auras are now hidden inside player housing, which previously counted as a dungeon.
- Fixed the portrait being washed purple by Voidform's glow while portrait icons were showing.

## 5.10.2

- Fixed nameplate CC icons not showing border when the CC is undispelable.
- Fixed Deathmark TTS announcement when the rogue is on your team.
- Fixed nameplate icon sizing issue.

## 5.10.1

- Various minor optimisations.
- Fixed styles not applying to personal auras in arena.

## 5.10.0

- Added ability to specify the strata of personal auras.
- Increased font size of personal aura stack number.

## 5.9.1

- Fixed an error when the game hides a player's specialization, which a mouseover of a stranger was enough to trigger.
- The last five seconds of a countdown now read pure red.

## 5.9.0

- Nameplates and group auras now have their own Important and Defensive colour pickers, the same as the alerts already had. CC icons keep the game's dispel type colours.
- Group frames can now show defensive and important icons up to Max Icons each, instead of sharing one allowance between them.
- Fixed your own interrupt showing twice in the ally interrupt tracker while your readiness row was already counting it down.
- Fixed the pet frame's border art turning black while portrait icons were showing.

## 5.8.0

- MiniAuras now needs patch 12.1 and will not load on 12.0.7.
- Text-to-speech announces around forty more spells, including Ice Barrier, Darkness, Dark Pact, and Rallying Cry. The fourteen noisiest start switched off.
- Fixed portraits and nameplates not showing some CC spells.
- Fixed the TTS Spells tab turning some spells off.
- Fixed Show Important and Show Defensives on group frames acting as one switch.

## 5.7.0

- Text-to-speech has a new Spells tab for choosing which spells are announced. Every spell starts on, and ticking one plays its clip.
- New Zoom Icons option in Miscellaneous. Turning it off gives back the silver border Blizzard bakes into spell icons.

## 5.6.2

- Sound channels now include music, ambience, and dialog, alongside master and sound effects.

## 5.6.1

- Portrait icons now draw inside the portrait instead of over its border.

## 5.6.0

- Personal auras can now hide the cooldown swipe and the countdown numbers, each on its own switch.
- The starter "Precognition" aura group is now called "Precog".
- Fixed the spell name switch doing nothing to a personal aura bar while it was being previewed.

## 5.5.0

- Personal auras can now play a sound with nothing drawn, which is the only way to track debuffs on yourself or your group.
- Big enemy cooldowns landing on your team are announced over text-to-speech: Deathmark, Kingsbane, and Feral Frenzy.
- Fixed personal auras filling up with random buffs after entering a vehicle.
- Fixed portrait icons not clearing when you change target.
- Fixed group frames showing every buff on a duel opponent, a mind controlled ally, or someone out of range.
- Colouring the countdown by time is now off by default, and turning it off works on bars.

## 5.4.1

- Portraits no longer show every debuff on friendly units.
- Interrupts on group frames are now off by default for party groups on new profiles. Raid groups are unchanged.

## 5.4.0

- Masque icon skinning works again on 12.1. Reload after changing a skin.
- Glows and the cooldown swipe now follow the icon's edges cleanly.

## 5.3.0

- Personal auras can now be shown as bars instead of icons.
- New glows: Twins, Mirror, Twins Mirror, and Static Pixel Border.
- Ten more spells are announced over TTS, including Tranquility, Spirit Link, Zephyr and Army of the Dead.
- The "Healer in CC!" text works again on 12.1.
- The pandemic reveal no longer draws on groups that have it switched off.
- Balance Druid's Faerie Swarm counts as a disarm.

## 5.2.2

- Disarms on nameplate bars and portraits working.
- Various localisation fixes for labels that are too long and wrong fonts.

## 5.2.1

- Fixed the config scrollbar moving in the opposite direction to the scroll position.
- Removed the unnecessary scrollbar from the personal auras page.

## 5.2.0

- New "Arena Frames" unit for personal auras.
- Added X and Y offset edit boxes for finer control of personal aura positioning.
- Added Mandarin TTS voices.
- New API for addons to register their own voice packs.

## 5.1.0

Text to speech announcements are back on 12.1, now powered by pre-recorded voice packs.

- Choose from five voices in the alerts TTS options: David, Elise, Emma, Grampa Werthers, and Theo Silk.
- Other addons can register their own voice packs via the MiniAurasApi.
- Note: a full client restart (not just a reload) is needed to hear new audio after updating.

Personal auras:

- New "Unit Frames" unit that shows a copy of the group on every party/raid frame, including frames from custom addon frame providers.
- The cast recorder now stops when the config window is closed.

Fixes:

- The Colour Countdown option is shown on 12.0.7 clients again.
- The ally kick tracker now renders Cyrillic names correctly.

## 5.0.1

Fixed portrait icons being invisible on the 12.0.7 client.

## 5.0.0

Added support for Blizzard patch 12.1.

What's removed:

- Friendly and enemy cooldown tracking (not possible in 12.1).
- Masque icon skinning.

What's added/changed:

- New personal auras functionality (think mini weak auras).
  - When aura added show icon and play sound.
  - Precognition & Nullifying Shroud module have been merged into this.
- Ally kick tracker for dungeons/M+.
- Wider range of spells on raid frames, e.g. Darkness, Spirit Link, Dark Pact, etc.
- UI overhaul so it looks sexier.