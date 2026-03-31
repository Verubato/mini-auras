---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local frames = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local spellCache = addon.Utils.SpellCache
local units = addon.Utils.Units
local unitAuraWatcher = addon.Core.UnitAuraWatcher
local inspector = addon.Core.Inspector
local fcdTalents = addon.Core.FriendlyCooldownTalents
local trinketsTracker = addon.Core.TrinketsTracker
local instanceOptions = addon.Core.InstanceOptions

-- Seconds of timing tolerance when matching a measured buff duration to a rule.
-- Covers frame-rate jitter, network latency, and slight timestamp rounding.
local tolerance = 0.5
-- Seconds within which a UNIT_SPELLCAST_SUCCEEDED counts as cast evidence, and as a tiebreaker
-- when multiple watched units match the same rule (e.g. two Paladins, both can produce BoP).
-- Must be >= evidenceTolerance so the deferred backfill can still catch late-arriving cast events.
-- Both castWindow and evidenceTolerance are kept equal for this reason.
local castWindow = 0.15
-- How long (seconds) to wait for concurrent evidence after a buff appears.
-- For cross-unit spells (e.g. BoF, BoP), UNIT_SPELLCAST_SUCCEEDED on the caster can arrive
-- after UNIT_AURA on the target by one or more server ticks.
local evidenceTolerance = 0.15
-- unit -> timestamp of most recent HARMFUL aura addition (Forbearance indicates Divine Shield).
local lastDebuffTime = {}
-- unit -> timestamp of most recent absorb change (absorb application indicates Divine Protection).
local lastShieldTime = {}
-- unit -> timestamp of most recent UNIT_SPELLCAST_SUCCEEDED (self-cast evidence e.g. Alter Time).
local lastCastTime = {}
-- unit -> timestamp of most recent UNIT_FLAGS (unit combat/immune flags changed e.g. Aspect of the Turtle).
local lastUnitFlagsTime = {}
-- unit -> timestamp of most recent feign death activation (UnitIsFeignDeath transition false->true).
local lastFeignDeathTime = {}
-- unit -> last known feign death state, used to detect false->true transitions.
local lastFeignDeathState = {}

---@class EvidenceSet
---@field Debuff     boolean?  a HARMFUL aura appeared near detectionTime (e.g. Forbearance from Divine Shield)
---@field Shield     boolean?  an absorb change appeared near detectionTime (e.g. Divine Protection)
---@field UnitFlags  boolean?  unit combat/immune flags changed near detectionTime (e.g. Aspect of the Turtle); suppressed when FeignDeath is the source
---@field FeignDeath boolean?  unit entered feign death near detectionTime; mutually exclusive with UnitFlags to prevent false AoT matches
---@field Cast       boolean?  the unit cast a spell near detectionTime

