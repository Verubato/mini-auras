---@type string, Addon
local _, addon = ...
local L = addon.L

-- Set English as the default
L:SetDefaultStrings({
	-- General
	["General"] = "General",
	["CC"] = "CC",
	["CDs"] = "CDs",
	["Alerts"] = "Alerts",
	["Healer"] = "Healer",
	["Nameplates"] = "Nameplates",
	["Portraits"] = "Portraits",
	["Test"] = "Test",
	["Reset"] = "Reset",
	["Enabled"] = "Enabled",

	-- Short names for tabs (to prevent overflow)
	["Nameplates_Short"] = "Nameplates",
	["Portraits_Short"] = "Portraits",
	["Kick timer_Short"] = "Kick Timer",
	["Party Trinkets_Short"] = "Trinkets",
	["Other Mini Addons_Short"] = "Other Addons",

	-- Notifications
	["Can't apply settings during combat."] = "Can't apply settings during combat.",
	["Can't do that during combat."] = "Can't do that during combat.",
	["Settings reset to default."] = "Settings reset to default.",
	["Notification"] = "Notification",

	-- Descriptions
	["Shows CC and other important spell alerts."] = "Shows CC and other important spell alerts.",
	["Addon is under ongoing development."] = "Addon is under ongoing development.",
	["Feel free to report any bugs/ideas on our discord."] = "Feel free to report any bugs/ideas on our discord.",

	-- Settings
	["Discord"] = "Discord",
	["Glow Type"] = "Glow Type",
	["Pixel Glow"] = "Pixel Glow",
	["Autocast Shine"] = "Autocast Shine",
	["Proc Glow"] = "Proc Glow",
	["The Proc Glow uses the least CPU."] = "The Proc Glow uses the least CPU.",
	["The others seem to use a non-trivial amount of CPU."] = "The others seem to use a non-trivial amount of CPU.",
	["Font Scale"] = "Font Scale",
	["Are you sure you wish to reset to factory settings?"] = "Are you sure you wish to reset to factory settings?",

	-- CC Settings
	["Grow"] = "Grow",
	["Offset X"] = "Offset X",
	["Offset Y"] = "Offset Y",
	["Exclude self"] = "Exclude self",
	["Exclude yourself from showing CC icons."] = "Exclude yourself from showing CC icons.",
	["Show a glow around the CC icons."] = "Show a glow around the CC icons.",
	["Dispel colours"] = "Dispel colours",
	["Change the colour of the glow/border based on the type of debuff."] = "Change the colour of the glow/border based on the type of debuff.",
	["Reverse swipe"] = "Reverse swipe",
	["Reverses the direction of the cooldown swipe animation."] = "Reverses the direction of the cooldown swipe animation.",
	["Enable this module everywhere."] = "Enable this module everywhere.",

	-- Alerts Settings
	["A separate region for showing important enemy spells."] = "A separate region for showing important enemy spells.",
	["Include Defensives"] = "Include Defensives",
	["Includes defensives in the alerts."] = "Includes defensives in the alerts.",
	["Color by class"] = "Color by class",
	["Color the glow/border by the enemy's class color."] = "Color the glow/border by the enemy's class color.",

	-- Nameplates Settings
	["Whether to enable or disable this type."] = "Whether to enable or disable this type.",

	-- Kick Timer
	["Kick timer"] = "Kick timer",
	["Enable if you are:"] = "Enable if you are:",
	["Caster"] = "Caster",
	["Whether to enable or disable this module if you are a healer."] = "Whether to enable or disable this module if you are a healer.",
	["Whether to enable or disable this module if you are a caster."] = "Whether to enable or disable this module if you are a caster.",
	["Any"] = "Any",
	["Whether to enable or disable this module regardless of what spec you are."] = "Whether to enable or disable this module regardless of what spec you are.",
	["Icon Size"] = "Icon Size",
	["Important Notes"] = "Important Notes",
	["How does it work? It guesses who kicked you by correlating enemy action events against interrupt events."] = "How does it work? It guesses who kicked you by correlating enemy action events against interrupt events.",
	["For example you are facing 3 enemies who are all pressing buttons."] = "For example you are facing 3 enemies who are all pressing buttons.",
	["You just got kicked and the last enemy who successfully landed a spell was enemy A, therefore we deduce it was enemy A who kicked you."] = "You just got kicked and the last enemy who successfully landed a spell was enemy A, therefore we deduce it was enemy A who kicked you.",
	["As you can tell it's not guaranteed to be accurate, but so far from our testing it's pretty damn good with ancedotally a 95%+ success rate."] = "As you can tell it's not guaranteed to be accurate, but so far from our testing it's pretty damn good with ancedotally a 95%+ success rate.",
	["Limitations:"] = "Limitations:",
	[" - Doesn't work if the enemy misses kick (still investigating potential workaround/solution)."] = " - Doesn't work if the enemy misses kick (still investigating potential workaround/solution).",
	[" - Currently only works inside arena (doesn't work in duels/world, will add this later)."] = " - Currently only works inside arena (doesn't work in duels/world, will add this later).",
	["Still working on improving this, so stay tuned for updates."] = "Still working on improving this, so stay tuned for updates.",

	-- Trinkets
	["Party Trinkets"] = "Party Trinkets",
	["Whether to enable or disable this module."] = "Whether to enable or disable this module.",
	["Exclude yourself from showing trinket icons."] = "Exclude yourself from showing trinket icons.",
	[" - Doesn't work if your team mates trinket in the starting room."] = " - Doesn't work if your team mates trinket in the starting room.",
	[" - Doesn't work in the open world."] = " - Doesn't work in the open world.",

	-- Other Addons
	["Other Mini Addons"] = "Other Mini Addons",
	["Other mini addons to enhance your PvP experience:"] = "Other mini addons to enhance your PvP experience:",
	["MiniMarkers"] = "MiniMarkers",
	[" - shows markers above your team mates."] = " - shows markers above your team mates.",
	["MiniOvershields"] = "MiniOvershields",
	[" - shows overshields on frames and nameplates."] = " - shows overshields on frames and nameplates.",
	["MiniPressRelease"] = "MiniPressRelease",
	[" - basically doubles your APM."] = " - basically doubles your APM.",
	["MiniArenaDebuffs"] = "MiniArenaDebuffs",
	[" - shows your debuffs on enemy arena frames."] = " - shows your debuffs on enemy arena frames.",
	["MiniKillingBlow"] = "MiniKillingBlow",
	[" - plays sound effects when getting killing blows."] = " - plays sound effects when getting killing blows.",
	["MiniMeter"] = "MiniMeter",
	[" - shows fps and ping on a draggable UI element."] = " - shows fps and ping on a draggable UI element.",
	["MiniQueueTimer"] = "MiniQueueTimer",
	[" - shows a draggable timer on your UI when in queue."] = " - shows a draggable timer on your UI when in queue.",
	["MiniTabTarget"] = "MiniTabTarget",
	[" - changes you tab key to enemy players in PvP, and enemy units in PvE."] = " - changes you tab key to enemy players in PvP, and enemy units in PvE.",
	["MiniCombatNotifier"] = "MiniCombatNotifier",
	[" - notifies you when entering/leaving combat."] = " - notifies you when entering/leaving combat.",

	-- Additional Settings
	["Max Icons"] = "Max Icons",
	["Shows CC icons on party/raid frames."] = "Shows CC icons on party/raid frames.",
	["Enable in:"] = "Enable in:",
	["Everywhere"] = "Everywhere",
	["Arena"] = "Arena",
	["BGS & Raids"] = "BGS & Raids",
	["Enable this module in BGs and raids."] = "Enable this module in BGs and raids.",
	["Dungeons"] = "Dungeons",
	["Enable this module in dungeons and M+."] = "Enable this module in dungeons and M+.",
	["Enable this module in Dungeons and M+"] = "Enable this module in Dungeons and M+",
	["Settings"] = "Settings",
	["Sound"] = "Sound",
	["Sound File"] = "Sound File",
	["Sound Alerts"] = "Sound Alerts",
	["TTS"] = "Text-to-speech",
	["TTS Volume"] = "TTS Volume",
	["Important Spells"] = "Important Spells",
	["Defensive Spells"] = "Defensive Spells",
	["Play a sound when the healer is CC'd."] = "Play a sound when the healer is CC'd.",
	["Play a sound when an important spell is pressed."] = "Play a sound when an important spell is pressed.",
	["Play a sound when a defensive spell is pressed."] = "Play a sound when a defensive spell is pressed.",
	["Announce spell names using text-to-speech when they are cast."] = "Announce spell names using text-to-speech when they are cast.",
	["Announce important spell names using text-to-speech when they are cast."] = "Announce important spell names using text-to-speech when they are cast.",
	["Announce defensive spell names using text-to-speech when they are cast."] = "Announce defensive spell names using text-to-speech when they are cast.",

	-- Portraits
	["Shows CC, defensives, and other important spells on the player/target/focus portraits."] = "Shows CC, defensives, and other important spells on the player/target/focus portraits.",
	["Reverses the direction of the cooldown swipe."] = "Reverses the direction of the cooldown swipe.",

	-- Healer
	["A separate region for when your healer is CC'd."] = "A separate region for when your healer is CC'd.",
	["Show warning text"] = "Warning text",
	["Show the 'Healer in CC!' text above the icons."] = "Show 'Healer in CC!' text above icons.",

	-- Friendly Indicator
	["Shows active friendly cooldowns party/raid frames."] = "Shows active friendly cooldowns party/raid frames.",
	["Enable this module in arena."] = "Enable this module in arena.",

	-- Nameplates
	["Shows CC and important spells on nameplates (works with nameplate addons e.g. BBP, Platynator, and Plater)."] = "Shows CC and important spells on nameplates (works with nameplate addons e.g. BBP, Platynator, and Plater).",
	["Glow icons"] = "Glow icons",
	["Show a glow around the icons."] = "Show a glow around the icons.",
	["Spell colours"] = "Spell colours",
	["Change the colour of the glow/border. CC spells use dispel type colours (e.g., blue for magic), Defensive spells are green, and Important spells are red."] = "Change the colour of the glow/border. CC spells use dispel type colours (e.g., blue for magic), Defensive spells are green, and Important spells are red.",
	["Change the colour of the glow/border based on dispel type (e.g., blue for magic, red for physical)."] = "Change the colour of the glow/border based on dispel type (e.g., blue for magic, red for physical).",
	["Change the colour of the glow/border. Defensive spells are green and Important spells are red."] = "Change the colour of the glow/border. Defensive spells are green and Important spells are red.",
	["Ignore Enemy Pets"] = "Ignore Enemy Pets",
	["Do not show auras on enemy pet nameplates."] = "Do not show auras on enemy pet nameplates.",
	["Ignore Friendly Pets"] = "Ignore Friendly Pets",
	["Do not show auras on friendly pet nameplates."] = "Do not show auras on friendly pet nameplates.",
	["Enemy - CC"] = "Enemy - CC",
	["Enemy - Combined"] = "Enemy - Combined",
	["Enemy - Important Spells"] = "Enemy - Important Spells",
	["Friendly - Combined"] = "Friendly - Combined",
	["Friendly - CC"] = "Friendly - CC",
	["Friendly - Important Spells"] = "Friendly - Important Spells",

	-- Healer CC
	["Healer in CC!"] = "Healer in CC!",
	["Less than 5 members (arena/dungeons)"] = "Less than 5 members (arena/dungeons)",
	["Greater than 5 members (raids/bgs)"] = "Greater than 5 members (raids/bgs)",
	["Text Size"] = "Text Size",

	-- Portraits
	["Don't forget to disable the Blizzard 'center big defensives' option when using this."] = "Don't forget to disable the Blizzard 'center big defensives' option when using this.",
})

-- Also set as current locale strings for enUS/enGB
if GetLocale() == "enUS" or GetLocale() == "enGB" then
	for key, value in pairs(addon.L) do
		if type(value) == "string" then
			L:SetString(key, value)
		end
	end
end
