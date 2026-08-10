---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local spellSearch = addon.Core.SpellSearch
local units = addon.Utils.Units

-- The shape of a custom aura group, shared by the display, the options page and the import path.
--
-- The rule the whole design turns on: 12.1 only honours includeSpellIDs for helpful auras on
-- assistable units and harmful auras on the rest. Everywhere else the engine drops the map
-- silently and the bare token matches every aura on the unit. Hence AuraType being explicit,
-- SupportsAuraType, and the display's zero-icon budget.
--
-- That rule covers SPELL ids only. A filter string and every other candidate filter are applied
-- whatever the unit's reaction, so a group tracking by filter is free of all of it: debuffs on
-- yourself are perfectly trackable that way, they just cannot be narrowed to a spell id. The one
-- exception is the caster filters: the engine cannot attribute casters on a unit outside the
-- player's visible world, and a check it cannot evaluate is skipped rather than failed, so the
-- group would show the aura from everyone. CanFilterUnit budgets those to zero.
--
-- Class and spec conditions are deliberately absent; profiles already switch on specialisation.

addon.Modules.CustomAuras = addon.Modules.CustomAuras or {}

-- Aura types, which are also the base of the container filter string.
local HELPFUL = "HELPFUL"
local HARMFUL = "HARMFUL"
-- What decides which auras a group sees: a list of spell ids, or a filter string built from the
-- engine's own components.
local BY_SPELLS = "SPELLS"
local BY_FILTERS = "FILTERS"
-- Anchor modes.
local SCREEN = "SCREEN"
local NAMEPLATE = "NAMEPLATE"
local FRAMES = "FRAMES"
local ARENA = "ARENA"

local DEFAULT_ICON_SIZE = 40
local DEFAULT_SPACING = 2
-- Where a new screen-anchored group lands, measured up from the centre of the screen.
local DEFAULT_POSITION_Y = 220
local MIN_ICON_SIZE = 10
local MAX_ICON_SIZE = 200
-- How many icons one group can ever show. Fixed rather than configurable: the engine only
-- builds a frame when there is an aura for it, so a high cap costs nothing until it is used,
-- and a group that hits forty of anything has bigger problems than its icon budget.
local MAX_ICONS = 40
-- Stand-ins are drawn while a group is being positioned. Three is enough to see which way it
-- grows without covering the screen for a filter group that could match anything.
local PREVIEW_ICONS = 3
-- Anything above this is a corrupt or hostile import rather than a configuration.
local MAX_SPELLS_PER_GROUP = 100

-- Filter string components a group can require or forbid, in the order the options page lists
-- them. Helpful and harmful are excluded: AuraType already carries that.
local FILTER_COMPONENTS = {
	"PLAYER", "RAID", "DISPELLABLE", "RAID_PLAYER_DISPELLABLE", "CANCELABLE",
	"CROWD_CONTROL", "IMPORTANT", "BIG_DEFENSIVE", "EXTERNAL_DEFENSIVE",
}
-- Candidate filters that are a plain boolean on the aura. Applied whatever the unit's reaction,
-- unlike the spell id map, though isFromPlayerOrPlayerPet still needs an attributable caster
-- (see CanFilterUnit).
local CANDIDATE_FLAGS = {
	"isFromPlayerOrPlayerPet", "isBossAura", "isStealable", "isPriorityAura", "canApplyAura",
}
-- A component or flag is off, required, or required to be absent.
local OFF = "OFF"
local REQUIRE = "REQUIRE"
local FORBID = "FORBID"
-- Who applied the aura, which is the |PLAYER component either way round.
local CASTER_ANY = "ANY"
local CASTER_MINE = "MINE"
local CASTER_OTHERS = "OTHERS"
-- Icon order within a group.
local SORT_OLDEST = "OLDEST"
local SORT_LONGEST = "LONGEST"
local SORT_SHORTEST = "SHORTEST"
-- The unit choices. Target and nameplates are split by reaction rather than left to a separate
-- setting, because the reaction decides which aura type is even possible: a buff group aimed at
-- a hostile target would sit there showing nothing with nothing on screen to explain why.
local SELF_UNIT = "player"
local PET_UNIT = "pet"
local TANK_UNIT = "tank"
local HEALER_UNIT = "healer"
local OTHER_DPS_UNIT = "otherdps"
local TARGET_FRIENDLY = "targetfriendly"
local TARGET_ENEMY = "targetenemy"
local NAMEPLATE_FRIENDLY = "nameplatefriendly"
local NAMEPLATE_ENEMY = "nameplateenemy"
local UNIT_FRAMES_UNIT = "unitframes"
local ARENA_FRAMES_UNIT = "arenaframes"

