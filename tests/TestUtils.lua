-- Tier 2 pure-logic tests: SlotDistribution, ModuleUtil (enable gating + icon sizing),
-- WoWEx (12.1 build gate + styling restriction), Array, and AuraCategoryIds sanity.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

local function loadModule(path, addon)
	local fn = assert(loadfile(path))
	fn("MiniCC", addon)
	return addon
end

local function newAddon(db)
	return {
		Utils = {},
		Core = {},
		Framework = {
			GetSavedVars = function()
				return db
			end,
		},
		Modules = {},
		Config = {},
	}
end

-- SlotDistribution

local slotAddon = loadModule("src/Utils/SlotDistribution.lua", newAddon({}))
local slots = slotAddon.Utils.SlotDistribution

fw.describe("SlotDistribution.Calculate", function()
	local function calc(...)
		local cc, def, imp = slots.Calculate(...)
		return cc .. "," .. def .. "," .. imp
	end

	fw.it("returns zeros when nothing is active", function()
		assert(calc(10, 0, 0, 0) == "0,0,0")
	end)

	fw.it("guarantees each active category a slot, then fills by priority", function()
		assert(calc(10, 3, 2, 1) == "3,2,1", "capped by counts: " .. calc(10, 3, 2, 1))
		assert(calc(4, 2, 2, 2) == "2,1,1", "priority gets the spare slot: " .. calc(4, 2, 2, 2))
	end)

	fw.it("round-robins by priority when slots are scarcer than categories", function()
		assert(calc(2, 5, 5, 5) == "1,1,0", "cc and defensive win: " .. calc(2, 5, 5, 5))
		assert(calc(1, 0, 4, 4) == "0,1,0", "first active category wins: " .. calc(1, 0, 4, 4))
	end)

	fw.it("never allocates more than the aura counts", function()
		assert(calc(8, 1, 0, 1) == "1,0,1")
		assert(calc(5, 10, 0, 2) == "3,0,2", "leftovers flow to the hungriest by priority: " .. calc(5, 10, 0, 2))
	end)
end)

-- Array

local arrayAddon = loadModule("src/Libs/MiniFramework/Framework/Tables.lua", newAddon({}))
local array = arrayAddon.Framework

fw.describe("Array", function()
	fw.it("reverses odd and even length arrays in place", function()
		local odd = { 1, 2, 3 }
		assert(array:Reverse(odd) == odd, "returns the same table")
		assert(odd[1] == 3 and odd[2] == 2 and odd[3] == 1)
		local even = { "a", "b", "c", "d" }
		array:Reverse(even)
		assert(even[1] == "d" and even[4] == "a")
		array:Reverse({})
	end)

	fw.it("appends preserving order", function()
		local dst = { 1 }
		array:Append({ 2, 3 }, dst)
		assert(#dst == 3 and dst[2] == 2 and dst[3] == 3)
		array:Append({}, dst)
		assert(#dst == 3)
	end)
end)

-- ModuleUtil

fw.describe("ModuleUtil:IsModuleEnabled", function()
	local moduleUtil, db

	local function setup(enabledSettings)
		db = { Modules = { TestModule = { Enabled = enabledSettings } } }
		local addon = loadModule("src/Utils/ModuleUtil.lua", newAddon(db))
		moduleUtil = addon.Utils.ModuleUtil
		moduleUtil:Init()
	end

	local function setWorld(inInstance, instanceType, inRaid)
		_G.IsInInstance = function()
			return inInstance, instanceType
		end
		_G.IsInRaid = function()
			return inRaid == true
		end
	end

	fw.it("defaults to enabled when settings are missing", function()
		setup(nil)
		setWorld(false, "none", false)
		assert(moduleUtil:IsModuleEnabled("TestModule") == true)
		assert(moduleUtil:IsModuleEnabled("UnknownModule") == true)
	end)

	fw.it("Always short-circuits every context", function()
		setup({ Always = true, Arena = false, World = false })
		setWorld(true, "arena", false)
		assert(moduleUtil:IsModuleEnabled("TestModule") == true)
	end)

	fw.it("selects the flag matching the instance context", function()
		setup({ Arena = true, BattleGrounds = false, Dungeons = true, Raid = false, World = false })
		setWorld(true, "arena", false)
		assert(moduleUtil:IsModuleEnabled("TestModule") == true, "arena flag")
		setWorld(true, "pvp", false)
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "battleground flag")
		setWorld(true, "party", false)
		assert(moduleUtil:IsModuleEnabled("TestModule") == true, "dungeon flag")
		setWorld(true, "raid", true)
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "raid flag")
	end)

	fw.it("open world uses Raid when grouped in a raid, else World", function()
		setup({ Raid = true, World = false })
		setWorld(false, "none", true)
		assert(moduleUtil:IsModuleEnabled("TestModule") == true, "world raid group -> Raid flag")
		setWorld(false, "none", false)
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "solo world -> World flag (false)")
	end)
