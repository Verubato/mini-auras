---@diagnostic disable: unused-function
local _, addon = ...
local L = addon.L
local M = addon.Config.Migrator

function M:UpgradeToVersion41(vars)
	if vars.Version ~= 40 then return false end

	-- Add DisabledSpells to EnemyCooldownTrackerModule (new spell-filter feature).
	-- DisabledSpells is an opaque user hash; initialise to empty for existing installs.
	local ecd = vars.Modules and vars.Modules.EnemyCooldownTrackerModule
	if ecd and ecd.DisabledSpells == nil then
		ecd.DisabledSpells = {}
	end

	vars.Version = 41
	return true
end

function M:UpgradeToVersion42(vars)
	if vars.Version ~= 41 then return false end

	vars.Version = 42
	return true
end

function M:UpgradeToVersion43(vars)
	if vars.Version ~= 42 then return false end

	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L[" - Added enemy cooldown tracking module."])
	vars.NotifiedChanges = false

	vars.Version = 43
	return true
end

function M:UpgradeToVersion44(vars)
	if vars.Version ~= 43 then return false end

	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L["With the new Blizzard restrictions in 12.0.5, this is what has changed in MiniAuras.\n\nThe good news:\n* Cooldown tracking still works mostly fine in arena and dungeons.\n* Added support for multiple spell charges (e.g. 2x Pain Suppression, 2x Blur) for both friendly and enemy CDs.\n\nThe bad news:\n* Friendly externals no longer track in Raids and Battlegrounds.\n* Predictive glows are less reliable.\n* PvP kick tracking can no longer identify the kicker. Now just displays a generic icon using the shortest known enemy kick cooldown.\n\nWe've put a lot of work into this update, but there may still be issues. \nPlease report any bugs you find in our Discord so we can address them."])
	vars.NotifiedChanges = false

	vars.Version = 44
	return true
end

function M:UpgradeToVersion45(vars)
	if vars.Version ~= 44 then return false end

	-- The new AlwaysShow key is filled from dbDefaults by GetAndUpgradeDb; this step exists to
	-- bump the version and surface the feature in What's New.
	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L[" - Enemy cooldowns can now always be shown (faded when off cooldown) via the 'Always show cooldowns' option, plus a new Split layout mode (offensive cooldowns on the linear bar, defensive cooldowns on the arena frames)."])
	vars.NotifiedChanges = false

	vars.Version = 45
	return true
end

function M:UpgradeToVersion46(vars)
	if vars.Version ~= 45 then return false end

	-- New SplitBars + Defensives anchor block is filled from dbDefaults by GetAndUpgradeDb.
	vars.Version = 46
	return true
end

function M:UpgradeToVersion47(vars)
	if vars.Version ~= 46 then return false end

	-- New Icons.SizeIsPercent + Icons.SizePercent fields are filled from dbDefaults by GetAndUpgradeDb.
	vars.Version = 47
	return true
end

function M:UpgradeToVersion48(vars)
	if vars.Version ~= 47 then return false end

	-- The "Split" enemy-cooldown layout mode has been removed (it split offensive vs defensive
	-- cooldowns, and offensive cooldown tracking no longer exists). Fall back to "Linear".
	local ecd = vars.Modules and vars.Modules.EnemyCooldownTrackerModule
	if ecd and ecd.DisplayMode == "Split" then
		ecd.DisplayMode = "Linear"
	end

	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L["As of Blizzard's 12.0.7 patch the following features are no longer possible:\n- Display offensives in alerts.\n- Display offensives on nameplates.\n- Display offensives on portraits.\n- Display offensives on party/raid frames.\n- Track offensive cooldowns.\n- Show precog and nullifying shroud.\n- Sound alert for important spells.\n- Text-to-speech of important spells."])
	vars.NotifiedChanges = false

	vars.Version = 48
	return true
end

function M:UpgradeToVersion49(vars)
	if vars.Version ~= 48 then return false end

	-- Nameplates: the fixed "CC" and "Combined/Defensives" sections became two generic bars
	-- ("Bar1", "Bar2"), each with its own ShowCC / ShowDefensives toggles. Map the old sections
	-- onto the bars - CC -> Bar1 (Show CC), Combined -> Bar2 (Show Defensives) - so each user's
	-- existing size/position/enabled settings carry over. Leftover CC/Combined keys are stripped
	-- by CleanTable against the new defaults.
	local nameplates = vars.Modules and vars.Modules.NameplatesModule
	if nameplates then
		for _, factionKey in ipairs({ "Friendly", "Enemy" }) do
			local faction = nameplates[factionKey]
			if faction then
				if faction.CC and not faction.Bar1 then
					faction.CC.ShowCC = true
					faction.CC.ShowDefensives = false
					faction.Bar1 = faction.CC
					faction.CC = nil
				end
				if faction.Combined and not faction.Bar2 then
					faction.Combined.ShowCC = false
					faction.Combined.ShowDefensives = true
					faction.Bar2 = faction.Combined
					faction.Combined = nil
				end
			end
		end
	end

	vars.Version = 49
	return true
