-- The personal aura module. The rule the whole design hangs off is that 12.1 only honours a
-- spell-id filter for helpful auras on assistable units and harmful auras on the rest, and
-- silently drops it otherwise. The sharp end of these tests is the icon budget: a group pointed
-- at the wrong side of that rule must be budgeted to zero, never left running on a bare
-- HELPFUL/HARMFUL token that would match every aura on the unit.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local acm = require("AuraContainerMock")

local env = moduleEnv.build()
local addon = env.addon

env.loadModule("src/Modules/PersonalAuras/Groups.lua")
env.loadModule("src/Modules/PersonalAuras/Sound.lua")
env.loadModule("src/Modules/PersonalAuras/Recorder.lua")
env.loadModule("src/Modules/PersonalAuras/Display.lua")
env.loadModule("src/Modules/PersonalAuras/Module.lua")

local groups = addon.Modules.PersonalAuras.Groups
local artTextures = addon.Core.ArtTextures
local display = addon.Modules.PersonalAuras.Display
local recorder = addon.Modules.PersonalAuras.Recorder
local sound = addon.Modules.PersonalAuras.Sound
local auraSounds = addon.Core.AuraSounds
local module = addon.Modules.PersonalAurasModule
local db = env.db
local options = db.Modules.PersonalAuras

-- Everything below authors its own groups, so the starter ones are switched off before Init:
-- they would otherwise be built against fixture spell names that are not installed yet, and
-- every "the container for the player" lookup would find one of them instead.
options.SeededDefaults = true

-- Off, because the tests that make the engine refuse are about what the module does next, not
-- about the chat message. The block that covers the messages switches it back on for itself.
db.DebugMode = false

module:Init()

local ICE_BLOCK = 45438
local POLYMORPH = 118
-- Four ids of one ability, so a tracked id can be proven to match only itself.
local TORRENT_IDS = { 33390, 36022, 47779, 222783 }

-- Ids nothing in the addon carries, which is the point: the wrong-side check asks the client, so
-- it has to answer for whatever somebody types into the picker. Stubbed here rather than in the
-- mock because these two calls arrived in 12.1 and the mock has no spells to have a side.
local A_DEBUFF = 900001
local A_BUFF = 900002
local BOTH_SIDES = 900003
local NEITHER_SIDE = 900004
local OLD_CLIENT_SPELL = 900005
local HARMFUL_SPELLS = { [A_DEBUFF] = true, [BOTH_SIDES] = true }
local HELPFUL_SPELLS = { [A_BUFF] = true, [BOTH_SIDES] = true }

_G.C_Spell.IsSpellHarmful = function(spellId)
	return HARMFUL_SPELLS[spellId] == true
end

_G.C_Spell.IsSpellHelpful = function(spellId)
	return HELPFUL_SPELLS[spellId] == true
end

---Adds a group with the given overrides applied on top of the defaults.
---@param overrides table
---@return PersonalAuraGroup
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
	-- An entry is handed over without its groups. The walker declares them a group per turn, so
	-- reading them back means letting it run.
	acm.tickAll(20)

	local list = env.containersForUnit(token)

	return list[1]
end

---@param container table
---@param key string
---@return number
local function Budget(container, key)
	-- As ContainerFor: the groups arrive from the walker, a group per turn.
	acm.tickAll(20)

	local group = container._groups[key]

	return group and group.maxFrameCount or -1
end