-- Token is the unit the container watches; Plates means one copy per matching nameplate instead,
-- Frames one copy per party or raid frame, and ArenaFrames one copy per arena enemy frame.
-- Friendly is the reaction the unit must have for the group to show at all, nil for either.
local UNIT_INFO = {
	[SELF_UNIT] = { Token = "player", Helpful = true, Harmful = true },
	[PET_UNIT] = { Token = "pet", Helpful = true, Harmful = true },
	-- Resolved per refresh rather than fixed: whoever is holding the role right now.
	[TANK_UNIT] = { Role = "TANK", Friendly = true, Helpful = true },
	[HEALER_UNIT] = { Role = "HEALER", Friendly = true, Helpful = true },
	[OTHER_DPS_UNIT] = { Role = "DAMAGER", SkipSelf = true, Friendly = true, Helpful = true },
	[TARGET_FRIENDLY] = { Token = "target", Friendly = true, Helpful = true },
	[TARGET_ENEMY] = { Token = "target", Friendly = false, Harmful = true },
	[NAMEPLATE_FRIENDLY] = { Plates = true, Friendly = true, Helpful = true },
	[NAMEPLATE_ENEMY] = { Plates = true, Friendly = false, Harmful = true },
	-- Group members are always assistable, so the harmful side is only reachable by filter.
	[UNIT_FRAMES_UNIT] = { Frames = true, Friendly = true, Helpful = true, Harmful = true },
	-- Arena enemies are never assistable, so a spell id filter is honoured on them and debuffs
	-- work in both tracking modes. Buffs are not offered: the engine would drop the id map.
	[ARENA_FRAMES_UNIT] = { ArenaFrames = true, Friendly = false, Harmful = true },
}

-- What a unit saved before the split becomes. Focus and the target's target are gone, so they
-- fall back to the target itself rather than quietly disabling the group.
local RENAMED_UNITS = {
	target = true,
	focus = true,
	targettarget = true,
	nameplate = true,
}
-- A sound file name when the group should stay silent.
local NO_SOUND = ""
-- The keys under group.Sound that hold a file, in the order the options page lists them. The
-- engine trigger each maps to lives in the sound module.
local SOUND_TRIGGERS = { "Applied", "Stacks", "Removed" }
-- Shown for a group with no icon of its own and nothing to borrow one from.
local FALLBACK_ICON = [[Interface\Icons\INV_Misc_QuestionMark]]
-- Resolved on first use, because the browser hands the same icon back as a number.
---@type number?
local fallbackFileId
-- Bare party and arena tokens are left out: they have no stable place on screen, and the frame
-- choices cover them by hanging a copy off each member's or opponent's frame instead.
local UNITS = {
	SELF_UNIT, PET_UNIT, TANK_UNIT, HEALER_UNIT, OTHER_DPS_UNIT, UNIT_FRAMES_UNIT,
	TARGET_FRIENDLY, TARGET_ENEMY, NAMEPLATE_FRIENDLY, NAMEPLATE_ENEMY, ARENA_FRAMES_UNIT,
}
-- Units that are always assistable, so a harmful group on them could never filter by spell id.
local ALWAYS_FRIENDLY = { [SELF_UNIT] = true, [PET_UNIT] = true, [UNIT_FRAMES_UNIT] = true }

