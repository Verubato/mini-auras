-- Tier 2 pure-logic tests: SlotDistribution, ModuleUtil (enable gating + icon sizing),
-- WoWEx (12.1 build gate + styling restriction), Array, and AuraCategoryIds sanity.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

local function loadModule(path, addon)
	local fn = assert(loadfile(path))
	fn("MiniAuras", addon)
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

fw.describe("ModuleUtil", function()
	local moduleUtil, db
	-- What the test preview is pretending the context is; nil outside test mode.
	local previewIsRaid

	local function setup(enabledSettings)
		db = { Modules = { TestModule = { Enabled = enabledSettings } } }
		previewIsRaid = nil

		local addon = newAddon(db)
		addon.Core.InstanceOptions = {
			GetTestIsRaid = function()
				return previewIsRaid
			end,
		}

		loadModule("src/Utils/ModuleUtil.lua", addon)
		moduleUtil = addon.Utils.ModuleUtil
		moduleUtil:Init()
	end

	-- A world flip in the client always arrives with an event ModuleUtil's own frame turns into
	-- an invalidation, so the test helper does the same.
	local function setWorld(inInstance, instanceType, inRaid, perSide)
		_G.IsInInstance = function()
			return inInstance, instanceType
		end
		_G.IsInRaid = function()
			return inRaid == true
		end
		_G.GetInstanceInfo = function()
			return "Test Zone", instanceType, 0, "", perSide or 0, 0, false, 0, 0, 0
		end
		moduleUtil:InvalidateWorldState()
	end

	fw.it("reports a battleground's team size and nothing else", function()
		-- What the prewarms size themselves against. Everywhere else the client's number counts
		-- the players the place fits rather than the enemies it puts in front of you, so a
		-- five-man would otherwise read as "prepare for five".
		setup(nil)
		setWorld(true, "pvp", false, 40)
		assert(moduleUtil:PvpTeamSize() == 40, "the battleground's own size")

		setWorld(true, "party", false, 5)
		assert(moduleUtil:PvpTeamSize() == nil, "a dungeon's player cap says nothing about mobs")

		setWorld(false, "none", false, 0)
		assert(moduleUtil:PvpTeamSize() == nil, "nothing outdoors, so callers keep their default")
	end)

	fw.it("sizes a prewarm off the place rather than the module asking", function()
		setup(nil)

		-- Numbers belonging to no module, so the shared rule is what is under test.
		local function target()
			return moduleUtil:PrewarmTarget(3, 20, 8)
		end

		-- An arena is asked for by name ahead of its size, which the client still reports.
		setWorld(true, "arena", false, 40)
		assert(target() == 3, "an arena sets its own")

		setWorld(true, "pvp", false, 10)
		assert(target() == 10, "one per enemy a side holds")

		setWorld(true, "pvp", false, 500)
		assert(target() == 20, "capped however big the side is")

		setWorld(true, "raid", false, 30)
		assert(target() == 8, "a raid's size is not an enemy count")

		setWorld(false, "none", false, 0)
		assert(target() == 8, "and the default outdoors")
	end)

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

	fw.it("housing hides everything, Always included", function()
		setup({ Always = true, Dungeons = true })
		setWorld(true, "party", false)
		_G.C_Housing = {
			IsOnNeighborhoodMap = function()
				return false
			end,
			IsInsideHouseOrPlot = function()
				return true
			end,
		}
		moduleUtil:InvalidateWorldState()
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "inside a house or plot")

		_G.C_Housing.IsInsideHouseOrPlot = function()
			return false
		end
		_G.C_Housing.IsOnNeighborhoodMap = function()
			return true
		end
		moduleUtil:InvalidateWorldState()
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "on the neighborhood map")

		_G.C_Housing.IsOnNeighborhoodMap = function()
			return false
		end
		moduleUtil:InvalidateWorldState()
		assert(moduleUtil:IsModuleEnabled("TestModule") == true, "outside housing again")
		_G.C_Housing = nil
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

	-- The preview tabs are what the user is really asking about: previewing the raid layout from
	-- the open world must read the Raid flag, and previewing the other tab must not borrow a
	-- context the player is not in - a dungeons-only module stays off in the world.
	fw.it("takes the raid question from the preview, not from the group", function()
		setup({ World = true, Arena = true, Dungeons = true, Raid = false, BattleGrounds = false })
		setWorld(false, "none", false)

		previewIsRaid = true
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "previewing a raid reads the Raid flag")

		previewIsRaid = false
		assert(moduleUtil:IsModuleEnabled("TestModule") == true, "and the other tab reads World")

		previewIsRaid = nil
		assert(moduleUtil:IsModuleEnabled("TestModule") == true, "back to the live zone when the preview ends")
	end)

	fw.it("never lets a preview borrow a context the player is not in", function()
		setup({ World = false, Arena = false, Dungeons = true, Raid = false, BattleGrounds = false })
		setWorld(false, "none", false)

		previewIsRaid = false
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "dungeons-only stays off in the world")

		previewIsRaid = true
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "and off previewing a raid")
	end)

	fw.it("keeps the zone's own answer while previewing", function()
		setup({ World = true, Arena = false, Dungeons = false, Raid = true, BattleGrounds = false })
		setWorld(true, "pvp", true)

		previewIsRaid = false
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "a battleground reads BattleGrounds")

		previewIsRaid = true
		assert(moduleUtil:IsModuleEnabled("TestModule") == false, "whichever tab is up")
	end)

	fw.it("lets Always win over the previewed context", function()
		setup({ Always = true, Raid = false, BattleGrounds = false })
		setWorld(false, "none", false)

		previewIsRaid = true
		assert(moduleUtil:IsModuleEnabled("TestModule") == true)
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

fw.describe("ModuleUtil:Coalesced", function()
	local moduleUtil = loadModule("src/Utils/ModuleUtil.lua", newAddon({})).Utils.ModuleUtil

	-- The suite's C_Timer.After runs its callback on the spot, which would collapse the
	-- distinction this is about; these hold the callbacks so the burst can be counted.
	local function withHeldTimers(body)
		local queued = {}
		local realAfter = _G.C_Timer.After

		_G.C_Timer.After = function(_, callback)
			queued[#queued + 1] = callback
		end

		local ok, err = pcall(body, queued)

		_G.C_Timer.After = realAfter

		assert(ok, err)
	end

	fw.it("runs once for a burst, on the next frame", function()
		withHeldTimers(function(queued)
			local runs = 0
			local queueRun = moduleUtil:Coalesced(function()
				runs = runs + 1
			end)

			for _ = 1, 10 do
				queueRun()
			end

			assert(runs == 0, "nothing runs until the frame turns over")
			assert(#queued == 1, "ten calls queue one timer, not ten (got " .. #queued .. ")")

			queued[1]()

			assert(runs == 1, "and the burst produces exactly one run (got " .. runs .. ")")
		end)
	end)

	fw.it("queues again after the pending run has gone", function()
		withHeldTimers(function(queued)
			local runs = 0
			local queueRun = moduleUtil:Coalesced(function()
				runs = runs + 1
			end)

			queueRun()
			queued[1]()
			queueRun()
			queued[2]()

			assert(runs == 2, "a later burst is not swallowed by the earlier one (got " .. runs .. ")")
		end)
	end)

	fw.it("a cancel drops the pending run", function()
		withHeldTimers(function(queued)
			local runs = 0
			local queueRun, cancelRun = moduleUtil:Coalesced(function()
				runs = runs + 1
			end)

			queueRun()
			cancelRun()
			queued[1]()

			assert(runs == 0, "the cancelled timer still fires, but must refuse (got " .. runs .. ")")
		end)
	end)

	fw.it("queues again after a cancel", function()
		withHeldTimers(function(queued)
			local runs = 0
			local queueRun, cancelRun = moduleUtil:Coalesced(function()
				runs = runs + 1
			end)

			queueRun()
			cancelRun()
			-- Lands before the cancelled timer has run, which is the case a plain flag gets wrong.
			queueRun()

			assert(#queued == 2, "the cancelled request no longer covers a later one")

			queued[1]()
			queued[2]()

			assert(runs == 1, "the stranded timer refuses and the later request runs (got " .. runs .. ")")
		end)
	end)

	fw.it("a cancel with nothing queued swallows nothing", function()
		withHeldTimers(function(queued)
			local runs = 0
			local queueRun, cancelRun = moduleUtil:Coalesced(function()
				runs = runs + 1
			end)

			cancelRun()
			queueRun()
			queued[1]()

			assert(runs == 1, "a cancel with nothing pending must not eat the next run (got " .. runs .. ")")
		end)
	end)

	fw.it("keeps two wrapped functions apart", function()
		withHeldTimers(function(queued)
			local first, second = 0, 0
			local queueFirst = moduleUtil:Coalesced(function()
				first = first + 1
			end)
			local queueSecond = moduleUtil:Coalesced(function()
				second = second + 1
			end)

			queueFirst()
			queueSecond()

			assert(#queued == 2, "each wrapper coalesces on its own")

			queued[1]()
			queued[2]()

			assert(first == 1 and second == 1, "and both run")
		end)
	end)
end)

-- WoWEx

fw.describe("WoWEx aura-styling gate", function()
	local function loadWoWEx(inCombat, shouldAurasBeSecret)
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

	fw.it("IsAuraStylingRestricted covers combat, aura secrecy, and missing C_Secrets", function()
		assert(loadWoWEx(false, false):IsAuraStylingRestricted() == false, "idle")
		assert(loadWoWEx(true, false):IsAuraStylingRestricted() == true, "combat lockdown")
		assert(loadWoWEx(false, true):IsAuraStylingRestricted() == true, "auras secret out of combat")
		assert(loadWoWEx(false, nil):IsAuraStylingRestricted() == false, "no C_Secrets to ask")
	end)
end)

-- 12.1 moved the specialization functions onto C_SpecializationInfo and the globals stopped
-- answering, which emptied every spec lookup in the addon: profiles stopped auto switching and
-- the kick tracker errored. The classic clients only ever had the globals, so both shapes have
-- to work, and a test that leaves both in place cannot tell the difference.

fw.describe("WoWEx specialization lookup", function()
	local FROST_DK = 251

	---@param shape string "modern" (12.1), "legacy", or "none"
	local function loadWoWEx(shape, specIndex, specId)
		local function Index()
			return specIndex
		end

		local function Info(index)
			if index ~= specIndex then
				return nil
			end
			return specId, "Frost", "A spec", 135773, "DAMAGER"
		end

		if shape == "modern" then
			_G.GetSpecialization = nil
			_G.GetSpecializationInfo = nil
			_G.C_SpecializationInfo = { GetSpecialization = Index, GetSpecializationInfo = Info }
		elseif shape == "legacy" then
			_G.C_SpecializationInfo = nil
			_G.GetSpecialization = Index
			_G.GetSpecializationInfo = Info
		else
			_G.C_SpecializationInfo = nil
			_G.GetSpecialization = nil
			_G.GetSpecializationInfo = nil
		end

		return loadModule("src/Utils/WoWEx.lua", newAddon({})).Utils.WoWEx
	end

	fw.it("reads the spec through C_SpecializationInfo when the globals are gone", function()
		assert(loadWoWEx("modern", 2, FROST_DK):GetPlayerSpecId() == FROST_DK, "12.1 client")
	end)

	fw.it("falls back to the globals on a client without C_SpecializationInfo", function()
		assert(loadWoWEx("legacy", 2, FROST_DK):GetPlayerSpecId() == FROST_DK, "classic client")
	end)

	fw.it("answers nil rather than erroring when neither shape is present", function()
		assert(loadWoWEx("none"):GetPlayerSpecId() == nil, "no spec api at all")
	end)

	fw.it("answers nil while the spec is not known yet", function()
		assert(loadWoWEx("modern", nil, nil):GetPlayerSpecId() == nil, "no index yet")
		assert(loadWoWEx("modern", 2, nil):GetPlayerSpecId() == nil, "index but no info yet")
		assert(loadWoWEx("modern", 2, 0):GetPlayerSpecId() == nil, "zero is not a spec")
	end)
end)

-- AuraCategoryIds sanity

fw.describe("AuraCategoryIds", function()
	local data = loadModule("src/Core/Auras/AuraCategoryIds.lua", newAddon({})).Core.AuraCategoryIds

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

	fw.it("Important and Defensive are disjoint", function()
		for id in pairs(data.Important) do
			assert(not data.Defensive[id], "spell in both lists: " .. id)
		end
	end)
end)

-- The change stamp behind every "has this moved?" test in the addon. What it replaced built a
-- string, so the traps are the ones a string could not have: a list that shrinks, a set whose
-- pairs order varies, and two keys sharing one set.
fw.describe("ChangeStamp", function()
	local function newStamps()
		local addon = newAddon({})
		loadModule("src/Utils/ChangeStamp.lua", addon)
		return addon.Utils.ChangeStamp:New()
	end

	local function stamp(stamps, key, ...)
		stamps:Begin(key)
		for i = 1, select("#", ...) do
			stamps:Add((select(i, ...)))
		end
		return stamps:Commit()
	end

	fw.it("keeps its number while nothing moves", function()
		local stamps = newStamps()
		local first = stamp(stamps, "k", 1, "a", true)

		assert(stamp(stamps, "k", 1, "a", true) == first, "same values, same number")
		assert(stamp(stamps, "k", 1, "a", false) ~= first, "a changed value moves it")
	end)

	fw.it("gives every key its own number", function()
		local stamps = newStamps()

		assert(stamp(stamps, "left", 1) ~= stamp(stamps, "right", 1), "keys never collide")
	end)

	fw.it("notices a list that gets shorter", function()
		-- The values are kept between calls, so a dropped tail would otherwise still match.
		local stamps = newStamps()
		local long = stamp(stamps, "k", 1, 2, 3)
		local short = stamp(stamps, "k", 1, 2)

		assert(short ~= long, "dropping a value counts as a change")
		assert(stamp(stamps, "k", 1, 2, 3) ~= short, "and putting it back counts again")
	end)

	fw.it("compares a colour by its components", function()
		local stamps = newStamps()

		stamps:Begin("k")
		stamps:AddColor({ 1, 0, 0 })

		local red = stamps:Commit()

		stamps:Begin("k")
		stamps:AddColor({ 1, 0, 0 })

		assert(stamps:Commit() == red, "a refilled scratch table still reads as the same colour")

		stamps:Begin("k")
		stamps:AddColor(nil)

		assert(stamps:Commit() ~= red, "and losing the colour is a change")
	end)

	fw.it("reads a spell-id set the same whatever order pairs hands it back", function()
		-- Sound registrations are rebuilt when this moves, so an unstable order would re-register
		-- every set on every login.
		local stamps = newStamps()
		local scratch = {}

		stamps:Begin("k")
		stamps:AddSet(scratch, { [12345] = true, [678] = true, [90] = true })

		local set = stamps:Commit()

		stamps:Begin("k")
		stamps:AddSet(scratch, { [90] = true, [12345] = true, [678] = true })

		assert(stamps:Commit() == set, "the same ids read the same")

		stamps:Begin("k")
		stamps:AddSet(scratch, { [12345] = true, [678] = true })

		assert(stamps:Commit() ~= set, "dropping one does not")

		stamps:Begin("k")
		stamps:AddSet(scratch, { [12345] = true, [678] = true, [90] = false })

		assert(stamps:Commit() ~= set, "and an id switched off is not in the set")
	end)

	fw.it("forgets a key that cannot come back", function()
		local stamps = newStamps()
		local before = stamp(stamps, "k", 1)

		stamps:Forget("k")

		assert(stamp(stamps, "k", 1) ~= before, "the key starts again from nothing")
	end)
end)