fw.describe("PersonalAuras - group defaults", function()
	fw.it("fills in everything a bare group is missing", function()
		local group = groups:Normalise({})

		assert(group.AuraType == "HELPFUL", "buffs are the default")
		assert(group.Anchor == "SCREEN", "screen anchored by default")
		assert(group.Unit == "player", "pointed at the player by default")
		assert(type(group.Spells) == "table" and #group.Spells == 0, "no spells yet")
		assert(group.Icons.Size > 0, "an icon size")
		assert(group.Icons.FontScale == 1.0, "text left at the size the icon would draw it anyway")
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
			Icons = { Size = -5, Spacing = 1e6, FontScale = 1e6 },
			Grow = "SIDEWAYS",
			Unit = "vehicle",
			AuraType = "SOMETHING",
		})

		assert(group.Icons.Size >= groups.MinIconSize, "the icon size is floored")
		assert(group.Icons.Spacing <= 50, "the spacing is capped")
		assert(group.Icons.FontScale == groups.MaxFontScale, "the font scale is capped")
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

fw.describe("PersonalAuras - the groups a profile starts with", function()
	---A profile that has never been seeded, standing alone so the module's own options are
	---left exactly as the rest of this file expects them.
	---@return table
	local function FreshOptions()
		return { Groups = {}, NextId = 1 }
	end

	fw.it("creates the starter groups once", function()
		local fresh = FreshOptions()

		assert(groups:SeedDefaults(fresh), "the first run seeds")
		assert(#fresh.Groups == 2, "two of them")
		assert(not groups:SeedDefaults(fresh), "and the second run does nothing")
		assert(#fresh.Groups == 2, "so they are not doubled up")
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

		local precog, shroud = fresh.Groups[1], fresh.Groups[2]

		assert(precog.Icons.Color.R == 1 and precog.Icons.Color.G == 1 and precog.Icons.Color.B == 1, "white precog")
		assert(shroud.Icons.Color.R == 0.64 and shroud.Icons.Color.B == 0.93, "purple shroud")
	end)

	fw.it("centres them above the player frame", function()
		local fresh = FreshOptions()

		groups:SeedDefaults(fresh)

		for _, group in ipairs(fresh.Groups) do
			assert(group.Position.X == 0, "centred on the screen")
			assert(group.Position.Y == 80, "just above the middle of the screen")
		end
	end)

	fw.it("gives one of them a sound on the applied trigger", function()
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

		assert(withSound == 1, "Precognition, but not Shroud")
	end)

	fw.it("hands out ids no later group can reuse", function()
		local fresh = FreshOptions()

		groups:SeedDefaults(fresh)

		assert(fresh.NextId > 2, "the counter moved past both of them")
		assert(groups:NewGroup(fresh).Id ~= fresh.Groups[1].Id, "so a new group is not a collision")
	end)
end)

fw.describe("PersonalAuras - duplicating a group", function()
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

fw.describe("PersonalAuras - reordering", function()
	---@return PersonalAuraGroup[]
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

fw.describe("PersonalAuras - group icons", function()
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

fw.describe("PersonalAuras - what a group is allowed to track", function()
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

	fw.it("offers one aura type per side of the focus, same as the target", function()
		assert(groups:SupportsAuraType("focusfriendly", "HELPFUL"), "buffs on a friendly focus")
		assert(not groups:SupportsAuraType("focusfriendly", "HARMFUL"), "but not debuffs")
		assert(groups:SupportsAuraType("focusenemy", "HARMFUL"), "debuffs on an enemy focus")
		assert(not groups:SupportsAuraType("focusenemy", "HELPFUL"), "but not buffs")
		assert(not groups:IsNameplateUnit("focusenemy"), "and a focus is not a plate")
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
		assert(groups:GetToken(groups:Normalise({ Unit = "focusenemy" })) == "focus",
			"both focus sides watch the focus")
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
		assert(groups:GetWarning(groups:Normalise({ Unit = "focusfriendly" }))
			== "HELPFUL_FRIENDLY_ONLY", "and a friendly focus the same reason")
		assert(groups:GetWarning(groups:Normalise({ Unit = "focusenemy" }))
			== "HARMFUL_HOSTILE_ONLY", "and an enemy focus hostile")
		assert(groups:GetWarning(groups:Normalise({ Unit = "player" })) == nil,
			"you are always there, so there is nothing to say")
	end)

	fw.it("lists both focus units in the dropdown", function()
		local found = { Friendly = false, Enemy = false }

		for _, unit in ipairs(groups.Units) do
			if unit == "focusfriendly" then
				found.Friendly = true
			elseif unit == "focusenemy" then
				found.Enemy = true
			end
		end

		assert(found.Friendly and found.Enemy, "both focus units are offered")
	end)
end)

fw.describe("PersonalAuras - spells on the wrong side of the group", function()
	fw.it("reads a spell's side off the client", function()
		assert(groups:SpellAuraType(A_DEBUFF) == "HARMFUL", "a spell cast at enemies is a debuff")
		assert(groups:SpellAuraType(A_BUFF) == "HELPFUL", "and one cast at allies a buff")
	end)

	fw.it("leaves a spell the client will not place alone", function()
		assert(groups:SpellAuraType(BOTH_SIDES) == nil, "a dispel is aimed at either side")
		assert(groups:SpellAuraType(NEITHER_SIDE) == nil, "and a proc cannot be cast at all")
	end)

	fw.it("says nothing on a client without the two calls", function()
		local harmful, helpful = _G.C_Spell.IsSpellHarmful, _G.C_Spell.IsSpellHelpful

		_G.C_Spell.IsSpellHarmful = nil
		_G.C_Spell.IsSpellHelpful = nil

		local placed = groups:SpellAuraType(OLD_CLIENT_SPELL)

		_G.C_Spell.IsSpellHarmful = harmful
		_G.C_Spell.IsSpellHelpful = helpful

		assert(placed == nil, "an older client leaves every spell unplaced")
	end)

	fw.it("catches a debuff sitting in a buff group", function()
		local group = groups:Normalise({ Unit = "player", Spells = { A_BUFF, A_DEBUFF } })

		assert(group.AuraType == "HELPFUL", "a self group is a buff group")
		assert(not groups:SpellFitsAuraType(group, A_DEBUFF), "the debuff can never match")
		assert(groups:SpellFitsAuraType(group, A_BUFF), "the buff is what the group is for")
		assert(groups:CountWrongTypeSpells(group) == 1, "one of the two is on the wrong side")
	end)

	fw.it("catches a buff sitting in a debuff group", function()
		local group = groups:Normalise({ Unit = "targetenemy", Spells = { A_BUFF, POLYMORPH } })

		assert(group.AuraType == "HARMFUL", "an enemy target group is a debuff group")
		assert(groups:CountWrongTypeSpells(group) == 1, "the buff is the odd one out")
	end)

	fw.it("has nothing to say about a spell neither side claims", function()
		local group = groups:Normalise({ Unit = "player", Spells = { BOTH_SIDES, NEITHER_SIDE } })

		assert(groups:CountWrongTypeSpells(group) == 0, "an unplaced spell is not a wrong one")
	end)

	fw.it("has nothing to say about a sound only group", function()
		-- A sound registration is (unit, spell id, sound file) with no filter string in it, so a
		-- debuff on yourself really does work that way and must not be marked up as broken.
		local group = groups:Normalise({ Unit = "player", Spells = { A_DEBUFF } })

		group.Icons.Display = "SOUND"
		groups:Normalise(group)

		assert(groups:CountWrongTypeSpells(group) == 0, "the aura type never enters into a sound")
	end)

	fw.it("has nothing to say about a group tracking by filter", function()
		local group = groups:Normalise({
			Unit = "player",
			TrackingMode = "FILTERS",
			Spells = { A_DEBUFF },
		})

		assert(groups:CountWrongTypeSpells(group) == 0, "a filter group matches on no spell ids")
	end)

	fw.it("warns rather than refusing the group", function()
		-- The client answers about what a spell can be cast at, which is a hair off what its aura
		-- counts as, so a wrong verdict must never be able to switch a working group off.
		local group = groups:Normalise({ Unit = "player", Spells = { A_DEBUFF } })

		assert(groups:Supports(group), "the group still runs")
		assert(groups:CountWrongTypeSpells(group) == 1, "with the warning on it")
	end)
end)

fw.describe("PersonalAuras - units saved before the split", function()
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

	fw.it("sends an old focus group to the side matching its aura type", function()
		assert(groups:Normalise({ Unit = "focus", AuraType = "HELPFUL" }).Unit == "focusfriendly",
			"a buff group becomes a friendly focus group")
		assert(groups:Normalise({ Unit = "focus", AuraType = "HARMFUL" }).Unit == "focusenemy",
			"and a debuff group an enemy focus group")
	end)

	fw.it("moves the target's target onto the target", function()
		-- The target's target has no home of its own, so pointing it at the target keeps the
		-- group working on something rather than silently disabling it.
		assert(groups:Normalise({ Unit = "targettarget" }).Unit == "targetfriendly",
			"the target's target becomes a friendly target group")
	end)
end)

fw.describe("PersonalAuras - units that follow a role", function()
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
	---@return PersonalAuraGroup
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

fw.describe("PersonalAuras - spell filters", function()
	fw.it("matches only the tracked id, not the other ids the ability is known by", function()
		local group = groups:Normalise({ Spells = { TORRENT_IDS[1] } })
		local filters = groups:BuildFilters(group)
		local count = 0

		for _ in pairs(filters.includeSpellIDs) do
			count = count + 1
		end

		assert(filters.includeSpellIDs[TORRENT_IDS[1]], "the id that was asked for")
		assert(count == 1, "and nothing else")
	end)

	fw.it("changes its generation when the tracked set moves", function()
		local group = groups:Normalise({ Spells = { POLYMORPH } })
		local before = groups:GetFilterGeneration(group)

		group.Spells[#group.Spells + 1] = ICE_BLOCK

		local withSpell = groups:GetFilterGeneration(group)

		assert(withSpell ~= before, "adding a spell is a change")

		group.AuraType = "HARMFUL"

		-- Against the reading taken after the spell landed, not the first one. Comparing with that
		-- passes on the spell alone and says nothing about the aura type.
		assert(groups:GetFilterGeneration(group) ~= withSpell, "so is flipping the aura type")
	end)
end)

fw.describe("PersonalAuras - screen anchored displays", function()
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
		-- check it cannot evaluate is skipped rather than failed. The group would show the aura
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

	fw.it("re-budgets a focus group off the focus changing", function()
		ClearGroups()
		AddGroup({ Unit = "focusfriendly", Spells = { ICE_BLOCK }, Caster = groups.Caster.Mine })
		env.enemies.focus = nil
		env.phased.focus = true
		module:Refresh()

		local container = ContainerFor("focus")

		assert(Budget(container, "helpful") == 0, "an unattributable focus shows nothing")

		local frame = acm.lastFrameForEvent("PLAYER_FOCUS_CHANGED")

		assert(frame, "the module listens for the focus changing")

		env.phased.focus = nil
		frame:TriggerEvent("PLAYER_FOCUS_CHANGED")

		assert(Budget(container, "helpful") == groups.MaxIcons,
			"and the swap alone brings the group back")
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

fw.describe("PersonalAuras - the combat condition", function()
	fw.it("leaves a new group showing whatever the player is doing", function()
		ClearGroups()
		env.inCombat = false

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		assert(group.ShowWhen == groups.ShowWhen.Always, "nothing is conditional until it is asked for")
	end)

	fw.it("holds an in-combat group back until the pull", function()
		ClearGroups()
		env.inCombat = false

		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, ShowWhen = groups.ShowWhen.InCombat })
		module:Refresh()

		local container = ContainerFor("player")

		assert(container == nil or Budget(container, "helpful") == 0, "nothing out of combat")

		env.inCombat = true
		module:Refresh()

		container = ContainerFor("player")

		assert(container and Budget(container, "helpful") == groups.MaxIcons,
			"and the full budget once combat starts")

		env.inCombat = false
	end)

	fw.it("takes an out-of-combat group away for the fight", function()
		ClearGroups()
		env.inCombat = false

		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, ShowWhen = groups.ShowWhen.OutOfCombat })
		module:Refresh()

		local container = ContainerFor("player")

		assert(container and Budget(container, "helpful") == groups.MaxIcons, "shown at rest")

		env.inCombat = true
		module:Refresh()

		container = ContainerFor("player")

		assert(container == nil or Budget(container, "helpful") == 0, "and gone for the fight")

		env.inCombat = false
	end)

	fw.it("draws a conditional group in test mode whatever the combat state", function()
		ClearGroups()
		env.inCombat = false

		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, ShowWhen = groups.ShowWhen.InCombat })
		module:StartTesting()

		assert(ContainerFor("player"), "a preview that hid itself would read as broken")

		module:StopTesting()
	end)

	fw.it("rebuilds on the regen events", function()
		ClearGroups()
		env.inCombat = false

		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, ShowWhen = groups.ShowWhen.InCombat })
		module:Refresh()

		local frame = acm.lastFrameForEvent("PLAYER_REGEN_DISABLED")

		assert(frame, "the module listens for combat starting")

		env.inCombat = true
		frame:TriggerEvent("PLAYER_REGEN_DISABLED")

		assert(Budget(ContainerFor("player"), "helpful") == groups.MaxIcons,
			"the pull alone brings the group up")

		env.inCombat = false
		frame:TriggerEvent("PLAYER_REGEN_ENABLED")

		local container = ContainerFor("player")

		assert(container == nil or Budget(container, "helpful") == 0,
			"and dropping combat takes it away")
	end)

	fw.it("ignores the regen events while no group is conditional", function()
		ClearGroups()
		env.inCombat = false

		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local frame = acm.lastFrameForEvent("PLAYER_REGEN_DISABLED")
		local refreshes = 0
		local real = display.Refresh

		display.Refresh = function(...)
			refreshes = refreshes + 1
			return real(...)
		end

		frame:TriggerEvent("PLAYER_REGEN_DISABLED")
		frame:TriggerEvent("PLAYER_REGEN_ENABLED")

		display.Refresh = real

		assert(refreshes == 0, "a profile of plain groups pays nothing per pull")
	end)
end)

fw.describe("PersonalAuras - options page preview", function()
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

	fw.it("drops the name from a previewed bar when the group turned it off", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Icons = { Display = "BAR" } })

		display:SetPreviewGroup(group.Id)

		local slot = display:GetStates()[group.Id].Screen.Test.Slots[1]

		assert(slot.Name:GetText() ~= "", "the stand-in bar is labelled while the switch is on")

		group.Icons.SpellName = false
		module:Refresh()

		assert(display:GetStates()[group.Id].Screen.Test.Slots[1].Name:GetText() == "",
			"and the preview follows the switch, like the live bars do")

		display:SetPreviewGroup(nil)
	end)

	fw.it("resizes a previewed bar's text when the font scale moves under it", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Icons = { Display = "BAR" } })

		group.Icons.FontScale = 1.0
		display:SetTestMode(true)
		module:Refresh()

		local slot = display:GetStates()[group.Id].Screen.Test.Slots[1]

		group.Icons.FontScale = 2.0
		module:Refresh()

		assert(slot.Name._fontScale == 2.0,
			"the name was sized at " .. tostring(slot.Name._fontScale))
		assert(slot.Time._fontScale == 2.0,
			"the countdown was sized at " .. tostring(slot.Time._fontScale))

		display:SetTestMode(false)
		ClearGroups()
	end)

	fw.it("skips a group with nothing to draw", function()
		-- The stand-in icons are the drag handle when the anchor has no backdrop, so a group
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

fw.describe("PersonalAuras - nameplate anchored displays", function()
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

	fw.it("restyles a plate copy away from the plate", function()
		-- A button's size is secret anywhere inside a nameplate, so a restyle applied while the
		-- display hangs off one is refused and the icons keep the old size for good.
		ClearGroups()
		local group = AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })
		group.Icons.Size = 30

		local plate = env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		module:Refresh()
		acm.tickAll(20)

		local entry = display:GetStates()[group.Id].Plates.nameplate1
		local parents = {}
		local applyConfig = entry.Display.ApplyConfig

		entry.Display.ApplyConfig = function(self, ...)
			parents[#parents + 1] = self.Frame:GetParent()

			return applyConfig(self, ...)
		end

		group.Icons.Size = 55
		module:Refresh()
		acm.tickAll(20)

		entry.Display.ApplyConfig = applyConfig

		assert(#parents > 0, "the size change restyled the copy")

		for _, parent in ipairs(parents) do
			assert(parent == UIParent, "the copy left the plate to take its new size")
		end

		assert(entry.Display.Size == 55, "and the new size landed")
		assert(entry.Display.Frame:GetParent() == plate, "the copy is back on its plate after")
	end)

	fw.it("scales a plate copy with its nameplate, and never a unit frame copy", function()
		ClearGroups()
		local plateGroup = AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })
		local frameGroup = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })
		local nmOptions = db.Modules.Nameplates
		local original = nmOptions.ScaleWithNameplate

		nmOptions.ScaleWithNameplate = true
		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		local frame = env.addUnitFrame("party1")
		module:Refresh()

		local plateEntry = display:GetStates()[plateGroup.Id].Plates.nameplate1
		local frameEntry = display:GetStates()[frameGroup.Id].Frames[frame]

		assert(not plateEntry.Display.Frame:IsIgnoringParentScale(),
			"the plate copy follows its plate's scale")
		assert(frameEntry.Display.Frame:IsIgnoringParentScale(),
			"a copy anchored to anything but a nameplate is never affected by the option")

		nmOptions.ScaleWithNameplate = original
		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil

		for index = #env.unitFrames, 1, -1 do
			env.unitFrames[index] = nil
		end

		module:Refresh()
	end)

	fw.it("drops a plate copy back to pixel size when the option is turned off", function()
		ClearGroups()
		local group = AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })
		local nmOptions = db.Modules.Nameplates
		local original = nmOptions.ScaleWithNameplate

		nmOptions.ScaleWithNameplate = true
		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		module:Refresh()

		local entry = display:GetStates()[group.Id].Plates.nameplate1

		assert(not entry.Display.Frame:IsIgnoringParentScale(), "scaling engages first")

		nmOptions.ScaleWithNameplate = false
		module:Refresh()

		assert(entry.Display.Frame:IsIgnoringParentScale(),
			"and turning the option back off returns the copy to pixel size")

		nmOptions.ScaleWithNameplate = true
		module:Refresh()

		assert(not entry.Display.Frame:IsIgnoringParentScale(),
			"and back on again, since the cached state must not strand a live copy")

		nmOptions.ScaleWithNameplate = original
		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil
	end)

	fw.it("takes the scaling off a pooled copy a screen group reuses", function()
		ClearGroups()
		local plateGroup = AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })
		local nmOptions = db.Modules.Nameplates
		local original = nmOptions.ScaleWithNameplate

		nmOptions.ScaleWithNameplate = true
		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		module:Refresh()

		local scaledFrame = display:GetStates()[plateGroup.Id].Plates.nameplate1.Display.Frame

		assert(not scaledFrame:IsIgnoringParentScale(), "the plate copy is scaled to begin with")

		ClearGroups()
		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil

		local screenGroup = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		module:Refresh()

		local screenEntry = display:GetStates()[screenGroup.Id].Screen

		assert(screenEntry.Display.Frame == scaledFrame, "the pool handed the same copy back")
		assert(scaledFrame:IsIgnoringParentScale(),
			"and it is back at pixel size now it hangs off the screen rather than a plate")

		nmOptions.ScaleWithNameplate = original
	end)

	fw.it("scales the preview stand-ins with the plate too, or a drag lands them wrong", function()
		ClearGroups()
		local group = AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })
		local nmOptions = db.Modules.Nameplates
		local original = nmOptions.ScaleWithNameplate

		nmOptions.ScaleWithNameplate = true
		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		display:SetPreviewGroup(group.Id)
		module:Refresh()

		local entry = display:GetStates()[group.Id].Plates.nameplate1

		assert(entry.Test, "the group is previewing, so it grew stand-ins")
		assert(not entry.Test.Frame:IsIgnoringParentScale(),
			"the stand-ins take the plate's scale, as the live copy does")

		nmOptions.ScaleWithNameplate = false
		module:Refresh()

		assert(entry.Test.Frame:IsIgnoringParentScale(),
			"and drop back to pixel size with it")

		display:SetPreviewGroup(nil)
		nmOptions.ScaleWithNameplate = original
		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil
	end)
