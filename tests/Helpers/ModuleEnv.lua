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
		plates = {},
		inInstance = false,
		instanceType = "none",
		-- AddAuraSound accounting.
		auraSoundAdds = 0,
		auraSoundRemoves = 0,
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
	_G.Enum = _G.Enum or {}
	_G.Enum.PvPMatchState = { StartUp = 0 }
	_G.Enum.NamePlateEnemyPlayerAuraDisplay = { LossOfControl = 1 }
	_G.Enum.NamePlateEnemyNpcAuraDisplay = { CrowdControl = 1 }
	_G.Enum.NamePlateFriendlyPlayerAuraDisplay = { LossOfControl = 1 }
	_G.Enum.UnitAuraSoundTrigger = { Added = 0, ApplicationsIncreased = 1, Removed = 2 }
	_G.Enum.UnitAuraSortRule = { Default = 0, Unsorted = 1 }
	_G.Enum.UnitAuraSortDirection = { Normal = 0, Reverse = 1 }
	_G.DEBUFF_TYPE_NONE_COLOR = { r = 0.8, g = 0, b = 0 }
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
	_G.C_UnitAuras.AddAuraSound = function()
		env.auraSoundAdds = env.auraSoundAdds + 1
		return env.auraSoundAdds
	end
	_G.C_UnitAuras.RemoveAuraSound = function()
		env.auraSoundRemoves = env.auraSoundRemoves + 1
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
	_G.MiniCCDB = nil

	-- Real core files

	local addon = {
		Utils = {},
		Core = {},
		Modules = {},
		Config = { SoundLocation = "Interface\\AddOns\\MiniCC\\Sounds\\" },
		L = setmetatable({}, {
			__index = function(_, key)
				return key
			end,
		}),
	}
	env.addon = addon

	local function loadFile(path)
		assert(loadfile(path))("MiniCC", addon)
	end

	local addonFiles = require("AddonFiles")
	addonFiles.load(addonFiles.framework, addon)
	loadFile("src/Core/ProfileManager.lua")
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
	}
	addon.Utils.Auras = {
		IsPurgeableNonDefensive = function()
			return false
		end,
	}
	addon.Utils.Units = {
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
	loadFile("src/Core/TestSpells.lua")
	loadFile("src/Core/EventGate.lua")
	loadFile("src/Core/Display/Pool.lua")
	loadFile("src/Core/Display/GrowAnchors.lua")
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
