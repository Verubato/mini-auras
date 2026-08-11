-- The custom aura module. The rule the whole design hangs off is that 12.1 only honours a
-- spell-id filter for helpful auras on assistable units and harmful auras on the rest, and
-- silently drops it otherwise - so the sharp end of these tests is the icon budget: a group
-- pointed at the wrong side of that rule must be budgeted to ZERO, never left running on a bare
-- HELPFUL/HARMFUL token that would match every aura on the unit.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local acm = require("AuraContainerMock")

local env = moduleEnv.build()
local addon = env.addon

env.loadModule("src/Core/Auras/SpellSearch.lua")
env.loadModule("src/Modules/CustomAuras/Groups.lua")
env.loadModule("src/Modules/CustomAuras/Sound.lua")
env.loadModule("src/Modules/CustomAuras/Recorder.lua")
env.loadModule("src/Modules/CustomAuras/Display.lua")
env.loadModule("src/Modules/CustomAuras/Module.lua")

local groups = addon.Modules.CustomAuras.Groups
local display = addon.Modules.CustomAuras.Display
local recorder = addon.Modules.CustomAuras.Recorder
local module = addon.Modules.CustomAurasModule
local db = env.db
local options = db.Modules.CustomAurasModule

-- Everything below authors its own groups, so the starter ones are switched off before Init:
-- they would otherwise be built against fixture spell names that are not installed yet, and
-- every "the container for the player" lookup would find one of them instead.
options.SeededDefaults = true

module:Init()

local ICE_BLOCK = 45438
local POLYMORPH = 118
-- Four ids the generated data really does carry for one ability. The mock names spells after
-- their id by default, so the shared name has to be installed before anything builds the search
-- index, or nothing would ever look like a variant of anything.
local TORRENT_IDS = { 33390, 36022, 47779, 222783 }

for _, spellId in ipairs(TORRENT_IDS) do
	env.spellNames[spellId] = "Arcane Torrent"
end

