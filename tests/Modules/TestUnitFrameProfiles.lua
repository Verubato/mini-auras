-- Crowd control and important auras, 12.1 container path: what a battleground does to the icons.
--
-- Entering one puts the player in a raid group, which swaps both modules onto their Raid options
-- and every icon size with them, and the same match makes auras secret for its whole length, where
-- a display's buttons can no longer be restyled. A display built for the other profile would wear
-- that profile's icon size until the player left.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

-- A crowd control display carries the one cc group. An important auras display carries that plus
-- the two spell-id-filtered helpful groups.
local CC_GROUPS = 1
local IMPORTANT_GROUPS = 3
-- What a walk costs from the tick that starts it, with headroom for a lane having to wait its turn
-- behind whatever else the sweep is working through.
local WALK_TICKS = 8

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("CrowdControl", true)
env.setModuleEnabled("ImportantAuras", true)
env.setModuleEnabled("PetCrowdControl", false)

local anchor = env.addUnitFrame("party4", "CUF_Profiles")

env.loadModule("src/Modules/CrowdControl/Display.lua")
env.loadModule("src/Modules/CrowdControl/Module.lua")
local crowdControl = env.addon.Modules.CrowdControlModule
crowdControl:Init()

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")
local importantAuras = env.addon.Modules.ImportantAurasModule
importantAuras:Init()

local ccProfiles = db.Modules.CrowdControl
local importantProfiles = db.Modules.ImportantAuras
local instanceOptions = env.addon.Core.InstanceOptions

local function refreshBoth()
	crowdControl:Refresh()
	importantAuras:Refresh()
	-- The groups are declared by the background walker, a group per turn, so a display's buttons
	-- do not exist until the walk has been given its ticks.
	acm.tickAll(WALK_TICKS)
end

---The display a module is drawing on the anchor, told apart from one parked for another profile by
---which of them is on screen.
---@param groupCount number
---@param unit string? The unit the anchor holds, defaulting to the fixture's own.
---@return table
local function liveDisplay(groupCount, unit)
	local found

	for _, container in ipairs(env.containersForUnit(unit or "party4")) do
		if env.groupCount(container) == groupCount and container:IsShown() then
			assert(not found, "two displays on screen at once")
			found = container
		end
	end

	return assert(found, "no display on screen for " .. (unit or "party4"))
end

---How many displays the anchor has ever been given for its unit, parked ones included. This is the
---frame cost of the profile split, and the client can never give one back.
---@param groupCount number
---@param unit string? The unit the anchor holds, defaulting to the fixture's own.
---@return number
local function displayCount(groupCount, unit)
	local count = 0

	for _, container in ipairs(env.containersForUnit(unit or "party4")) do
		if env.groupCount(container) == groupCount then
			count = count + 1
		end
	end

	return count
end

---The size the aura icons are actually drawn at, which is the one thing no restyle can correct
---inside a match.
---@param container table
---@return number
local function iconSize(container)
	local button = assert(container._buttons[1], "the display has no buttons yet")

	return button._width
end

---What a display stamped on its buttons' cooldowns, which is the owning module's text multiplier.
---@param container table
---@return number?
local function fontScale(container)
	local button = assert(container._buttons[1], "the display has no buttons yet")

	for _, frame in ipairs(acm.frames) do
		if frame._type == "Cooldown" and frame._parent == button then
			return frame.FontScale
		end
	end
end

---The size the kick and test icon container is drawn at. It leads the same row as the aura icons,
---so the two have to move together.
---@param moduleTag string
---@return number
local function kickIconSize(moduleTag)
	for _, frame in ipairs(acm.frames) do
		if frame.MiniCCModule == moduleTag and frame._type ~= "AuraContainer" and frame._parent == anchor then
			for _, slot in ipairs(acm.frames) do
				if slot._parent == frame then
					return slot._width
				end
			end
		end
	end

	return assert(nil, "no kick container on the anchor for " .. moduleTag)
end

---Everything a battleground changes at once: the player is in a raid group, and auras are secret
---for the length of the match rather than just for combat.
---@param inside boolean
local function SetInBattleground(inside)
	env.inInstance = inside
	env.instanceType = inside and "pvp" or "none"
	env.isRaid = inside
	acm.restricted = inside
	env.invalidateWorldState()