-- What a profile starts with: the three self-buffs worth knowing the instant they land. Each
-- tracks one spell and leaves Icon empty, which borrows that spell's own icon. A Color tints
-- the border/glow after the spell's own art; without one the group keeps the default white.
local DEFAULT_GROUPS = {
	{ Name = "Precognition", SpellId = 377362, Sound = "ElectricalSpark" },
	{ Name = "Shroud", SpellId = 378464, Color = { R = 0.64, G = 0.21, B = 0.93 } },
	{ Name = "PI", SpellId = 10060, Sound = "BubblePop", Color = { R = 1, G = 0.82, B = 0 } },
}
-- Where they land: a row near the top of the screen, clear of the unit frames and cast bar.
local DEFAULT_ROW_Y = 300
local DEFAULT_ROW_SPACING = 50

---@class CustomAurasGroups
local M = {}

addon.Modules.CustomAuras.Groups = M

M.AuraType = { Helpful = HELPFUL, Harmful = HARMFUL }
M.Anchor = { Screen = SCREEN, Nameplate = NAMEPLATE, Frames = FRAMES, Arena = ARENA }
M.Units = UNITS
M.NoSound = NO_SOUND
M.SoundTriggers = SOUND_TRIGGERS
M.TrackingMode = { Spells = BY_SPELLS, Filters = BY_FILTERS }
M.FilterComponents = FILTER_COMPONENTS
M.CandidateFlags = CANDIDATE_FLAGS
M.FilterState = { Off = OFF, Require = REQUIRE, Forbid = FORBID }
M.Caster = { Any = CASTER_ANY, Mine = CASTER_MINE, Others = CASTER_OTHERS }
M.Sort = { Oldest = SORT_OLDEST, Longest = SORT_LONGEST, Shortest = SORT_SHORTEST }
M.MaxSpells = MAX_SPELLS_PER_GROUP
M.MaxIcons = MAX_ICONS
M.PreviewIcons = PREVIEW_ICONS
M.MinIconSize = MIN_ICON_SIZE
M.MaxIconSize = MAX_ICON_SIZE

---@param value any
---@param fallback number
---@param minimum number
---@param maximum number
---@return number
local function Clamped(value, fallback, minimum, maximum)
	return mini:ClampInt(value, minimum, maximum, fallback)
end

---The question mark means "no icon", so a spell added later still gets to supply one. Compares
---both forms: the browser deals in file IDs, the fallback is written as a path.
---@param icon string|number
---@return boolean
local function IsFallbackIcon(icon)
	if type(icon) == "string" then
		return icon:lower() == FALLBACK_ICON:lower()
	end

	if not fallbackFileId and GetFileIDFromPath then
		fallbackFileId = GetFileIDFromPath(FALLBACK_ICON)
	end

	return fallbackFileId ~= nil and icon == fallbackFileId
end

---Keeps only the keys the engine knows about, each off, required or forbidden. Anything else an
---import supplied is dropped rather than passed through to a validating setter.
---@param stored any
---@param keys string[]
---@return table<string, string>
local function TriState(stored, keys)
	local out = {}

	if type(stored) == "table" then
		for _, key in ipairs(keys) do
			local state = stored[key]

			if state == REQUIRE or state == FORBID then
				out[key] = state
			end
		end
	end

	return out
end