end

function M:UpgradeToVersion50(vars)
	if vars.Version ~= 49 then return false end

	-- New FadeWithParent option (default true) is filled from dbDefaults by GetAndUpgradeDb.
	vars.Version = 50
	return true
end

function M:UpgradeToVersion51(vars)
	if vars.Version ~= 50 then return false end

	-- The dedicated arena important alerts bar is filled from dbDefaults by GetAndUpgradeDb.
	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L["Some good news after the 12.0.7 restrictions:\n- The precog/nullifying shroud module is back.\n- The alerts module can now show 1 important/offensive icon per arena opponent.\n\nThese features won't work as well as before, but it's better than nothing."])
	vars.NotifiedChanges = false

	vars.Version = 51
	return true
end

function M:UpgradeToVersion52(vars)
	if vars.Version ~= 51 then return false end

	-- Nameplates can now show the "important" buffs Blizzard permits (e.g. enemy offensive
	-- cooldowns) via a per-bar ShowImportant toggle. Missing ShowImportant keys are filled
	-- from dbDefaults by GetAndUpgradeDb (Enemy Bar1 defaults to on). For existing users we
	-- additionally turn it on for one enabled bar so the feature surfaces somewhere sensible
	-- without retroactively overriding a deliberately empty layout. Prefer an enabled bar that
	-- already shows defensives (important buffs are cooldowns, so they sit naturally alongside
	-- them); otherwise fall back to the first enabled bar.
	local nameplates = vars.Modules and vars.Modules.NameplatesModule
	local enemy = nameplates and nameplates.Enemy
	local friendly = nameplates and nameplates.Friendly
	local scanOrder = {
		enemy and enemy.Bar1,
		friendly and friendly.Bar1,
		enemy and enemy.Bar2,
		friendly and friendly.Bar2,
	}
	local firstEnabled, defensivesBar
	for i = 1, 4 do
		local bar = scanOrder[i]
		if bar and bar.Enabled then
			firstEnabled = firstEnabled or bar
			if bar.ShowDefensives then
				defensivesBar = bar
				break
			end
		end
	end

	local target = defensivesBar or firstEnabled
	if target then
		target.ShowImportant = true
	end

	vars.Version = 52
	return true
end

function M:UpgradeToVersion53(vars)
	if vars.Version ~= 52 then return false end

	-- Important auras are back via a nameplate-buff-list workaround (nameplates/portraits/alerts).
	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L["Some good news:\n- A workaround has been implemented to show important auras again for nameplates/portraits/alerts."])
	vars.NotifiedChanges = false

	vars.Version = 53
	return true
end

function M:UpgradeToVersion54(vars)
	if vars.Version ~= 53 then return false end

	-- Alerts and Nameplates now have their own icon padding instead of sharing the global
	-- (Miscellaneous) IconSpacing. Seed each from the current global so existing layouts don't shift;
	-- the module sliders take over once the user changes them. Alerts has one shared value; nameplates
	-- are per-bar (like their Icon Size / Max Icons).
	local spacing = vars.IconSpacing or 2
	local alerts = vars.Modules and vars.Modules.AlertsModule
	if alerts then
		alerts.IconSpacing = spacing
	end
	local nameplates = vars.Modules and vars.Modules.NameplatesModule
	if nameplates then
		local function seedBar(bar)
			if bar and bar.Icons then
				bar.Icons.Spacing = spacing
			end
		end
		if nameplates.Enemy then
			seedBar(nameplates.Enemy.Bar1)
			seedBar(nameplates.Enemy.Bar2)
		end
		if nameplates.Friendly then
			seedBar(nameplates.Friendly.Bar1)
			seedBar(nameplates.Friendly.Bar2)
		end
	end

	vars.Version = 54
	return true
end

function M:UpgradeToVersion55(vars)
	if vars.Version ~= 54 then return false end

	-- The remaining modules that shared the global (Miscellaneous) IconSpacing now own their padding,
	-- and the global setting is retired. Seed each from the current global so existing layouts don't
	-- shift. CC and FriendlyIndicator are per-instance (Default/Raid); Healer and KickTimer are single.
	local spacing = vars.IconSpacing or 2
	local modules = vars.Modules
	if modules then
		local function seed(t)
			if t then
				t.IconSpacing = spacing
			end
		end
		if modules.CCModule then
			seed(modules.CCModule.Default)
			seed(modules.CCModule.Raid)
		end
		seed(modules.PetCCModule)
		if modules.FriendlyIndicatorModule then
			seed(modules.FriendlyIndicatorModule.Default)
			seed(modules.FriendlyIndicatorModule.Raid)
		end
		seed(modules.HealerCCModule)
		seed(modules.KickTimerModule)
	end

	vars.Version = 55
	return true
