-- Builds a 12.1-mode environment for module lifecycle tests: real MiniFramework, Migrator
-- (providing the genuine default db), WoWEx (build 120100 so useAuraContainers is true at
-- module load), ModuleUtil, IconSlotContainer, and AuraContainerDisplay - with the WoW-side
-- and cross-module dependencies stubbed and controllable.
--
-- Call M.build() ONCE per test file, load the module under test with M.loadModule, then drive
-- it through the event frames (find them via aura_container_mock's frame registry).

local wow = require("WowApi")
local acm = require("AuraContainerMock")

local M = {}

function M.build()
	wow.setup()
	acm.setup()
	acm.reset()
	wow.setBuildNumber(120100)

	local env = {
		-- Controllable unit classification sets.
		enemies = {},
		pets = {},
		healers = {},
		-- Units outside the player's visible world (another instance or phase); caster filters
		-- cannot work on these.
		phased = {},
		plates = {},
		-- Group member tokens handed back by Units:FriendlyUnits(), i.e. the roster.
		friendlyUnits = {},
		inInstance = false,
		instanceType = "none",
		-- Drives UnitAffectingCombat; the combat events themselves are fired by the tests.
		inCombat = false,
		-- Raid target index per unit, read when an interrupt lands.
		raidTargets = {},
		-- What an interrupter's GUID resolves to. Inside an instance the client answers the name
		-- and class with secret values and the token with nothing at all.
		unitTokens = {},
		unitNames = {},
		unitClasses = {},
		-- What UnitClassBase("player") answers, for the class conditions.
		playerClass = "MAGE",
		-- Overrides for spell name / base spell lookups, used by the secret-ID identification.
		spellNames = {},
		baseSpells = {},
		-- AddAuraSound accounting, plus the live registrations by handle so a test can see which
		-- spells were handed to the engine and on which trigger.
		auraSoundAdds = 0,
		auraSoundRemoves = 0,
		auraSounds = {},
		kicks = {},
		-- Unit frames handed to the modules that anchor to raid frames (CC, Auras).
		unitFrames = {},
		-- PvP match state driving the alerts prep-room gate (99 = not in a match).
		matchState = 99,
		-- Everything the addon reported through mini:Notify. A module warning here is almost
		-- always a misuse (e.g. SetMaxIcons on a group key that does not exist), so tests
		-- assert this stays empty.
		notifications = {},
	}

	-- Globals

	_G.wipe = _G.wipe or function(t)
		for k in pairs(t) do
			t[k] = nil
		end
		return t
	end
	_G.hooksecurefunc = function() end
	_G.InCombatLockdown = function()
		return false
	end
	_G.UnitAffectingCombat = function()
		return env.inCombat == true
	end
	-- Raid markers: the index a unit carries, and the helper that paints one onto a texture.
	_G.GetRaidTargetIndex = function(unit)
		return env.raidTargets[unit]
	end
	_G.SetRaidTargetIconTexture = function(texture, index)
		texture._marker = index
	end
	_G.UnitTokenFromGUID = function(guid)
		return env.unitTokens[guid]
	end
	_G.UnitNameFromGUID = function(guid)
		return env.unitNames[guid]
	end
	-- Only the player is modelled: the class conditions on custom aura groups are about who the
	-- user is playing, and nothing else in the addon asks a token for its base class.
	_G.UnitClassBase = function(unit)
		return unit == "player" and env.playerClass or nil
	end
	-- Returns the localised name first and the class token second, as the client does.
	_G.UnitClassFromGUID = function(guid)
		local class = env.unitClasses[guid]

		return class, class
	end
	-- The secret-safe way to a class colour: a function call takes a secret token, where indexing
	-- RAID_CLASS_COLORS with one would throw. The colour object it hands back is an ordinary
	-- table whose components are secret, so they can be given to a setter but never read.
	_G.C_ClassColor = {
		GetClassColor = function(token)
			if issecretvalue(token) then
				return { r = wow.markSecret({}), g = wow.markSecret({}), b = wow.markSecret({}) }
			end

			return _G.RAID_CLASS_COLORS[token]
		end,
	}
	_G.IsInInstance = function()
		return env.inInstance, env.instanceType
	end
	_G.IsInRaid = function()
		return false
	end
	_G.UnitExists = function()
		return true
	end
	_G.PlaySoundFile = function() end
	_G.PlaySound = function() end
	-- Duration objects are opaque handles; test mode builds them for its synthetic cooldowns.
	_G.C_DurationUtil = {
		CreateDuration = function()
			return {
				SetTimeFromStart = function() end,
				GetRemainingDuration = function()
					return 0
				end,
			}
		end,
	}
	_G.GetSpecialization = function()
		return nil
	end
	_G.GetSpecializationInfo = function()
		return nil
	end
	_G.C_TTSSettings = { GetVoiceOptionID = function()
		return 0
	end }
	_G.C_CVar = { SetCVarBitfield = function() end }
	_G.UnitName = function(unit)
		return unit
	end
	-- Gates the auras module's spell-id filter; false once a duel makes the unit hostile.
	_G.UnitCanAssist = function(_, unit)
		return env.enemies[unit] ~= true
	end
	-- No third-party addon is "installed": the unit frame modules probe for ElvUI/Cell/... here.
	_G.C_AddOns = {
		GetAddOnEnableState = function()
			return 0
		end,
		GetAddOnMetadata = function()
			return nil
		end,
	}
	_G.C_PvP = { GetActiveMatchState = function()
		return env.matchState
	end }
	_G.C_Spell = _G.C_Spell or {}
	_G.C_Spell.GetSpellTexture = function(spellId)
		return "tex:" .. tostring(spellId)
	end
	-- Names are how a cast whose spell ID arrived secret still gets identified; the test env
	-- keeps them mechanical so a test can build the same string the tracker will look up.
	_G.C_Spell.GetSpellName = function(spellId)
		return env.spellNames[spellId] or ("spell:" .. tostring(spellId))
	end
	_G.C_Spell.GetBaseSpell = function(spellId)
		return env.baseSpells[spellId]
	end
	_G.Enum = _G.Enum or {}
	_G.Enum.PvPMatchState = { StartUp = 0 }
	_G.Enum.NamePlateEnemyPlayerAuraDisplay = { None = 0, Buffs = 1, Debuffs = 2, LossOfControl = 3 }
	_G.Enum.NamePlateEnemyNpcAuraDisplay = { CrowdControl = 1 }
	_G.Enum.NamePlateFriendlyPlayerAuraDisplay = { LossOfControl = 1 }
	_G.Enum.UnitAuraSoundTrigger = { Added = 0, ApplicationsIncreased = 1, Removed = 2 }
	_G.Enum.UnitAuraSortRule = { Default = 0, Unsorted = 1 }
	_G.Enum.UnitAuraSortDirection = { Normal = 0, Reverse = 1 }
	_G.DEBUFF_TYPE_NONE_COLOR = { r = 0.8, g = 0, b = 0 }
	_G.RAID_CLASS_COLORS = {
		MAGE = { r = 0.41, g = 0.8, b = 0.94 },
		ROGUE = { r = 1, g = 0.96, b = 0.41 },
		SHAMAN = { r = 0, g = 0.44, b = 0.87 },
		PRIEST = { r = 1, g = 1, b = 1 },
		WARLOCK = { r = 0.58, g = 0.51, b = 0.79 },
	}
	_G.C_NamePlate = {
		GetNamePlates = function()
			local list = {}
			for _, plate in pairs(env.plates) do
				list[#list + 1] = plate
			end
			return list
		end,
		GetNamePlateForUnit = function(token)
			return env.plates[token]
		end,
	}
	_G.C_UnitAuras = _G.C_UnitAuras or {}
	_G.C_UnitAuras.AddAuraSound = function(trigger, info)
		env.auraSoundAdds = env.auraSoundAdds + 1
		-- Copied field by field: callers reuse one scratch table across a registration loop, so
		-- keeping the reference would leave every entry showing the last spell id.
		env.auraSounds[env.auraSoundAdds] = {
			Trigger = trigger,
			Unit = info and info.unitToken,
			SpellId = info and info.spellID,
			File = info and info.soundFileName,
			Channel = info and info.outputChannel,
		}
		return env.auraSoundAdds
	end
	_G.C_UnitAuras.RemoveAuraSound = function(handle)
		env.auraSoundRemoves = env.auraSoundRemoves + 1
		env.auraSounds[handle] = nil
	end
	_G.LibStub = function(name)
		if name == "LibRangeCheck-3.0" then
			return {
				GetRange = function()
					return nil, nil
				end,
			}
		end
		return nil
	end
	_G.GetLocale = _G.GetLocale or function()
		return "enUS"
	end
	_G.MiniAurasDB = nil

	-- Real core files

	local addon = {
		Utils = {},
		Core = {},
		Modules = {},
		Config = { SoundLocation = "Interface\\AddOns\\MiniAuras\\Sounds\\" },
		L = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}),
	}
	env.addon = addon

	local function loadFile(path)
		assert(loadfile(path))("MiniAuras", addon)
	end

	local addonFiles = require("AddonFiles")
	addonFiles.load(addonFiles.framework, addon)
	loadFile("src/Core/ProfileManager.lua")
	-- The real resolver: with no LibSharedMedia in the mock it falls back to the bundled files,
	-- which is the path a client without a media addon takes anyway.
	loadFile("src/Core/Sounds.lua")
	loadFile("src/Core/AuraSounds.lua")
	addonFiles.load(addonFiles.migrator, addon)
	env.db = addon.Config.Migrator:GetAndUpgradeDb()

	-- Capture warnings instead of printing them; a warning is a test failure signal, not noise.
	addon.Framework.Notify = function(_, message, ...)
		env.notifications[#env.notifications + 1] = string.format(message, ...)
	end

	loadFile("src/Utils/WoWEx.lua")
	assert(addon.Utils.WoWEx:UseAuraContainers(), "env must be in 12.1 mode")
	loadFile("src/Utils/ModuleUtil.lua")
	addon.Utils.ModuleUtil:Init()
	loadFile("src/Utils/SlotDistribution.lua")
	loadFile("src/Core/Auras/AuraCategoryIds.lua")

	-- Cross-module stubs

	addon.Utils.FontUtil = {
		UpdateCooldownFontSize = function() end,
		UpdateStackFontSize = function() end,
	}
	addon.Utils.Auras = {
		IsPurgeableNonDefensive = function()
			return false
		end,
	}
	addon.Utils.Units = {
		FriendlyUnits = function()
			return env.friendlyUnits
		end,
		IsEnemy = function(_, unit)
			return env.enemies[unit] == true
		end,
		IsFriend = function(_, unit)
			return env.enemies[unit] ~= true
		end,
		IsPetOrMinion = function(_, unit)
			return env.pets[unit] == true
		end,
		IsCompoundUnit = function()
			return false
		end,
		IsCharmed = function()
			return false
		end,
		CanAttack = function(_, unit)
			return env.enemies[unit] == true
		end,
		CanAssist = function(_, unit)
			return env.enemies[unit] ~= true
		end,
		IsVisible = function(_, unit)
			return env.phased[unit] ~= true
		end,
		SameUnit = function(_, a, b)
			return a == b
		end,
		IsHealer = function(_, unit)
			return env.healers[unit] == true
		end,
		FindHealers = function()
			local list = {}
			for unit in pairs(env.healers) do
				list[#list + 1] = unit
			end
			table.sort(list)
			return list
		end,
	}
	addon.Core.InstanceOptions = {
		IsRaid = function()
			return false
		end,
	}
	addon.Core.Frames = {
		GetNextStrata = function(_, strata)
			return strata
		end,
		ShowHideFrame = function(_, frame)
			frame:Show()
		end,
		ShowHideDisplay = function(_, display)
			display:Show()
		end,
		GetAll = function()
			return env.unitFrames
		end,
		IsFriendlyCuf = function()
			return false
		end,
		HookCellSpotlightVisibility = function() end,
		HookNDuiVisibility = function() end,
		-- Mirrors the real helper's surface. The CUF/FrameSort/Danders globals do not exist in
		-- this environment, so it only records the callbacks for tests that want to fire them.
		InstallUnitFrameHooks = function(_, _, hooks)
			env.unitFrameHooks = hooks
		end,
	}
	-- Kick tracking is recorded rather than simulated: modules that re-target a container to a
	-- different unit have to move their kick subscription with it, and nothing else would show
	-- that they forgot.
	env.kickCalls = {}
	local kickKey = 0
	local function recordKick(action, unit, key)
		env.kickCalls[#env.kickCalls + 1] = { Action = action, Unit = unit, Key = key }
	end

	addon.Core.KickTracker = {
		Watch = function(_, unit)
			recordKick("Watch", unit)
		end,
		Unwatch = function(_, unit)
			recordKick("Unwatch", unit)
		end,
		GetKick = function(_, unit)
			return env.kicks[unit]
		end,
		Subscribe = function(_, unit)
			kickKey = kickKey + 1
			recordKick("Subscribe", unit, kickKey)
			return kickKey
		end,
		Unsubscribe = function(_, unit, key)
			recordKick("Unsubscribe", unit, key)
		end,
	}

	---Kick tracker calls for a unit since the given index into env.kickCalls.
	env.kickCallsSince = function(index, unit)
		local list = {}
		for i = index + 1, #env.kickCalls do
			local call = env.kickCalls[i]
			if not unit or call.Unit == unit then
				list[#list + 1] = call
			end
		end
		return list
	end
	-- Tripwire: the 12.1 path must never construct legacy watchers.
	addon.Core.UnitAuraWatcher = {
		New = function()
			error("legacy UnitAuraWatcher created on the 12.1 path")
		end,
	}

	-- Arena opponent specs, keyed by the arena unit token. The kick tracker reads them to work
	-- out the shortest interrupt cooldown it could be looking at.
	env.arenaSpecs = {}
	_G.GetNumArenaOpponentSpecs = function()
		local count = 0
		for _ in pairs(env.arenaSpecs) do
			count = count + 1
		end
		return count
	end
	addon.Core.InspectorFacade = {
		GetUnitSpecId = function(_, unit)
			return env.arenaSpecs[unit]
		end,
	}

	loadFile("src/Core/Kicks/KickData.lua")
	loadFile("src/Core/Kicks/KickEvents.lua")
	loadFile("src/Core/TestSpells.lua")
	loadFile("src/Core/EventGate.lua")
	loadFile("src/Core/Display/Pool.lua")
	loadFile("src/Core/Display/GrowAnchors.lua")
	-- Must precede IconSlotContainer and AuraContainerDisplay: both read the glow catalog at load.
	loadFile("src/Core/Display/GlowStyles.lua")
	loadFile("src/Core/Auras/AuraFilters.lua")
	loadFile("src/Core/DuelPoller.lua")
	loadFile("src/Core/Display/IconSlotContainer.lua")
	loadFile("src/Core/Kicks/KickSlot.lua")
	loadFile("src/Core/Display/AnchoredIcons.lua")
	addon.Core.AnchoredIcons:Init()
	loadFile("src/Core/Auras/AuraContainerDisplay.lua")

	env.loadModule = function(path)
		loadFile(path)
	end

	---Registers a mock nameplate frame for a unit token and returns it.
	env.addPlate = function(token)
		local plate = acm.NewFrame("Frame", "Plate_" .. token)
		plate.unitToken = token
		env.plates[token] = plate
		return plate
	end

	---Switches a module on or off for EVERY context. Setting `Always` alone is not enough - the
	---per-context flags (World, Arena, ...) still enable a module on their own, so a test that
	---only clears `Always` is testing an enabled module.
	---@param moduleKey string db.Modules key, e.g. "CCModule".
	---@param enabled boolean
	env.setModuleEnabled = function(moduleKey, enabled)
		local settings = assert(env.db.Modules[moduleKey], "no module " .. moduleKey).Enabled
		for context in pairs(settings) do
			settings[context] = enabled
		end
	end

	---Registers a mock raid/party unit frame for the CC + Auras anchors and returns it.
	env.addUnitFrame = function(unit, name)
		local frame = acm.NewFrame("Frame", name or ("CUF_" .. unit))
		frame.unit = unit
		frame.GetAttribute = function(_, key)
			return key == "unit" and frame.unit or nil
		end
		env.unitFrames[#env.unitFrames + 1] = frame
		return frame
	end

	---Total AuraContainers ever created. Pooled modules must not grow this on plate churn - a
	---display that leaks out of its pool shows up as an extra container here.
	env.auraContainerCount = function()
		local count = 0
		for _, frame in ipairs(acm.frames) do
			if frame._type == "AuraContainer" then
				count = count + 1
			end
		end
		return count
	end

	---All mock AuraContainers currently assigned to the given unit token.
	env.containersForUnit = function(token)
		local list = {}
		for _, frame in ipairs(acm.frames) do
			if frame._type == "AuraContainer" and frame._unit == token then
				list[#list + 1] = frame
			end
		end
		return list
	end

	local function groupCount(container)
		local n = 0
		for _ in pairs(container._groups) do
			n = n + 1
		end
		return n
	end
	env.groupCount = groupCount

	return env
end

return M