---Adds a group with the given overrides applied on top of the defaults.
---@param overrides table
---@return CustomAuraGroup
local function AddGroup(overrides)
	local group = groups:NewGroup(options, "Test")

	for key, value in pairs(overrides) do
		group[key] = value
	end

	groups:Normalise(group)
	options.Groups[#options.Groups + 1] = group

	return group
end

local function ClearGroups()
	for index = #options.Groups, 1, -1 do
		options.Groups[index] = nil
	end

	module:Refresh()
end

---The mock AuraContainer currently tracking a unit token, or nil.
---@param token string
---@return table?
local function ContainerFor(token)
	local list = env.containersForUnit(token)

	return list[1]
end

---@param container table
---@param key string
---@return number
local function Budget(container, key)
	local group = container._groups[key]

	return group and group.maxFrameCount or -1
end

fw.describe("CustomAuras - group defaults", function()
	fw.it("fills in everything a bare group is missing", function()
		local group = groups:Normalise({})

		assert(group.AuraType == "HELPFUL", "buffs are the default")
		assert(group.Anchor == "SCREEN", "screen anchored by default")
		assert(group.Unit == "player", "pointed at the player by default")
		assert(type(group.Spells) == "table" and #group.Spells == 0, "no spells yet")
		assert(group.Icons.Size > 0, "an icon size")
		assert(group.Icons.ReverseCooldown, "the swipe fills up, which reads as time running out")
		assert(group.Enabled, "switched on")
		assert(group.Position.Y > 0, "placed above the middle of the screen, not on top of it")
	end)

	fw.it("leaves a group dragged to the exact centre where it was put", function()
		local group = groups:Normalise({ Position = { X = 0, Y = 0 } })

		assert(group.Position.Y == 0, "a real zero is a position, not a missing value")
	end)

	fw.it("clamps values a hand-edited or imported group got wrong", function()
		local group = groups:Normalise({
			Icons = { Size = -5, Spacing = 1e6 },
			Grow = "SIDEWAYS",
			Unit = "vehicle",
			AuraType = "SOMETHING",
		})

		assert(group.Icons.Size >= groups.MinIconSize, "the icon size is floored")
		assert(group.Icons.Spacing <= 50, "the spacing is capped")
		assert(group.Grow == "CENTER", "an unknown grow direction falls back")
		assert(group.Unit == "player", "an unsupported unit falls back")
		assert(group.AuraType == "HELPFUL", "an unknown aura type falls back")
	end)

	fw.it("drops duplicate and nonsense spell ids", function()
		local group = groups:Normalise({ Spells = { POLYMORPH, POLYMORPH, "x", -3, 0, 1.5 } })

		assert(#group.Spells == 1 and group.Spells[1] == POLYMORPH, "one valid id survives")
	end)

	fw.it("caps how many spells one group can hold", function()
		local many = {}

		for index = 1, groups.MaxSpells + 50 do
			many[index] = index
		end

		assert(#groups:Normalise({ Spells = many }).Spells == groups.MaxSpells,
			"an oversized import is truncated rather than accepted")
	end)

	fw.it("hands out an id no later group can reuse", function()
		local before = options.NextId
		local first = groups:NewGroup(options)
		local second = groups:NewGroup(options)

		assert(first.Id ~= second.Id, "ids are unique")
		assert(options.NextId > before + 1, "the counter moves past both")
	end)
end)

fw.describe("CustomAuras - the groups a profile starts with", function()
	---A profile that has never been seeded, standing alone so the module's own options are
	---left exactly as the rest of this file expects them.
	---@return table
	local function FreshOptions()
		return { Groups = {}, NextId = 1 }
	end

	fw.it("creates the starter groups once", function()
		local fresh = FreshOptions()

		assert(groups:SeedDefaults(fresh), "the first run seeds")
		assert(#fresh.Groups == 3, "three of them")
		assert(not groups:SeedDefaults(fresh), "and the second run does nothing")
		assert(#fresh.Groups == 3, "so they are not doubled up")
	end)

	fw.it("never brings back one that was deleted", function()
		local fresh = FreshOptions()

		groups:SeedDefaults(fresh)

		for index = #fresh.Groups, 1, -1 do
			fresh.Groups[index] = nil
		end

		groups:SeedDefaults(fresh)

		assert(#fresh.Groups == 0, "the flag outlives the groups themselves")
	end)

	fw.it("tracks one self-buff each, glowing and bordered", function()
		local fresh = FreshOptions()

		groups:SeedDefaults(fresh)

		for _, group in ipairs(fresh.Groups) do
			assert(group.Unit == "player", group.Name .. " watches you")
			assert(group.AuraType == "HELPFUL", group.Name .. " is a buff")
			assert(#group.Spells == 1, group.Name .. " tracks one spell")
			assert(group.Icons.Glow and group.Icons.Border, group.Name .. " glows and has a border")
			assert(group.Icon == "", group.Name .. " borrows its spell's icon")
		end
	end)

	fw.it("tints each starter group to match its spell", function()
		local fresh = FreshOptions()

		groups:SeedDefaults(fresh)

		local precog, shroud, pi = fresh.Groups[1], fresh.Groups[2], fresh.Groups[3]

		assert(precog.Icons.Color.R == 1 and precog.Icons.Color.G == 1 and precog.Icons.Color.B == 1, "white precog")
		assert(pi.Icons.Color.R == 1 and pi.Icons.Color.G == 0.82 and pi.Icons.Color.B == 0, "gold PI")
		assert(shroud.Icons.Color.R == 0.64 and shroud.Icons.Color.B == 0.93, "purple shroud")
	end)

	fw.it("lays them out in a row near the top of the screen", function()
		local fresh = FreshOptions()
		local seen = {}

		groups:SeedDefaults(fresh)

		for _, group in ipairs(fresh.Groups) do
			assert(group.Position.Y > 0, "above the middle of the screen")
			assert(not seen[group.Position.X], "and each one beside the last, not on top of it")
			seen[group.Position.X] = true
		end
	end)

	fw.it("gives two of them a sound on the applied trigger", function()
		local fresh = FreshOptions()
		local withSound = 0

		groups:SeedDefaults(fresh)

		for _, group in ipairs(fresh.Groups) do
			if group.Sound.Applied ~= groups.NoSound then
				withSound = withSound + 1
			end

			assert(group.Sound.Removed == groups.NoSound, "and nothing on the other triggers")
			assert(group.Sound.Stacks == groups.NoSound, "either of them")
		end

		assert(withSound == 2, "Precognition and Power Infusion, but not Shroud")
	end)

	fw.it("hands out ids no later group can reuse", function()
		local fresh = FreshOptions()

		groups:SeedDefaults(fresh)

		assert(fresh.NextId > 3, "the counter moved past all three")
		assert(groups:NewGroup(fresh).Id ~= fresh.Groups[1].Id, "so a new group is not a collision")
	end)
end)

fw.describe("CustomAuras - duplicating a group", function()
	fw.it("copies everything but the id and the name", function()
		ClearGroups()

		local original = AddGroup({ Unit = "targetenemy", Spells = { POLYMORPH }, MaxIcons = 7 })
		local copy = groups:Duplicate(options, original.Id, "Copy")

		assert(copy, "the copy was made")
		assert(copy.Id ~= original.Id, "with an id of its own")
		assert(copy.Name == "Copy", "and the name it was given")
		assert(copy.Unit == original.Unit, "the unit came across")
		assert(copy.MaxIcons == 7, "and the settings")
		assert(copy.Spells[1] == POLYMORPH, "and the spells")
	end)

	fw.it("deep copies, so editing the copy leaves the original alone", function()
		ClearGroups()

		local original = AddGroup({ Spells = { POLYMORPH } })
		local copy = groups:Duplicate(options, original.Id, "Copy")

		copy.Spells[1] = ICE_BLOCK
		copy.Icons.Size = 99

		assert(original.Spells[1] == POLYMORPH, "the original's spells are its own")
		assert(original.Icons.Size ~= 99, "and so are its icons")
	end)

	fw.it("puts the copy straight after the group it came from", function()
		ClearGroups()

		local first = AddGroup({ Name = "A" })
		AddGroup({ Name = "B" })

		groups:Duplicate(options, first.Id, "A copy")

		assert(options.Groups[2].Name == "A copy", "next to its original, not at the end")
	end)

	fw.it("does nothing for an id that is not in the list", function()
		ClearGroups()
		AddGroup({ Name = "A" })

		assert(groups:Duplicate(options, "nope", "Copy") == nil, "an unknown id is refused")
		assert(#options.Groups == 1, "and nothing was added")
	end)
end)

fw.describe("CustomAuras - reordering", function()
	---@return CustomAuraGroup[]
	local function ThreeGroups()
		ClearGroups()

		return { AddGroup({ Name = "A" }), AddGroup({ Name = "B" }), AddGroup({ Name = "C" }) }
	end

	---@return string
	local function Order()
		local names = {}

		for _, group in ipairs(options.Groups) do
			names[#names + 1] = group.Name
		end

		return table.concat(names, "")
	end

	fw.it("moves a group down to another's place", function()
		local made = ThreeGroups()

		assert(groups:Move(options, made[1].Id, made[3].Id), "the move happened")
		assert(Order() == "BCA", "A landed where C was, got " .. Order())
	end)

	fw.it("moves a group up to another's place", function()
		local made = ThreeGroups()

		assert(groups:Move(options, made[3].Id, made[1].Id), "the move happened")
		assert(Order() == "CAB", "C landed at the front, got " .. Order())
	end)

	fw.it("does nothing when the source and target are the same", function()
		local made = ThreeGroups()

		assert(not groups:Move(options, made[2].Id, made[2].Id), "nothing to do")
		assert(Order() == "ABC", "the order is untouched")
	end)

	fw.it("does nothing for an id that is not in the list", function()
		local made = ThreeGroups()

		assert(not groups:Move(options, made[1].Id, "nope"), "an unknown target is refused")
		assert(Order() == "ABC", "the order is untouched")
	end)
end)

fw.describe("CustomAuras - group icons", function()
	fw.it("borrows the first tracked spell's icon when none was chosen", function()
		local group = groups:Normalise({ Spells = { ICE_BLOCK } })

		assert(group.Icon == "", "a new group has no icon of its own")
		assert(groups:GetIcon(group) == C_Spell.GetSpellTexture(ICE_BLOCK),
			"so the grid shows the thing it tracks")
	end)

	fw.it("keeps borrowing from the first spell added, whatever its id", function()
		-- POLYMORPH is the lower id, so anything that sorted the list would hand the icon to it.
		local group = groups:Normalise({ Spells = { ICE_BLOCK, POLYMORPH } })

		assert(group.Spells[1] == ICE_BLOCK, "the order spells were added in is the order kept")
		assert(groups:GetIcon(group) == C_Spell.GetSpellTexture(ICE_BLOCK),
			"so adding a second spell does not move the icon")
	end)

	fw.it("prefers the icon the user picked", function()
		local chosen = [[Interface\Icons\Chosen]]
		local group = groups:Normalise({ Spells = { ICE_BLOCK }, Icon = chosen })

		assert(groups:GetIcon(group) == chosen, "the choice wins")
	end)

	fw.it("treats the question mark as no icon at all", function()
		-- Picking it out of the browser has to mean the same as never picking one, or a spell
		-- added afterwards could never supply the icon.
		local group = groups:Normalise({
			Icon = [[Interface\Icons\INV_Misc_QuestionMark]],
			Spells = { ICE_BLOCK },
		})

		assert(group.Icon == "", "the question mark is stored as no choice")
		assert(groups:GetIcon(group) == C_Spell.GetSpellTexture(ICE_BLOCK), "so the spell wins")
	end)

	fw.it("recognises the question mark by file id too", function()
		local questionMark = 134400

		_G.GetFileIDFromPath = function()
			return questionMark
		end

		local group = groups:Normalise({ Icon = questionMark, Spells = { ICE_BLOCK } })

		_G.GetFileIDFromPath = nil

		assert(group.Icon == "", "the browser hands back ids, not paths")
	end)

	fw.it("keeps a chosen file id as a number", function()
		-- SetTexture will not take the digits as a string.
		local group = groups:Normalise({ Icon = 556000 })

		assert(group.Icon == 556000, "a file id survives normalisation intact")
	end)

	fw.it("falls back to a question mark with nothing to borrow from", function()
		local icon = groups:GetIcon(groups:Normalise({}))

		assert(type(icon) == "string" and icon:find("QuestionMark"), "an empty group still has a tile")
	end)
end)

fw.describe("CustomAuras - what a group is allowed to track", function()
	fw.it("refuses debuffs on units that are always friendly", function()
		assert(not groups:SupportsAuraType("player", "HARMFUL"), "not on yourself")
		assert(not groups:SupportsAuraType("pet", "HARMFUL"), "not on your pet")
		assert(groups:SupportsAuraType("player", "HELPFUL"), "buffs on yourself are fine")
		assert(groups:SupportsAuraType("targetenemy", "HARMFUL"), "debuffs on an enemy target are fine")
	end)

	-- The reaction is part of the unit choice, so each side offers the one aura type it can carry
	-- rather than letting a group be pointed at a combination that could never show anything.
	fw.it("offers one aura type per side of a split unit", function()
		assert(groups:SupportsAuraType("targetfriendly", "HELPFUL"), "buffs on a friendly target")
		assert(not groups:SupportsAuraType("targetfriendly", "HARMFUL"), "but not debuffs")
		assert(groups:SupportsAuraType("targetenemy", "HARMFUL"), "debuffs on an enemy target")
		assert(not groups:SupportsAuraType("targetenemy", "HELPFUL"), "but not buffs")
		assert(groups:SupportsAuraType("nameplatefriendly", "HELPFUL"), "and the same for plates")
		assert(not groups:SupportsAuraType("nameplatefriendly", "HARMFUL"), "either way round")
		assert(groups:SupportsAuraType("nameplateenemy", "HARMFUL"), "enemy plates carry debuffs")
		assert(not groups:SupportsAuraType("nameplateenemy", "HELPFUL"), "and not buffs")
	end)

	fw.it("corrects an aura type the chosen side cannot carry", function()
		local group = groups:Normalise({ Unit = "targetenemy", AuraType = "HELPFUL" })

		assert(group.AuraType == "HARMFUL", "an enemy target group is a debuff group")
	end)

	fw.it("keeps the split even for a group tracking by filter", function()
		-- Filter mode escapes the engine's spell id rule, but not the user's own choice of side.
		assert(not groups:SupportsAuraType("targetfriendly", "HARMFUL", groups.TrackingMode.Filters),
			"a friendly target group stays a buff group")
	end)

	fw.it("reports a group configured into an impossible state", function()
		local group = groups:Normalise({ Unit = "player", AuraType = "HARMFUL", Spells = { POLYMORPH } })
		local ok, reason = groups:Supports(group)

		assert(not ok and reason == "HARMFUL_ON_FRIENDLY", "the reason names the problem")
	end)

	fw.it("refuses a group with nothing to track, without a message about it", function()
		local ok, reason = groups:Supports(groups:Normalise({}))

		assert(not ok, "an empty group can never show anything")
		assert(reason == nil, "and needs no explaining - the spell list beside it is empty")
	end)

	fw.it("treats either nameplate side as the nameplate anchor", function()
		assert(groups:Normalise({ Unit = "nameplateenemy" }).Anchor == "NAMEPLATE", "enemy plates")
		assert(groups:Normalise({ Unit = "nameplatefriendly" }).Anchor == "NAMEPLATE", "and friendly")
		assert(groups:IsNameplateUnit("nameplateenemy"), "the display asks this way")
		assert(not groups:IsNameplateUnit("targetenemy"), "and a target is not a plate")
	end)

	fw.it("treats the unit frames choice as an anchor of its own", function()
		assert(groups:Normalise({ Unit = "unitframes" }).Anchor == "FRAMES", "one copy per frame")
		assert(groups:IsFrameUnit("unitframes"), "the display asks this way")
		assert(not groups:IsFrameUnit("nameplatefriendly"), "and a plate is not a unit frame")
		assert(not groups:IsNameplateUnit("unitframes"), "either way round")
		assert(groups:GetToken(groups:Normalise({ Unit = "unitframes" })) == nil,
			"there is no single token behind it")
	end)

	fw.it("refuses debuffs on unit frames by spell id, but not by filter", function()
		-- Group members are always assistable, so the engine drops a spell id map on a debuff.
		assert(groups:SupportsAuraType("unitframes", "HELPFUL"), "buffs on the group")
		assert(not groups:SupportsAuraType("unitframes", "HARMFUL"), "debuffs by id are dropped")
		assert(groups:SupportsAuraType("unitframes", "HARMFUL", groups.TrackingMode.Filters),
			"a filter string is honoured whatever the unit is")
	end)

	fw.it("gives a unit frame debuff group a reason of its own", function()
		local group = groups:Normalise({
			Unit = "unitframes",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
		})
		local ok, reason = groups:Supports(group)

		assert(not ok and reason == "HARMFUL_ON_GROUP",
			"the message is about group members, not about your pet")
	end)

	fw.it("has no side to wait for on the unit frames", function()
		assert(groups:GetWarning(groups:Normalise({ Unit = "unitframes" })) == nil,
			"a group frame always holds somebody friendly")
	end)

	fw.it("treats the arena frames choice as an anchor of its own", function()
		local group = groups:Normalise({ Unit = "arenaframes" })

		assert(group.Anchor == "ARENA", "one copy per arena enemy frame")
		assert(group.Offset.Y == 0, "sitting centred on the frame, like a unit frame copy")
		assert(groups:IsArenaFrameUnit("arenaframes"), "the display asks this way")
		assert(not groups:IsArenaFrameUnit("unitframes"), "and a party frame is not an arena one")
		assert(not groups:IsFrameUnit("arenaframes"), "either way round")
		assert(not groups:IsNameplateUnit("arenaframes"), "nor is it a plate")
		assert(groups:GetToken(group) == nil, "there is no single token behind it")
	end)

	fw.it("makes an arena frames group a debuff group whatever it was set to", function()
		local group = groups:Normalise({ Unit = "arenaframes", AuraType = "HELPFUL" })

		assert(group.AuraType == "HARMFUL", "buffs on an opponent are not on offer")
	end)

	fw.it("allows debuffs on arena frames in both tracking modes", function()
		-- The difference from the unit frames: an arena enemy is never assistable, so the engine
		-- honours a spell id map on a debuff there rather than dropping it.
		assert(groups:SupportsAuraType("arenaframes", "HARMFUL"), "debuffs by spell id")
		assert(groups:SupportsAuraType("arenaframes", "HARMFUL", groups.TrackingMode.Filters),
			"and by filter")
		assert(not groups:SupportsAuraType("arenaframes", "HELPFUL"), "but never buffs")
		assert(not groups:SupportsAuraType("arenaframes", "HELPFUL", groups.TrackingMode.Filters),
			"whichever way it tracks")
	end)

	fw.it("lets an arena frames group track spell ids without complaint", function()
		local group = groups:Normalise({ Unit = "arenaframes", Spells = { POLYMORPH } })

		assert(groups:Supports(group), "a spell list on an opponent is the ordinary case")
	end)

	fw.it("has no side to wait for on the arena frames", function()
		assert(groups:GetWarning(groups:Normalise({ Unit = "arenaframes" })) == nil,
			"an arena frame only ever holds an opponent")
	end)

	fw.it("lets a nameplate group be pointed back at a unit", function()
		-- Normalise runs after every edit, so anything that re-derived the unit from the stored
		-- anchor would undo the change the instant it was made.
		local group = groups:Normalise({ Unit = "nameplateenemy", Spells = { POLYMORPH } })

		group.Unit = "targetenemy"
		groups:Normalise(group)

		assert(group.Unit == "targetenemy", "the unit that was just chosen sticks")
		assert(group.Anchor == "SCREEN", "and the anchor follows it back")
	end)

	fw.it("hands back the real token behind a choice", function()
		assert(groups:GetToken(groups:Normalise({ Unit = "targetenemy" })) == "target",
			"both target sides watch the target")
		assert(groups:GetToken(groups:Normalise({ Unit = "player" })) == "player", "self is the player")
		assert(groups:GetToken(groups:Normalise({ Unit = "nameplateenemy" })) == nil,
			"a plate group has no single token")
	end)

	fw.it("falls back to the player for a unit it does not offer", function()
		assert(groups:Normalise({ Unit = "raid7" }).Unit == "player", "unknown units are refused")
	end)

	fw.it("warns that a split unit only shows on its own side", function()
		assert(groups:GetWarning(groups:Normalise({ Unit = "targetfriendly" }))
			== "HELPFUL_FRIENDLY_ONLY", "a friendly target has to actually be friendly")
		assert(groups:GetWarning(groups:Normalise({ Unit = "targetenemy" }))
			== "HARMFUL_HOSTILE_ONLY", "and an enemy target hostile")
		assert(groups:GetWarning(groups:Normalise({ Unit = "player" })) == nil,
			"you are always there, so there is nothing to say")
	end)
end)

fw.describe("CustomAuras - units saved before the split", function()
	-- Target, focus and the target's target were one choice each with a separate aura type. The
	-- type it already had decides which side it becomes, so the group keeps showing what it showed.
	fw.it("sends an old target group to the side matching its aura type", function()
		assert(groups:Normalise({ Unit = "target", AuraType = "HELPFUL" }).Unit == "targetfriendly",
			"a buff group becomes a friendly target group")
		assert(groups:Normalise({ Unit = "target", AuraType = "HARMFUL" }).Unit == "targetenemy",
			"and a debuff group an enemy target group")
	end)

	fw.it("does the same for old nameplate groups", function()
		assert(groups:Normalise({ Unit = "nameplate", AuraType = "HARMFUL" }).Unit == "nameplateenemy",
			"debuffs on plates are the common case")
		assert(groups:Normalise({ Unit = "nameplate", AuraType = "HELPFUL" }).Unit
			== "nameplatefriendly", "and buffs go to the friendly side")
	end)

	fw.it("moves the two removed units onto the target", function()
		-- Focus and the target's target are gone. Pointing them at the target keeps the group
		-- working on something rather than silently disabling it.
		assert(groups:Normalise({ Unit = "focus", AuraType = "HARMFUL" }).Unit == "targetenemy",
			"focus becomes the target")
		assert(groups:Normalise({ Unit = "targettarget" }).Unit == "targetfriendly",
			"and so does the target's target")
	end)
end)

fw.describe("CustomAuras - units that follow a role", function()
	local wow = require("WowApi")

	---Puts a roster in place, in the order the tokens are given.
	---@param roster table[] { unit, role } pairs.
	local function Roster(roster)
		wow.clearRoles()
		env.friendlyUnits = {}

		for _, entry in ipairs(roster) do
			env.friendlyUnits[#env.friendlyUnits + 1] = entry[1]
			wow.setRole(entry[1], entry[2])
		end
	end

	---@param unit string
	---@return CustomAuraGroup
	local function Group(unit)
		return groups:Normalise({ Unit = unit })
	end

	fw.it("follows whoever holds the healer role", function()
		Roster({ { "player", "DAMAGER" }, { "party1", "DAMAGER" }, { "party2", "HEALER" } })

		assert(groups:GetToken(Group("healer")) == "party2", "the one healer in the group")
	end)

	fw.it("takes the first healer in roster order when there are two", function()
		Roster({ { "player", "DAMAGER" }, { "party1", "HEALER" }, { "party3", "HEALER" } })

		-- Roster order, not the order the roles were assigned in: with two there is no better
		-- answer than a stable one.
		assert(groups:GetToken(Group("healer")) == "party1", "the earlier token wins")
	end)

	fw.it("finds you when you are the healer", function()
		Roster({ { "player", "HEALER" }, { "party1", "DAMAGER" } })

		assert(groups:GetToken(Group("healer")) == "player", "the player is in the roster too")
	end)

	fw.it("skips you for other dps, which is the whole point of it", function()
		Roster({ { "player", "DAMAGER" }, { "party2", "DAMAGER" } })

		assert(groups:GetToken(Group("otherdps")) == "party2", "the other one, not you")
	end)

	fw.it("has no token when the group cannot fill the role", function()
		Roster({ { "player", "DAMAGER" } })

		assert(groups:GetToken(Group("healer")) == nil, "no healer in the group")
		assert(groups:GetToken(Group("otherdps")) == nil, "and nobody else to be the other dps")
	end)

	fw.it("shows nothing while the role is unfilled rather than everything", function()
		Roster({ { "player", "DAMAGER" } })
		ClearGroups()

		local group = AddGroup({ Unit = "healer", Spells = { ICE_BLOCK } })

		module:Refresh()

		-- The container has to watch something, so it watches a token that does not exist and
		-- is budgeted to zero. A bare HELPFUL filter on a real unit would match every buff.
		local entry = display:GetStates()[group.Id].Screen

		assert(entry, "the group still has a display")
		assert(Budget(entry.Display.Frame, "helpful") == 0, "but no icons without a healer")
	end)

	fw.it("carries buffs only, being a friendly unit either way", function()
		assert(groups:SupportsAuraType("healer", "HELPFUL"), "buffs on the healer")
		assert(not groups:SupportsAuraType("healer", "HARMFUL"), "and not debuffs")
		assert(groups:SupportsAuraType("otherdps", "HELPFUL"), "same for the other dps")
		assert(not groups:SupportsAuraType("otherdps", "HARMFUL"), "either way")
	end)

	fw.it("is a screen anchored group, not a nameplate one", function()
		assert(Group("healer").Anchor == "SCREEN", "the healer has one place on screen")
		assert(not groups:IsNameplateUnit("otherdps"), "and so does the other dps")
	end)
end)

fw.describe("CustomAuras - spell filters", function()
	fw.it("expands each tracked id to every variant of the ability", function()
		local group = groups:Normalise({ Spells = { TORRENT_IDS[1] } })
		local filters = groups:BuildFilters(group)
		local count = 0

		for _ in pairs(filters.includeSpellIDs) do
			count = count + 1
		end

		assert(filters.includeSpellIDs[TORRENT_IDS[1]], "the id that was asked for")
		assert(count > 1, "and the other ids the same ability is known by")
	end)

	fw.it("changes its signature when the tracked set moves", function()
		local group = groups:Normalise({ Spells = { POLYMORPH } })
		local before = groups:GetFilterSignature(group)

		group.Spells[#group.Spells + 1] = ICE_BLOCK

		assert(groups:GetFilterSignature(group) ~= before, "adding a spell is a change")

		group.AuraType = "HARMFUL"

		assert(groups:GetFilterSignature(group) ~= before, "so is flipping the aura type")
	end)
end)

fw.describe("CustomAuras - screen anchored displays", function()
	fw.it("builds one container carrying both an aura-type group", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local container = ContainerFor("player")

		assert(container, "a container tracks the player")
		assert(container._groups.helpful, "with a helpful group")
		assert(container._groups.harmful, "and a harmful one, so the type can be switched")
	end)

	fw.it("creates its groups with buttons to give, not at zero", function()
		-- Containers allocate a group's buttons from the count it was created with. A group
		-- created empty has none when its budget is raised later, which is why harmful groups
		-- showed nothing: they are the side that starts unbudgeted, because there is rarely a
		-- hostile target at the moment the container is built.
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local container = ContainerFor("player")

		assert(container._groups.harmful.maxFrameCountAtCreation > 0,
			"the harmful group was built with buttons")
		assert(container._groups.helpful.maxFrameCountAtCreation > 0,
			"and so was the helpful one")
	end)

	fw.it("budgets only the side the assist check allows", function()
		ClearGroups()
		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local container = ContainerFor("player")

		assert(Budget(container, "helpful") == groups.MaxIcons, "the helpful group gets the budget")
		assert(Budget(container, "harmful") == 0, "the harmful group gets none")

		-- The player is always assistable, so a harmful group here can never be honoured.
		group.AuraType = "HARMFUL"
		module:Refresh()

		assert(Budget(container, "helpful") == 0, "and neither side runs once it is impossible")
		assert(Budget(container, "harmful") == 0, "the unfiltered token never gets a budget")
	end)

	fw.it("drops the budget to zero when the unit turns hostile", function()
		ClearGroups()
		AddGroup({ Unit = "targetfriendly", Spells = { ICE_BLOCK } })
		env.enemies.target = nil
		module:Refresh()

		local container = ContainerFor("target")

		assert(Budget(container, "helpful") == groups.MaxIcons, "a friendly target can be filtered by id")

		env.enemies.target = true
		display:OnUnitChanged("target")

		assert(Budget(container, "helpful") == 0,
			"a hostile target cannot, so nothing is shown rather than everything")

		env.enemies.target = nil
	end)

	fw.it("budgets a harmful group only while the unit is hostile", function()
		ClearGroups()
		AddGroup({ Unit = "targetenemy", Spells = { POLYMORPH } })
		env.enemies.target = true
		module:Refresh()

		local container = ContainerFor("target")

		assert(Budget(container, "harmful") == groups.MaxIcons, "a hostile target can be filtered by id")

		env.enemies.target = nil
		display:OnUnitChanged("target")

		assert(Budget(container, "harmful") == 0, "a friendly one cannot")
	end)

	fw.it("budgets a caster filter to zero while the unit is out of the visible world", function()
		ClearGroups()
		AddGroup({ Unit = "targetfriendly", Spells = { ICE_BLOCK }, Caster = groups.Caster.Mine })
		env.enemies.target = nil
		module:Refresh()

		local container = ContainerFor("target")

		assert(Budget(container, "helpful") == groups.MaxIcons,
			"a visible unit can be filtered by caster")

		-- The engine cannot attribute casters on a member in another instance or phase, and a
		-- check it cannot evaluate is skipped rather than failed - the group would show the aura
		-- from everyone.
		env.phased.target = true
		display:OnUnitChanged("target")

		assert(Budget(container, "helpful") == 0,
			"an unattributable unit shows nothing rather than everyone's copies")

		env.phased.target = nil
		display:OnUnitChanged("target")

		assert(Budget(container, "helpful") == groups.MaxIcons,
			"and the budget comes back when they return")
	end)

	fw.it("gates the from-my-side flag on visibility the same way", function()
		ClearGroups()
		AddGroup({
			Unit = "targetfriendly",
			TrackingMode = groups.TrackingMode.Filters,
			Candidates = { isFromPlayerOrPlayerPet = "REQUIRE" },
		})
		env.enemies.target = nil
		env.phased.target = true
		module:Refresh()

		local container = ContainerFor("target")

		assert(Budget(container, "helpful") == 0, "the flag needs an attributable caster too")

		env.phased.target = nil
		display:OnUnitChanged("target")

		assert(Budget(container, "helpful") == groups.MaxIcons,
			"and runs again once the unit is visible")
	end)

	fw.it("shows nothing for a group with no spells", function()
		ClearGroups()
		AddGroup({ Unit = "focus", Spells = {} })
		module:Refresh()

		local container = ContainerFor("focus")

		assert(container == nil or Budget(container, "helpful") == 0,
			"an empty group never gets a budget")
	end)

	fw.it("reuses the same container across refreshes", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local before = env.auraContainerCount()

		module:Refresh()
		module:Refresh()

		assert(env.auraContainerCount() == before, "a refresh must not build frames")
	end)
end)

fw.describe("CustomAuras - options page preview", function()
	fw.it("draws a selected group that its own conditions would otherwise hide", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Enabled = false })

		module:Refresh()

		assert(ContainerFor("player") == nil or Budget(ContainerFor("player"), "helpful") == 0,
			"a switched-off group shows nothing")

		display:SetPreviewGroup(group.Id)

		local container = ContainerFor("player")

		assert(container, "selecting it in the options builds its display")
		assert(Budget(container, "helpful") == 0,
			"but the container stays empty - the preview icons are stand-ins, not live auras")

		display:SetPreviewGroup(nil)
	end)

	fw.it("skips a group with nothing to draw", function()
		-- The stand-in icons ARE the drag handle now that the anchor has no backdrop, so a group
		-- with no spells yet would be an invisible frame sitting over whatever is behind it.
		ClearGroups()

		local group = AddGroup({ Unit = "player" })

		display:SetPreviewGroup(group.Id)

		-- Parked containers keep the unit they last watched, so the state is what to look at.
		assert(display:GetStates()[group.Id].Screen == nil, "an empty group is not previewed")

		display:SetPreviewGroup(nil)
	end)

	fw.it("previews a filter group, which needs no spells to be worth drawing", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", TrackingMode = groups.TrackingMode.Filters })

		display:SetPreviewGroup(group.Id)

		assert(display:GetStates()[group.Id].Screen, "the aura type alone is already a working filter")

		display:SetPreviewGroup(nil)
	end)

	fw.it("keeps the live budget for a group that is allowed to run", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		display:SetPreviewGroup(group.Id)

		local container = ContainerFor("player")

		assert(Budget(container, "helpful") == groups.MaxIcons, "an allowed group keeps its icon budget")

		display:SetPreviewGroup(nil)
	end)

	fw.it("parks the preview again once the options page lets go", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Enabled = false })

		display:SetPreviewGroup(group.Id)
		assert(ContainerFor("player"), "a disabled group can still be positioned")

		display:SetPreviewGroup(nil)

		local container = ContainerFor("player")

		assert(container == nil or container._enabled == false, "and stops tracking afterwards")
	end)

end)

fw.describe("CustomAuras - nameplate anchored displays", function()
	fw.it("takes a display per plate and gives it back when the plate goes", function()
		ClearGroups()
		AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })

		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		module:Refresh()

		local container = ContainerFor("nameplate1")

		assert(container, "the plate has a container")
		assert(Budget(container, "harmful") > 0, "budgeted, because the plate is hostile")

		local created = env.auraContainerCount()

		display:OnNamePlateRemoved("nameplate1")
		env.plates.nameplate1 = nil
		display:OnNamePlateAdded("nameplate2")

		assert(env.auraContainerCount() == created,
			"a recycled plate reuses the parked display rather than building another")
	end)

end)

fw.describe("CustomAuras - unit frame anchored displays", function()
	---Replaces whatever unit frames the last test left with one per token given.
	---@param unitList string[]
	---@return table[]
	local function UnitFrames(unitList)
		for index = #env.unitFrames, 1, -1 do
			env.unitFrames[index] = nil
		end

		local made = {}

		for _, unit in ipairs(unitList) do
			made[#made + 1] = env.addUnitFrame(unit)
		end

		return made
	end

	---@param state table
	---@return number
	local function CopyCount(state)
		local count = 0

		for _ in pairs(state.Frames) do
			count = count + 1
		end

		return count
	end

	fw.it("puts a copy on every unit frame", function()
		ClearGroups()
		UnitFrames({ "party1", "party2" })
		AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })
		module:Refresh()

		assert(Budget(ContainerFor("party1"), "helpful") == groups.MaxIcons, "the first frame's member")
		assert(Budget(ContainerFor("party2"), "helpful") == groups.MaxIcons, "and the second's")
	end)

	fw.it("hands a copy back when its frame goes, and reuses it for the next one", function()
		ClearGroups()
		UnitFrames({ "party1", "party2" })

		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		module:Refresh()

		local created = env.auraContainerCount()
		local state = display:GetStates()[group.Id]

		-- The frame addon put one away, leaving the other where it was.
		table.remove(env.unitFrames, 2)
		module:Refresh()

		assert(CopyCount(state) == 1, "only the frame that is still there keeps one")

		env.addUnitFrame("party3")
		module:Refresh()

		assert(CopyCount(state) == 2, "the new frame gets one")
		assert(env.auraContainerCount() == created, "out of the pool, rather than built again")
	end)

	fw.it("skips a frame holding a pet", function()
		ClearGroups()

		local made = UnitFrames({ "party1", "partypet1" })

		env.pets.partypet1 = true

		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		module:Refresh()
		env.pets.partypet1 = nil

		local state = display:GetStates()[group.Id]

		assert(state.Frames[made[1]], "the member's frame has a copy")
		assert(state.Frames[made[2]] == nil, "the pet's frame does not")
	end)

	fw.it("drops the copy from a member the player cannot assist", function()
		ClearGroups()

		local made = UnitFrames({ "party1" })
		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		module:Refresh()

		local state = display:GetStates()[group.Id]

		assert(state.Frames[made[1]], "a friendly member has a copy")

		-- A mind control flips the token to the other side, and the spell id filter with it.
		env.enemies.party1 = true
		module:Refresh()
		env.enemies.party1 = nil

		assert(state.Frames[made[1]] == nil, "a mind controlled one does not")
	end)

	fw.it("registers the group's sounds on each member it shows on", function()
		ClearGroups()
		addon.Modules.CustomAuras.Sound:Clear()
		UnitFrames({ "party1", "party2" })
		AddGroup({
			Unit = "unitframes",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local seen = {}

		for _, entry in pairs(env.auraSounds) do
			seen[entry.Unit] = true
		end

		assert(seen.party1 and seen.party2, "one registration per member")
	end)

	fw.it("follows a frame that is pointed at somebody else", function()
		ClearGroups()

		local made = UnitFrames({ "party1" })
		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		module:Refresh()

		local hooks = env.unitFrameHooks

		assert(hooks, "the frame hooks went on once a group asked for them")

		-- The real guard is a name test, which the mock frames cannot answer.
		addon.Core.Frames.IsFriendlyCuf = function()
			return true
		end
		made[1].unit = "party3"
		hooks.OnSetUnit(made[1], "party3")
		addon.Core.Frames.IsFriendlyCuf = function()
			return false
		end

		assert(display:GetStates()[group.Id].Frames[made[1]].Unit == "party3",
			"the copy moved with the frame")
	end)

	fw.it("leaves nothing behind when the group is pointed somewhere else", function()
		ClearGroups()
		UnitFrames({ "party1", "party2" })

		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		module:Refresh()

		group.Unit = "player"
		groups:Normalise(group)
		module:Refresh()

		assert(CopyCount(display:GetStates()[group.Id]) == 0, "the per-frame copies were released")

		UnitFrames({})
		ClearGroups()
	end)
end)

fw.describe("CustomAuras - arena frame anchored displays", function()
	-- The frames come from whichever addon owns them, so the finder walks a fixed priority list
	-- of globals. Every test here installs its own and clears them again.
	local ARENA_PREFIXES = { "sArenaEnemyFrame", "ElvUF_Arena" }
	local ARENA_TOKENS = { "arena1", "arena2", "arena3" }

	local function ClearArenaFrames()
		for _, prefix in ipairs(ARENA_PREFIXES) do
			for index = 1, 3 do
				_G[prefix .. index] = nil
			end
		end

		_G.CompactArenaFrame = nil

		for _, token in ipairs(ARENA_TOKENS) do
			env.enemies[token] = nil
		end
	end

	---Installs one frame per index under the given addon's global names, and makes the matching
	---arena tokens hostile so the group's own reaction check passes.
	---@param prefix string
	---@param indexes number[]
	---@return table[] made Keyed by opponent index.
	local function AddArenaFrames(prefix, indexes)
		local made = {}

		for _, index in ipairs(indexes) do
			made[index] = acm.NewFrame("Frame", prefix .. index)
			_G[prefix .. index] = made[index]
			env.enemies["arena" .. index] = true
		end

		return made
	end

	---@param state table
	---@return number
	local function CopyCount(state)
		local count = 0

		for _ in pairs(state.Arena) do
			count = count + 1
		end

		return count
	end

	fw.it("puts a copy on every arena enemy frame", function()
		ClearGroups()
		ClearArenaFrames()
		AddArenaFrames("sArenaEnemyFrame", { 1, 2, 3 })
		AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })
		module:Refresh()

		-- Spell ids really are honoured here: an arena enemy is never assistable, which is the one
		-- thing that lets a debuff group narrow itself by id.
		assert(Budget(ContainerFor("arena1"), "harmful") == groups.MaxIcons, "the first opponent")
		assert(Budget(ContainerFor("arena2"), "harmful") == groups.MaxIcons, "the second")
		assert(Budget(ContainerFor("arena3"), "harmful") == groups.MaxIcons, "and the third")

		ClearArenaFrames()
		ClearGroups()
	end)

	fw.it("hangs the copy off the frame the priority list picks first", function()
		ClearGroups()
		ClearArenaFrames()

		local blizzard = acm.NewFrame("Frame", "CompactArenaFrameMember1")
		_G.CompactArenaFrame = { memberUnitFrames = { blizzard } }

		local replacement = AddArenaFrames("sArenaEnemyFrame", { 1 })
		local group = AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })

		module:Refresh()

		local entry = display:GetStates()[group.Id].Arena[1]

		assert(entry, "the opponent has a copy")
		assert(entry.Display.Frame:GetParent() == replacement[1],
			"the addon that replaces the Blizzard frames wins, or the copy hangs off a dead frame")

		ClearArenaFrames()
		ClearGroups()
	end)

	fw.it("has no copy for an index nothing has built a frame for", function()
		ClearGroups()
		ClearArenaFrames()
		AddArenaFrames("ElvUF_Arena", { 1, 2 })

		local group = AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })

		module:Refresh()

		local state = display:GetStates()[group.Id]

		assert(CopyCount(state) == 2, "one per frame that exists")
		assert(state.Arena[3] == nil, "and none waiting on the third")

		ClearArenaFrames()
		ClearGroups()
	end)

	fw.it("drops the copy from an opponent the player can assist", function()
		ClearGroups()
		ClearArenaFrames()
		AddArenaFrames("sArenaEnemyFrame", { 1 })

		local group = AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })

		module:Refresh()

		local state = display:GetStates()[group.Id]

		assert(state.Arena[1], "a hostile opponent has a copy")

		-- A mind control flips the token to the player's side, and the spell id filter with it.
		env.enemies.arena1 = nil
		module:Refresh()

		assert(state.Arena[1] == nil, "a mind controlled one does not")

		ClearArenaFrames()
		ClearGroups()
	end)

	fw.it("registers the group's sounds on each opponent it shows on", function()
		ClearGroups()
		ClearArenaFrames()
		addon.Modules.CustomAuras.Sound:Clear()
		AddArenaFrames("sArenaEnemyFrame", { 1, 2 })
		AddGroup({
			Unit = "arenaframes",
			Spells = { POLYMORPH },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local seen = {}

		for _, entry in pairs(env.auraSounds) do
			seen[entry.Unit] = true
		end

		assert(seen.arena1 and seen.arena2, "one registration per opponent")
		assert(not seen.arena3, "and none for the opponent that is not there")

		ClearArenaFrames()
		ClearGroups()
	end)

	fw.it("leaves nothing behind when the group is pointed somewhere else", function()
		ClearGroups()
		ClearArenaFrames()
		AddArenaFrames("sArenaEnemyFrame", { 1, 2, 3 })

		local group = AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })

		module:Refresh()

		assert(CopyCount(display:GetStates()[group.Id]) == 3, "three copies to give back")

		group.Unit = "player"
		group.AuraType = "HELPFUL"
		groups:Normalise(group)
		module:Refresh()

		assert(CopyCount(display:GetStates()[group.Id]) == 0, "the per-opponent copies were released")

		ClearArenaFrames()
		ClearGroups()
	end)