---A list of whole positive spell ids, deduplicated and capped.
---@param stored any
---@return number[]
local function SpellList(stored)
	local out = {}
	local seen = {}

	for _, spellId in ipairs(type(stored) == "table" and stored or {}) do
		spellId = tonumber(spellId)

		if spellId and spellId > 0 and spellId == math.floor(spellId) and not seen[spellId]
			and #out < MAX_SPELLS_PER_GROUP then
			seen[spellId] = true
			out[#out + 1] = spellId
		end
	end

	return out
end

---A fresh group with everything filled in, and the module's id counter advanced past it.
---@param options CustomAurasModuleOptions
---@param name string?
---@return CustomAuraGroup
function M:NewGroup(options, name)
	local id = options.NextId or 1
	options.NextId = id + 1

	return M:Normalise({
		Id = "g" .. id,
		Name = name,
	})
end

---Fills in what a group is missing and clamps what it got wrong, in place. Run on every group at
---load and on every import: the data is user-editable and an import string comes from a stranger.
---@param group table
---@return CustomAuraGroup
function M:Normalise(group)
	group.Id = tostring(group.Id or "g0")
	group.Name = tostring(group.Name or "")
	group.Enabled = group.Enabled ~= false
	-- Empty borrows the first tracked spell's icon. A file ID stays a NUMBER; SetTexture will
	-- not take the digits as a string.
	local icon = group.Icon
	group.Icon = (type(icon) == "number" or type(icon) == "string") and icon or ""

	if IsFallbackIcon(group.Icon) then
		group.Icon = ""
	end
	group.AuraType = group.AuraType == HARMFUL and HARMFUL or HELPFUL

	local unit = group.Unit ~= nil and tostring(group.Unit) or nil

	if RENAMED_UNITS[unit] then
		-- Saved before target and nameplates were split by reaction. Which side it becomes is
		-- the aura type it was already set to, so the group keeps showing what it showed.
		local harmful = group.AuraType == HARMFUL

		if unit == "nameplate" then
			unit = harmful and NAMEPLATE_ENEMY or NAMEPLATE_FRIENDLY
		else
			unit = harmful and TARGET_ENEMY or TARGET_FRIENDLY
		end
	end

	if not UNIT_INFO[unit] then
		unit = SELF_UNIT
	end

	local info = UNIT_INFO[unit]

	-- Anchor is derived, never chosen: it is the unit question asked twice.
	group.Unit = unit
	group.Anchor = info.Plates and NAMEPLATE or info.Frames and FRAMES
		or info.ArenaFrames and ARENA or SCREEN

	-- A split unit allows one aura type only, so a group pointed at one takes that type whatever
	-- it was set to. Nothing else could be shown there anyway.
	if not M:SupportsAuraType(unit, group.AuraType, group.TrackingMode) then
		group.AuraType = info.Harmful and HARMFUL or HELPFUL
	end

	-- Upper middle: dead centre is where the unit frames and cast bar already are.
	group.Position = group.Position or {}
	group.Position.Point = tostring(group.Position.Point or "CENTER")
	group.Position.RelativePoint = tostring(group.Position.RelativePoint or "CENTER")
	group.Position.X = tonumber(group.Position.X) or 0
	group.Position.Y = tonumber(group.Position.Y) or DEFAULT_POSITION_Y

	-- Groups that hang off a frame carry an offset rather than a screen point. Plates default to
	-- hanging above (the plate itself is the health bar); a unit frame or arena frame copy sits
	-- centred on the frame it decorates.
	group.Offset = group.Offset or {}
	group.Offset.X = tonumber(group.Offset.X) or 0
	group.Offset.Y = tonumber(group.Offset.Y) or ((info.Frames or info.ArenaFrames) and 0 or 40)

	group.Grow = addon.Core.GrowAnchors.Anchor[group.Grow] and group.Grow or "CENTER"

	local icons = group.Icons or {}
	group.Icons = icons
	icons.Size = Clamped(icons.Size, DEFAULT_ICON_SIZE, MIN_ICON_SIZE, MAX_ICON_SIZE)
	icons.Spacing = Clamped(icons.Spacing, DEFAULT_SPACING, 0, 50)
	icons.Glow = icons.Glow == true
	icons.Border = icons.Border == true
	icons.Pandemic = icons.Pandemic == true
	-- On unless it was turned off: the swipe filling up reads as time running out, which is what
	-- these icons are for. A group saved before this carries the field either way.
	icons.ReverseCooldown = icons.ReverseCooldown ~= false
	icons.ShowTooltips = icons.ShowTooltips == true
	icons.Color = icons.Color or {}
	icons.Color.R = tonumber(icons.Color.R) or 1
	icons.Color.G = tonumber(icons.Color.G) or 1
	icons.Color.B = tonumber(icons.Color.B) or 1
	icons.Color.A = tonumber(icons.Color.A) or 1
	-- Amber by default, matching the built-in ring tint.
	icons.PandemicColor = icons.PandemicColor or {}
	icons.PandemicColor.R = tonumber(icons.PandemicColor.R) or 1
	icons.PandemicColor.G = tonumber(icons.PandemicColor.G) or 0.6
	icons.PandemicColor.B = tonumber(icons.PandemicColor.B) or 0.1

	-- An empty file name is "no sound", which the picker offers as its first entry. One file per
	-- trigger, sharing a channel; File is what the single-sound version of this called Applied.
	local sound = group.Sound or {}
	group.Sound = sound
	sound.Applied = tostring(sound.Applied or sound.File or NO_SOUND)
	sound.Removed = tostring(sound.Removed or NO_SOUND)
	sound.Stacks = tostring(sound.Stacks or NO_SOUND)
	sound.File = nil
	sound.Channel = sound.Channel == "SFX" and "SFX" or "Master"

	group.TrackingMode = group.TrackingMode == BY_FILTERS and BY_FILTERS or BY_SPELLS
	group.Caster = (group.Caster == CASTER_MINE or group.Caster == CASTER_OTHERS)
		and group.Caster or CASTER_ANY
	group.Sort = (group.Sort == SORT_LONGEST or group.Sort == SORT_SHORTEST)
		and group.Sort or SORT_OLDEST

	-- Rebuilt rather than cleaned in place, so an import cannot smuggle in keys the engine would
	-- reject and a component Blizzard has since dropped falls out on its own.
	group.Filters = TriState(group.Filters, FILTER_COMPONENTS)
	group.Candidates = TriState(group.Candidates, CANDIDATE_FLAGS)

	-- In the order they were added, NOT sorted by id: the first one supplies the group's icon.
	group.Spells = SpellList(group.Spells)

	return group
end

---Adds the groups a profile starts with, once. The flag is what stops them coming back after
---they are deleted, and is also what gets them into a profile that predates them: an install
---updating from an older version has no flag, so it seeds on the next load like a fresh one.
---@param options CustomAurasModuleOptions
---@return boolean seeded True only on the run that created them.
function M:SeedDefaults(options)
	if options.SeededDefaults then
		return false
	end

	options.SeededDefaults = true

	-- Centred on the row: three groups sit at -50, 0 and 50.
	local first = -DEFAULT_ROW_SPACING * (#DEFAULT_GROUPS - 1) / 2

	for index, template in ipairs(DEFAULT_GROUPS) do
		local group = M:NewGroup(options, template.Name)

		group.Spells = { template.SpellId }
		group.Icons.Glow = true
		group.Icons.Border = true

		if template.Color then
			group.Icons.Color.R = template.Color.R
			group.Icons.Color.G = template.Color.G
			group.Icons.Color.B = template.Color.B
		end

		group.Sound.Applied = template.Sound or NO_SOUND
		group.Position.X = first + (index - 1) * DEFAULT_ROW_SPACING
		group.Position.Y = DEFAULT_ROW_Y

		options.Groups[#options.Groups + 1] = M:Normalise(group)
	end

	return true
end

---Copies a group, giving it a new id and a name that says what it came from. The copy lands
---next to the original in the list, which is where the eye expects it.
---@param options CustomAurasModuleOptions
---@param groupId string
---@param name string What to call the copy; the caller owns the wording.
---@return CustomAuraGroup? copy
function M:Duplicate(options, groupId, name)
	for index, group in ipairs(options.Groups) do
		if group.Id == groupId then
			local id = options.NextId or 1
			local copy = M:Normalise(CopyTable(group))

			options.NextId = id + 1
			copy.Id = "g" .. id
			copy.Name = name

			table.insert(options.Groups, index + 1, copy)

			return copy
		end
	end

	return nil
end

---Moves one group to another's position, for the drag-to-reorder in the options grid. Order is
---presentation only: nothing about what a group shows depends on where it sits in the list.
---@param options CustomAurasModuleOptions
---@param fromId string
---@param toId string
---@return boolean moved
function M:Move(options, fromId, toId)
	local from, to

	for index, group in ipairs(options.Groups) do
		if group.Id == fromId then
			from = index
		end

		if group.Id == toId then
			to = index
		end
	end

	if not from or not to or from == to then
		return false
	end

	table.insert(options.Groups, to, table.remove(options.Groups, from))

	return true
end

---The one the user picked, else the first spell added, else a question mark.
---@param group CustomAuraGroup
---@return string|number
function M:GetIcon(group)
	if group.Icon ~= "" then
		return group.Icon
	end

	local first = group.Spells[1]

	return (first and C_Spell.GetSpellTexture(first)) or FALLBACK_ICON
end

---True while a group narrows what it shows to a list of spell ids, which is the only setting
---the engine's assist rule applies to.
---@param group CustomAuraGroup
---@return boolean
function M:TracksSpells(group)
	return group.TrackingMode == BY_SPELLS
end

---The first group member holding a role, in roster order. FriendlyUnits leads with the player,
---so a healer choice finds you when you are the healer, while other dps deliberately does not.
---@param role string
---@param skipSelf boolean?
---@return string?
local function FirstWithRole(role, skipSelf)
	for _, unit in ipairs(units:FriendlyUnits()) do
		if UnitGroupRolesAssigned(unit) == role
			and not (skipSelf and UnitIsUnit(unit, "player")) then
			return unit
		end
	end

	return nil
end

---The real unit a group watches, or nil for one that lives on nameplates and for a role choice
---the group cannot fill. With two healers there is no better answer than a stable one, so the
---first in roster order wins.
---@param group CustomAuraGroup
---@return string?
function M:GetToken(group)
	local info = UNIT_INFO[group.Unit]

	if not info then
		return nil
	end

	if info.Role then
		return FirstWithRole(info.Role, info.SkipSelf)
	end

	return info.Token
end

---True for the choices that put a copy of the group on every matching nameplate.
---@param unit string
---@return boolean
function M:IsNameplateUnit(unit)
	local info = UNIT_INFO[unit]

	return info ~= nil and info.Plates == true
end

---True for the choices that put a copy of the group on every party or raid frame.
---@param unit string
---@return boolean
function M:IsFrameUnit(unit)
	local info = UNIT_INFO[unit]

	return info ~= nil and info.Frames == true
end

---True for the choices that put a copy of the group on every arena enemy frame.
---@param unit string
---@return boolean
function M:IsArenaFrameUnit(unit)
	local info = UNIT_INFO[unit]

	return info ~= nil and info.ArenaFrames == true
end

---Whether a live unit is on the side the group's choice names. Always true for a choice that
---does not name one. Uses the assist check rather than IsFriend, because the question is the
---same one the engine asks when it decides whether a spell id filter applies.
---@param unit string The group's unit choice.
---@param token string The live unit token.
---@return boolean
function M:MatchesReaction(unit, token)
	local info = UNIT_INFO[unit]

	if not info or info.Friendly == nil then
		return true
	end

	return units:CanAssist(token) == info.Friendly
end

---Which aura types a unit choice can carry. A split unit allows one; self and pet allow both,
---subject to the spell-id rule below.
---@param unit string
---@param auraType string
---@param trackingMode string?
---@return boolean
function M:SupportsAuraType(unit, auraType, trackingMode)
	local info = UNIT_INFO[unit]

	if not info then
		return false
	end

	if auraType == HARMFUL and not info.Harmful then
		return false
	end

	if auraType == HELPFUL and not info.Helpful then
		return false
	end

	if trackingMode == BY_FILTERS then
		return true
	end

	return not (ALWAYS_FRIENDLY[unit] and auraType == HARMFUL)
end

---Whether a group is in a state that can never show anything, and why. The options page says so
---rather than letting the display quietly budget it to zero.
---@param group CustomAuraGroup
---@return boolean supported
---@return string? reason Key the options page maps to a message.
function M:Supports(group)
	-- Nameplates and arena frames are excluded because neither is ever always-assistable, so the
	-- only anchors that can land here are the screen and the unit frames.
	if group.Anchor ~= NAMEPLATE and group.Anchor ~= ARENA
		and not M:SupportsAuraType(group.Unit, group.AuraType, group.TrackingMode) then
		return false, group.Anchor == FRAMES and "HARMFUL_ON_GROUP" or "HARMFUL_ON_FRIENDLY"
	end

	-- No reason given: the empty spell list says it already. A filter group has nothing it must
	-- carry, because the aura type alone is already a working filter string.
	if M:TracksSpells(group) and #group.Spells == 0 then
		return false
	end

	return true
end

---A caveat worth showing next to a group that is legal but will only show on some units.
---@param group CustomAuraGroup
---@return string? reason
function M:GetWarning(group)
	local info = UNIT_INFO[group.Unit]

	-- Only the split units have a reaction to wait for. Self and pet are always there, and
	-- whether they can carry the chosen aura type is a hard refusal rather than a caveat.
	-- A unit frame holds a group member and an arena frame an opponent, so neither side is
	-- something the user is waiting on.
	if not info or info.Friendly == nil or info.Frames or info.ArenaFrames then
		return nil
	end

	return info.Friendly and "HELPFUL_FRIENDLY_ONLY" or "HARMFUL_HOSTILE_ONLY"
end

---Whether the group's filters care who cast the aura: the caster choice, the PLAYER component,
---or the from-my-side flag.
---@param group CustomAuraGroup
---@return boolean
local function DependsOnCaster(group)
	if group.Caster ~= CASTER_ANY then
		return true
	end

	local flag = group.Candidates["isFromPlayerOrPlayerPet"]

	if flag == REQUIRE or flag == FORBID then
		return true
	end

	if M:TracksSpells(group) then
		return false
	end

	local component = group.Filters["PLAYER"]

	return component == REQUIRE or component == FORBID
end

---Whether the engine will honour this group's filters for the unit it is on right now. False
---means the display must budget it to zero, or the container matches auras the group excludes.
---@param group CustomAuraGroup
---@param unit string
---@return boolean
function M:CanFilterUnit(group, unit)
	if not unit or not UnitExists(unit) then
		return false
	end

	-- A unit choice that names a side only shows on that side, whichever way the group tracks.
	if not M:MatchesReaction(group.Unit, unit) then
		return false
	end

	-- Caster filters need the engine to attribute each aura's caster, which it cannot do for a
	-- group member outside the player's visible world (another instance or phase). A check it
	-- cannot evaluate is skipped rather than failed, so the group would show the aura from
	-- everyone; budget it to zero until the unit is back.
	if DependsOnCaster(group) and not units:IsVisible(unit) then
		return false
	end

	-- A filter string and the flag filters are honoured whatever the unit is, so there is nothing
	-- left to gate: the group shows on every unit it is pointed at.
	if not M:TracksSpells(group) then
		return true
	end

	local assistable = units:CanAssist(unit)

	if group.AuraType == HELPFUL then
		return assistable
	end

	return not assistable
end

---Every id a spell list covers, each expanded to the ids sharing its name, because the aura the
---game applies is often not the spellbook one.
---@param spells number[]
---@return table<number, boolean>?
local function ExpandSpells(spells)
	if #spells == 0 then
		return nil
	end

	local ids = {}

	for _, spellId in ipairs(spells) do
		for _, variant in ipairs(spellSearch:GetVariants(spellId)) do
			ids[variant] = true
		end
	end

	return ids
end

---The filter string the group's container parses auras with: the aura type, whoever the caster
---has to be, and whatever components the group requires or forbids.
---@param group CustomAuraGroup
---@return string
function M:BuildFilterString(group)
	local parts = { group.AuraType }

	if group.Caster == CASTER_MINE then
		parts[#parts + 1] = "PLAYER"
	elseif group.Caster == CASTER_OTHERS then
		parts[#parts + 1] = "!PLAYER"
	end

	if not M:TracksSpells(group) then
		for _, component in ipairs(FILTER_COMPONENTS) do
			local state = group.Filters[component]

			if state == REQUIRE then
				parts[#parts + 1] = component
			elseif state == FORBID then
				parts[#parts + 1] = "!" .. component
			end
		end
	end

	return table.concat(parts, "|")
end

---The candidate filters a group's container tracks with. Only the spell id maps are subject to
---the engine's assist rule; everything else here applies on any unit.
---Returns a fresh table each time, because the engine keeps the reference it is handed.
---@param group CustomAuraGroup
---@return table filters
function M:BuildFilters(group)
	local filters = {}

	if M:TracksSpells(group) then
		filters.includeSpellIDs = ExpandSpells(group.Spells)
	end

	for _, flag in ipairs(CANDIDATE_FLAGS) do
		local state = group.Candidates[flag]

		if state == REQUIRE then
			filters[flag] = true
		elseif state == FORBID then
			filters[flag] = false
		end
	end

	return filters
end

---The engine sort the group's icon order maps to.
---@param group CustomAuraGroup
---@return number method
---@return number direction
function M:GetSortMethod(group)
	if group.Sort == SORT_LONGEST then
		return AuraContainerSortMethod.ExpirationOnly, AuraContainerSortDirection.Reverse
	elseif group.Sort == SORT_SHORTEST then
		return AuraContainerSortMethod.ExpirationOnly, AuraContainerSortDirection.Normal
	end

	-- Aura instance ids only ever increase, so sorting on them is oldest first.
	return AuraContainerSortMethod.AuraInstanceIDOnly, AuraContainerSortDirection.Normal
end

---Changes whenever something the container was built from changes, so the display can tell a
---cosmetic edit from one that has to reach the engine.
---@param group CustomAuraGroup
---@return string
function M:GetFilterSignature(group)
	local parts = {
		-- The mode itself, not just what it produces. Switching between a spell list and a set
		-- of components that happen to build the same string still has to reach the engine,
		-- because only one of the two sends an includeSpellIDs map at all.
		group.TrackingMode,
		M:BuildFilterString(group),
		group.Sort,
		table.concat(group.Spells, ","),
	}

	for _, flag in ipairs(CANDIDATE_FLAGS) do
		parts[#parts + 1] = group.Candidates[flag] or ""
	end

	return table.concat(parts, "/")
end

---@class CustomAuraGroup
---@field Id string
---@field Name string
---@field Enabled boolean
---@field Icon string|number Texture or file ID for the options grid; empty borrows the first spell's icon.
---@field AuraType string "HELPFUL"|"HARMFUL"
---@field Anchor string "SCREEN"|"NAMEPLATE"|"FRAMES"|"ARENA", derived from Unit.
---@field Unit string A unit choice: a token, a role, or one copy per nameplate, unit frame or arena frame.
---@field Position { Point: string, RelativePoint: string, X: number, Y: number } Screen anchor only.
---@field Offset { X: number, Y: number } Nameplate, unit frame and arena frame anchors only.
---@field Grow string
---@field Icons { Size: number, Spacing: number, Glow: boolean, Border: boolean, Pandemic: boolean, PandemicColor: table, ReverseCooldown: boolean, ShowTooltips: boolean, Color: table }
---@field Sound { Applied: string, Removed: string, Stacks: string, Channel: string } Empty means silent.
---@field TrackingMode string "SPELLS" narrows to a spell list, "FILTERS" to a filter string.
---@field Filters table<string, string> Filter component to "REQUIRE"|"FORBID". Filter mode only.
---@field Candidates table<string, string> Aura flag to "REQUIRE"|"FORBID", applied in both modes.
---@field Caster string "ANY"|"MINE"|"OTHERS"
---@field Sort string "OLDEST"|"LONGEST"|"SHORTEST"
---@field Spells number[]
