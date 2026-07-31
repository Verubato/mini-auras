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
	_G.C_PvP = { GetActiveMatchState = function()
		return 99
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
		Config = { MediaLocation = "Interface\\AddOns\\MiniCC\\Media\\" },
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

	loadFile("src/Utils/WoWEx.lua")
	assert(addon.Utils.WoWEx:UseAuraContainers(), "env must be in 12.1 mode")
	loadFile("src/Utils/ModuleUtil.lua")
	addon.Utils.ModuleUtil:Init()
	loadFile("src/Utils/SlotDistribution.lua")
	loadFile("src/Core/AuraSoundData.lua")

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
		GetAll = function()
			return {}
		end,
		IsFriendlyCuf = function()
			return false
		end,
		HookCellSpotlightVisibility = function() end,
		HookNDuiVisibility = function() end,
	}
	addon.Core.KickTracker = {
		Watch = function() end,
		Unwatch = function() end,
		GetKick = function(_, unit)
			return env.kicks[unit]
		end,
		Subscribe = function()
			return 1
		end,
		Unsubscribe = function() end,
	}
	-- Tripwire: the 12.1 path must never construct legacy watchers.
	addon.Core.UnitAuraWatcher = {
		New = function()
			error("legacy UnitAuraWatcher created on the 12.1 path")
		end,
	}

	loadFile("src/Core/EventGate.lua")
	loadFile("src/Core/DuelPoller.lua")
	loadFile("src/Core/IconSlotContainer.lua")
	loadFile("src/Core/AuraContainerDisplay.lua")

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