end

function M:UpgradeToVersion56(vars)
	if vars.Version ~= 55 then return false end

	-- FriendlyIndicator's important-buff category (12.1) used to follow the defensives toggle.
	-- It now has its own ShowImportant option; seed it from ShowDefensives so nobody's
	-- indicator gains or loses icons on upgrade.
	local fi = vars.Modules and vars.Modules.FriendlyIndicatorModule
	if fi then
		if fi.Default then
			fi.Default.ShowImportant = fi.Default.ShowDefensives == true
		end
		if fi.Raid then
			fi.Raid.ShowImportant = fi.Raid.ShowDefensives == true
		end
	end

	vars.Version = 56
	return true
end

local KICK_DUPE_ZONES = { "World", "Arena", "BattleGrounds", "Dungeons", "Raid" }

function M:UpgradeToVersion57(vars)
	if vars.Version ~= 56 then return false end

	-- The CC module always draws the kick icon (it has no toggle), so anyone running it in the
	-- same zone as the friendly indicator with ShowKicks on got two identical interrupt icons
	-- on the same unit frames. Drop the indicator's copy where the two overlap; CC keeps its own.
	local function DisableDuplicateKicks(modules)
		local cc = modules and modules.CCModule
		local fi = modules and modules.FriendlyIndicatorModule
		if not cc or not fi or not cc.Enabled or not fi.Enabled then
			return
		end

		local overlaps = false
		for _, zone in ipairs(KICK_DUPE_ZONES) do
			if cc.Enabled[zone] and fi.Enabled[zone] then
				overlaps = true
				break
			end
		end

		if not overlaps then
			return
		end

		-- ShowKicks is per instance profile (Default/Raid) and either can apply in any zone -
		-- the split is group size, not zone - so an overlap anywhere turns both off.
		if fi.Default then
			fi.Default.ShowKicks = false
		end
		if fi.Raid then
			fi.Raid.ShowKicks = false
		end
	end

	DisableDuplicateKicks(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			DisableDuplicateKicks(profile.Modules)
		end
	end

	vars.Version = 57
	return true
end


function M:UpgradeToVersion58(vars)
	if vars.Version ~= 57 then return false end

	-- PrecogGuesserModule became PrecogModule when the module stopped guessing (it filters on
	-- the spell IDs now). Carry the saved settings across rather than letting CleanTable drop
	-- them as an unknown key.
	local function MoveOptions(modules)
		if not modules or not modules.PrecogGuesserModule then
			return
		end

		if modules.PrecogModule == nil then
			modules.PrecogModule = modules.PrecogGuesserModule
		end

		modules.PrecogGuesserModule = nil
	end

	MoveOptions(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			MoveOptions(profile.Modules)
		end
	end

	vars.Version = 58
	return true
end

function M:UpgradeToVersion59(vars)
	if vars.Version ~= 58 then return false end

	-- KickTimerModule became EnemyKickTrackerModule when the ally kick tracker arrived and the
	-- two needed telling apart. Carry the saved settings across rather than letting CleanTable
	-- drop them as an unknown key.
	local function MoveOptions(modules)
		if not modules or not modules.KickTimerModule then
			return
		end

		if modules.EnemyKickTrackerModule == nil then
			modules.EnemyKickTrackerModule = modules.KickTimerModule
		end

		modules.KickTimerModule = nil
	end

	MoveOptions(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			MoveOptions(profile.Modules)
		end
	end

	vars.Version = 59
	return true
end

function M:UpgradeToVersion60(vars)
	if vars.Version ~= 59 then return false end

	-- FriendlyIndicatorModule became AurasModule: the module shows any tracked aura, not just an
	-- indicator on friendly frames, and the options page has been called Auras for a while.
	-- Carry the saved settings across rather than letting CleanTable drop them as an unknown key.
	local function MoveOptions(modules)
		if not modules or not modules.FriendlyIndicatorModule then
			return
		end

		if modules.AurasModule == nil then
			modules.AurasModule = modules.FriendlyIndicatorModule
		end

		modules.FriendlyIndicatorModule = nil
	end

	MoveOptions(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			MoveOptions(profile.Modules)
		end
	end

	vars.Version = 60
	return true
end

function M:UpgradeToVersion61(vars)
	if vars.Version ~= 60 then return false end

	-- AurasModule became RaidFrameAurasModule to leave the "Auras" name free for the custom
	-- aura module. Carry the saved settings across rather than letting CleanTable drop them.
	local function MoveOptions(modules)
		if not modules or not modules.AurasModule then
			return
		end

		if modules.RaidFrameAurasModule == nil then
			modules.RaidFrameAurasModule = modules.AurasModule
		end

		modules.AurasModule = nil
	end

	MoveOptions(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			MoveOptions(profile.Modules)
		end
	end

	vars.Version = 61
	return true
end

function M:UpgradeToVersion62(vars)
	if vars.Version ~= 61 then return false end

	-- On 12.1 the precog module is superseded by starter custom aura groups tracking the same
	-- two spells, but seeding at module load cannot tell an upgrader from a fresh install, so
	-- the user's precog position/icon/sound settings would be lost. Build the starter groups
	-- here instead, carrying those settings onto the Precognition and Shroud groups, and mark
	-- the profile seeded so SeedDefaults stands down. Normalise fills anything left out.
	local function SeedFromPrecog(modules)
		if not modules then
			return
		end

		local customAuras = modules.CustomAurasModule

		-- A profile that already seeded, or authored groups of its own, keeps what it has.
		if customAuras and (customAuras.SeededDefaults or (customAuras.Groups and customAuras.Groups[1])) then
			return
		end

		local precog = modules.PrecogModule or {}
		local icons = precog.Icons or {}
		local color = icons.Color or {}
		local offset = precog.Offset or {}
		local sound = precog.Sound or {}

		-- White is the precog default, so it reads as "never picked one": those installs get the
		-- designed per-spell tints; an actual choice is carried onto both groups.
		local r, g, b, a = color.R or 1, color.G or 1, color.B or 1, color.A or 1
		local pickedColor = not (r == 1 and g == 1 and b == 1 and a == 1)

		-- The module's single on/off switch, stored as an Enabled zone table.
		local enabled = false
		for _, on in pairs(precog.Enabled or { Always = true }) do
			if on then
				enabled = true
			end
		end

		-- Both spells shared one single-icon container, so both groups sit on its anchor.
		-- Fallbacks are the precog defaults, for a db old enough to predate the module.
		local function PrecogGroup(id, name, spellId, soundFile, tint)
			return {
				Id = id,
				Name = name,
				Enabled = enabled,
				Spells = { spellId },
				Position = {
					Point = precog.Point or "CENTER",
					RelativePoint = precog.RelativePoint or "CENTER",
					X = offset.X or 0,
					Y = offset.Y or 70,
				},
				Icons = {
					Size = icons.Size or 70,
					Glow = icons.Glow ~= false,
					Border = icons.Border ~= false,
					ReverseCooldown = icons.ReverseCooldown ~= false,
					Color = pickedColor and { R = r, G = g, B = b, A = a }
						or { R = tint.R, G = tint.G, B = tint.B, A = 1 },
				},
				Sound = soundFile and { Applied = soundFile, Channel = sound.Channel } or nil,
			}
		end

		modules.CustomAurasModule = {
			Groups = {
				-- The module only ever sounded for precog, never shroud. Precog keeps the default
				-- white tint, so its designed colour and its carried colour are the same thing.
				PrecogGroup("g1", "Precognition", 377362, sound.Enabled and sound.File or nil,
					{ R = 1, G = 1, B = 1 }),
				PrecogGroup("g2", "Shroud", 378464, nil, { R = 0.64, G = 0.21, B = 0.93 }),
				-- PI is a new starter with no precog history; it keeps the designed spot and tint.
				{
					Id = "g3",
					Name = "PI",
					Spells = { 10060 },
					Position = { X = 0, Y = 300 },
					Icons = { Glow = true, Border = true, Color = { R = 1, G = 0.82, B = 0, A = 1 } },
					Sound = { Applied = "BubblePop" },
				},
			},
			NextId = 4,
			SeededDefaults = true,
		}
	end

	SeedFromPrecog(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			SeedFromPrecog(profile.Modules)
		end
	end

	vars.Version = 62
	return true
end

function M:UpgradeToVersion63(vars)
	if vars.Version ~= 62 then return false end

	-- The split-mode defensives bar gained its own anchor (AlertsModule.Defensives); fresh
	-- installs ship it mirrored beside the important bar. Existing installs seed it from the
	-- main bar's anchor instead, so a split layout someone already positioned does not move.
	local function SeedDefensives(modules)
		local alerts = modules and modules.AlertsModule

		if not alerts or alerts.Defensives ~= nil then
			return
		end

		local offset = alerts.Offset or {}
		alerts.Defensives = {
			Point = alerts.Point or "CENTER",
			RelativePoint = alerts.RelativePoint or "TOP",
			RelativeTo = alerts.RelativeTo or "UIParent",
			Offset = {
				X = offset.X or 0,
				Y = offset.Y or -150,
			},
		}
	end

	SeedDefensives(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			SeedDefensives(profile.Modules)
		end
	end

	vars.Version = 63
	return true
end