end)

fw.describe("ModuleUtil:GetIconSize", function()
	local moduleUtil = loadModule("src/Utils/ModuleUtil.lua", newAddon({ Modules = {} })).Utils.ModuleUtil

	local function anchor(height, scale)
		return {
			GetHeight = function()
				return height
			end,
			GetEffectiveScale = function()
				return scale
			end,
		}
	end

	fw.it("percent mode derives from anchor height and effective scale", function()
		assert(moduleUtil:GetIconSize({ SizeIsPercent = true, SizePercent = 50 }, anchor(100, 1), 32, 80) == 50)
		assert(moduleUtil:GetIconSize({ SizeIsPercent = true, SizePercent = 50 }, anchor(100, 0.5), 32, 80) == 25)
	end)

	fw.it("degenerately small results fall back to the pixel size", function()
		assert(moduleUtil:GetIconSize({ SizeIsPercent = true, SizePercent = 10, Size = 24 }, anchor(20, 1), 32, 80) == 24)
	end)

	fw.it("pixel mode uses Size with fallback", function()
		assert(moduleUtil:GetIconSize({ Size = 40 }, nil, 32, 80) == 40)
		assert(moduleUtil:GetIconSize({}, nil, 32, 80) == 32)
	end)
end)

-- WoWEx

fw.describe("WoWEx 12.1 gates", function()
	local function loadWoWEx(buildNumber, inCombat, shouldAurasBeSecret)
		wow.setBuildNumber(buildNumber)
		_G.InCombatLockdown = function()
			return inCombat == true
		end
		if shouldAurasBeSecret == nil then
			_G.C_Secrets = nil
		else
			_G.C_Secrets = {
				ShouldAurasBeSecret = function()
					return shouldAurasBeSecret
				end,
			}
		end
		return loadModule("src/Utils/WoWEx.lua", newAddon({})).Utils.WoWEx
	end

	fw.it("UseAuraContainers flips on the 12.1 interface number", function()
		assert(loadWoWEx(120007):UseAuraContainers() == false)
		assert(loadWoWEx(120100):UseAuraContainers() == true)
		assert(loadWoWEx(120200):UseAuraContainers() == true)
	end)

	fw.it("IsAuraStylingRestricted covers combat, aura secrecy, and missing C_Secrets", function()
		assert(loadWoWEx(120100, false, false):IsAuraStylingRestricted() == false, "idle")
		assert(loadWoWEx(120100, true, false):IsAuraStylingRestricted() == true, "combat lockdown")
		assert(loadWoWEx(120100, false, true):IsAuraStylingRestricted() == true, "auras secret out of combat")
		assert(loadWoWEx(120100, false, nil):IsAuraStylingRestricted() == false, "no C_Secrets (12.0 client)")
	end)
end)

-- AuraCategoryIds sanity

fw.describe("AuraCategoryIds", function()
	local data = loadModule("src/Core/AuraCategoryIds.lua", newAddon({})).Core.AuraCategoryIds

	local function count(t)
		local n = 0
		for _ in pairs(t) do
			n = n + 1
		end
		return n
	end

	fw.it("has plausible list sizes", function()
		assert(count(data.CC) > 500, "CC list unexpectedly small: " .. count(data.CC))
		assert(count(data.Important) > 40, "Important list unexpectedly small: " .. count(data.Important))
		assert(count(data.Defensive) > 40, "Defensive list unexpectedly small: " .. count(data.Defensive))
	end)

	fw.it("is keyed by numeric spell ids with true values", function()
		for _, list in pairs({ data.CC, data.Important, data.Defensive }) do
			for id, value in pairs(list) do
				assert(type(id) == "number" and value == true, "bad entry: " .. tostring(id))
			end
		end
	end)

	fw.it("contains well-known anchor spells", function()
		assert(data.CC[408], "Kidney Shot in CC")
		assert(data.CC[118], "Polymorph in CC")
		assert(data.Important[377362], "Precognition in Important")
		assert(data.Defensive[45438], "Ice Block in Defensive")
	end)

	fw.it("Important and Defensive overlap only where the game reclassifies with talents", function()
		-- An overlap cannot double-render: the 12.1 filter tokens decide the category and
		-- partition with `!` negation, so these maps only ever say "do not veto this id in
		-- whichever group the game routes it to". Anti-Magic Shell reads as a defensive
		-- normally and as important once talented into Spellwarding, so it needs both.
		local reclassified = { [48707] = true, [410358] = true } -- Anti-Magic Shell
		for id in pairs(data.Important) do
			assert(not data.Defensive[id] or reclassified[id], "spell in both lists: " .. id)
		end
	end)
end)