end)

fw.describe("CustomAuras - stand-in frames while a group is being placed", function()
	---Empties the real unit frame list, so nothing but the stand-ins can be anchored to.
	local function NoRealFrames()
		for index = #env.unitFrames, 1, -1 do
			env.unitFrames[index] = nil
		end
	end

	---The mock treats every token as assistable unless it is listed as an enemy. The live client
	---answers false for a unit that does not exist, which is what a stand-in frame's token always
	---is, so the tokens are listed to model that.
	---@param prefix string
	---@param absent boolean
	local function SetTokensAbsent(prefix, absent)
		for index = 1, 3 do
			env.enemies[prefix .. index] = absent or nil
		end
	end

	---@param copies table
	---@return number
	local function Count(copies)
		local count = 0

		for _ in pairs(copies) do
			count = count + 1
		end

		return count
	end

	local function Reset()
		ClearGroups()
		NoRealFrames()
		SetTokensAbsent("party", false)
		SetTokensAbsent("arena", false)
		display:SetPreviewGroup(nil)
		display:SetTestMode(false)
		env.testFramesShown = false
		env.testArenaFramesShown = false
	end

	fw.it("puts the party stand-ins up for a unit frames group with nothing real on screen", function()
		Reset()
		SetTokensAbsent("party", true)

		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		display:SetPreviewGroup(group.Id)

		assert(env.testFramesShown, "the stand-in party frames were asked for")
		assert(not env.testArenaFramesShown, "and only those - the group is not an arena one")

		-- The reaction check is skipped while previewing, or a stand-in's "party1" (nobody at all)
		-- would hand the copy straight back and the preview would show nothing.
		assert(Count(display:GetStates()[group.Id].Frames) == 3, "a copy on each stand-in")

		Reset()
	end)

	fw.it("puts the arena stand-ins up for an arena group with nothing real on screen", function()
		Reset()
		SetTokensAbsent("arena", true)

		local group = AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })

		display:SetPreviewGroup(group.Id)

		assert(env.testArenaFramesShown, "the stand-in arena frames were asked for")
		assert(not env.testFramesShown, "and not the party ones")
		assert(Count(display:GetStates()[group.Id].Arena) == 3, "a copy on each stand-in")

		Reset()
	end)

	fw.it("prefers the stand-in over a real arena frame that is not on screen", function()
		Reset()
		SetTokensAbsent("arena", true)

		-- The default arena frames exist from login and sit hidden outside an arena; a copy
		-- anchored to one would be invisible, which is exactly what the stand-ins exist to avoid.
		local hidden = acm.NewFrame("Frame", "CompactArenaFrameMember1")
		hidden:Hide()
		_G.CompactArenaFrame = { memberUnitFrames = { hidden } }

		local group = AddGroup({ Unit = "arenaframes", Spells = { POLYMORPH } })

		display:SetPreviewGroup(group.Id)

		local entry = display:GetStates()[group.Id].Arena[1]

		assert(entry, "the opponent has a copy")
		assert(entry.Display.Frame:GetParent() == env.testArenaFrames[1],
			"it hangs off the stand-in, not the hidden default frame")

		-- The offset drag re-anchors every frame through AnchorGroup, which has to resolve the
		-- same host or the copy tears off its stand-in mid-move.
		group.Offset.X = 25
		display:AnchorGroup(group.Id)

		assert(entry.Display.Frame:GetParent() == env.testArenaFrames[1],
			"a drag keeps the copy on the stand-in")

		local _, _, _, offsetX = entry.Display.Frame:GetPoint(1)

		assert(offsetX == 25, "and applies the new offset")

		_G.CompactArenaFrame = nil
		Reset()
	end)

	fw.it("takes them away again and hands the copies back when the preview ends", function()
		Reset()
		SetTokensAbsent("party", true)

		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		display:SetPreviewGroup(group.Id)
		assert(env.testFramesShown, "up while the group is selected")

		display:SetPreviewGroup(nil)

		assert(not env.testFramesShown, "and away once it is not")
		assert(Count(display:GetStates()[group.Id].Frames) == 0,
			"the copies on them went back to the pool")

		Reset()
	end)

	fw.it("leaves them alone with real frames on screen", function()
		Reset()

		local made = env.addUnitFrame("party1")
		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		display:SetPreviewGroup(group.Id)

		assert(not env.testFramesShown, "there is something real to position against")
		assert(display:GetStates()[group.Id].Frames[made], "and the copy went on it")

		Reset()
	end)

	fw.it("does not fight test mode over them", function()
		Reset()
		SetTokensAbsent("party", true)

		local group = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		-- Test mode owns the stand-ins while it runs. A sentinel rather than a boolean: the point
		-- is that the preview path did not touch the switch either way.
		display:SetTestMode(true)
		env.testFramesShown = "owned by test mode"
		display:SetPreviewGroup(group.Id)

		assert(env.testFramesShown == "owned by test mode", "the preview left the switch alone")
		assert(Count(display:GetStates()[group.Id].Frames) == 3,
			"and test mode still anchors copies to the stand-ins")

		Reset()
	end)