end)

fw.describe("PersonalAuras - the layer a group draws in", function()
	fw.it("leaves a screen group on the layer it would have inherited", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		assert(ContainerFor("player"):GetFrameStrata() == UIParent:GetFrameStrata(),
			"automatic is whatever the screen anchor already had")
	end)

	fw.it("pins a screen group to the layer it was given", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Strata = "HIGH" })
		module:Refresh()

		assert(ContainerFor("player"):GetFrameStrata() == "HIGH",
			"the group draws where it was told to")
	end)

	fw.it("puts a group back down when its layer is set to automatic again", function()
		-- Displays come out of a shared pool and a strata cannot be un-set, so a frame left pinned
		-- would carry the old layer into whatever group takes it next.
		ClearGroups()
		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Strata = "FULLSCREEN" })
		module:Refresh()

		group.Strata = groups.StrataAuto
		module:Refresh()

		assert(ContainerFor("player"):GetFrameStrata() == UIParent:GetFrameStrata(),
			"back on the layer it would have inherited")
	end)

	fw.it("follows the plate a nameplate group hangs off", function()
		ClearGroups()
		AddGroup({ Unit = "nameplate", AuraType = "HARMFUL", Spells = { POLYMORPH } })

		env.addPlate("nameplate1"):SetFrameStrata("BACKGROUND")
		env.enemies.nameplate1 = true
		module:Refresh()

		assert(ContainerFor("nameplate1"):GetFrameStrata() == "BACKGROUND",
			"automatic takes the plate's own layer, not the screen's")
	end)

	fw.it("pins a nameplate group above its plate when asked", function()
		ClearGroups()
		AddGroup({
			Unit = "nameplate",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Strata = "DIALOG",
		})

		env.addPlate("nameplate1"):SetFrameStrata("BACKGROUND")
		env.enemies.nameplate1 = true
		module:Refresh()

		assert(ContainerFor("nameplate1"):GetFrameStrata() == "DIALOG",
			"its own choice beats the plate's")

		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil
		module:Refresh()
	end)

end)