end

fw.describe("Unit frame auras - the profile a battleground switches to", function()
	fw.before_each(function()
		SetInBattleground(false)
		refreshBoth()
	end)

	fw.it("draws the open world sizes to start with", function()
		assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == importantProfiles.Default.Icons.Size,
			"important auras started at " .. iconSize(liveDisplay(IMPORTANT_GROUPS)))
		assert(iconSize(liveDisplay(CC_GROUPS)) == ccProfiles.Default.Icons.Size,
			"crowd control started at " .. iconSize(liveDisplay(CC_GROUPS)))
	end)

	fw.it("draws the raid sizes once the match has switched profiles", function()
		SetInBattleground(true)
		refreshBoth()

		assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == importantProfiles.Raid.Icons.Size,
			"important auras drew at " .. iconSize(liveDisplay(IMPORTANT_GROUPS))
			.. ", wanted " .. importantProfiles.Raid.Icons.Size)
		assert(iconSize(liveDisplay(CC_GROUPS)) == ccProfiles.Raid.Icons.Size,
			"crowd control drew at " .. iconSize(liveDisplay(CC_GROUPS))
			.. ", wanted " .. ccProfiles.Raid.Icons.Size)
	end)

	fw.it("puts the profiles it has already built back rather than building more", function()
		SetInBattleground(true)
		refreshBoth()

		local important = displayCount(IMPORTANT_GROUPS)
		local crowd = displayCount(CC_GROUPS)

		-- Out and back in twice. Nothing releases a display, so a rebuild per match would strand a
		-- raid's worth of frames every time the player queued.
		for _ = 1, 2 do
			SetInBattleground(false)
			refreshBoth()

			assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == importantProfiles.Default.Icons.Size,
				"important auras kept the raid size on the way out")
			assert(iconSize(liveDisplay(CC_GROUPS)) == ccProfiles.Default.Icons.Size,
				"crowd control kept the raid size on the way out")

			SetInBattleground(true)
			refreshBoth()

			assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == importantProfiles.Raid.Icons.Size,
				"important auras came back at the wrong size")
			assert(iconSize(liveDisplay(CC_GROUPS)) == ccProfiles.Raid.Icons.Size,
				"crowd control came back at the wrong size")
		end

		assert(displayCount(IMPORTANT_GROUPS) == important,
			"important auras grew to " .. displayCount(IMPORTANT_GROUPS) .. " displays for one anchor")
		assert(displayCount(CC_GROUPS) == crowd,
			"crowd control grew to " .. displayCount(CC_GROUPS) .. " displays for one anchor")
	end)

	fw.it("keeps the kick icon at the size the aura icons are still wearing", function()
		-- An arena rather than a battleground: the profile has not moved, so nothing is swapped in
		-- and the size the user just changed has nowhere to land until the match ends.
		env.inInstance = true
		env.instanceType = "arena"
		acm.restricted = true
		env.invalidateWorldState()

		local started = iconSize(liveDisplay(IMPORTANT_GROUPS))
		importantProfiles.Default.Icons.Size = started + 20

		importantAuras:Refresh()
		acm.tickAll(WALK_TICKS)

		assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == started, "the aura icons cannot resize here")
		assert(kickIconSize("Important Auras") == started,
			"the kick icon jumped to " .. kickIconSize("Important Auras")
			.. " beside aura icons still at " .. started)

		acm.restricted = false
		importantAuras:Refresh()
		acm.tickAll(WALK_TICKS)

		assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == started + 20, "the aura icons catch up")
		assert(kickIconSize("Important Auras") == started + 20, "and the kick icon with them")

		importantProfiles.Default.Icons.Size = started
	end)

	fw.it("relabels the display it has when the profile moves outside a match", function()
		-- An anchor of its own, so what it keeps is only what this test has put there.
		local joiner = env.addUnitFrame("party8", "CUF_Joiner")

		refreshBoth()

		local important = displayCount(IMPORTANT_GROUPS, "party8")
		local crowd = displayCount(CC_GROUPS, "party8")

		assert(important > 0 and crowd > 0, "fixture: the anchor has a display of each")

		-- Joining a raid in the open world is the same profile switch, with the restyle still able
		-- to reach the buttons, so it must cost no frames at all.
		env.isRaid = true
		env.invalidateWorldState()
		refreshBoth()

		assert(displayCount(IMPORTANT_GROUPS, "party8") == important,
			"important auras grew to " .. displayCount(IMPORTANT_GROUPS, "party8") .. " displays for one anchor")
		assert(displayCount(CC_GROUPS, "party8") == crowd,
			"crowd control grew to " .. displayCount(CC_GROUPS, "party8") .. " displays for one anchor")
		assert(iconSize(liveDisplay(IMPORTANT_GROUPS, "party8")) == importantProfiles.Raid.Icons.Size,
			"important auras drew at " .. iconSize(liveDisplay(IMPORTANT_GROUPS, "party8")))
		assert(iconSize(liveDisplay(CC_GROUPS, "party8")) == ccProfiles.Raid.Icons.Size,
			"crowd control drew at " .. iconSize(liveDisplay(CC_GROUPS, "party8")))

		joiner:Hide()
	end)

	fw.it("builds nothing for the profile a preview stands in for", function()
		local preview = env.addUnitFrame("party6", "CUF_Preview")

		SetInBattleground(true)
		refreshBoth()

		local built = displayCount(IMPORTANT_GROUPS, "party6")
		assert(built > 0, "fixture: the preview anchor has a display")

		-- Pressing Test on the other tab from inside a battleground. The preview draws through the
		-- container with the live display hidden, so a display built for it is one nobody can see.
		instanceOptions:SetTestIsRaid(false)
		importantAuras:StartTesting()
		acm.tickAll(WALK_TICKS)

		assert(displayCount(IMPORTANT_GROUPS, "party6") == built,
			"the preview allocated " .. (displayCount(IMPORTANT_GROUPS, "party6") - built) .. " displays")

		instanceOptions:SetTestIsRaid(nil)
		importantAuras:StopTesting()
		preview:Hide()
	end)

	fw.it("gives a frame that becomes a pet the pet options rather than the member ones", function()
		local petOptions = db.Modules.PetCrowdControl
		local petAnchor = env.addUnitFrame("party5", "CUF_Pet")

		env.setModuleEnabled("PetCrowdControl", true)
		env.pets["partypet1"] = true
		-- Apart from every member size, so which options the display was built to is readable off
		-- the icons themselves.
		local petSize = petOptions.Icons.Size
		petOptions.Icons.Size = 14

		crowdControl:Refresh()
		acm.tickAll(WALK_TICKS)

		SetInBattleground(true)
		refreshBoth()

		-- Raid frames are recycled onto whatever the roster needs, pets included, and a display
		-- built for a member cannot be restyled down to the pet size inside the match.
		petAnchor.unit = "partypet1"
		crowdControl:Refresh()
		acm.tickAll(WALK_TICKS)

		assert(iconSize(liveDisplay(CC_GROUPS, "partypet1")) == petOptions.Icons.Size,
			"the pet drew at " .. iconSize(liveDisplay(CC_GROUPS, "partypet1"))
			.. ", wanted " .. petOptions.Icons.Size)

		-- The member display it kept has to come back rather than the pet's.
		petAnchor.unit = "party5"
		crowdControl:Refresh()
		acm.tickAll(WALK_TICKS)

		assert(iconSize(liveDisplay(CC_GROUPS, "party5")) == ccProfiles.Raid.Icons.Size,
			"the member came back at " .. iconSize(liveDisplay(CC_GROUPS, "party5")))

		petOptions.Icons.Size = petSize
		env.setModuleEnabled("PetCrowdControl", false)
		petAnchor:Hide()
	end)

	fw.it("takes each important auras tab's own font scale into that tab's display", function()
		local defaultScale = importantProfiles.Default.FontScale
		local raidScale = importantProfiles.Raid.FontScale

		importantProfiles.Default.FontScale = 1.4
		importantProfiles.Raid.FontScale = 0.7

		refreshBoth()

		assert(fontScale(liveDisplay(IMPORTANT_GROUPS)) == 1.4,
			"the open world tab drew at " .. tostring(fontScale(liveDisplay(IMPORTANT_GROUPS))))

		SetInBattleground(true)
		refreshBoth()

		assert(fontScale(liveDisplay(IMPORTANT_GROUPS)) == 0.7,
			"the raid tab drew at " .. tostring(fontScale(liveDisplay(IMPORTANT_GROUPS))))

		importantProfiles.Default.FontScale = defaultScale
		importantProfiles.Raid.FontScale = raidScale
	end)

	fw.it("takes each crowd control tab's own font scale into that tab's display", function()
		local defaultScale = ccProfiles.Default.FontScale
		local raidScale = ccProfiles.Raid.FontScale

		ccProfiles.Default.FontScale = 1.4
		ccProfiles.Raid.FontScale = 0.7

		refreshBoth()

		assert(fontScale(liveDisplay(CC_GROUPS)) == 1.4,
			"the open world tab drew at " .. tostring(fontScale(liveDisplay(CC_GROUPS))))

		SetInBattleground(true)
		refreshBoth()

		assert(fontScale(liveDisplay(CC_GROUPS)) == 0.7,
			"the raid tab drew at " .. tostring(fontScale(liveDisplay(CC_GROUPS))))

		ccProfiles.Default.FontScale = defaultScale
		ccProfiles.Raid.FontScale = raidScale
		-- Inside the match still, so the spares waiting on the list are rebuilt to the restored
		-- look rather than left carrying this test's.
		refreshBoth()
		acm.tickAll(WALK_TICKS)
	end)

	fw.it("takes the pet module's font scale on a pet and the member one elsewhere", function()
		local petOptions = db.Modules.PetCrowdControl
		local petAnchor = env.addUnitFrame("party9", "CUF_PetFont")

		env.setModuleEnabled("PetCrowdControl", true)
		env.pets["partypet2"] = true
		petAnchor.unit = "partypet2"

		local ccScale = ccProfiles.Default.FontScale
		local petScale = petOptions.FontScale

		ccProfiles.Default.FontScale = 0.75
		petOptions.FontScale = 1.4

		crowdControl:Refresh()
		acm.tickAll(WALK_TICKS)

		assert(fontScale(liveDisplay(CC_GROUPS, "partypet2")) == 1.4,
			"the pet drew at " .. tostring(fontScale(liveDisplay(CC_GROUPS, "partypet2"))))
		assert(fontScale(liveDisplay(CC_GROUPS, "party4")) == 0.75,
			"the member drew at " .. tostring(fontScale(liveDisplay(CC_GROUPS, "party4"))))

		ccProfiles.Default.FontScale = ccScale
		petOptions.FontScale = petScale
		env.setModuleEnabled("PetCrowdControl", false)
		env.pets["partypet2"] = nil
		petAnchor:Hide()
	end)

	fw.it("rebuilds a display it kept for a profile the settings have moved under", function()
		SetInBattleground(true)
		refreshBoth()

		local raidSize = importantProfiles.Raid.Icons.Size

		SetInBattleground(false)
		refreshBoth()

		-- Between matches, which is when a player sits down and changes their settings. The kept
		-- display still wears the old size and no restyle can reach it in the next match.
		importantProfiles.Raid.Icons.Size = raidSize + 15

		SetInBattleground(true)
		refreshBoth()

		assert(iconSize(liveDisplay(IMPORTANT_GROUPS)) == raidSize + 15,
			"came back at " .. iconSize(liveDisplay(IMPORTANT_GROUPS)) .. ", wanted " .. (raidSize + 15))

		importantProfiles.Raid.Icons.Size = raidSize
	end)

	fw.it("nothing was reported through Notify", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)

fw.describe("Unit frame auras - warming up inside a match", function()
	fw.before_each(function()
		SetInBattleground(false)
		refreshBoth()
	end)

	fw.it("converges on spares a frame can actually be handed", function()
		-- A spare bakes its look in, and a restyle is refused for the length of a match, so one
		-- built to the open world profile can never be handed out here. Left on the list it counts
		-- towards the target, and every frame that turns up pays to build its own display.
		SetInBattleground(true)
		refreshBoth()
		acm.tickAll(WALK_TICKS * 2)

		local before = env.auraContainerCount()

		env.addUnitFrame("party7", "CUF_Joined")
		refreshBoth()

		assert(env.auraContainerCount() == before,
			"the frame built its own containers instead of taking the waiting ones")
		assert(#env.containersForUnit("party7") == 2, "and both of them track the new unit")
	end)

	fw.it("nothing was reported through Notify", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