end)

fw.describe("CustomAuras - tracking by filter", function()
	-- Spell ids are the only thing 12.1's assist rule touches. A filter string and the flag
	-- filters are honoured on any unit, so a filter group escapes every limit the spell path has.
	fw.it("puts the aura type and nothing else in the string by default", function()
		local group = groups:Normalise({ Spells = { ICE_BLOCK } })

		assert(groups:BuildFilterString(group) == "HELPFUL", "a plain group is a bare token")
	end)

	fw.it("appends the components a filter group requires and forbids", function()
		local group = groups:Normalise({
			AuraType = "HARMFUL",
			TrackingMode = groups.TrackingMode.Filters,
			Filters = { DISPELLABLE = "REQUIRE", CROWD_CONTROL = "FORBID" },
		})
		local filterString = groups:BuildFilterString(group)

		assert(filterString:find("HARMFUL", 1, true), "the aura type leads")
		assert(filterString:find("|DISPELLABLE", 1, true), "a required component is a bare token")
		assert(filterString:find("|!CROWD_CONTROL", 1, true), "a forbidden one is negated")
	end)

	fw.it("ignores components while the group tracks spell ids", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Filters = { DISPELLABLE = "REQUIRE" },
		})

		assert(groups:BuildFilterString(group) == "HELPFUL",
			"a spell group's string stays bare, or the ids would be narrowed twice")
	end)

	fw.it("turns the caster choice into the PLAYER component either way round", function()
		local mine = groups:Normalise({ Caster = groups.Caster.Mine })
		local others = groups:Normalise({ Caster = groups.Caster.Others })

		assert(groups:BuildFilterString(mine) == "HELPFUL|PLAYER", "mine requires it")
		assert(groups:BuildFilterString(others) == "HELPFUL|!PLAYER", "anyone else negates it")
	end)

	fw.it("changes signature on the mode itself, not just what it builds", function()
		-- With no components chosen, both modes build the same bare filter string. Only the
		-- mode says whether an includeSpellIDs map is sent at all, so the display has to be
		-- told, or switching back to a spell list leaves the container filtering on nothing.
		local group = groups:Normalise({ Spells = { ICE_BLOCK } })
		local bySpells = groups:GetFilterSignature(group)

		group.TrackingMode = groups.TrackingMode.Filters
		groups:Normalise(group)

		assert(groups:BuildFilterString(group) == "HELPFUL", "the string really is unchanged")
		assert(groups:GetFilterSignature(group) ~= bySpells, "but the signature moved anyway")
	end)

	fw.it("names no spell ids, so the engine never drops the filter", function()
		local group = groups:Normalise({
			TrackingMode = groups.TrackingMode.Filters,
			Spells = { ICE_BLOCK },
		})

		assert(groups:BuildFilters(group).includeSpellIDs == nil,
			"a leftover spell list from before the switch is not sent")
	end)

	fw.it("lets a debuff group sit on the player, which spell ids never can", function()
		local byId = groups:Normalise({ Unit = "player", AuraType = "HARMFUL", Spells = { ICE_BLOCK } })
		local byFilter = groups:Normalise({
			Unit = "player",
			AuraType = "HARMFUL",
			TrackingMode = groups.TrackingMode.Filters,
		})

		assert(not groups:Supports(byId), "spell ids cannot filter a debuff on a friendly unit")
		assert(groups:Supports(byFilter), "a filter string can")
		assert(groups:CanFilterUnit(byFilter, "player"), "and the display budgets it")
	end)

	fw.it("needs no spells to be worth showing", function()
		local group = groups:Normalise({ TrackingMode = groups.TrackingMode.Filters })

		assert(groups:Supports(group), "the aura type alone is already a working filter")
	end)

	fw.it("keeps the caveat about the unit's side, which the mode has no say in", function()
		-- The engine's assist rule is a spell id rule, but the group's own choice of side is
		-- not: an enemy target group still shows nothing while the target is friendly.
		local group = groups:Normalise({
			Unit = "targetenemy",
			TrackingMode = groups.TrackingMode.Filters,
		})

		assert(groups:GetWarning(group) == "HARMFUL_HOSTILE_ONLY", "the caveat is about the unit")
	end)