---Collects all concurrent evidence types for a unit near detectionTime.
---Returns an EvidenceSet or nil if no evidence was found.
---Multiple types can be present simultaneously when several events fire in the same window;
---callers check for specific keys rather than comparing a single string.
---@param unit string
---@param detectionTime number
---@return EvidenceSet?
local function BuildEvidenceSet(unit, detectionTime)
	---@type EvidenceSet?
	local ev = nil
	if lastDebuffTime[unit] and math.abs(lastDebuffTime[unit] - detectionTime) <= evidenceTolerance then
		ev = ev or {}
		ev.Debuff = true
	end
	if lastShieldTime[unit] and math.abs(lastShieldTime[unit] - detectionTime) <= evidenceTolerance then
		ev = ev or {}
		ev.Shield = true
	end
	-- FeignDeath and UnitFlags are mutually exclusive: if feign death is the source of the flags
	-- change, UnitFlags is suppressed to prevent false Aspect of the Turtle detections.
	if lastFeignDeathTime[unit] and math.abs(lastFeignDeathTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.FeignDeath = true
	elseif lastUnitFlagsTime[unit] and math.abs(lastUnitFlagsTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.UnitFlags = true
	end
	if lastCastTime[unit] and math.abs(lastCastTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.Cast = true
	end
	return ev
end

-- Rules keyed first by spec ID (more precise), then by class token (fallback).
-- Each rule carries flags for which aura type(s) it can match:
--   BigDefensive = true      matches BIG_DEFENSIVE auras from GetDefensiveState()
--   ExternalDefensive = true matches EXTERNAL_DEFENSIVE auras from GetDefensiveState()
--   Important = true         matches IMPORTANT auras from GetImportantState()
-- A rule may carry multiple flags when a spell is tagged as both (e.g. Paladin Divine Protection).
--
-- Paladin:     Holy=65,    Prot=66,      Ret=70
-- Warrior:     Arms=71,    Fury=72,      Prot=73
-- Mage:        Arcane=62,  Fire=63,      Frost=64
-- Hunter:      BM=253,     MM=254,       Survival=255
-- Priest:      Disc=256,   Holy=257,     Shadow=258
-- Rogue:       Assassination=259, Outlaw=260, Subtlety=261
-- Death Knight: Blood=250, Frost=251,    Unholy=252
-- Shaman:      Elem=262,   Enh=263,      Resto=264
-- Warlock:     Affliction=265, Demonology=266, Destruction=267
-- Monk:        Brew=268,   WW=269,       MW=270
-- Demon Hunter: Havoc=577, Vengeance=581, Devourer=1480
-- Druid:       Balance=102,Feral=103,    Guardian=104, Resto=105
-- Evoker:      Devas=1467, Preserv=1468, Aug=1473

-- SpellId maps a rule to the canonical spell ID used for talent CDR lookups.

local rules = {
	bySpec = {
		[65] = { -- Holy Paladin
			{
				BuffDuration = 12,
				Cooldown = 120,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 31884,
				MinDuration = true,
				ExcludeIfTalent = 216331,
			}, -- Avenging Wrath (hidden if Avenging Crusader talented)
			{
				BuffDuration = 10,
				Cooldown = 60,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 216331,
				MinDuration = true,
				RequiresTalent = 216331,
			}, -- Avenging Crusader
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				RequiresEvidence = { "Cast", "Debuff", "UnitFlags" },
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 60,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 498,
			}, -- Divine Protection
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 204018,
				RequiresTalent = 5692,
			}, -- Blessing of Spellwarding (replaces BoP)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 1022,
				ExcludeIfTalent = 5692,
			}, -- Blessing of Protection
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				RequiresEvidence = "Cast",
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[66] = { -- Protection Paladin
			{
				BuffDuration = 25,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 31884,
				ExcludeIfTalent = 389539,
			}, -- Avenging Wrath (hidden if Sentinel talented)
			{
				BuffDuration = 20,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 389539,
				RequiresTalent = 389539,
				ExcludeIfTalent = 31884,
			}, -- Sentinel (hidden if Avenging Wrath talented)
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				RequiresEvidence = { "Cast", "Debuff", "UnitFlags" },
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 90,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				SpellId = 31850,
				RequiresEvidence = "Cast",
			}, -- Ardent Defender
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				Important = false,
				ExternalDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 86659,
			}, -- Guardian of Ancient Kings
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 204018,
				RequiresTalent = 5692,
			}, -- Blessing of Spellwarding (replaces BoP)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 1022,
				ExcludeIfTalent = 5692,
			}, -- Blessing of Protection
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				RequiresEvidence = "Cast",
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[70] = { -- Retribution Paladin
			{
				BuffDuration = 24,
				Cooldown = 60,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				RequiresEvidence = "Cast",
				SpellId = 31884,
				ExcludeIfTalent = 458359,
			}, -- Avenging Wrath (hidden if Radiant Glory talented)
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				RequiresEvidence = { "Cast", "Debuff", "UnitFlags" },
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 90,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				RequiresEvidence = { "Cast", "Shield" },
				SpellId = 403876,
			}, -- Divine Protection (90s base for Ret)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 204018,
				RequiresTalent = 5692,
			}, -- Blessing of Spellwarding (replaces BoP)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 1022,
				ExcludeIfTalent = 5692,
			}, -- Blessing of Protection
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				RequiresEvidence = "Cast",
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[62] = { { BuffDuration = 15, Cooldown = 90, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", MinDuration = true, SpellId = 365350 } }, -- Arcane Mage: Arcane Surge
		[63] = { { BuffDuration = 10, Cooldown = 120, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", SpellId = 190319, MinDuration = true } }, -- Fire Mage: Combustion
		[71] = { -- Arms Warrior
			{ BuffDuration = 8, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 118038 }, -- Die by the Sword
			{ BuffDuration = 20, Cooldown = 90, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", SpellId = 107574, MinDuration = true, RequiresTalent = 107574 }, -- Avatar
		},
		[72] = { -- Fury Warrior
			{ BuffDuration = 8, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 184364 }, -- Enraged Regeneration
			{ BuffDuration = 11, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 184364 }, -- Enraged Regeneration + duration talent
			{ BuffDuration = 20, Cooldown = 90, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", SpellId = 107574, MinDuration = true, RequiresTalent = 107574 }, -- Avatar
		},
		[73] = { -- Protection Warrior
			{ BuffDuration = 8, Cooldown = 180, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 871 }, -- Shield Wall
			{ BuffDuration = 20, Cooldown = 90, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", SpellId = 107574, MinDuration = true, RequiresTalent = 107574 }, -- Avatar
		},
		[251] = { { BuffDuration = 12, Cooldown = 45, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", MinDuration = true, SpellId = 51271 } }, -- Frost Death Knight: Pillar of Frost
		[250] = { -- Blood Death Knight
			{ BuffDuration = 10, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 55233 }, -- Vampiric Blood
			{ BuffDuration = 12, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 55233 }, -- Vampiric Blood + Goreringers Anguish rank 1 (+2s)
			{ BuffDuration = 14, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 55233 }, -- Vampiric Blood + Goreringers Anguish rank 2 (+4s)
		},
		[256] = { { BuffDuration = 8, Cooldown = 180, ExternalDefensive = true, BigDefensive = false, Important = false, RequiresEvidence = "Cast", SpellId = 33206 } }, -- Discipline Priest: Pain Suppression
		[257] = { -- Holy Priest
			{ BuffDuration = 10, Cooldown = 180, ExternalDefensive = true, BigDefensive = false, Important = false, CanCancelEarly = true, RequiresEvidence = "Cast", SpellId = 47788 }, -- Guardian Spirit
			{ BuffDuration = 5, Cooldown = 180, Important = true, BigDefensive = false, ExternalDefensive = false, CanCancelEarly = true, RequiresEvidence = "Cast", SpellId = 64843 }, -- Divine Hymn
		},
		[258] = { -- Shadow Priest
			{ BuffDuration = 6, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = true, CanCancelEarly = true, RequiresEvidence = "Cast", SpellId = 47585 }, -- Dispersion
			{ BuffDuration = 20, Cooldown = 120, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", SpellId = 228260 }, -- Voidform
		},
		[102] = { { BuffDuration = 20, Cooldown = 180, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", MinDuration = true, SpellId = 102560 } }, -- Balance Druid: Incarnation: Chosen of Elune
		[103] = {
			{ BuffDuration = 15, Cooldown = 180, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", MinDuration = true, SpellId = 106951, RequiresTalent = 106951, ExcludeIfTalent = 102543 }, -- Feral Druid: Berserk (hidden if Incarnation talented)
			{ BuffDuration = 20, Cooldown = 180, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 102543, RequiresTalent = 102543 }, -- Feral Druid: Incarnation: Avatar of Ashamane (shown when 102543 talented; Berserk self-excludes via ExcludeIfTalent=102543)
		},
		[104] = { { BuffDuration = 30, Cooldown = 180, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 102558 } }, -- Guardian Druid: Incarnation: Guardian of Ursoc
		[105] = { { BuffDuration = 12, Cooldown = 90, ExternalDefensive = true, BigDefensive = false, Important = false, RequiresEvidence = "Cast", SpellId = 102342 } }, -- Restoration Druid: Ironbark
		[268] = { -- Brewmaster Monk
			{ BuffDuration = 25, Cooldown = 120, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 132578 }, -- Invoke Niuzao, the Black Ox
			{ BuffDuration = 15, Cooldown = 360, BigDefensive = true, Important = true, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 115203 }, -- Fortifying Brew
		},
		[270] = { { BuffDuration = 12, Cooldown = 120, ExternalDefensive = true, BigDefensive = false, Important = false, CanCancelEarly = true, RequiresEvidence = "Cast", SpellId = 116849 } }, -- Mistweaver Monk: Life Cocoon
		[577] = { -- Havoc Demon Hunter
			{ BuffDuration = 10, Cooldown = 60, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 198589 }, -- Blur
		},
		[1480] = { -- Devourer Demon Hunter
			{ BuffDuration = 10, Cooldown = 60, BigDefensive = true, ExternalDefensive = false, Important = false, RequiresEvidence = "Cast", SpellId = 198589 }, -- Blur
		},
		[581] = { -- Vengeance Demon Hunter
			{ BuffDuration = 12, Cooldown = 60, BigDefensive = true, ExternalDefensive = false, Important = false, MinDuration = true, RequiresEvidence = "Cast", SpellId = 204021 }, -- Fiery Brand
		},
		[254] = {
			{ BuffDuration = 15, Cooldown = 120, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 288613 }, -- Marksmanship Hunter: Trueshot
			{ BuffDuration = 17, Cooldown = 120, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 288613 }, -- Marksmanship Hunter: Trueshot +2s
		},
		[255] = { -- Survival Hunter
			{ BuffDuration = 8, Cooldown = 90, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 1250646 }, -- Takedown
			{ BuffDuration = 10, Cooldown = 90, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 1250646 }, -- Takedown +2s
		},
		[261] = { { BuffDuration = 16, Cooldown = 90, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", SpellId = 121471 } }, -- Subtlety Rogue: Shadow Blades
		[1467] = { { BuffDuration = 18, Cooldown = 120, Important = true, BigDefensive = false, ExternalDefensive = false, RequiresEvidence = "Cast", MinDuration = true, SpellId = 375087 } }, -- Devastation Evoker: Dragonrage
		[1468] = { { BuffDuration = 8, Cooldown = 60, ExternalDefensive = true, BigDefensive = false, Important = false, RequiresEvidence = "Cast", SpellId = 357170 } }, -- Preservation Evoker: Time Dilation
		[1473] = { { BuffDuration = 13.4, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", MinDuration = true, SpellId = 363916 } }, -- Augmentation Evoker: Obsidian Scales
	},
	byClass = {
		PALADIN = {
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				RequiresEvidence = { "Cast", "Debuff", "UnitFlags" },
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 25,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 1044,
			}, -- Blessing of Freedom
			{
				BuffDuration = 10,
				Cooldown = 45,
				ExternalDefensive = true,
				Important = false,
				BigDefensive = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 204018,
				RequiresTalent = 5692,
			}, -- Blessing of Spellwarding (replaces BoP)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				Important = false,
				BigDefensive = false,
				CanCancelEarly = true,
				RequiresEvidence = "Cast",
				SpellId = 1022,
				ExcludeIfTalent = 5692,
			}, -- Blessing of Protection
		},
		WARRIOR = {},
		MAGE = {
			{ BuffDuration = 10, Cooldown = 240, BigDefensive = true, ExternalDefensive = false, Important = true, CanCancelEarly = true, SpellId = 45438, RequiresEvidence = { "Cast", "Debuff", "UnitFlags" } }, -- Ice Block
			{ BuffDuration = 10, Cooldown = 50, BigDefensive = true, ExternalDefensive = false, Important = true, CanCancelEarly = true, SpellId = 342246, RequiresEvidence = "Cast" }, -- Alter Time
		},
		HUNTER = {
			{ BuffDuration = 8, Cooldown = 180, BigDefensive = true, ExternalDefensive = false, Important = true, CanCancelEarly = true, SpellId = 186265, RequiresEvidence = { "Cast", "UnitFlags" } }, -- Aspect of the Turtle
			{ BuffDuration = 6, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, MinDuration = true, SpellId = 264735, RequiresEvidence = "Cast" }, -- Survival of the Fittest
			{ BuffDuration = 8, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, MinDuration = true, SpellId = 264735, RequiresEvidence = "Cast" }, -- Survival of the Fittest + Survival of the Fittest talent (+2s)
		},
		DRUID = {
			{ BuffDuration = 8, Cooldown = 60, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 22812 }, -- Barkskin
			{ BuffDuration = 12, Cooldown = 60, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 22812 }, -- Barkskin + Improved Barkskin (+4s)
		},
		ROGUE = {
			{ BuffDuration = 10, Cooldown = 120, Important = true, ExternalDefensive = false, BigDefensive = false, RequiresEvidence = "Cast", SpellId = 5277 }, -- Evasion
			{ BuffDuration = 5, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = false, RequiresEvidence = "Cast", SpellId = 31224 }, -- Cloak of Shadows
		},
		DEATHKNIGHT = {
			{ BuffDuration = 5, Cooldown = 60, BigDefensive = true, Important = true, ExternalDefensive = false, CanCancelEarly = true, SpellId = 48707, RequiresEvidence = { "Cast", "Shield" } }, -- Anti-Magic Shell (BigDefensive, without Spellwarding)
			{ BuffDuration = 7, Cooldown = 60, BigDefensive = true, Important = true, ExternalDefensive = false, CanCancelEarly = true, SpellId = 48707, RequiresEvidence = { "Cast", "Shield" } }, -- Anti-Magic Shell + Anti-Magic Barrier (+40%) (BigDefensive, without Spellwarding)
			{ BuffDuration = 8, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 48792 }, -- Icebound Fortitude
			{ BuffDuration = 5, Cooldown = 60, BigDefensive = false, Important = true, ExternalDefensive = false, CanCancelEarly = true, SpellId = 48707, RequiresEvidence = { "Cast", "Shield" } }, -- Anti-Magic Shell (with Spellwarding)
			{ BuffDuration = 7, Cooldown = 60, BigDefensive = false, Important = true, ExternalDefensive = false, CanCancelEarly = true, SpellId = 48707, RequiresEvidence = { "Cast", "Shield" } }, -- Anti-Magic Shell + Anti-Magic Barrier (+40%) (with Spellwarding)
		},
		DEMONHUNTER = {},
		MONK = { { BuffDuration = 15, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = false, RequiresEvidence = "Cast", SpellId = 115203 } }, -- Fortifying Brew
		SHAMAN = { { BuffDuration = 12, Cooldown = 120, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 108271 } }, -- Astral Shift
		WARLOCK = { { BuffDuration = 8, Cooldown = 180, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 104773 } }, -- Unending Resolve
		PRIEST = {
			{ BuffDuration = 10, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", SpellId = 19236 }, -- Desperate Prayer
		},
		EVOKER = {
			{ BuffDuration = 12, Cooldown = 90, BigDefensive = true, ExternalDefensive = false, Important = true, RequiresEvidence = "Cast", MinDuration = true, SpellId = 363916 }, -- Obsidian Scales
		},
	},
}

---@class FriendlyCooldownTrackerModule : IModule
local M = {}
addon.Modules.FriendlyCooldownTrackerModule = M

local watchEntries = {} ---@type table<table, FcdWatchEntry>  keyed by anchor frame
local testModeActive = false
local editModeActive = false
local eventsFrame
---@type Db
local db

---Shows or hides an entry's container frame, suppressing display while edit mode is active.
local function ShowHideEntryContainer(frame, anchor)
	if editModeActive then
		frame:Hide()
		return
	end
	frames:ShowHideFrame(frame, anchor, testModeActive, false)
end

local function GetOptions()
	return db and db.Modules.FriendlyCooldownTrackerModule
end

local function GetAnchorOptions()
	local m = GetOptions()
	if not m then
		return nil
	end
	return instanceOptions:IsRaid() and m.Raid or m.Default
end

local function GetEntryForUnit(unit)
	local fallback = nil
	for _, entry in pairs(watchEntries) do
		if UnitIsUnit(entry.Unit, unit) then
			if entry.Anchor:IsShown() then
				return entry
			end
			fallback = entry
		end
	end
	return fallback
end

---Returns the spec ID for a unit via FrameSort API if available, otherwise the internal inspector.
---@param unit string
---@return number|nil
local function GetSpecId(unit)
	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Inspector then
		return fs.Inspector:GetUnitSpecId(unit)
	end
	return inspector:GetUnitSpecId(unit)
end

---Returns true if every defined flag on the rule matches the aura's type set.
--- true  -> type must be present
--- false -> type must be absent
--- nil   -> type is unconstrained
---@param auraTypes table<string,boolean>
local function AuraTypeMatchesRule(auraTypes, rule)
	if rule.BigDefensive == true and not auraTypes["BIG_DEFENSIVE"] then
		return false
	end
	if rule.BigDefensive == false and auraTypes["BIG_DEFENSIVE"] then
		return false
	end
	if rule.ExternalDefensive == true and not auraTypes["EXTERNAL_DEFENSIVE"] then
		return false
	end
	if rule.ExternalDefensive == false and auraTypes["EXTERNAL_DEFENSIVE"] then
		return false
	end
	if rule.Important == true and not auraTypes["IMPORTANT"] then
		return false
	end
	return true
end

---Returns true if evidence satisfies a RequiresEvidence value.
---  nil         -> no constraint (always ok)
---  false       -> requires no evidence present
---  string      -> that key must be present in evidence
---  string[]    -> ALL listed keys must be present in evidence
---@param req any
---@param evidence EvidenceSet?
---@return boolean
local function EvidenceMatchesReq(req, evidence)
	if req == nil then return true end
	if req == false then return not evidence or not next(evidence) end
	if type(req) == "string" then return evidence ~= nil and evidence[req] == true end
	if type(req) == "table" then
		if not evidence then return false end
		for _, k in ipairs(req) do
			if not evidence[k] then return false end
		end
		return true
	end
	return false
end


---Finds the first rule matching the aura type and measured duration.
---Tries spec-level rules first for precision, falls back to class-level rules.
---@param unit string   caster unit for EXTERNAL_DEFENSIVE, recipient unit for BIG_DEFENSIVE/IMPORTANT
---@param auraTypes table<string,boolean>
---@param measuredDuration number
---@param context MatchRuleContext?
---@return table?
local function MatchRule(unit, auraTypes, measuredDuration, context)
	local _, classToken = UnitClass(unit)
	if not classToken then
		return nil
	end

	local specId = GetSpecId(unit)
	local evidence = context and context.Evidence
	local activeCooldowns = context and context.ActiveCooldowns

	local function tryRuleList(ruleList)
		if not ruleList then
			return nil
		end
		local fallback = nil
		for _, rule in ipairs(ruleList) do
			local excluded = rule.ExcludeIfTalent and fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
			local required = rule.RequiresTalent and not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
			if excluded or required then
				-- Skip: talent gate not satisfied.
			else
				local expectedDuration = rule.SpellId
						and fcdTalents:GetUnitBuffDuration(unit, specId, classToken, rule.SpellId, rule.BuffDuration)
					or rule.BuffDuration
				local typeMatch = AuraTypeMatchesRule(auraTypes, rule)
				if typeMatch then
					-- RequiresEvidence = nil       -> no constraint (matches any evidence state)
					-- RequiresEvidence = false     -> requires NO evidence
					-- RequiresEvidence = "Cast" etc -> requires that key present in the EvidenceSet
					local req = rule.RequiresEvidence
					local evidenceOk = EvidenceMatchesReq(req, evidence)
					if evidenceOk then
						-- MinDuration = true        -> duration must be >= expected (e.g. Combustion which can be extended)
						-- ExternalDefensive = true  -> accept any duration up to expected (target can remove the buff)
						-- CanCancelEarly = true     -> accept any duration up to expected (buff can be cancelled/dispelled early)
						-- otherwise                -> require duration close to expected (±tolerance)
						local durationOk
						if rule.MinDuration then
							durationOk = measuredDuration >= expectedDuration - tolerance
						elseif rule.CanCancelEarly == true then
							durationOk = measuredDuration <= expectedDuration + tolerance
						else
							durationOk = math.abs(measuredDuration - expectedDuration) <= tolerance
						end
						if durationOk then
							-- Prefer rules whose SpellId is not already on cooldown.
							-- This handles cases like AMS (CanCancelEarly) overlapping in duration
							-- with Icebound Fortitude when we don't have talent data for the +40% duration.
							local alreadyOnCd = activeCooldowns and rule.SpellId and activeCooldowns[rule.SpellId]
							if not alreadyOnCd then
								return rule
							elseif not fallback then
								fallback = rule
							end
						end
					end
				end
			end
		end
		return fallback
	end

	-- Spec rules take priority; fall through to class rules if no match.
	return tryRuleList(specId and rules.bySpec[specId]) or tryRuleList(rules.byClass[classToken])
end

-- Spell IDs treated as offensive cooldowns for the ShowOffensiveCooldowns option.
local offensiveSpellIds = {
	[375087] = true, -- Dragonrage
	[107574] = true, -- Avatar
	[121471] = true, -- Shadow Blades
	[31884]  = true, -- Avenging Wrath
	[216331] = true, -- Avenging Crusader
	[190319] = true, -- Combustion
	[288613] = true, -- Trueshot
	[228260] = true, -- Voidform
	[102560] = true, -- Incarnation: Chosen of Elune (Balance)
	[102543] = true, -- Incarnation: Avatar of Ashamane (Feral)
	[106951] = true, -- Berserk (Feral, same choice node as Incarnation)
	[102558] = true, -- Incarnation: Guardian of Ursoc (Guardian)
	[1250646] = true, -- Takedown
}

---Returns ordered list of abilities for a unit's known spells (spec rules first, then class fallback).
---Used to populate static icon slots that are always visible regardless of cooldown state.
---@class FcdStaticAbility
---@field SpellId number
---@field IsOffensive boolean
---@param unit string
---@return FcdStaticAbility[]
local function GetStaticAbilities(unit)
	local _, classToken = UnitClass(unit)
	if not classToken then
		return {}
	end

	local specId = GetSpecId(unit) or fcdTalents:GetUnitSpecId(unit)
	local seen = {}
	local result = {}

	local function addRules(ruleList)
		if not ruleList then return end
		for _, rule in ipairs(ruleList) do
			if rule.SpellId and not seen[rule.SpellId] then
				local excluded = rule.ExcludeIfTalent and fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
				local required = rule.RequiresTalent and not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
				if not excluded and not required then
					seen[rule.SpellId] = true
					result[#result + 1] = { SpellId = rule.SpellId, IsOffensive = offensiveSpellIds[rule.SpellId] == true }
				end
			end
		end
	end

	addRules(specId and rules.bySpec[specId])
	addRules(rules.byClass[classToken])

	return result
end

local function IsInArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "arena"
end

---@param entry FcdWatchEntry
---Builds the slot list shown in test mode.
local function BuildTestSlots(showOffensive, showDefensive, showTrinket, showTooltips, iconOptions)
	local now = GetTime()
	local slots = {}
	if showTrinket then
		slots[#slots + 1] = {
			Texture = trinketsTracker:GetDefaultIcon(),
			DurationObject = wowEx:CreateDuration(now - 45, 120),
			Alpha = 1,
			ReverseCooldown = false,
			Glow = false,
			FontScale = db.FontScale,
		}
	end
	local testSpells = {
		{ SpellId = 642,    StartOffset = 60,  Cooldown = 300, IsOffensive = false }, -- Divine Shield
		{ SpellId = 33206,  StartOffset = 30,  Cooldown = 180, IsOffensive = false }, -- Pain Suppression
		{ SpellId = 45438,  StartOffset = 120, Cooldown = 240, IsOffensive = false }, -- Ice Block
		{ SpellId = 190319, StartOffset = 10,  Cooldown = 120, IsOffensive = true  }, -- Combustion
	}
	for _, t in ipairs(testSpells) do
		if (not t.IsOffensive or showOffensive) and (t.IsOffensive or showDefensive) then
			local texture = spellCache:GetSpellTexture(t.SpellId)
			if texture then
				slots[#slots + 1] = {
					Texture = texture,
					SpellId = showTooltips and t.SpellId or nil,
					DurationObject = wowEx:CreateDuration(now - t.StartOffset, t.Cooldown),
					Alpha = 1,
					ReverseCooldown = iconOptions.ReverseCooldown,
					FontScale = db.FontScale,
				}
			end
		end
	end
	return slots
end

---Appends always-visible static ability slots, with a cooldown swipe when active.
local function AppendStaticSlots(slots, entry, now, showOffensive, showDefensive, showTooltips, iconOptions)
	local staticAbilities = GetStaticAbilities(entry.Unit)
	local hasActiveCd = false
	for _, ability in ipairs(staticAbilities) do
		if entry.ActiveCooldowns[ability.SpellId] then hasActiveCd = true end
	end
	for _, ability in ipairs(staticAbilities) do
		if (not ability.IsOffensive or showOffensive) and (ability.IsOffensive or showDefensive) then
			local texture = spellCache:GetSpellTexture(ability.SpellId)
			local cd = entry.ActiveCooldowns[ability.SpellId]
			if texture then
				local durationObject = nil
				if cd and now < cd.StartTime + cd.Cooldown then
					durationObject = wowEx:CreateDuration(cd.StartTime, cd.Cooldown)
				end
				slots[#slots + 1] = {
					Texture = texture,
					SpellId = showTooltips and ability.SpellId or nil,
					DurationObject = durationObject,
					Alpha = 1,
					ReverseCooldown = iconOptions.ReverseCooldown,
					FontScale = db.FontScale,
				}
			end
		end
	end
end

---Appends string-keyed (non-static) active-cooldown slots, pruning expired entries.
local function AppendDynamicSlots(slots, entry, now, showOffensive, showDefensive, showTooltips, iconOptions)
	for cdKey, cd in pairs(entry.ActiveCooldowns) do
		if type(cdKey) == "string" then
			if now >= cd.StartTime + cd.Cooldown then
				entry.ActiveCooldowns[cdKey] = nil
			elseif (not cd.IsOffensive or showOffensive) and (cd.IsOffensive or showDefensive) then
				local texture = spellCache:GetSpellTexture(cd.SpellId)
				if texture then
					slots[#slots + 1] = {
						Texture = texture,
						SpellId = showTooltips and cd.SpellId or nil,
						DurationObject = wowEx:CreateDuration(cd.StartTime, cd.Cooldown),
						Alpha = 1,
						ReverseCooldown = iconOptions.ReverseCooldown,
						FontScale = db.FontScale,
					}
				end
			end
		end
	end
end

local function UpdateDisplay(entry)
	local options = GetOptions()
	local anchorOptions = GetAnchorOptions()
	if not options or not anchorOptions then
		return
	end

	local container = entry.Container
	container:ResetAllSlots()

	local showTooltips = anchorOptions.ShowTooltips
	local iconOptions = anchorOptions.Icons

	local function FlushSlots(slots)
		for i, slotData in ipairs(slots) do
			if i > container.Count then
				break
			end
			container:SetSlot(i, slotData)
		end
	end

	local showOffensive = anchorOptions.ShowOffensiveCooldowns ~= false
	local showDefensive = anchorOptions.ShowDefensiveCooldowns ~= false
	local showTrinket = anchorOptions.ShowTrinket ~= false

	if testModeActive then
		FlushSlots(BuildTestSlots(showOffensive, showDefensive, showTrinket, showTooltips, iconOptions))
		return
	end

	local now = GetTime()
	local slots = {}

	-- Trinket: always slot 1 in arena so it lands at the priority position determined by InvertLayout.
	if showTrinket and IsInArena() then
		local durationData = trinketsTracker:GetUnitDuration(entry.Unit)
		slots[#slots + 1] = {
			Texture = trinketsTracker:GetDefaultIcon(),
			DurationObject = durationData or wowEx:CreateDuration(0, 0),
			Alpha = true,
			ReverseCooldown = false,
			Glow = false,
			FontScale = db.FontScale,
		}
	end

	AppendStaticSlots(slots, entry, now, showOffensive, showDefensive, showTooltips, iconOptions)
	AppendDynamicSlots(slots, entry, now, showOffensive, showDefensive, showTooltips, iconOptions)

	FlushSlots(slots)
end

---Evaluates all watched units and returns the best-matching rule and caster unit.
---Primary tiebreaker: most recent cast evidence wins (distinguishes caster from recipient).
---Secondary tiebreaker: for EXTERNAL_DEFENSIVE, a non-target is preferred when neither has cast evidence.
---@return table? rule
---@return string ruleUnit
local function FindBestCandidate(entry, tracked, measuredDuration)
	local rule = nil
	local ruleUnit = entry.Unit
	local bestTime = nil
	local isExternal = tracked.AuraTypes["EXTERNAL_DEFENSIVE"]

	local function consider(candidate, isTarget)
		-- Build candidate-specific evidence: share Debuff/Shield/UnitFlags from the aura's evidence,
		-- but only add Cast if THIS candidate has a CastSnapshot entry — so a cast by unit A cannot
		-- satisfy RequiresEvidence="Cast" when evaluating unit B.
		local candidateEvidence = nil
		if tracked.Evidence then
			for k in pairs(tracked.Evidence) do
				if k ~= "Cast" then
					candidateEvidence = candidateEvidence or {}
					candidateEvidence[k] = true
				end
			end
		end
		local castTime = tracked.CastSnapshot[candidate]
		if castTime and math.abs(castTime - tracked.StartTime) <= castWindow then
			candidateEvidence = candidateEvidence or {}
			candidateEvidence.Cast = true
		end
		local candidateRule = MatchRule(candidate, tracked.AuraTypes, measuredDuration, { Evidence = candidateEvidence, ActiveCooldowns = entry.ActiveCooldowns })
		if not candidateRule then return end
		local isBetter = not rule
			or (castTime and (not bestTime or castTime > bestTime))
			or (not castTime and not bestTime and isExternal and not isTarget)
		if isBetter then
			rule, ruleUnit, bestTime = candidateRule, candidate, castTime
		end
	end

	consider(entry.Unit, true)
	for _, e in pairs(watchEntries) do
		if e.Unit ~= entry.Unit then
			consider(e.Unit, false)
		end
	end

	return rule, ruleUnit
end

---Stores the matched cooldown across all caster entries, refreshes their displays,
---and schedules the cleanup timer.
local function CommitCooldown(entry, tracked, rule, ruleUnit, measuredDuration)
	-- Resolve the primary caster entry for routing/logging.
	local targetEntry = ruleUnit ~= entry.Unit and (GetEntryForUnit(ruleUnit) or entry) or entry

	-- Apply talent-based cooldown reduction.
	local cooldown = rule.Cooldown
	if rule.SpellId then
		local specId = GetSpecId(ruleUnit)
		local _, classToken = UnitClass(ruleUnit)
		if classToken then
			cooldown = fcdTalents:GetUnitCooldown(ruleUnit, specId, classToken, rule.SpellId, cooldown, measuredDuration)
		end
	end

	local auraTypesKey = tracked.AuraTypes["BIG_DEFENSIVE"] and "BIG_DEFENSIVE"
		or tracked.AuraTypes["EXTERNAL_DEFENSIVE"] and "EXTERNAL_DEFENSIVE"
		or "IMPORTANT"
	local cdKey = rule.SpellId or (auraTypesKey .. "_" .. rule.BuffDuration .. "_" .. rule.Cooldown)
	local cdData = {
		StartTime = tracked.StartTime,
		Cooldown = cooldown,
		SpellId = tracked.SpellId,
		IsOffensive = rule.SpellId ~= nil and offensiveSpellIds[rule.SpellId] == true,
	}

	-- Store in every watch entry for this unit so all containers (e.g. "player" and "raid3")
	-- for the same player show the cooldown swipe.
	-- Cancel any pending clear-timer from a previous detection of this same cooldown key.
	local casterEntries = {}
	for _, e in pairs(watchEntries) do
		if UnitIsUnit(e.Unit, ruleUnit) then
			local existing = e.ActiveCooldowns[cdKey]
			if existing and existing.Timer then
				existing.Timer:Cancel()
				existing.Timer = nil
			end
			e.ActiveCooldowns[cdKey] = cdData
			casterEntries[#casterEntries + 1] = e
		end
	end
	if #casterEntries == 0 then
		local existing = targetEntry.ActiveCooldowns[cdKey]
		if existing and existing.Timer then
			existing.Timer:Cancel()
			existing.Timer = nil
		end
		targetEntry.ActiveCooldowns[cdKey] = cdData
		casterEntries[1] = targetEntry
	end

	-- Refresh every caster entry except the detecting entry, which OnWatcherChanged
	-- already refreshes at the end of its own pass.
	for _, e in ipairs(casterEntries) do
		if e ~= entry then
			UpdateDisplay(e)
			ShowHideEntryContainer(e.Container.Frame, e.Anchor)
		end
	end

	local remaining = cooldown - measuredDuration
	if remaining <= 0 then
		for _, e in ipairs(casterEntries) do
			e.ActiveCooldowns[cdKey] = nil
		end
		return
	end
	cdData.Timer = C_Timer.NewTimer(remaining, function()
		cdData.Timer = nil
		for _, e in ipairs(casterEntries) do
			e.ActiveCooldowns[cdKey] = nil
			UpdateDisplay(e)
		end
	end)
end

---Called when a tracked aura instance disappears.
---Measures elapsed time and starts a cooldown entry if a rule matches.
---@param entry FcdWatchEntry
---@param tracked FcdTrackedAura
---@param now number
local function OnAuraRemoved(entry, tracked, now)
	local measuredDuration = now - tracked.StartTime
	local rule, ruleUnit = FindBestCandidate(entry, tracked, measuredDuration)

	if not rule then
		return
	end

	CommitCooldown(entry, tracked, rule, ruleUnit, measuredDuration)
end

---Builds a table of current aura instance IDs → { AuraTypes } from the watcher.
---GetDefensiveState doesn't expose which filter each aura came from, so each aura is
---re-checked via IsAuraFilteredOutByInstanceID to classify EXTERNAL_DEFENSIVE vs BIG_DEFENSIVE.
local function BuildCurrentAuraIds(unit, watcher)
	local currentIds = {}
	for _, aura in ipairs(watcher:GetDefensiveState()) do
		local id = aura.AuraInstanceID
		if id then
			local isExt = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|EXTERNAL_DEFENSIVE")
			local isImportant = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|IMPORTANT")
			local auraType = isExt and "EXTERNAL_DEFENSIVE" or "BIG_DEFENSIVE"
			local auraTypes = { [auraType] = true }
			if isImportant then
				auraTypes["IMPORTANT"] = true
			end
			currentIds[id] = { AuraTypes = auraTypes }
		end
	end
	-- Auras already added from GetDefensiveState are excluded from GetImportantState by the
	-- watcher's seen-set; IMPORTANT was already probed above via IsAuraFilteredOutByInstanceID.
	for _, aura in ipairs(watcher:GetImportantState()) do
		local id = aura.AuraInstanceID
		if id then
			if currentIds[id] then
				currentIds[id].AuraTypes["IMPORTANT"] = true
			else
				currentIds[id] = { AuraTypes = { IMPORTANT = true } }
			end
		end
	end
	return currentIds
end

---Begins tracking a newly detected aura: records evidence and a cast snapshot,
---then schedules a deferred backfill for events that may arrive after UNIT_AURA.
local function TrackNewAura(unit, trackedAuras, id, info, now)
	-- Collect concurrent Debuff/Shield/UnitFlags evidence (HARMFUL auras fire in the same
	-- UNIT_AURA batch). Cast evidence is intentionally excluded here — it is derived
	-- per-candidate from CastSnapshot in OnAuraRemoved so a cast by unit A cannot satisfy
	-- RequiresEvidence="Cast" when evaluating unit B.
	local evidence = BuildEvidenceSet(unit, now)

	-- Snapshot cast times so OnAuraRemoved can attribute the cooldown to the correct
	-- caster even after lastCastTime has been overwritten by subsequent casts.
	local castSnapshot = {}
	for snapshotUnit, snapshotTime in pairs(lastCastTime) do
		castSnapshot[snapshotUnit] = snapshotTime
	end

	trackedAuras[id] = {
		StartTime = now,
		AuraTypes = info.AuraTypes,
		Evidence = evidence,
		CastSnapshot = castSnapshot,
	}

	-- Deferred backfill: UNIT_SPELLCAST_SUCCEEDED and UNIT_ABSORB_AMOUNT_CHANGED can arrive
	-- slightly after UNIT_AURA. Augment Evidence and CastSnapshot once the window elapses.
	C_Timer.After(evidenceTolerance, function()
		local tracked = trackedAuras[id]
		if not tracked then return end
		local ev = BuildEvidenceSet(unit, now)
		if ev then
			tracked.Evidence = tracked.Evidence or {}
			for k in pairs(ev) do
				tracked.Evidence[k] = true
			end
		end
		-- Backfill casters whose UNIT_SPELLCAST_SUCCEEDED arrived after UNIT_AURA.
		-- Guard with castWindow to avoid picking up unrelated later casts.
		for snapshotUnit, snapshotTime in pairs(lastCastTime) do
			if math.abs(snapshotTime - now) <= castWindow and not tracked.CastSnapshot[snapshotUnit] then
				tracked.CastSnapshot[snapshotUnit] = snapshotTime
			end
		end
	end)
end

---Called by the UnitAuraWatcher after each state rebuild.
---Diffs the new defensive state against TrackedAuras, fires OnAuraRemoved for
---anything that disappeared, and records new arrivals.
---On full updates aura instance IDs are reassigned by the server; a missing ID does
---not necessarily mean the buff dropped — it may just have a new ID. We reconcile by
---SpellId: if the same spell is still present under a new ID, carry the original
---StartTime/Evidence/CastSnapshot forward instead of firing a false removal.
---@param entry FcdWatchEntry
---@param watcher Watcher
local function OnWatcherChanged(entry, watcher)
	if testModeActive then return end
	if not entry.Container.Frame:IsVisible() then return end
	if UnitCanAttack("player", entry.Unit) then return end

	-- Skip expensive rule-matching when no cooldown category is visible.
	local anchorOptions = GetAnchorOptions()
	if anchorOptions
		and anchorOptions.ShowOffensiveCooldowns == false
		and anchorOptions.ShowDefensiveCooldowns == false
	then
		UpdateDisplay(entry)
		return
	end

	local now = GetTime()
	local trackedAuras = entry.TrackedAuras
	local currentIds = BuildCurrentAuraIds(entry.Unit, watcher)

	-- Collect new IDs (present in currentIds but not yet tracked) for heuristic reconciliation.
	-- On full updates the server reassigns aura instance IDs, so a tracked ID disappearing does
	-- not necessarily mean the buff dropped. We match orphaned entries to new IDs by AuraTypes
	-- signature — the only non-secret identity information available to us.
	local unmatchedNewIds = {}
	for id in pairs(currentIds) do
		if not trackedAuras[id] then
			unmatchedNewIds[#unmatchedNewIds + 1] = id
		end
	end

	local function auraTypesSignature(auraTypes)
		local s = ""
		if auraTypes["BIG_DEFENSIVE"] then s = s .. "B" end
		if auraTypes["EXTERNAL_DEFENSIVE"] then s = s .. "E" end
		if auraTypes["IMPORTANT"] then s = s .. "I" end
		return s
	end

	-- Group unmatched new IDs by their AuraTypes signature.
	local newIdsBySignature = {}
	for _, id in ipairs(unmatchedNewIds) do
		local sig = auraTypesSignature(currentIds[id].AuraTypes)
		newIdsBySignature[sig] = newIdsBySignature[sig] or {}
		newIdsBySignature[sig][#newIdsBySignature[sig] + 1] = id
	end

	for id, tracked in pairs(trackedAuras) do
		if not currentIds[id] then
			local sig = auraTypesSignature(tracked.AuraTypes)
			local candidates = newIdsBySignature[sig]
			if candidates and #candidates > 0 then
				-- Carry tracking forward under the new instance ID.
				local reassignedId = table.remove(candidates, 1)
				trackedAuras[reassignedId] = tracked
			else
				OnAuraRemoved(entry, tracked, now)
			end
			trackedAuras[id] = nil
		end
	end

	for id, info in pairs(currentIds) do
		if not trackedAuras[id] then
			TrackNewAura(entry.Unit, trackedAuras, id, info, now)
		end
	end

	UpdateDisplay(entry)
end

---@param entry FcdWatchEntry
local function AnchorContainer(entry)
	local options = GetAnchorOptions()
	if not options then
		return
	end

	local frame = entry.Container.Frame
	local anchor = entry.Anchor

	frame:ClearAllPoints()
	frame:SetAlpha(1)
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	local rowsEnabled = options.Icons.Rows and options.Icons.Rows > 1

	if rowsEnabled then
		-- For multi-row, anchor the container's top edge so that the first row appears at
		-- the same position as the single-row icon (vertically centred on the party frame).
		-- Adding half an icon height to the Y offset achieves this because the top of the
		-- container sits half an icon above the first row's centre.
		local size = tonumber(options.Icons.Size) or 32
		local yOffset = options.Offset.Y + size / 2

		if options.Grow == "LEFT" then
			frame:SetPoint("TOPRIGHT", anchor, "LEFT", options.Offset.X, yOffset)
		elseif options.Grow == "RIGHT" then
			frame:SetPoint("TOPLEFT", anchor, "RIGHT", options.Offset.X, yOffset)
		else
			frame:SetPoint("TOP", anchor, "CENTER", options.Offset.X, yOffset)
		end
	else
		if options.Grow == "LEFT" then
			frame:SetPoint("RIGHT", anchor, "LEFT", options.Offset.X, options.Offset.Y)
		elseif options.Grow == "RIGHT" then
			frame:SetPoint("LEFT", anchor, "RIGHT", options.Offset.X, options.Offset.Y)
		else
			frame:SetPoint("CENTER", anchor, "CENTER", options.Offset.X, options.Offset.Y)
		end
	end
end

---Creates or updates the watch entry for a given anchor frame.
---@param anchor table
---@param unit string?
---@return FcdWatchEntry?
local function EnsureEntry(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	if units:IsPet(unit) or units:IsCompoundUnit(unit) then
		return nil
	end

	local options = GetOptions()
	local anchorOptions = GetAnchorOptions()
	if not options or not anchorOptions then
		return nil
	end

	if anchorOptions.ExcludeSelf and UnitIsUnit(unit, "player") then
		return nil
	end

	local entry = watchEntries[anchor]

	if not entry then
		local size = tonumber(anchorOptions.Icons.Size) or 32
		local maxIcons = tonumber(anchorOptions.Icons.MaxIcons) or 3
		-- noBorder = true: cooldown icons don't need debuff-style borders
		local container = iconSlotContainer:New(UIParent, maxIcons, size, db.IconSpacing or 2, "Friendly CDs", true)

		entry = {
			Anchor = anchor,
			Unit = unit,
			Container = container,
			TrackedAuras = {},
			ActiveCooldowns = {},
			Watcher = nil,
			CastEventFrame = nil,
		}
		watchEntries[anchor] = entry

		-- castEventFrame tracks self-cast times (evidence for RequiresEvidence="Cast" rules),
		-- unit flags changes, and HARMFUL aura additions (for Paladin Divine Shield vs Divine
		-- Protection disambiguation via Forbearance).
		-- IMPORTANT: UNIT_AURA must be registered here BEFORE unitAuraWatcher:New so that our handler
		-- fires before the watcher's — ensuring lastDebuffTime is set before OnWatcherChanged runs.
		local castEventFrame = CreateFrame("Frame")
		castEventFrame:SetScript("OnEvent", function(_, event, ...)
			-- Use entry.Unit rather than the closed-over `unit` so that if the
			-- frame is reassigned to a different player (unit token change) after
			-- EnsureEntry re-registers events, we key evidence into the correct unit.
			local u = entry.Unit
			if UnitCanAttack("player", u) then return end
			if event == "UNIT_SPELLCAST_SUCCEEDED" then
				local now = GetTime()
				if lastCastTime[u] ~= now then
					lastCastTime[u] = now
				end
			elseif event == "UNIT_FLAGS" then
				local now = GetTime()
				local isFeign = UnitIsFeignDeath(u)
				if isFeign and not lastFeignDeathState[u] then
					lastFeignDeathTime[u] = now
				end
				lastFeignDeathState[u] = isFeign
				if not isFeign then
					lastUnitFlagsTime[u] = now
				end
			elseif event == "UNIT_AURA" then
				-- Detect HARMFUL aura additions (e.g. Forbearance from Divine Shield).
				-- All aura data is secret, but IsAuraFilteredOutByInstanceID is safe to use in conditionals.
				local _, updateInfo = ...
				if updateInfo and not updateInfo.isFullUpdate and updateInfo.addedAuras then
					for _, aura in ipairs(updateInfo.addedAuras) do
						if
							aura.auraInstanceID
							and not C_UnitAuras.IsAuraFilteredOutByInstanceID(u, aura.auraInstanceID, "HARMFUL")
						then
							lastDebuffTime[u] = GetTime()
							break
						end
					end
				end
			end
		end)
		castEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit)
		castEventFrame:RegisterUnitEvent("UNIT_FLAGS", unit)
		castEventFrame:RegisterUnitEvent("UNIT_AURA", unit)
		entry.CastEventFrame = castEventFrame

		local watcher = unitAuraWatcher:New(unit, nil, { Defensives = true, Important = true })
		watcher:RegisterCallback(function(w)
			OnWatcherChanged(entry, w)
		end)
		-- M:New primed state before our callback was registered; seed TrackedAuras now.
		OnWatcherChanged(entry, watcher)
		entry.Watcher = watcher
	elseif entry.Unit ~= unit then
		-- Unit token changed (e.g. frame reassigned after group change)
		entry.Unit = unit
		entry.TrackedAuras = {}
		entry.ActiveCooldowns = {}
		entry.Container:ResetAllSlots()

		-- Re-register castEventFrame before creating the new watcher to preserve handler fire order.
		entry.CastEventFrame:UnregisterAllEvents()
		entry.CastEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit)
		entry.CastEventFrame:RegisterUnitEvent("UNIT_FLAGS", unit)
		entry.CastEventFrame:RegisterUnitEvent("UNIT_AURA", unit)

		entry.Watcher:Dispose()
		local watcher = unitAuraWatcher:New(unit, nil, { Defensives = true, Important = true })
		watcher:RegisterCallback(function(w)
			OnWatcherChanged(entry, w)
		end)
		OnWatcherChanged(entry, watcher)
		entry.Watcher = watcher
	end

	AnchorContainer(entry)
	ShowHideEntryContainer(entry.Container.Frame, anchor)

	return entry
end

local function EnsureAllEntries()
	for _, anchor in ipairs(frames:GetAll(true, testModeActive)) do
		EnsureEntry(anchor)
	end
end

local function DisableAll()
	for _, entry in pairs(watchEntries) do
		entry.Watcher:Disable()
		entry.CastEventFrame:UnregisterAllEvents()
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end
end

local function EnableAll()
	for _, entry in pairs(watchEntries) do
		-- Register castEventFrame events before Watcher:Enable to preserve handler fire order.
		entry.CastEventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", entry.Unit)
		entry.CastEventFrame:RegisterUnitEvent("UNIT_FLAGS", entry.Unit)
		entry.CastEventFrame:RegisterUnitEvent("UNIT_AURA", entry.Unit)
		entry.Watcher:Enable()
		entry.Watcher:ForceFullUpdate()
	end
end

function M:Refresh()
	local options = GetOptions()
	local anchorOptions = GetAnchorOptions()
	if not options or not anchorOptions then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker)

	if not moduleEnabled then
		DisableAll()
		return
	end

	EnableAll()
	EnsureAllEntries()

	for anchor, entry in pairs(watchEntries) do
		if anchorOptions.ExcludeSelf and UnitIsUnit(entry.Unit, "player") then
			entry.Watcher:Disable()
			entry.CastEventFrame:UnregisterAllEvents()
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		else
			local size = tonumber(anchorOptions.Icons.Size) or 32
			local maxIcons = tonumber(anchorOptions.Icons.MaxIcons) or 3
			local rows = math.max(1, tonumber(anchorOptions.Icons.Rows) or 1)
			entry.Container:SetIconSize(size)
			entry.Container:SetCount(maxIcons)
			entry.Container:SetSpacing(db.IconSpacing or 2)
			entry.Container:SetRows(rows, anchorOptions.Grow, anchorOptions.Grow ~= "RIGHT")
			AnchorContainer(entry)
			ShowHideEntryContainer(entry.Container.Frame, anchor)
			UpdateDisplay(entry)
		end
	end
end

function M:RefreshDisplays()
	for _, entry in pairs(watchEntries) do
		UpdateDisplay(entry)
	end
end

function M:StartTesting()
	testModeActive = true
	M:Refresh()
end

function M:StopTesting()
	testModeActive = false

	for _, entry in pairs(watchEntries) do
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end

	M:Refresh()
end

function M:Init()
	db = mini:GetSavedVars()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event)
		if event == "GROUP_ROSTER_UPDATE" then
			C_Timer.After(0, function()
				M:Refresh()
			end)
		elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
			-- Defer so FriendlyCooldownTalents updates spec/talent data first.
			C_Timer.After(0, function()
				M:RefreshDisplays()
			end)
		elseif event == "UNIT_FACTION" then
			M:RefreshDisplays()
		elseif event == "PVP_MATCH_STATE_CHANGED" then
			if C_PvP.GetActiveMatchState() == Enum.PvPMatchState.StartUp then
				for _, entry in pairs(watchEntries) do
					entry.ActiveCooldowns = {}
					entry.TrackedAuras = {}
					UpdateDisplay(entry)
				end
			end
		end
	end)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("UNIT_FACTION")

	EventRegistry:RegisterCallback("EditMode.Enter", function()
		editModeActive = true
		for _, entry in pairs(watchEntries) do
			entry.Container.Frame:Hide()
		end
	end)
	EventRegistry:RegisterCallback("EditMode.Exit", function()
		editModeActive = false
		M:Refresh()
	end)

	-- Refresh trinket slot whenever arena cooldown data changes.
	trinketsTracker:RegisterCallback(function(unit)
		if unit then
			local entry = GetEntryForUnit(unit)
			if entry then
				UpdateDisplay(entry)
			end
		else
			M:RefreshDisplays()
		end
	end)

	fcdTalents:RegisterTalentCallback(function(playerName)
		-- playerName is a realm-stripped short name.
		-- GetEntryForUnit uses UnitIsUnit which is unreliable with bare player names and fails
		-- for cross-realm players whose UnitNameUnmodified returns "Name-RealmName".
		-- Iterate directly and compare short names so the display always refreshes.
		for _, entry in pairs(watchEntries) do
			local entryName = UnitNameUnmodified(entry.Unit)
			if entryName and not issecretvalue(entryName) then
				local shortName = entryName:match("^([^%-]+)") or entryName
				if shortName == playerName then
					UpdateDisplay(entry)
				end
			end
		end
	end)

	-- Track absorb shield applications globally. Divine Protection applies an absorb; Divine Shield
	-- does not. Used as concurrent evidence to disambiguate the two 8-second Paladin defensives.
	local absorbFrame = CreateFrame("Frame")
	absorbFrame:SetScript("OnEvent", function(_, _, unit)
		lastShieldTime[unit] = GetTime()
	end)
	absorbFrame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")

	if not wowEx:IsDandersEnabled() then
		if CompactUnitFrame_SetUnit then
			hooksecurefunc("CompactUnitFrame_SetUnit", function(frame, unit)
				if not frames:IsFriendlyCuf(frame) then
					return
				end
				if not moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker) then
					return
				end
				EnsureEntry(frame, unit)
			end)
		end

		if CompactUnitFrame_UpdateVisible then
			hooksecurefunc("CompactUnitFrame_UpdateVisible", function(frame)
				if not frames:IsFriendlyCuf(frame) then
					return
				end
				local entry = watchEntries[frame]
				if not entry then
					return
				end
				if not moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker) then
					entry.Container.Frame:Hide()
					return
				end
				local options = GetOptions()
				if options then
					ShowHideEntryContainer(entry.Container.Frame, frame)
				end
			end)
		end
	end

	local fs = FrameSortApi and FrameSortApi.v3

	-- Use FrameSort's inspector if available; otherwise start our own.
	if not (fs and fs.Inspector) then
		inspector:Init()
	end

	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(function()
			M:Refresh()
		end)
	end

	if moduleUtil:IsModuleEnabled(moduleName.FriendlyCooldownTracker) then
		EnsureAllEntries()
	end
end

---@class FriendlyCooldownTrackerModule
---@field Init fun(self: FriendlyCooldownTrackerModule)
---@field Refresh fun(self: FriendlyCooldownTrackerModule)
---@field StartTesting fun(self: FriendlyCooldownTrackerModule)
---@field StopTesting fun(self: FriendlyCooldownTrackerModule)

---@class FcdTrackedAura
---@field StartTime      number                  GetTime() when the aura was first detected
---@field AuraTypes      table<string,boolean>   set of applicable types: "BIG_DEFENSIVE", "IMPORTANT", "EXTERNAL_DEFENSIVE"
---@field SpellId        number                  aura.spellId (may be a secret value)
---@field Evidence       EvidenceSet?            evidence types collected at detection time; nil if none found
---@field CastSnapshot   table<string,number>    snapshot of lastCastTime at detection; used by OnAuraRemoved to attribute the cooldown to the correct caster

---@class FcdCooldownEntry
---@field StartTime number   GetTime() when the defensive was cast (buff start)
---@field Cooldown  number   Total cooldown duration in seconds
---@field SpellId   number   aura.spellId used for icon lookup (may be a secret value)

---@class FcdWatchEntry
---@field Anchor          table
---@field Unit            string
---@field Container       IconSlotContainer
---@field TrackedAuras    table<number, FcdTrackedAura>              keyed by auraInstanceID
---@field ActiveCooldowns table<number|string, FcdCooldownEntry>     keyed by rule.SpellId or primaryAuraType_buffDuration_cooldown
---@field Watcher         Watcher
---@field CastEventFrame  table

---@class MatchRuleContext
---@field Evidence EvidenceSet? evidence types present when the aura was detected; nil if none
---@field ActiveCooldowns table? active cooldowns keyed by SpellId; used to deprioritise already-cooling rules