fw.describe("PersonalAuras - unit frame anchored displays", function()
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
		addon.Modules.PersonalAuras.Sound:Clear()
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

fw.describe("PersonalAuras - arena frame anchored displays", function()
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
		addon.Modules.PersonalAuras.Sound:Clear()
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

fw.describe("PersonalAuras - stand-in frames while a group is being placed", function()
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

	fw.it("leaves the stand-ins alone for a sound only group", function()
		Reset()
		SetTokensAbsent("party", true)

		local group = AddGroup({
			Unit = "unitframes",
			Spells = { ICE_BLOCK },
			Icons = { Display = groups.DisplayStyle.SoundOnly },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		display:SetPreviewGroup(group.Id)

		-- Nothing is ever drawn on them, so there is nothing to stand a frame in for.
		assert(not env.testFramesShown, "no stand-in party frames for a group that draws nothing")
		assert(Count(display:GetStates()[group.Id].Frames) == 0, "and no copies taken out")

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

		-- The default arena frames exist from login and sit hidden outside an arena. A copy
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

fw.describe("PersonalAuras - the anchor walk per refresh", function()
	local frames = addon.Core.Frames

	---Counts the walks one refresh makes, with the module left as the body found it.
	---@param body fun()
	---@return number
	local function CountWalks(body)
		local realGetAll = frames.GetAll
		local walks = 0

		frames.GetAll = function(...)
			walks = walks + 1

			return realGetAll(...)
		end

		local ok, err = pcall(body)

		frames.GetAll = realGetAll
		assert(ok, err)

		return walks
	end

	fw.it("walks once however many groups hang off the unit frames", function()
		ClearGroups()

		for _ = 1, 4 do
			AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })
		end

		local walks = CountWalks(function()
			module:Refresh()
		end)

		assert(walks == 1, "four frame groups share one walk (got " .. walks .. ")")

		ClearGroups()
	end)

	fw.it("adds one walk for the group being previewed, not one per group", function()
		ClearGroups()

		local previewed = AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })

		for _ = 1, 3 do
			AddGroup({ Unit = "unitframes", Spells = { ICE_BLOCK } })
		end

		display:SetPreviewGroup(previewed.Id)

		local walks = CountWalks(function()
			module:Refresh()
		end)

		-- The plain list, plus the one with the stand-ins on the end that only the previewed
		-- group reads.
		assert(walks <= 2, "a preview costs one extra walk at most (got " .. walks .. ")")

		display:SetPreviewGroup(nil)
		ClearGroups()
	end)
end)

fw.describe("PersonalAuras - tracking by filter", function()
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

	fw.it("changes generation on the mode itself, not just what it builds", function()
		-- With no components chosen, both modes build the same bare filter string. Only the
		-- mode says whether an includeSpellIDs map is sent at all, so the display has to be
		-- told, or switching back to a spell list leaves the container filtering on nothing.
		local group = groups:Normalise({ Spells = { ICE_BLOCK } })
		local bySpells = groups:GetFilterGeneration(group)

		group.TrackingMode = groups.TrackingMode.Filters
		groups:Normalise(group)

		assert(groups:BuildFilterString(group) == "HELPFUL", "the string really is unchanged")
		assert(groups:GetFilterGeneration(group) ~= bySpells, "but the generation moved anyway")
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

fw.describe("PersonalAuras - candidate filters", function()
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

	fw.it("never caps the duration, so a permanent tracked buff still shows", function()
		-- Any maxDuration also drops auras with no duration at all, which cost people their
		-- permanent buffs.
		local bySpells = groups:Normalise({ Spells = { ICE_BLOCK } })
		local byFilter = groups:Normalise({ TrackingMode = groups.TrackingMode.Filters })

		assert(groups:BuildFilters(bySpells).maxDuration == nil, "a spell list keeps permanents")
		assert(groups:BuildFilters(byFilter).maxDuration == nil, "so does a filter group")
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

	fw.it("moves its generation when any of it changes", function()
		local group = groups:Normalise({ Spells = { ICE_BLOCK } })
		local before = groups:GetFilterGeneration(group)

		group.Candidates.isBossAura = "REQUIRE"

		local withFlag = groups:GetFilterGeneration(group)

		assert(withFlag ~= before, "a flag reaches the engine")

		group.Sort = groups.Sort.Longest

		assert(groups:GetFilterGeneration(group) ~= withFlag, "and so does the order")
	end)
end)

fw.describe("PersonalAuras - icon order", function()
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

fw.describe("PersonalAuras - sounds", function()
	fw.it("registers a sound for a tracked spell on the group's unit", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()

		local before = env.auraSoundAdds

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		-- One handle per id, so a group that registered anything beyond the id it was given would
		-- show up as a second add.
		assert(env.auraSoundAdds == before + 1, "one spell on one trigger is one registration")

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
		addon.Modules.PersonalAuras.Sound:Clear()

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
		addon.Modules.PersonalAuras.Sound:Clear()

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

---A two spell request whose second id the engine will turn down.
---@param groupId string
---@return PersonalAuraSoundRequest
local function RefusedRequest(groupId)
	return {
		GroupId = groupId,
		Unit = "player",
		Trigger = "Applied",
		File = "Sonar",
		Channel = "Master",
		SpellIds = { ICE_BLOCK, POLYMORPH },
	}
end

---Makes the engine refuse the polymorph id, and counts what it was offered. The caller puts the
---real function back.
---@return function realAdd
---@return fun(): number offered
local function RefuseOne()
	local realAdd = _G.C_UnitAuras.AddAuraSound
	local offered = 0

	-- A refusal, which the engine gives no reason for.
	_G.C_UnitAuras.AddAuraSound = function(trigger, info)
		offered = offered + 1

		if info.spellID == POLYMORPH then
			return nil
		end

		return realAdd(trigger, info)
	end

	return realAdd, function()
		return offered
	end
end

---A run of distinct spell ids, for the cap tests that need more of them than the cap allows.
---@param count number
---@param base number
---@return number[]
local function SpellList(count, base)
	local ids = {}

	for index = 1, count do
		ids[index] = base + index
	end

	return ids
end

---The engine's live registrations matching a test, as a handle set and how many there are.
---@param match fun(entry: table): boolean
---@return table<number, boolean> held
---@return number count
local function SoundHandles(match)
	local held, count = {}, 0

	for handle, entry in pairs(env.auraSounds) do
		if match(entry) then
			held[handle] = true
			count = count + 1
		end
	end

	return held, count
end

---True while every handle in the set is still registered, so a false says one was handed back.
---@param held table<number, boolean>
---@return boolean
local function StillHeld(held)
	for handle in pairs(held) do
		if not env.auraSounds[handle] then
			return false
		end
	end

	return true
end

---@param entry table
---@param name string
---@return boolean
local function PlaysFile(entry, name)
	return entry.File ~= nil and entry.File:find(name, 1, true) ~= nil
end

---Drops every plate the mock is holding. Called on the way in as well as on the way out, since a
---test that ends early leaves its plates behind and the next one would then add nothing.
local function ClearPlates()
	for token in pairs(env.plates) do
		display:OnNamePlateRemoved(token)
		env.plates[token] = nil
		env.enemies[token] = nil
	end

	module:Refresh()
end

fw.describe("PersonalAuras - reconciling the sound registrations", function()
	fw.it("leaves a player group's handles alone while plates come and go", function()
		ClearGroups()
		ClearPlates()
		sound:Clear()

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		AddGroup({
			Unit = "nameplate",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Sound = { Applied = "AirHorn", Channel = "Master" },
		})

		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		module:Refresh()

		local function OnPlayer(entry)
			return entry.Unit == "player"
		end

		local held, count = SoundHandles(OnPlayer)

		assert(count > 0, "the player group registered something to protect")

		env.addPlate("nameplate2")
		env.enemies.nameplate2 = true
		module:Refresh()

		local _, arrived = SoundHandles(OnPlayer)

		assert(StillHeld(held), "a plate arriving hands back none of the player's handles")
		assert(arrived == count, "and takes out no new ones for the player either")

		display:OnNamePlateRemoved("nameplate2")
		env.plates.nameplate2 = nil
		env.enemies.nameplate2 = nil
		module:Refresh()

		local _, gone = SoundHandles(OnPlayer)

		assert(StillHeld(held), "and neither does one leaving")
		assert(gone == count, "still the same registrations on the player")

		ClearPlates()
		ClearGroups()
	end)

	fw.it("registers the plate that arrived without touching the ones already there", function()
		ClearGroups()
		ClearPlates()
		sound:Clear()

		AddGroup({
			Unit = "nameplate",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		env.addPlate("nameplate1")
		env.enemies.nameplate1 = true
		module:Refresh()

		local held, count = SoundHandles(function(entry)
			return entry.Unit == "nameplate1"
		end)

		assert(count > 0, "the first plate is registered")

		env.addPlate("nameplate2")
		env.enemies.nameplate2 = true
		module:Refresh()

		local _, second = SoundHandles(function(entry)
			return entry.Unit == "nameplate2"
		end)

		assert(StillHeld(held), "the plate that was already there keeps every handle")
		assert(second == count, "and the one that arrived got its own")

		ClearPlates()
		ClearGroups()
	end)

	fw.it("keeps two groups on one unit apart, and moves only the one that changed", function()
		ClearGroups()
		sound:Clear()

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		-- Same unit, same trigger, same file. Only the group they belong to tells the two
		-- registration sets apart, and the channel is what lets the test see which is which.
		local changing = AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "SFX" },
		})

		module:Refresh()

		local function OnMaster(entry)
			return entry.Channel == "Master"
		end

		local kept, keptCount = SoundHandles(OnMaster)
		local moved, movedCount = SoundHandles(function(entry)
			return entry.Channel == "SFX"
		end)

		assert(keptCount > 0 and movedCount > 0, "both groups are registered at once")

		changing.Sound.Applied = "AirHorn"
		module:Refresh()

		assert(StillHeld(kept), "the group that did not move keeps its handles")
		assert(not StillHeld(moved), "the one that did handed its own back")

		local _, replaced = SoundHandles(function(entry)
			return entry.Channel == "SFX" and PlaysFile(entry, "AirHorn")
		end)
		local _, master = SoundHandles(OnMaster)

		assert(replaced == movedCount, "and took out the same number on the new file")
		assert(master == keptCount, "with nothing re-registered for the other group")

		ClearGroups()
	end)

	fw.it("hands back the handles of a group that was deleted", function()
		ClearGroups()
		sound:Clear()

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		local doomed = AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "AirHorn", Channel = "Master" },
		})

		module:Refresh()

		local kept = SoundHandles(function(entry)
			return PlaysFile(entry, "Sonar")
		end)
		local _, doomedCount = SoundHandles(function(entry)
			return PlaysFile(entry, "AirHorn")
		end)

		assert(doomedCount > 0, "the doomed group registered something")

		for index, group in ipairs(options.Groups) do
			if group.Id == doomed.Id then
				table.remove(options.Groups, index)
				break
			end
		end

		module:Refresh()

		local _, left = SoundHandles(function(entry)
			return PlaysFile(entry, "AirHorn")
		end)

		assert(left == 0, "the deleted group's handles are all back")
		assert(StillHeld(kept), "and the group that stayed keeps its own")

		ClearGroups()
	end)

	fw.it("registers a spell at a time, so a long list cannot starve the group behind it", function()
		ClearGroups()
		sound:Clear()

		-- Past the module's cap on its own, so draining it before moving on would leave the
		-- group behind it with nothing.
		local many = SpellList(1600, 900100)

		sound:Apply({
			{
				GroupId = "gLong",
				Unit = "player",
				Trigger = "Applied",
				File = "Sonar",
				Channel = "Master",
				SpellIds = many,
			},
			{
				GroupId = "gShort",
				Unit = "focus",
				Trigger = "Applied",
				File = "AirHorn",
				Channel = "Master",
				SpellIds = { ICE_BLOCK },
			},
		})

		local _, short = SoundHandles(function(entry)
			return entry.Unit == "focus"
		end)

		assert(short == 1, "the group behind the long one registered too")
		assert(sound:WasTruncated(), "and the cap really did bite")

		sound:Clear()
		sound:Apply({
			{
				GroupId = "gAfter",
				Unit = "focus",
				Trigger = "Applied",
				File = "Sonar",
				Channel = "Master",
				SpellIds = { ICE_BLOCK },
			},
		})

		local _, freed = SoundHandles(function(entry)
			return entry.Unit == "focus"
		end)

		assert(not sound:WasTruncated(), "clearing puts the cap report back")
		assert(freed == 1, "and gives the budget the cleared pass was holding back too")

		sound:Clear()
	end)

	fw.it("tops a capped key up from where it stopped once room opens", function()
		ClearGroups()
		sound:Clear()

		local many = SpellList(1600, 900100)

		local long = {
			GroupId = "gLong",
			Unit = "player",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = many,
		}

		sound:Apply({
			long,
			{
				GroupId = "gShort",
				Unit = "focus",
				Trigger = "Applied",
				File = "AirHorn",
				Channel = "Master",
				SpellIds = { ICE_BLOCK },
			},
		})

		local function OnLong(entry)
			return entry.Unit == "player"
		end

		local held, before = SoundHandles(OnLong)

		assert(sound:WasTruncated(), "the long key was cut off by the cap")

		-- The short key goes, which is the only room the long one is ever going to get.
		sound:Apply({ long })

		local _, after = SoundHandles(OnLong)

		assert(after > before, "the freed room went to the key the cap cut off")
		assert(StillHeld(held), "and it kept every handle it already had")

		sound:Clear()
	end)

	fw.it("stops counting a capped key once it has caught up", function()
		ClearGroups()
		sound:Clear()

		-- Short enough to finish inside the cap once the sibling goes, so the key really does
		-- reach the end of its list rather than staying cut off for good.
		local many = SpellList(1400, 900100)
		local sibling = SpellList(200, 905100)

		local long = {
			GroupId = "gLong",
			Unit = "player",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = many,
		}

		sound:Apply({
			long,
			{
				GroupId = "gSibling",
				Unit = "focus",
				Trigger = "Applied",
				File = "AirHorn",
				Channel = "Master",
				SpellIds = sibling,
			},
		})

		assert(sound:WasTruncated(), "the long key was cut off by the cap")

		-- The sibling goes, leaving exactly enough room for the long key to finish its list.
		sound:Apply({ long })

		local caughtUp = sound:WasTruncated()
		local before = env.auraSoundAdds

		sound:Apply({ long })

		local seen, twice = {}, 0

		for _, entry in pairs(env.auraSounds) do
			if entry.Unit == "player" then
				twice = twice + (seen[entry.SpellId] and 1 or 0)
				seen[entry.SpellId] = true
			end
		end

		assert(twice == 0, "no spell id was registered twice")
		assert(not caughtUp, "a key that caught up stops counting against the cap")
		assert(env.auraSoundAdds == before, "and the pass after it is free")

		sound:Clear()
	end)

	fw.it("registers a key a list names twice only once", function()
		ClearGroups()
		sound:Clear()

		local request = {
			GroupId = "gTwice",
			Unit = "focus",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = { ICE_BLOCK, POLYMORPH },
		}

		sound:Apply({ request, request })

		local _, count = SoundHandles(function(entry)
			return entry.Unit == "focus"
		end)

		local before = env.auraSoundAdds

		sound:Apply({ request, request })

		assert(count == 2, "one registration per spell id, not one per mention")
		assert(env.auraSoundAdds == before, "and the key settled, so the pass after it is free")

		sound:Clear()
	end)

	fw.it("retries the refused id every pass without disturbing the rest", function()
		ClearGroups()
		sound:Clear()

		local requests = { RefusedRequest("gRetry") }
		local realAdd, offered = RefuseOne()

		local function OnPlayer(entry)
			return entry.Unit == "player"
		end

		-- Counted first and asserted afterwards, so a failure still puts the engine back. Left
		-- refusing, every test after this one would see nothing register.
		sound:Apply(requests)

		local first = offered()
		local held, landed = SoundHandles(OnPlayer)

		sound:Apply(requests)
		sound:Apply(requests)

		local later = offered()
		local undisturbed = StillHeld(held)
		local _, stillLanded = SoundHandles(OnPlayer)

		_G.C_UnitAuras.AddAuraSound = realAdd

		-- The engine takes it this time, and the key has been offering it all along.
		sound:Apply(requests)

		local _, recovered = SoundHandles(OnPlayer)

		sound:Clear()

		assert(first == 2, "both spell ids were offered")
		assert(landed == 1, "and one of the two was refused")
		assert(later == 4, "each pass after offers the missing id and nothing else")
		assert(undisturbed and stillLanded == 1, "the id that did land is left alone")
		assert(recovered == 2, "and the missing one lands as soon as the engine takes it")
	end)

	fw.it("starts over when what the key wants changes", function()
		ClearGroups()
		sound:Clear()

		local request = RefusedRequest("gChange")
		local requests = { request }
		local realAdd, offered = RefuseOne()

		sound:Apply(requests)

		local first = offered()
		local held = SoundHandles(function(entry)
			return entry.Unit == "player"
		end)

		-- The file is baked into the handle it did get, so that one has to go back too.
		request.File = "AirHorn"
		sound:Apply(requests)

		local afterChange = offered()
		local kept = StillHeld(held)

		_G.C_UnitAuras.AddAuraSound = realAdd

		sound:Clear()

		assert(first == 2, "both spell ids were offered")
		assert(afterChange == 4, "a changed sound offers the whole list again")
		assert(not kept, "and the handle taken out on the old file went back")
	end)

	fw.it("keeps a key whose every id the engine turned down", function()
		ClearGroups()
		sound:Clear()

		local requests = { RefusedRequest("gRefusedAll") }
		local realAdd = _G.C_UnitAuras.AddAuraSound

		_G.C_UnitAuras.AddAuraSound = function()
			return nil
		end

		sound:Apply(requests)

		_G.C_UnitAuras.AddAuraSound = realAdd

		local _, none = SoundHandles(function(entry)
			return entry.Unit == "player"
		end)

		sound:Apply(requests)

		local _, recovered = SoundHandles(function(entry)
			return entry.Unit == "player"
		end)

		sound:Clear()

		assert(none == 0, "nothing was registered")
		assert(recovered == 2, "the key registers once the engine answers again")
	end)

	fw.it("releases the rest of a key's handles when one hand-back throws", function()
		ClearGroups()
		sound:Clear()

		-- Exactly the cap, so the key cannot fit a second time unless every handle it held really
		-- did come back.
		local full = {
			GroupId = "gFull",
			Unit = "pet",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = SpellList(1500, 900100),
		}

		sound:Apply({ full })

		local fitted = not sound:WasTruncated()
		local realRemove = _G.C_UnitAuras.RemoveAuraSound
		local thrown = false

		_G.C_UnitAuras.RemoveAuraSound = function(handle)
			if not thrown then
				thrown = true
				error("blocked")
			end

			return realRemove(handle)
		end

		local cleared = pcall(function()
			sound:Clear()
		end)

		_G.C_UnitAuras.RemoveAuraSound = realRemove

		sound:Apply({ full })

		local roomCameBack = not sound:WasTruncated()

		sound:Clear()

		assert(fitted, "the first pass fits inside the cap")
		assert(cleared, "the throw does not escape Clear")
		assert(thrown, "one hand-back really did throw")
		assert(roomCameBack, "and the room every handle held came back")
	end)
end)

fw.describe("PersonalAuras - reporting a sound the engine would not take", function()
	---Runs body with the messages switched on, and hands back what it printed to chat.
	---@param body function
	---@return string[]
	local function Printed(body)
		wipe(env.notifications)
		db.DebugMode = true

		local ok, err = pcall(body)

		db.DebugMode = false

		assert(ok, err)

		local said = {}

		for index = 1, #env.notifications do
			said[index] = env.notifications[index]
		end

		wipe(env.notifications)

		return said
	end

	---Makes every registration a refusal for the length of body.
	---@param body function
	local function Refusing(body)
		local realAdd = _G.C_UnitAuras.AddAuraSound

		_G.C_UnitAuras.AddAuraSound = function()
			return nil
		end

		local ok, err = pcall(body)

		_G.C_UnitAuras.AddAuraSound = realAdd

		assert(ok, err)
	end

	fw.it("names a refused registration once, however many passes it takes", function()
		ClearGroups()
		sound:Clear()

		local requests = { RefusedRequest("gSaid") }

		local said = Printed(function()
			Refusing(function()
				sound:Apply(requests)
				sound:Apply(requests)
			end)
		end)

		sound:Clear()

		assert(#said == 2, "one message per spell id, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find(tostring(ICE_BLOCK), 1, true), "the message carries the spell it was for")
		assert(said[1]:find("player", 1, true), "and the unit it was for")
		assert(said[2]:find(tostring(POLYMORPH), 1, true), "the second names the other spell")
	end)

	fw.it("reports only the id the engine turned down", function()
		ClearGroups()
		sound:Clear()

		local realAdd = RefuseOne()

		local said = Printed(function()
			sound:Apply({ RefusedRequest("gRefused") })
		end)

		_G.C_UnitAuras.AddAuraSound = realAdd

		sound:Clear()

		assert(#said == 1, "only the refused id is reported, got " .. #said)
		assert(said[1]:find(tostring(POLYMORPH), 1, true), "and it names that id: " .. said[1])
	end)

	fw.it("says nothing when the engine takes every id", function()
		ClearGroups()
		sound:Clear()

		local said = Printed(function()
			sound:Apply({
				{
					GroupId = "gQuiet",
					Unit = "player",
					Trigger = "Applied",
					File = "Sonar",
					Channel = "Master",
					SpellIds = { ICE_BLOCK, POLYMORPH },
				},
			})
		end)

		sound:Clear()

		assert(#said == 0, "unexpected messages: " .. table.concat(said, " | "))
	end)

	fw.it("stays quiet while the setting is off", function()
		ClearGroups()
		sound:Clear()
		wipe(env.notifications)

		Refusing(function()
			sound:Apply({ RefusedRequest("gOff") })
		end)

		local quiet = #env.notifications == 0
		local heard = table.concat(env.notifications, " | ")

		wipe(env.notifications)
		sound:Clear()

		assert(quiet, "unexpected messages: " .. heard)
	end)

	fw.it("says a failure again once it has been cleared", function()
		ClearGroups()
		sound:Clear()

		local requests = { RefusedRequest("gAgain") }

		local first = Printed(function()
			Refusing(function()
				sound:Apply(requests)
			end)
		end)

		sound:Clear()

		local afterClear = Printed(function()
			Refusing(function()
				sound:Apply(requests)
			end)
		end)

		sound:Clear()

		assert(#first == 2, "both ids were reported the first time, got " .. #first)
		assert(#afterClear == 2, "and again after the clear, got " .. #afterClear)
	end)

	fw.it("says a spell again when another module asked for it on another unit", function()
		ClearGroups()
		sound:Clear()

		local said = Printed(function()
			Refusing(function()
				-- The route the alert and healer CC modules take. The personal aura below is the
				-- same spell on the player, which is the failure we would be chasing.
				auraSounds:RemoveSet(
					auraSounds:RegisterSet(nil, "party1", { [ICE_BLOCK] = true }, "Sonar.ogg", "Master"))

				sound:Apply({
					{
						GroupId = "gShared",
						Unit = "player",
						Trigger = "Applied",
						File = "Sonar",
						Channel = "Master",
						SpellIds = { ICE_BLOCK },
					},
				})
			end)
		end)

		sound:Clear()

		assert(#said == 2, "one message per unit, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find("party1", 1, true), "the first names the unit the set was for")
		assert(said[2]:find("player", 1, true), "and the second the player's own aura")
	end)

	fw.it("says the cap was hit as it goes over and not on the passes after", function()
		ClearGroups()
		sound:Clear()

		local requests = {
			{
				GroupId = "gCap",
				Unit = "player",
				Trigger = "Applied",
				File = "Sonar",
				Channel = "Master",
				SpellIds = SpellList(1600, 900100),
			},
		}

		local said = Printed(function()
			sound:Apply(requests)
			sound:Apply(requests)
		end)

		local stillTruncated = sound:WasTruncated()

		sound:Clear()

		assert(stillTruncated, "the second pass is still over the cap")
		assert(#said == 1, "the cap is reported once, got " .. #said .. ": " .. table.concat(said, " | "))
		-- One hundred, because the key holds 1600 ids and only 1500 of them fit.
		assert(said[1] == "Sound registration hit its limit of 1500. Group sounds still waiting: 100.",
			"and it carries the cap and how many ids were left waiting: " .. said[1])
	end)
end)

fw.describe("PersonalAuras - filters the sound cannot honour", function()
	-- A registration is (unit, spell id, file), so the caster narrowing that shapes the icons is
	-- not in it. The sounds tab says so rather than letting the group sound wrong quietly.
	fw.it("says so when the group only wants its own casts", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Caster = groups.Caster.Mine,
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		assert(groups:SoundIgnoresFilters(group), "the sound plays for anyone's cast")
	end)

	fw.it("says so for a flag the registration cannot carry either", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Candidates = { isFromPlayerOrPlayerPet = "REQUIRE" },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		assert(groups:SoundIgnoresFilters(group), "a flag is no more reachable than the caster")
	end)

	fw.it("stays quiet about a group whose filters the sound already matches", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		assert(not groups:SoundIgnoresFilters(group), "nothing narrows this one")
	end)

	fw.it("stays quiet about a silent group, however it filters", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Caster = groups.Caster.Mine,
		})

		assert(not groups:SoundIgnoresFilters(group), "there is no sound to be wrong")
	end)

	fw.it("stays quiet about a sound-only group, whose filters shape nothing", function()
		local group = groups:Normalise({
			Spells = { ICE_BLOCK },
			Caster = groups.Caster.Mine,
			Icons = { Display = groups.DisplayStyle.SoundOnly },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		assert(not groups:SoundIgnoresFilters(group), "there is no display for them to shape")
	end)

	fw.it("stays quiet about a group with no spells in it yet", function()
		local group = groups:Normalise({
			Caster = groups.Caster.Mine,
			Sound = { Applied = "Sonar", Channel = "Master" },
		})

		assert(not groups:SoundIgnoresFilters(group), "nothing is registered to sound wrong")
	end)
end)

fw.describe("PersonalAuras - sounds from media addons", function()
	-- A media addon registers its sounds whenever it happens to load, which is routinely after our
	-- first registration pass. The engine bakes the file into the registration, so resolving to the
	-- fallback then meant every configured sound played the default for the rest of the session.
	local PACK_SOUND = "SomePackSound"
	local PACK_PATH = "Interface/AddOns/SomePack/Whoosh.ogg"

	---Installs a LibSharedMedia stand-in holding exactly the sounds given.
	---@param registered table<string, string>
	local function InstallMedia(registered)
		_G.LibStub = function(name)
			if name ~= "LibSharedMedia-3.0" then
				return nil
			end

			return {
				Register = function(_, _, key, path)
					registered[key] = path
				end,
				IsValid = function(_, _, key)
					return registered[key] ~= nil
				end,
				Fetch = function(_, _, key)
					return registered[key]
				end,
				List = function()
					local list = {}
					for key in pairs(registered) do
						list[#list + 1] = key
					end
					return list
				end,
				RegisterCallback = function() end,
			}
		end
	end

	fw.it("stays silent until the sound exists, then registers the real file", function()
		ClearGroups()
		env.auraSoundAdds = 0

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		group.Sound.Applied = PACK_SOUND
		module:Refresh()

		assert(env.auraSoundAdds == 0,
			"a sound nothing can resolve registers nothing, rather than the fallback")

		-- The pack loads and registers its sounds. The next refresh must notice.
		local registered = { [PACK_SOUND] = PACK_PATH }

		InstallMedia(registered)
		module:Refresh()

		assert(env.auraSoundAdds > 0, "the registration lands once the sound is there")

		local last = env.auraSounds[env.auraSoundAdds]

		assert(last.File == PACK_PATH, "and carries the pack's own file, not the fallback")

		_G.LibStub = nil
		ClearGroups()
	end)
end)

fw.describe("PersonalAuras - cast recorder", function()
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

fw.describe("PersonalAuras - profile switching", function()
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
		local snapshot = db.Profiles.Migrated.Modules.PersonalAuras
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

fw.describe("PersonalAuras - bars", function()
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

	fw.it("defaults the pandemic reveal to red", function()
		local group = groups:Normalise({})
		local color = group.Icons.PandemicColor

		assert(color.R == 1 and color.G == 0.1 and color.B == 0.1, "red, not the old amber")
	end)

	fw.it("normalises the bar settings a group did not set", function()
		local group = groups:Normalise({ Icons = { Display = "BAR" } })

		assert(group.Icons.BarWidth > 0 and group.Icons.BarHeight > 0, "a width and a height")
		assert(group.Icons.BarTexture == groups.DefaultBarTexture,
			"the raid bar fill, matching the kick tracker's bars")
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

		-- Above the fill, or the outline only survives where it crosses the icon: a status bar is
		-- a child frame and draws over the regions of whatever it sits on.
		assert(slot.BorderOverlay:GetFrameLevel() > slot.Bar:GetFrameLevel(),
			"the border sits above the fill, so it rings the whole bar")

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

fw.describe("PersonalAuras - textures", function()
	-- One of the game's proc overlays, by the file id the catalog holds it under.
	local ART = 450930

	---A texture group with the art already chosen, since one without it draws nothing.
	---@param texture table?
	---@return PersonalAuraGroup
	local function AddTextureGroup(texture)
		texture = texture or {}
		texture.Asset = texture.Asset or ART

		return AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = "TEXTURE" },
			Texture = texture,
		})
	end

	fw.it("paints the chosen art onto the button and nothing else", function()
		ClearGroups()
		AddTextureGroup()
		module:Refresh()

		local button = ContainerFor("player")._groups.helpful.buttons[1]
		local art = button._createdTextures[1]

		assert(button._calls.SetIcon == nil, "no icon is registered with the engine")
		assert(button._calls.SetDurationCooldown == nil, "and no clock either")
		assert(art._lastArgs.SetTexture[1] == ART, "the picture the group chose")
		assert(art._lastArgs.SetBlendMode[1] == "ADD", "additive by default, as the art expects")
	end)

	fw.it("shows one picture however many auras match", function()
		ClearGroups()
		AddTextureGroup()
		module:Refresh()

		local container = ContainerFor("player")

		assert(Budget(container, "helpful") == 1, "one, not the icon cap")
		assert(Budget(container, "harmful") == 0, "and nothing on the wrong-sided group")
	end)

	fw.it("sizes the button from the art's own width and height", function()
		ClearGroups()
		AddTextureGroup({ Width = 120, Height = 90 })
		module:Refresh()

		local button = ContainerFor("player")._groups.helpful.buttons[1]

		assert(button:GetWidth() == 120, "the texture width sizes the button")
		assert(button:GetHeight() == 90, "and the texture height")
	end)

	fw.it("keeps art in its own pool", function()
		-- A button's shape is baked in when it is created, so a display built for icons could
		-- never be turned into one drawing art.
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local iconContainer = ContainerFor("player")

		ClearGroups()
		AddTextureGroup()
		module:Refresh()

		local textureContainer = ContainerFor("player")

		assert(textureContainer ~= iconContainer, "the parked icon display is not reused")
		assert(textureContainer._groups.helpful.buttons[1]._calls.SetIcon == nil, "it draws art")
	end)

	fw.it("draws nothing until a picture is chosen", function()
		ClearGroups()

		local group = AddTextureGroup({ Asset = "" })

		module:Refresh()

		assert(not groups:Supports(group), "a group still being built is not supported")
		assert(ContainerFor("player") == nil, "so nothing is tracking the player yet")

		group.Texture.Asset = ART
		module:Refresh()

		assert(Budget(ContainerFor("player"), "helpful") == 1, "and it starts once art is picked")
	end)

	fw.it("normalises the texture settings a group did not set", function()
		local group = groups:Normalise({ Icons = { Display = "TEXTURE" } })

		-- Not empty: picking the texture shape has to draw something, or there is nothing on
		-- screen to drag into place.
		assert(group.Texture.Asset ~= "", "a group starts on one of the shapes we ship")
		assert(artTextures:Label(group.Texture.Asset) ~= "", "and the picker knows it by name")
		assert(group.Texture.Width > 0 and group.Texture.Height > 0, "a width and a height")
		assert(group.Texture.Opacity == 100, "solid")
		assert(group.Texture.Additive, "additive unless it is turned off")

		local clamped = groups:Normalise({
			Icons = { Display = "TEXTURE" },
			Texture = { Width = 5000, Height = -3, Rotation = 900, Opacity = 500 },
		})

		assert(clamped.Texture.Width == groups.MaxTextureSize, "an absurd width is clamped")
		assert(clamped.Texture.Height == groups.MinTextureSize, "and a nonsense height floored")
		assert(clamped.Texture.Rotation == groups.MaxRotation, "the turn is capped")
		assert(clamped.Texture.Opacity == 100, "and so is the opacity")
	end)

	fw.it("shows the same picture in the stand-in as the live one draws", function()
		ClearGroups()

		local group = AddTextureGroup({ Rotation = 90, Mirror = true })

		group.Icons.Color.R, group.Icons.Color.G, group.Icons.Color.B = 0.2, 0.4, 0.8
		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local art = display:GetStates()[group.Id].Screen.Test.Art
		local color = art._lastArgs.SetVertexColor

		assert(art._lastArgs.SetTexture[1] == ART, "the group's own art")
		assert(color[1] == 0.2 and color[2] == 0.4 and color[3] == 0.8, "tinted like the live one")
		assert(#art._lastArgs.SetTexCoord == 8, "turned and mirrored through the corners")

		display:SetPreviewGroup(nil)
	end)
end)

fw.describe("PersonalAuras - the countdown numbers on an icon group", function()
	---@return table cooldown The clock the one drawn button was given.
	local function CooldownOnPlayer()
		local button = ContainerFor("player")._groups.helpful.buttons[1]

		return button._lastArgs.SetDurationCooldown[1]
	end

	fw.it("drops them on a group that turned them off", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK }, Icons = { EnableNumbers = false } })
		module:Refresh()

		assert(CooldownOnPlayer()._lastArgs.SetHideCountdownNumbers[1] == true,
			"the group asked for the countdown to go")
	end)

	fw.it("keeps them on a group that left the switch alone", function()
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		assert(CooldownOnPlayer()._lastArgs.SetHideCountdownNumbers[1] == false,
			"an untouched group counts down")
	end)
end)

fw.describe("PersonalAuras - text only", function()
	local TEXT_ONLY = groups.DisplayStyle.TextOnly

	---@return PersonalAuraGroup
	local function AddTextGroup()
		return AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = TEXT_ONLY },
		})
	end

	fw.it("registers a clock and no icon", function()
		ClearGroups()
		AddTextGroup()
		module:Refresh()

		local button = ContainerFor("player")._groups.helpful.buttons[1]

		assert(button._calls.SetIcon == nil, "no icon is registered with the engine")
		assert(button._calls.SetDurationCooldown == 1, "the clock still is, for its numbers")
	end)

	fw.it("draws the countdown with the swipe off", function()
		-- The group's own Hide swipe switch is off here, so the swipe going is the shape's doing.
		ClearGroups()

		local group = AddTextGroup()

		module:Refresh()

		assert(group.Icons.HideSwipe == false, "the group never asked for the swipe to go")

		local button = ContainerFor("player")._groups.helpful.buttons[1]
		local cooldown = button._lastArgs.SetDurationCooldown[1]

		assert(cooldown._lastArgs.SetDrawSwipe[1] == false, "the swipe is off all the same")
		assert(cooldown._lastArgs.SetHideCountdownNumbers[1] == false, "and the numbers are on")
	end)

	fw.it("keeps its countdown whatever is set to hide it", function()
		-- The countdown is the whole display here, so every switch that would drop it on an icon
		-- has to be ignored or the group shows nothing at all. The global one is the sharp case:
		-- there is nothing in the personal auras editor to explain a group blanked by it.
		ClearGroups()
		db.DisableNumbers = true
		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = TEXT_ONLY, EnableNumbers = false, CenterStacks = true },
		})
		module:Refresh()

		local button = ContainerFor("player")._groups.helpful.buttons[1]
		local cooldown = button._lastArgs.SetDurationCooldown[1]
		local hidden = cooldown._lastArgs.SetHideCountdownNumbers[1]

		-- Put back before the assert, so a failure here cannot leave the global set for the
		-- tests that follow.
		db.DisableNumbers = false

		assert(hidden == false, "the numbers are on despite all three")
	end)

	fw.it("leaves the stack count in its corner", function()
		-- Centring it is how an icon group trades the countdown for the count. With the countdown
		-- forced back on, a centred count would sit on top of it.
		ClearGroups()
		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = TEXT_ONLY, CenterStacks = true },
		})
		module:Refresh()

		local button = ContainerFor("player")._groups.helpful.buttons[1]
		local stacks = button._lastArgs.SetApplicationCount[1]

		assert(stacks._lastArgs.SetPoint[1] == "BOTTOMRIGHT", "the count stays out of the way")
	end)

	fw.it("keeps text-only displays in their own pool", function()
		-- What a button registers is baked in when it is created, so an icon display handed to a
		-- text-only group would draw art for the rest of the session.
		ClearGroups()
		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		local iconContainer = ContainerFor("player")

		ClearGroups()
		AddTextGroup()
		module:Refresh()

		local textContainer = ContainerFor("player")

		assert(textContainer ~= iconContainer, "the parked icon display is not reused")
		assert(textContainer._groups.helpful.buttons[1]._calls.SetIcon == nil, "it draws no art")
	end)

	fw.it("takes the shape from a saved group and leaves the others alone", function()
		local group = groups:Normalise({ Icons = { Display = TEXT_ONLY } })

		assert(group.Icons.Display == TEXT_ONLY, "an import asking for it keeps it")
		assert(groups:DrawsTextOnly(group), "and the shape question agrees")
		assert(groups:GetShape(group) == TEXT_ONLY, "so the pool key is its own")
		assert(groups:GetSize(group) == group.Icons.Size, "sized like the icons it replaces")
		assert(groups:GetBudget(group) == groups.MaxIcons, "and it shows as many of them")

		local saved = groups:Normalise({ Icons = { Size = 30 } })

		assert(saved.Icons.Display == groups.DisplayStyle.Icons, "a group saved before it is icons")
		assert(groups:Normalise({ Icons = { Display = "NONSENSE" } }).Icons.Display
			== groups.DisplayStyle.Icons, "and so is anything the engine never named")
	end)

	fw.it("draws its stand-ins without a swipe", function()
		ClearGroups()

		local group = AddTextGroup()

		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local cooldown = display:GetStates()[group.Id].Screen.Test.Slots[1].Container.Cooldown

		assert(cooldown._lastArgs.SetDrawSwipe[1] == false,
			"the stand-in matches the shape it is standing in for")

		display:SetPreviewGroup(nil)
	end)

	fw.it("keeps the countdown on its stand-ins too", function()
		ClearGroups()

		local group = AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = TEXT_ONLY, EnableNumbers = false, CenterStacks = true },
		})

		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local cooldown = display:GetStates()[group.Id].Screen.Test.Slots[1].Container.Cooldown

		assert(cooldown._lastArgs.SetHideCountdownNumbers[1] == false,
			"the stand-in shows what the live one will")

		display:SetPreviewGroup(nil)
	end)

	fw.it("keeps the countdown on its stand-ins with numbers off globally", function()
		-- The preview reads the global setting itself, so the live fix does not reach it. Without
		-- this the user most likely to want the shape sees an empty box while deciding on it.
		ClearGroups()
		db.DisableNumbers = true

		local group = AddTextGroup()

		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local cooldown = display:GetStates()[group.Id].Screen.Test.Slots[1].Container.Cooldown
		local hidden = cooldown._lastArgs.SetHideCountdownNumbers[1]

		display:SetPreviewGroup(nil)
		-- Put back before the assert, so a failure here cannot leave the global set for the
		-- tests that follow.
		db.DisableNumbers = false

		assert(hidden == false, "the stand-in shows the countdown the live one will")
	end)

	fw.it("draws its stand-ins with no art, at the size the group asks for", function()
		-- The slot is sized by the container, not by what is in it, so dropping the art leaves a
		-- full square to drag around rather than a collapsed one.
		ClearGroups()

		local group = AddTextGroup()

		module:Refresh()
		display:SetPreviewGroup(group.Id)

		local slot = display:GetStates()[group.Id].Screen.Test.Slots[1]
		local icon = slot.Container.Icon

		assert(icon._calls.SetTexture > 0, "the stand-in's art was written")
		assert(icon._lastArgs.SetTexture[1] == nil, "and what went in was nothing")
		assert(slot.Frame:GetWidth() == group.Icons.Size, "the slot still takes its whole square")
		assert(slot.Frame:GetHeight() == group.Icons.Size, "on both sides")

		display:SetPreviewGroup(nil)
	end)