end)

fw.describe("CustomAuras - candidate filters", function()
	fw.it("sends a required flag as true and a forbidden one as false", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Candidates = { isBossAura = "REQUIRE", isStealable = "FORBID" },
		})
		local filters = groups:BuildFilters(group)

		assert(filters.isBossAura == true, "required means the flag must be set")
		assert(filters.isStealable == false, "forbidden means it must not be")
		assert(filters.isPriorityAura == nil, "an untouched flag is absent, not false")
	end)

	fw.it("applies the flags whichever way the group tracks", function()
		local group = groups:Normalise({
			TrackingMode = groups.TrackingMode.Filters,
			Candidates = { isFromPlayerOrPlayerPet = "REQUIRE" },
		})

		assert(groups:BuildFilters(group).isFromPlayerOrPlayerPet == true,
			"flags are not part of the spell id rule")
	end)

	fw.it("keeps only the states and keys the engine knows", function()
		local group = groups:Normalise({
			Candidates = { isBossAura = "REQUIRE", nonsense = "REQUIRE", isStealable = "MAYBE" },
		})

		assert(group.Candidates.isBossAura == "REQUIRE", "a known key survives")
		assert(group.Candidates.nonsense == nil, "an invented one does not")
		assert(group.Candidates.isStealable == nil, "nor does an invented state")
	end)

	fw.it("moves its signature when any of it changes", function()
		local group = groups:Normalise({ Spells = { ICE_BLOCK } })
		local before = groups:GetFilterSignature(group)

		group.Candidates.isBossAura = "REQUIRE"

		local withFlag = groups:GetFilterSignature(group)

		assert(withFlag ~= before, "a flag reaches the engine")

		group.Sort = groups.Sort.Longest

		assert(groups:GetFilterSignature(group) ~= withFlag, "and so does the order")
	end)
end)

fw.describe("CustomAuras - icon order", function()
	fw.it("sorts on aura instance id by default, which is oldest first", function()
		local method = groups:GetSortMethod(groups:Normalise({}))

		assert(method == AuraContainerSortMethod.AuraInstanceIDOnly, "instance id order")
	end)

	fw.it("sorts on expiry the other way round for longest and shortest", function()
		local longest, longestDirection =
			groups:GetSortMethod(groups:Normalise({ Sort = groups.Sort.Longest }))
		local shortest, shortestDirection =
			groups:GetSortMethod(groups:Normalise({ Sort = groups.Sort.Shortest }))

		assert(longest == AuraContainerSortMethod.ExpirationOnly, "longest sorts on expiry")
		assert(shortest == AuraContainerSortMethod.ExpirationOnly, "so does shortest")
		assert(longestDirection ~= shortestDirection, "in opposite directions")
	end)

	fw.it("hands the sort to both sides of the container", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Sort = groups.Sort.Shortest })
		module:Refresh()

		local container = ContainerFor("player")

		assert(container._groups.helpful.sortMethod == AuraContainerSortMethod.ExpirationOnly,
			"the budgeted side sorts as asked")
		assert(container._groups.harmful.sortMethod == AuraContainerSortMethod.ExpirationOnly,
			"and so does the one waiting to be switched to")
	end)

	fw.it("hands the filter string to the side the group is on", function()
		ClearGroups()
		AddGroup({
			Unit = "player",
			TrackingMode = groups.TrackingMode.Filters,
			Filters = { DISPELLABLE = "REQUIRE" },
		})
		module:Refresh()

		local container = ContainerFor("player")

		-- Canonical (token-sorted) spelling: the display canonicalises every string it hands over.
		assert(container._groups.helpful.filterString == "DISPELLABLE|HELPFUL",
			"the helpful side carries the built string")
	end)