end)

fw.describe("PersonalAuras - module gating", function()
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

fw.describe("PersonalAuras - sound only groups", function()
	local SOUND_ONLY = groups.DisplayStyle.SoundOnly

	fw.it("allows debuffs by spell id where a drawn group cannot have them", function()
		-- The engine drops the spell-id filter for a display on an assistable unit, but keys
		-- AddAuraSound on the bare id, so a group that draws nothing is free of the rule.
		assert(not groups:SupportsAuraType("unitframes", "HARMFUL", groups.TrackingMode.Spells),
			"a drawn group still cannot")
		assert(groups:SupportsAuraType("unitframes", "HARMFUL", groups.TrackingMode.Spells, true),
			"a sound only group can")
	end)

	fw.it("reports a sound only group with nothing to play", function()
		local group = groups:Normalise({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = SOUND_ONLY },
		})
		local supported, reason = groups:Supports(group)

		-- Quietly, with no message: a group still being built is not one configured wrongly.
		assert(not supported, "silent means nothing happens")
		assert(reason == nil, "and nothing is reported about it")

		group.Sound.Applied = "Sonar"

		assert(groups:Supports(group), "and a sound is all it needs")
	end)

	fw.it("registers its sounds without building a container", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()

		local before = env.auraSoundAdds

		AddGroup({
			Unit = "player",
			Spells = { ICE_BLOCK },
			Icons = { Display = SOUND_ONLY },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		assert(env.auraSoundAdds > before, "the sound is registered")
		assert(not ContainerFor("player"), "and nothing was built to draw it")
	end)

	fw.it("follows the roster rather than the frames it never hung off", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()
		env.friendlyUnits = { "player", "party1", "party2" }

		AddGroup({
			Unit = "unitframes",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Icons = { Display = SOUND_ONLY },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local seen = {}

		for _, entry in pairs(env.auraSounds) do
			seen[entry.Unit] = true
		end

		assert(seen.player and seen.party1 and seen.party2, "every group member is registered")

		env.friendlyUnits = {}
	end)

	fw.it("registers a target group on the token, not on the unit choice", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()

		AddGroup({
			Unit = "targetfriendly",
			Spells = { ICE_BLOCK },
			Icons = { Display = SOUND_ONLY },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local last = env.auraSounds[env.auraSoundAdds]

		assert(last.Unit == "target", "the unit the picker's name resolves to")
	end)
end)

fw.describe("PersonalAuras - sounds on units the picker renames", function()
	fw.it("registers a drawn target group on the token behind the choice", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()

		AddGroup({
			Unit = "targetfriendly",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local last = env.auraSounds[env.auraSoundAdds]

		assert(last and last.Unit == "target",
			"expected the resolved token, got " .. tostring(last and last.Unit))
	end)
end)

fw.describe("PersonalAuras - sound only ignores the aura type split", function()
	-- Every split in UNIT_INFO is there because the engine drops a spell-id filter for the
	-- display on the wrong side of the identity gate. A registration has no such side.
	local CASES = {
		{ Unit = "healer", Type = "HARMFUL", Why = "a debuff on the healer" },
		{ Unit = "targetfriendly", Type = "HARMFUL", Why = "a debuff on a friendly target" },
		{ Unit = "nameplateenemy", Type = "HELPFUL", Why = "a buff on an enemy plate" },
		{ Unit = "arenaframes", Type = "HELPFUL", Why = "a buff on an arena enemy" },
	}

	for _, case in ipairs(CASES) do
		fw.it("allows " .. case.Why, function()
			assert(not groups:SupportsAuraType(case.Unit, case.Type, groups.TrackingMode.Spells),
				"a drawn group still cannot")
			assert(groups:SupportsAuraType(case.Unit, case.Type, groups.TrackingMode.Spells, true),
				"a sound only group can")
		end)
	end
end)

fw.describe("PersonalAuras - sound only on the unit frames", function()
	fw.it("watches the player even with nobody else in the group", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()
		env.friendlyUnits = {}

		AddGroup({
			Unit = "unitframes",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Icons = { Display = groups.DisplayStyle.SoundOnly },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local seen = {}

		for _, entry in pairs(env.auraSounds) do
			seen[entry.Unit] = true
		end

		assert(seen.player, "your own frame is one of the unit frames")
	end)

	fw.it("does not register the player twice once there is a group", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()
		env.friendlyUnits = { "player", "party1" }

		local before = env.auraSoundAdds

		AddGroup({
			Unit = "unitframes",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Icons = { Display = groups.DisplayStyle.SoundOnly },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local playerAdds = 0

		for index = before + 1, env.auraSoundAdds do
			if env.auraSounds[index].Unit == "player" then
				playerAdds = playerAdds + 1
			end
		end

		-- One spell, one trigger, so the player is worth exactly one registration.
		assert(playerAdds == 1, "expected 1 registration on the player, got " .. playerAdds)

		env.friendlyUnits = {}
	end)
end)

fw.describe("PersonalAuras - sound only forces spell tracking", function()
	fw.it("puts a filter group back onto spells when it turns sound only", function()
		local group = groups:Normalise({
			Unit = "player",
			TrackingMode = groups.TrackingMode.Filters,
		})

		assert(group.TrackingMode == groups.TrackingMode.Filters, "a drawn group keeps filters")

		group.Icons.Display = groups.DisplayStyle.SoundOnly
		groups:Normalise(group)

		-- The engine registers a sound per spell id, so a filter group has nothing to hand it.
		assert(group.TrackingMode == groups.TrackingMode.Spells, "sound only tracks spells")
	end)

	fw.it("refuses an import that saved a sound only filter group", function()
		local group = groups:Normalise({
			Unit = "player",
			TrackingMode = "FILTERS",
			Icons = { Display = groups.DisplayStyle.SoundOnly },
		})

		assert(group.TrackingMode == groups.TrackingMode.Spells, "corrected on the way in")
	end)
end)

fw.describe("PersonalAuras - sound only respects the unit's side", function()
	local function TargetGroup()
		return AddGroup({
			Unit = "targetfriendly",
			Spells = { ICE_BLOCK },
			Icons = { Display = groups.DisplayStyle.SoundOnly },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
	end

	fw.it("registers a friendly target group while the target is friendly", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()
		env.enemies.target = nil

		local before = env.auraSoundAdds

		TargetGroup()
		module:Refresh()

		assert(env.auraSoundAdds > before, "the sound is registered")
	end)

	fw.it("drops it once the target is hostile", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()
		env.enemies.target = true

		local before = env.auraSoundAdds

		TargetGroup()
		module:Refresh()

		assert(env.auraSoundAdds == before,
			"a friendly target group has no business firing on a hostile one")

		env.enemies.target = nil
	end)

	fw.it("says nothing about a side it cannot show", function()
		local group = groups:Normalise({
			Unit = "targetfriendly",
			Spells = { ICE_BLOCK },
			Icons = { Display = groups.DisplayStyle.SoundOnly },
		})

		assert(groups:GetWarning(group) == nil, "the caveat is about icons, and there are none")

		group.Icons.Display = groups.DisplayStyle.Icons
		groups:Normalise(group)

		assert(groups:GetWarning(group) == "HELPFUL_FRIENDLY_ONLY", "a drawn group still says it")
	end)
end)

fw.describe("PersonalAuras - sound only follows the token's occupant", function()
	fw.it("registers a friendly target group when the friendly target arrives later", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()

		-- Built while the target is hostile, so the reaction test refuses it to begin with.
		env.enemies.target = true

		AddGroup({
			Unit = "targetfriendly",
			Spells = { ICE_BLOCK },
			Icons = { Display = groups.DisplayStyle.SoundOnly },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local before = env.auraSoundAdds

		-- Targeting a friendly is a unit change, not a refresh: nothing about the group moved,
		-- only who its token points at.
		env.enemies.target = nil
		display:OnUnitChanged("target")

		assert(env.auraSoundAdds > before, "the registration follows the new occupant")
		assert(env.auraSounds[env.auraSoundAdds].Unit == "target", "on the target token")
	end)

	fw.it("hands it back when the target turns hostile", function()
		local removes = env.auraSoundRemoves

		env.enemies.target = true
		display:OnUnitChanged("target")

		assert(env.auraSoundRemoves > removes, "the registration goes with the friendly target")

		env.enemies.target = nil
	end)
end)

fw.describe("PersonalAuras - a spell list that never reached the engine", function()
	fw.it("shows nothing rather than every aura on the unit", function()
		ClearGroups()

		local group = AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })

		module:Refresh()

		local container = assert(ContainerFor("player"), "the group is on screen to begin with")
		assert(Budget(container, "helpful") > 0, "and tracking its spell")

		-- Emptied in place, so the group's own signature is unchanged and nothing rebuilds it:
		-- this is the shape of any failure that leaves the id map from reaching the engine.
		local state = display:GetStates()[group.Id]
		wipe(state.Filters.includeSpellIDs)

		module:Refresh()

		-- Without the map the group is left with the bare HELPFUL token, which matches every
		-- buff the player has.
		assert(Budget(container, "helpful") == 0, "an unfiltered group is budgeted away")
	end)
end)

fw.describe("PersonalAuras - what a container is created holding", function()
	fw.it("never hands the engine an id map that matches everything", function()
		ClearGroups()

		AddGroup({ Unit = "player", Spells = { ICE_BLOCK } })
		module:Refresh()

		-- An empty includeSpellIDs reads as "no ids required", so a group created with one shows
		-- every aura on its unit from the moment it is shown until something re-parses it. Every
		-- group has to be born with an id map that cannot match.
		for _, frame in ipairs(acm.frames) do
			for key, group in pairs(frame._type == "AuraContainer" and frame._groups or {}) do
				local ids = group.options.candidateFilters
					and group.options.candidateFilters.includeSpellIDs

				assert(ids ~= nil, key .. " was created with no id map at all")
				assert(next(ids) ~= nil, key .. " was created with an id map matching everything")
			end
		end
	end)
end)

fw.describe("PersonalAuras - a drawn group's sound respects the unit's side", function()
	fw.it("does not sound a friendly target group on a hostile target", function()
		ClearGroups()
		addon.Modules.PersonalAuras.Sound:Clear()
		env.enemies.target = true

		local before = env.auraSoundAdds

		AddGroup({
			Unit = "targetfriendly",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		-- "target" is the same token whoever is in it, so without the gate the sound follows the
		-- token onto units the group was never pointed at.
		assert(env.auraSoundAdds == before, "no registration while the target is hostile")

		env.enemies.target = nil
		module:Refresh()

		assert(env.auraSoundAdds > before, "and one once a friendly target is there")
	end)
end)

fw.describe("PersonalAuras - coalescing the sound rebuild", function()
	fw.it("rebuilds once for a burst of nameplate churn", function()
		ClearGroups()
		AddGroup({
			Unit = "nameplate",
			AuraType = "HARMFUL",
			Spells = { POLYMORPH },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		-- The suite's C_Timer.After runs its callback on the spot, which would hide the
		-- coalescing entirely. This holds the callbacks so the burst can settle first.
		local queued = {}
		local realAfter = _G.C_Timer.After
		_G.C_Timer.After = function(_, callback)
			queued[#queued + 1] = callback
		end

		-- Counted rather than reading the queue length: the displays the plates build queue
		-- timers of their own, and those are nothing to do with the sounds.
		local rebuilds = 0
		local realRefreshSounds = display.RefreshSounds
		display.RefreshSounds = function(self)
			rebuilds = rebuilds + 1
			return realRefreshSounds(self)
		end

		for index = 1, 5 do
			local token = "nameplate" .. index

			env.addPlate(token)
			env.enemies[token] = true
			display:OnNamePlateAdded(token)
		end

		local before = env.auraSoundAdds

		for _, callback in ipairs(queued) do
			callback()
		end

		_G.C_Timer.After = realAfter
		display.RefreshSounds = realRefreshSounds

		assert(rebuilds == 1, "five plates rebuild the sounds once, not five times (got " .. rebuilds .. ")")
		assert(env.auraSoundAdds > before, "and that one rebuild registers the plates it collected")
	end)

	fw.it("drops a queued rebuild that a teardown has overtaken", function()
		-- A screen group, deliberately: its registration token comes from the unit choice rather
		-- than from copies, so parking it does not empty the request the way a plate group's does.
		-- On a plate group this would pass whether or not the guard is there.
		ClearGroups()
		env.enemies.target = nil
		AddGroup({
			Unit = "target",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local queued = {}
		local realAfter = _G.C_Timer.After
		_G.C_Timer.After = function(_, callback)
			queued[#queued + 1] = callback
		end

		display:OnUnitChanged("target")
		display:Teardown()

		local before = env.auraSoundAdds

		for _, callback in ipairs(queued) do
			callback()
		end

		_G.C_Timer.After = realAfter

		assert(env.auraSoundAdds == before,
			"the rebuild queued before the teardown must not re-register what it cleared")
	end)
end)

fw.describe("PersonalAuras - a teardown between the request and the rebuild", function()
	fw.it("still rebuilds for an event that arrives after the teardown", function()
		-- The stranded timer runs and refuses on the generation check. If the pending flag were
		-- left set, the request below would think a rebuild was already on its way and drop it,
		-- losing that event's sounds until the next plate or unit change.
		ClearGroups()
		env.enemies.target = nil
		AddGroup({
			Unit = "target",
			Spells = { ICE_BLOCK },
			Sound = { Applied = "Sonar", Channel = "Master" },
		})
		module:Refresh()

		local queued = {}
		local realAfter = _G.C_Timer.After
		_G.C_Timer.After = function(_, callback)
			queued[#queued + 1] = callback
		end

		-- Counted, not measured by registrations: the rebuild re-registers the same signature the
		-- refresh below already applied, so the engine-side count would not move either way.
		local rebuilds = 0
		local realRefreshSounds = display.RefreshSounds
		display.RefreshSounds = function(self)
			rebuilds = rebuilds + 1
			return realRefreshSounds(self)
		end

		display:OnUnitChanged("target")
		display:Teardown()

		-- Back on, and an event lands before the stranded timer has run.
		module:Refresh()
		display:OnUnitChanged("target")

		for _, callback in ipairs(queued) do
			callback()
		end

		_G.C_Timer.After = realAfter
		display.RefreshSounds = realRefreshSounds

		assert(rebuilds == 1,
			"the stranded timer refuses, but the request made after it must still rebuild (got "
			.. rebuilds .. ")")
	end)
end)

fw.describe("PersonalAuras - the group's icon on every aura", function()
	-- A file id rather than a path, since that is what the icon browser hands back.
	local GROUP_ICON = 556000

	---The texture on a button that was painted with the given picture, if there is one.
	---@param button table
	---@param asset string|number
	---@return table?
	local function PaintedWith(button, asset)
		for _, texture in ipairs(button._createdTextures) do
			local args = texture._lastArgs.SetTexture

			if args and args[1] == asset then
				return texture
			end
		end

		return nil
	end

	---@param overrides table?
	---@return PersonalAuraGroup
	local function AddIconGroup(overrides)
		overrides = overrides or {}
		overrides.Unit = "player"
		overrides.Spells = { ICE_BLOCK }

		return AddGroup(overrides)
	end

	---@return table
	local function PlayerButton()
		return ContainerFor("player")._groups.helpful.buttons[1]
	end

	fw.it("defaults to off and keeps the switch once it is set", function()
		assert(groups:Normalise({}).Icons.UseGroupIcon == false, "a bare group draws spell art")
		assert(groups:Normalise({ Icons = { UseGroupIcon = true } }).Icons.UseGroupIcon == true,
			"a group that asked for the group icon keeps it")
	end)

	fw.it("covers the spell art with the chosen icon", function()
		ClearGroups()
		AddIconGroup({ Icon = GROUP_ICON, Icons = { UseGroupIcon = true } })
		module:Refresh()

		local button = PlayerButton()
		local cover = PaintedWith(button, GROUP_ICON)

		assert(cover, "the group's icon is painted onto the button")
		assert(cover._shown, "and it is showing")
		assert(button._calls.SetIcon == 1, "the engine keeps its own icon region")
	end)

	fw.it("borrows the first spell's icon for a group that picked none", function()
		ClearGroups()
		AddIconGroup({ Icons = { UseGroupIcon = true } })
		module:Refresh()

		assert(PaintedWith(PlayerButton(), C_Spell.GetSpellTexture(ICE_BLOCK)),
			"an empty choice resolves the same way the options grid does")
	end)

	fw.it("puts the spell art back when the switch goes off", function()
		ClearGroups()

		local group = AddIconGroup({ Icon = GROUP_ICON, Icons = { UseGroupIcon = true } })

		module:Refresh()

		local button = PlayerButton()
		local cover = PaintedWith(button, GROUP_ICON)

		group.Icons.UseGroupIcon = false
		module:Refresh()

		assert(PlayerButton() == button, "the same button is still the live one")
		assert(cover._shown == false, "so the spell art is showing again")
	end)

	fw.it("leaves the text shape alone", function()
		ClearGroups()
		AddIconGroup({
			Icon = GROUP_ICON,
			Icons = { Display = groups.DisplayStyle.TextOnly, UseGroupIcon = true },
		})
		module:Refresh()

		assert(PaintedWith(PlayerButton(), GROUP_ICON) == nil, "the text shape draws no icon")
	end)
end)