end)

fw.describe("CustomAuras - sounds", function()
	fw.it("registers one sound per tracked spell variant on the group's unit", function()
		ClearGroups()
		addon.Modules.CustomAuras.Sound:Clear()

		local before = env.auraSoundAdds

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		assert(env.auraSoundAdds > before, "the engine was asked to play something")

		local last = env.auraSounds[env.auraSoundAdds]

		assert(last.Unit == "player", "on the group's unit")
		assert(last.Trigger == Enum.UnitAuraSoundTrigger.Added, "on the applied trigger")
	end)

	fw.it("carries a group's Sound.File over to the applied trigger", function()
		-- What the single-sound version of the feature saved. Normalise moves it rather than
		-- leaving the group silent after an update.
		local group = groups:NewGroup(options, "Old")

		group.Sound = { File = "Sonar", Channel = "Master" }
		groups:Normalise(group)

		assert(group.Sound.Applied == "Sonar", "the old file became the applied sound")
		assert(group.Sound.File == nil, "and the old key is gone")
	end)

	fw.it("registers each configured trigger separately", function()
		ClearGroups()
		addon.Modules.CustomAuras.Sound:Clear()

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Stacks = "Sonar", Removed = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local seen = {}

		for _, entry in pairs(env.auraSounds) do
			seen[entry.Trigger] = true
		end

		assert(seen[Enum.UnitAuraSoundTrigger.Added], "applied is registered")
		assert(seen[Enum.UnitAuraSoundTrigger.ApplicationsIncreased], "gaining a stack is registered")
		assert(seen[Enum.UnitAuraSoundTrigger.Removed], "removed is registered")
	end)

	fw.it("leaves the triggers that have no sound alone", function()
		ClearGroups()
		addon.Modules.CustomAuras.Sound:Clear()

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Removed = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		for _, entry in pairs(env.auraSounds) do
			assert(entry.Trigger == Enum.UnitAuraSoundTrigger.Removed,
				"only the removed trigger was registered")
		end
	end)

	fw.it("does not re-register when nothing about the sound changed", function()
		module:Refresh()

		local after = env.auraSoundAdds

		module:Refresh()

		assert(env.auraSoundAdds == after, "a repeat refresh is free")
	end)

	fw.it("hands the registrations back when every sound is set to none", function()
		for _, trigger in ipairs(groups.SoundTriggers) do
			options.Groups[1].Sound[trigger] = groups.NoSound
		end

		module:Refresh()

		local after = env.auraSoundAdds

		module:Refresh()

		assert(env.auraSoundAdds == after, "and stays quiet afterwards")
	end)
end)

fw.describe("CustomAuras - cast recorder", function()
	fw.it("records nothing until it is started", function()
		recorder:Clear()
		recorder:Stop()

		local frame = acm.lastFrameWithScript("OnEvent")

		assert(#recorder:GetEntries() == 0, "an idle recorder holds nothing")
		assert(frame, "the recorder built an event frame")
	end)

	fw.it("captures the player's casts, newest first, counting repeats", function()
		recorder:Clear()
		recorder:Start()

		local frame = acm.lastFrameForEvent("UNIT_SPELLCAST_SUCCEEDED")

		assert(frame, "recording registered the cast event")

		frame:GetScript("OnEvent")(frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast1", POLYMORPH)
		frame:GetScript("OnEvent")(frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast2", ICE_BLOCK)
		frame:GetScript("OnEvent")(frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast3", POLYMORPH)

		local entries = recorder:GetEntries()

		assert(#entries == 2, "a repeat is counted, not listed twice")
		assert(entries[1].SpellId == POLYMORPH, "the most recent cast leads")
		assert(entries[1].Count == 2, "with its count")

		recorder:Stop()
	end)

	fw.it("stops capturing once stopped", function()
		recorder:Clear()
		recorder:Start()

		local frame = acm.lastFrameForEvent("UNIT_SPELLCAST_SUCCEEDED")

		recorder:Stop()
		frame:GetScript("OnEvent")(frame, "UNIT_SPELLCAST_SUCCEEDED", "player", "cast4", ICE_BLOCK)

		assert(#recorder:GetEntries() == 0, "nothing is recorded after stopping")
	end)
end)

fw.describe("CustomAuras - profile switching", function()
	fw.it("repairs groups a migration wrote with only the fields it cared about", function()
		ClearGroups()

		local profileManager = addon.Core.ProfileManager

		addon.Refresh = function()
			module:Refresh()
		end
		profileManager:Init()
		profileManager:CreateProfile("Migrated", nil)

		-- The shape the precog migration leaves in a stored profile: marked seeded, so
		-- SeedDefaults stands down, with groups holding only the fields it carried over.
		local snapshot = db.Profiles.Migrated.Modules.CustomAurasModule
		snapshot.SeededDefaults = true
		snapshot.NextId = 2
		snapshot.Groups = { {
			Id = "g1",
			Name = "Old",
			Enabled = true,
			Spells = { ICE_BLOCK },
			Position = { X = 0, Y = 70 },
			Icons = { Size = 70 },
		} }

		profileManager:SwitchProfile("Migrated")

		local group = options.Groups[1]

		assert(group and group.Filters and group.Candidates, "the switch filled in the missing fields")

		profileManager:SwitchProfile("Default")
	end)
end)

fw.describe("CustomAuras - bars", function()
	fw.it("builds bar buttons for a group that asks for them", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Icons = { Display = "BAR" } })
		module:Refresh()

		local container = ContainerFor("player")
		local button = container._groups.helpful.buttons[1]

		assert(button._calls.SetDurationBar == 1, "the fill is registered with the engine")
		assert(button._calls.SetSpellName == 1, "and so is the name")
	end)

	fw.it("keeps the two shapes in separate pools", function()
		-- A button's shape is baked in when it is created, so handing a bar group a display that
		-- was built for icons would leave it drawing icons for the rest of the session.
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local iconContainer = ContainerFor("player")

		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Icons = { Display = "BAR" } })
		module:Refresh()

		local barContainer = ContainerFor("player")

		assert(barContainer ~= iconContainer, "the parked icon display is not reused for bars")
		assert(barContainer._groups.helpful.buttons[1]._calls.SetDurationBar == 1, "it draws bars")
	end)

	fw.it("swaps the display when a group switches shape", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		module:Refresh()

		local before = ContainerFor("player")

		group.Icons.Display = "BAR"
		module:Refresh()

		local after = ContainerFor("player")

		assert(after ~= before, "the icon display is handed back rather than restyled")
		assert(after._groups.helpful.buttons[1]._calls.SetDurationBar == 1, "and bars take over")
		assert(Budget(after, "helpful") == groups.MaxIcons, "the new display tracks straight away")
	end)

	fw.it("normalises the bar settings a group did not set", function()
		local group = groups:Normalise({ Icons = { Display = "BAR" } })

		assert(group.Icons.BarWidth > 0 and group.Icons.BarHeight > 0, "a width and a height")
		assert(type(group.Icons.BarTexture) == "string" and group.Icons.BarTexture ~= "", "a texture")
		assert(group.Icons.SpellName, "the name is on unless it is turned off")

		local clamped = groups:Normalise({
			Icons = { Display = "BAR", BarWidth = 5000, BarHeight = 5000 },
		})

		assert(clamped.Icons.BarWidth == groups.MaxBarWidth, "an absurd width is clamped")
		assert(clamped.Icons.BarHeight == groups.MaxBarHeight, "and so is the height")
	end)

	fw.it("builds a bar display at the bar height, not the icon size", function()
		-- The two are separate settings with separate ranges: a bar wants a row of text, an icon
		-- wants a square, and one number could not sensibly clamp for both.
		ClearGroups()
		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = "BAR", Size = 40, BarHeight = 18, BarWidth = 140 },
		})
		module:Refresh()

		local button = ContainerFor("player")._groups.helpful.buttons[1]

		assert(button:GetHeight() == 18, "the bar height sizes the button")
		assert(button:GetWidth() == 140, "and the bar width")
	end)

	fw.it("colours the stand-in bars even with no glow or border", function()
		-- The icon colour is withheld unless a glow or a border asked for it, because for an icon a
		-- colour is what draws the border. A bar's fill is coloured regardless, so reading it that
		-- way left the preview white while the live bars were coloured.
		ClearGroups()

		local group = AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = "BAR", Glow = false, Border = false },
		})

		group.Icons.Color.R, group.Icons.Color.G, group.Icons.Color.B = 0.2, 0.4, 0.8
		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local entry = display:GetStates()[group.Id].Screen
		local fill = entry.Test.Slots[1].Bar._color

		assert(fill[1] == 0.2 and fill[2] == 0.4 and fill[3] == 0.8,
			"the stand-in takes the group colour")

		display:SetPreviewGroup(nil)
	end)

	fw.it("draws the border on the stand-in bars too", function()
		-- The icon stand-ins get their border from the colour, which is why the option looked like
		-- it did nothing in the preview while the live bars drew one.
		ClearGroups()

		local group = AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = "BAR", Border = true },
		})

		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local slot = display:GetStates()[group.Id].Screen.Test.Slots[1]

		for _, edge in ipairs(slot.Border) do
			assert(edge._shown, "every edge of the stand-in border shows")
		end

		group.Icons.Border = false
		module:Refresh()

		for _, edge in ipairs(slot.Border) do
			assert(edge._shown == false, "and goes away with the option")
		end

		display:SetPreviewGroup(nil)
	end)

	fw.it("leaves a group saved before bars existed drawing icons", function()
		local group = groups:Normalise({ Icons = { Size = 30 } })

		assert(group.Icons.Display == groups.DisplayStyle.Icons, "no field means icons")
	end)
end)

fw.describe("CustomAuras - module gating", function()
	fw.it("tears everything down once the last group is gone", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		ClearGroups()

		local container = ContainerFor("player")

		assert(container == nil or container._enabled == false, "the container stops tracking")
	end)

	fw.it("stops tracking a group that is switched off", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		module:Refresh()
		assert(Budget(ContainerFor("player"), "helpful") == groups.MaxIcons, "an enabled group tracks")

		group.Enabled = false
		module:Refresh()

		local container = ContainerFor("player")

		assert(container == nil or container._enabled == false, "and a disabled one does not")
	end)

	fw.it("reports nothing through Notify", function()
		assert(#env.notifications == 0,
			"unexpected warnings: " .. table.concat(env.notifications, " | "))
	end)
end)
