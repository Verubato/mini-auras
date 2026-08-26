---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local artTextures = addon.Core.ArtTextures
local spellSearch = addon.Core.SpellSearch
local sounds = addon.Core.Sounds
local units = addon.Utils.UnitUtil
local changeStamp = addon.Utils.ChangeStamp

-- The shape of a personal aura group, shared by the display, the options page and the import path.
--
-- 12.1 only honours includeSpellIDs for helpful auras on assistable units and harmful auras on the
-- rest. Everywhere else the engine drops the map silently and the bare token matches every aura on
-- the unit, which is why AuraType is explicit.
--
-- That rule covers spell ids only. A filter string and every other candidate filter are applied
-- whatever the unit's reaction, so a group tracking by filter is free of it. The exception is the
-- caster filters: the engine cannot attribute casters on a unit outside the player's visible
-- world, and a check it cannot evaluate is skipped rather than failed, so those are budgeted to
-- zero there.
--
-- Class and spec conditions are deliberately absent. Profiles already switch on specialisation.

addon.Modules.PersonalAuras = addon.Modules.PersonalAuras or {}

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

-- How a group draws its auras: square icons, or bars the engine drains. The choice is baked into a
-- container's buttons at creation, so the display pools the shapes separately.
--
-- Sound only has no container at all, just the group's sound registrations. The engine drops a
-- spell id filter for the display but honours it for AddAuraSound, which is what makes debuffs on
-- your own side trackable by id.
--
-- Art is one picture drawn while any tracked aura is up. Which aura is up is secret, so a picture
-- that changed per aura could not be picked anyway.
--
-- Text only is the icon shape with the art and the swipe left out, so all that is drawn is the
-- countdown. What a button registers is settled as it is built, so this is a shape of its own
-- rather than a switch on the icon one.
local AS_ICONS = "ICON"
local AS_BARS = "BAR"
local AS_SOUND = "SOUND"
local AS_TEXTURE = "TEXTURE"
local AS_TEXT = "TEXT"

local DEFAULT_ICON_SIZE = 40
local DEFAULT_SPACING = 2
-- Bars keep their own width and height. A row of text wants a fraction of an icon's height and
-- several times its width, so sharing one number would leave both shapes with the wrong range.
local DEFAULT_BAR_WIDTH = 150
local MIN_BAR_WIDTH = 40
local MAX_BAR_WIDTH = 250
local DEFAULT_BAR_HEIGHT = 20
local MIN_BAR_HEIGHT = 8
local MAX_BAR_HEIGHT = 50
-- Art keeps its own pair of sides for the same reason a bar does, and it is routinely far bigger
-- than any icon.
local DEFAULT_TEXTURE_SIZE = 64
local MIN_TEXTURE_SIZE = 8
local MAX_TEXTURE_SIZE = 400
local MAX_ROTATION = 359
-- Held as a percentage like every other whole-number setting, and the display divides it back down.
local DEFAULT_OPACITY = 100
-- The same fill the kick tracker's bars ship with, so the two look like one addon out of the box.
local DEFAULT_BAR_TEXTURE = "Blizzard Raid Bar"
-- Where a new screen-anchored group lands, measured up from the centre of the screen.
local DEFAULT_POSITION_Y = 220
local MIN_ICON_SIZE = 10
local MAX_ICON_SIZE = 200
-- Text is sized off the icon, so a group tunes it with a percentage rather than a point size. Held
-- as a whole number so it clamps like every other group value.
local DEFAULT_TEXT_SCALE = 100
local MIN_TEXT_SCALE = 50
local MAX_TEXT_SCALE = 200
-- How many icons one group can ever show. The engine only builds a frame when there is an aura for
-- it, so a high cap costs nothing until it is used.
local MAX_ICONS = 40
-- Stand-ins are drawn while a group is being positioned. Three is enough to see which way it
-- grows without covering the screen for a filter group that could match anything.
local PREVIEW_ICONS = 3
-- Anything above this is a corrupt or hostile import rather than a configuration.
local MAX_SPELLS_PER_GROUP = 100

-- Filter string components a group can require or forbid, in the order the options page lists
-- them. Helpful and harmful are excluded, since AuraType already carries that.
local FILTER_COMPONENTS = {
	"PLAYER", "RAID", "DISPELLABLE", "RAID_PLAYER_DISPELLABLE", "CANCELABLE",
	"CROWD_CONTROL", "IMPORTANT", "BIG_DEFENSIVE", "EXTERNAL_DEFENSIVE",
}
-- Candidate filters that are a plain boolean on the aura. Applied whatever the unit's reaction,
-- unlike the spell id map, though isFromPlayerOrPlayerPet still needs an attributable caster.
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
-- Which combat state lets a group on screen at all, sound only groups included. One table rather
-- than three named strings, because Normalise is already at Lua's 60-upvalue ceiling.
local SHOW_WHEN = { Always = "ALWAYS", InCombat = "INCOMBAT", OutOfCombat = "OUTOFCOMBAT" }
-- Icon order within a group.
local SORT_OLDEST = "OLDEST"
local SORT_LONGEST = "LONGEST"
local SORT_SHORTEST = "SHORTEST"
-- The unit choices. Target and nameplates are split by reaction because the reaction decides which
-- aura type is even possible, and a buff group aimed at a hostile target would show nothing with
-- nothing on screen to explain why.
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

-- Token is the unit the container watches. Plates means one copy per matching nameplate instead,
-- Frames one copy per party or raid frame, and ArenaFrames one copy per arena enemy frame.
-- Friendly is the reaction the unit must have for the group to show at all, nil for either.
local UNIT_INFO = {
	[SELF_UNIT] = { Token = "player", Helpful = true, Harmful = true },
	[PET_UNIT] = { Token = "pet", Helpful = true, Harmful = true },
	-- Resolved per refresh to whoever is holding the role right now.
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
	-- work in both tracking modes. Buffs are not offered because the engine would drop the id map.
	[ARENA_FRAMES_UNIT] = { ArenaFrames = true, Friendly = false, Harmful = true },
}

-- The layer a group draws in. Automatic takes whatever the frame it hangs off is using. TOOLTIP is
-- absent because a group drawn there would cover the tooltips its own icons put up.
local STRATA_AUTO = "AUTO"
local STRATA_OPTIONS = {
	STRATA_AUTO, "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG",
}
local STRATA_VALID = {}

for _, strata in ipairs(STRATA_OPTIONS) do
	STRATA_VALID[strata] = true
end

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
-- Which side the client says a spell lands on, kept for the session because the answer never
-- changes within one. Only decided answers go in, since an id asked about before its data has
-- loaded answers neither and caching that would hide its real side for the rest of the session.
---@type table<number, string>
local spellAuraTypes = {}
-- Bare party and arena tokens are left out. They have no stable place on screen, and the frame
-- choices cover them by hanging a copy off each member's or opponent's frame instead.
local UNITS = {
	SELF_UNIT, PET_UNIT, TANK_UNIT, HEALER_UNIT, OTHER_DPS_UNIT, UNIT_FRAMES_UNIT,
	TARGET_FRIENDLY, TARGET_ENEMY, NAMEPLATE_FRIENDLY, NAMEPLATE_ENEMY, ARENA_FRAMES_UNIT,
}
-- Units that are always assistable, so a harmful group on them could never filter by spell id.
local ALWAYS_FRIENDLY = { [SELF_UNIT] = true, [PET_UNIT] = true, [UNIT_FRAMES_UNIT] = true }

-- What a profile starts with: the self-buffs worth knowing the instant they land. Each tracks one
-- spell and leaves Icon empty, which borrows that spell's own icon. A Color tints the border and
-- glow after the spell's own art, and without one the group keeps the default white.
local DEFAULT_GROUPS = {
	{ Name = "Precog", SpellId = 377362, Sound = "ElectricalSpark" },
	{ Name = "Shroud", SpellId = 378464, Color = { R = 0.64, G = 0.21, B = 0.93 } },
}
-- Where they land: centred, just above the player frame, where the eye already is.
local DEFAULT_ROW_X = 0
local DEFAULT_ROW_Y = 80

-- What each group's filters were last built from.
local filterStamp = changeStamp:New()

---@class PersonalAurasGroups
local M = {}

addon.Modules.PersonalAuras.Groups = M

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
M.ShowWhen = SHOW_WHEN
M.StrataAuto = STRATA_AUTO
M.StrataOptions = STRATA_OPTIONS
M.MaxSpells = MAX_SPELLS_PER_GROUP
M.MaxIcons = MAX_ICONS
M.PreviewIcons = PREVIEW_ICONS
M.MinIconSize = MIN_ICON_SIZE
M.MaxIconSize = MAX_ICON_SIZE
M.MinTextScale = MIN_TEXT_SCALE
M.MaxTextScale = MAX_TEXT_SCALE
M.DisplayStyle = {
	Icons = AS_ICONS, Bars = AS_BARS, SoundOnly = AS_SOUND, Texture = AS_TEXTURE,
	TextOnly = AS_TEXT,
}
M.MinBarWidth = MIN_BAR_WIDTH
M.MaxBarWidth = MAX_BAR_WIDTH
M.MinBarHeight = MIN_BAR_HEIGHT
M.MaxBarHeight = MAX_BAR_HEIGHT
M.DefaultBarTexture = DEFAULT_BAR_TEXTURE
M.MinTextureSize = MIN_TEXTURE_SIZE
M.MaxTextureSize = MAX_TEXTURE_SIZE
M.MaxRotation = MAX_ROTATION

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

---What a texture group is allowed to hold as its art: a whole positive file id, a path, or the
---empty string where the browser was reset. A group that has never chosen starts on the shipped
---default, so picking the texture shape draws something rather than nothing.
---@param stored any
---@return string|number
local function ArtAsset(stored)
	local fileId = tonumber(stored)

	if type(stored) == "number" and fileId and fileId > 0 and fileId == math.floor(fileId) then
		return fileId
	end

	if type(stored) == "string" then
		return stored
	end

	return artTextures:DefaultAsset()
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
---@param options PersonalAurasModuleOptions
---@param name string?
---@return PersonalAuraGroup
function M:NewGroup(options, name)
	local id = options.NextId or 1
	options.NextId = id + 1

	return M:Normalise({
		Id = "g" .. id,
		Name = name,
	})
end

---Fills in what a group is missing and clamps what it got wrong, in place. Run on every group at
---load and on every import, since the data is user-editable and an import comes from a stranger.
---@param group table
---@return PersonalAuraGroup
function M:Normalise(group)
	group.Id = tostring(group.Id or "g0")
	group.Name = tostring(group.Name or "")
	group.Enabled = group.Enabled ~= false
	-- Empty borrows the first tracked spell's icon. A file id stays a number, because SetTexture
	-- will not take the digits as a string.
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

	-- Anchor is derived, never chosen. It is the unit question asked twice.
	group.Unit = unit
	group.Anchor = info.Plates and NAMEPLATE or info.Frames and FRAMES
		or info.ArenaFrames and ARENA or SCREEN

	-- A split unit allows one aura type only, so a group pointed at one takes that type whatever
	-- it was set to. Nothing else could be shown there anyway.
	if not M:SupportsAuraType(unit, group.AuraType, group.TrackingMode, M:IsSoundOnly(group)) then
		group.AuraType = info.Harmful and HARMFUL or HELPFUL
	end

	-- Upper middle: dead centre is where the unit frames and cast bar already are.
	group.Position = group.Position or {}
	group.Position.Point = tostring(group.Position.Point or "CENTER")
	group.Position.RelativePoint = tostring(group.Position.RelativePoint or "CENTER")
	group.Position.X = tonumber(group.Position.X) or 0
	group.Position.Y = tonumber(group.Position.Y) or DEFAULT_POSITION_Y

	-- Groups that hang off a frame carry an offset rather than a screen point. Plates default to
	-- hanging above, since the plate itself is the health bar. A unit frame or arena frame copy
	-- sits centred on the frame it decorates.
	group.Offset = group.Offset or {}
	group.Offset.X = tonumber(group.Offset.X) or 0
	group.Offset.Y = tonumber(group.Offset.Y) or ((info.Frames or info.ArenaFrames) and 0 or 40)

	group.Grow = addon.Core.GrowAnchors.Anchor[group.Grow] and group.Grow or "CENTER"
	group.Strata = STRATA_VALID[group.Strata] and group.Strata or STRATA_AUTO

	local icons = group.Icons or {}
	group.Icons = icons
	icons.Size = Clamped(icons.Size, DEFAULT_ICON_SIZE, MIN_ICON_SIZE, MAX_ICON_SIZE)
	icons.Spacing = Clamped(icons.Spacing, DEFAULT_SPACING, 0, 50)
	icons.TextScale = Clamped(icons.TextScale, DEFAULT_TEXT_SCALE, MIN_TEXT_SCALE, MAX_TEXT_SCALE)
	-- Icons unless the group asked for something else. A group saved before bars existed has no
	-- field, and changing what those groups look like is not something a version bump gets to do.
	icons.Display = (icons.Display == AS_BARS or icons.Display == AS_SOUND
		or icons.Display == AS_TEXTURE or icons.Display == AS_TEXT) and icons.Display or AS_ICONS
	icons.BarWidth = Clamped(icons.BarWidth, DEFAULT_BAR_WIDTH, MIN_BAR_WIDTH, MAX_BAR_WIDTH)
	icons.BarHeight = Clamped(icons.BarHeight, DEFAULT_BAR_HEIGHT, MIN_BAR_HEIGHT, MAX_BAR_HEIGHT)
	-- A name from a media addon that is no longer installed resolves back to the default at draw
	-- time, so it is kept rather than rewritten here.
	icons.BarTexture = type(icons.BarTexture) == "string" and icons.BarTexture
		or DEFAULT_BAR_TEXTURE
	-- The name is most of why a bar is wider than an icon, so it is on unless turned off.
	icons.SpellName = icons.SpellName ~= false
	icons.Glow = icons.Glow == true
	icons.Border = icons.Border == true
	icons.Pandemic = icons.Pandemic == true
	-- On unless it was turned off, since the swipe filling up reads as time running out.
	icons.ReverseCooldown = icons.ReverseCooldown ~= false
	-- Both off by default, since an aura icon without a clock is the unusual want.
	icons.HideSwipe = icons.HideSwipe == true
	icons.HideNumbers = icons.HideNumbers == true
	icons.CenterStacks = icons.CenterStacks == true
	-- Off keeps every text on its default colouring, the colour-by-time countdown included. On puts
	-- the group's own TextColor on all of it.
	icons.ColorText = icons.ColorText == true
	icons.ShowTooltips = icons.ShowTooltips == true
	icons.Color = icons.Color or {}
	icons.Color.R = tonumber(icons.Color.R) or 1
	icons.Color.G = tonumber(icons.Color.G) or 1
	icons.Color.B = tonumber(icons.Color.B) or 1
	icons.Color.A = tonumber(icons.Color.A) or 1
	-- Red by default, matching the built-in ring tint.
	icons.PandemicColor = icons.PandemicColor or {}
	icons.PandemicColor.R = tonumber(icons.PandemicColor.R) or 1
	icons.PandemicColor.G = tonumber(icons.PandemicColor.G) or 0.1
	icons.PandemicColor.B = tonumber(icons.PandemicColor.B) or 0.1
	-- White leaves the fonts as they come, so a group saved before the option keeps its look.
	icons.TextColor = icons.TextColor or {}
	icons.TextColor.R = tonumber(icons.TextColor.R) or 1
	icons.TextColor.G = tonumber(icons.TextColor.G) or 1
	icons.TextColor.B = tonumber(icons.TextColor.B) or 1

	-- The art a texture group draws, kept apart from the icon settings it has no use for. An empty
	-- path is a group still being built, so nothing is drawn and Supports says so.
	local texture = group.Texture or {}
	group.Texture = texture
	-- A file id from the browser, a path for something typed by hand, or empty for neither. A file
	-- id stays a number, because SetTexture will not take the digits as a string.
	texture.Asset = ArtAsset(texture.Asset)
	texture.Width = Clamped(texture.Width, DEFAULT_TEXTURE_SIZE, MIN_TEXTURE_SIZE, MAX_TEXTURE_SIZE)
	texture.Height = Clamped(texture.Height, DEFAULT_TEXTURE_SIZE, MIN_TEXTURE_SIZE, MAX_TEXTURE_SIZE)
	texture.Rotation = Clamped(texture.Rotation, 0, 0, MAX_ROTATION)
	texture.Opacity = Clamped(texture.Opacity, DEFAULT_OPACITY, 0, 100)
	texture.Mirror = texture.Mirror == true
	texture.Desaturate = texture.Desaturate == true
	-- On unless it was turned off, since the client's overlay art is drawn over a black background
	-- and reads as a black box without it.
	texture.Additive = texture.Additive ~= false

	-- An empty file name is "no sound", which the picker offers as its first entry. One file per
	-- trigger, sharing a channel, and File is the older single-sound key that became Applied.
	local sound = group.Sound or {}
	group.Sound = sound
	sound.Applied = tostring(sound.Applied or sound.File or NO_SOUND)
	sound.Removed = tostring(sound.Removed or NO_SOUND)
	sound.Stacks = tostring(sound.Stacks or NO_SOUND)
	sound.File = nil
	sound.Channel = sounds:NormaliseChannel(sound.Channel)

	-- A sound-only group tracks spells whatever it was set to. The engine registers a sound per
	-- spell id, so a filter group has nothing to hand it and could never make a noise. Enforced
	-- here so an import cannot save one either.
	group.TrackingMode = (group.TrackingMode == BY_FILTERS and not M:IsSoundOnly(group))
		and BY_FILTERS or BY_SPELLS
	group.Caster = (group.Caster == CASTER_MINE or group.Caster == CASTER_OTHERS)
		and group.Caster or CASTER_ANY
	group.Sort = (group.Sort == SORT_LONGEST or group.Sort == SORT_SHORTEST)
		and group.Sort or SORT_OLDEST
	group.ShowWhen = (group.ShowWhen == SHOW_WHEN.InCombat
		or group.ShowWhen == SHOW_WHEN.OutOfCombat) and group.ShowWhen or SHOW_WHEN.Always

	-- Rebuilt rather than cleaned in place, so an import cannot smuggle in keys the engine would
	-- reject and a component Blizzard has since dropped falls out on its own.
	group.Filters = TriState(group.Filters, FILTER_COMPONENTS)
	group.Candidates = TriState(group.Candidates, CANDIDATE_FLAGS)

	-- In the order they were added rather than sorted by id, since the first one supplies the
	-- group's icon.
	group.Spells = SpellList(group.Spells)

	return group
end

---Adds the groups a profile starts with, once. The flag is what stops them coming back after they
---are deleted, and an install updating from an older version has no flag, so it seeds on the next
---load like a fresh one.
---@param options PersonalAurasModuleOptions
---@return boolean seeded True only on the run that created them.
function M:SeedDefaults(options)
	if options.SeededDefaults then
		return false
	end

	options.SeededDefaults = true

	for _, template in ipairs(DEFAULT_GROUPS) do
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
		group.Position.X = DEFAULT_ROW_X
		group.Position.Y = DEFAULT_ROW_Y

		options.Groups[#options.Groups + 1] = M:Normalise(group)
	end

	return true
end

---Copies a group, giving it a new id and a name that says what it came from. The copy lands
---next to the original in the list, which is where the eye expects it.
---@param options PersonalAurasModuleOptions
---@param groupId string
---@param name string What to call the copy; the caller owns the wording.
---@return PersonalAuraGroup? copy
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
---presentation only, and nothing about what a group shows depends on where it sits in the list.
---@param options PersonalAurasModuleOptions
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
---@param group PersonalAuraGroup
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
---@param group PersonalAuraGroup
---@return boolean
function M:TracksSpells(group)
	return group.TrackingMode == BY_SPELLS
end

---True while a group draws bars rather than square icons.
---@param group PersonalAuraGroup
---@return boolean
function M:DrawsBars(group)
	return group.Icons.Display == AS_BARS
end

---True while a group draws one picture rather than icons or bars.
---@param group PersonalAuraGroup
---@return boolean
function M:DrawsTexture(group)
	return group.Icons.Display == AS_TEXTURE
end

---True while a group draws its countdown and nothing else.
---@param group PersonalAuraGroup
---@return boolean
function M:DrawsTextOnly(group)
	return group.Icons.Display == AS_TEXT
end

---Which shape a group draws, as one of the DisplayStyle values. A button's shape is baked in when
---it is created, so this is also the key the display pools its frames under.
---@param group PersonalAuraGroup
---@return string
function M:GetShape(group)
	local display = group.Icons and group.Icons.Display

	return (display == AS_BARS or display == AS_TEXTURE or display == AS_TEXT)
		and display or AS_ICONS
end

---How many auras a group can show at once. Art is one picture however many auras are up, so a
---second copy of it would say nothing the first does not.
---@param group PersonalAuraGroup
---@return number
function M:GetBudget(group)
	return M:DrawsTexture(group) and 1 or MAX_ICONS
end

---True while a group draws nothing and only plays its sounds. Nil-safe on the appearance table,
---because the unit sanitiser asks this before it has filled one in.
---@param group PersonalAuraGroup
---@return boolean
function M:IsSoundOnly(group)
	return group.Icons ~= nil and group.Icons.Display == AS_SOUND
end

---True while a group has at least one trigger set to something audible.
---@param group PersonalAuraGroup
---@return boolean
function M:HasSound(group)
	for _, trigger in ipairs(SOUND_TRIGGERS) do
		if group.Sound[trigger] ~= NO_SOUND then
			return true
		end
	end

	return false
end

---Whether the group's filters reach further than its sounds can. The engine plays a sound per
---(unit, spell id) with nothing in the registration to say who cast the aura, so a caster or
---flag narrowing shapes the display and is ignored by the sound.
---@param group PersonalAuraGroup
---@return boolean
function M:SoundIgnoresFilters(group)
	-- The same three things CollectSoundRequests asks before it registers anything. A group with
	-- no spells in it yet has no sound to be wrong about.
	if not M:HasSound(group) or not M:TracksSpells(group) or #group.Spells == 0 then
		return false
	end

	-- A sound-only group builds no container, so its filters shape nothing at all and there is
	-- no gap between what it shows and what it plays. Its filters tab is put away for the same
	-- reason.
	if M:IsSoundOnly(group) then
		return false
	end

	if group.Caster ~= CASTER_ANY then
		return true
	end

	for _, flag in ipairs(CANDIDATE_FLAGS) do
		local state = group.Candidates[flag]

		if state == REQUIRE or state == FORBID then
			return true
		end
	end

	return false
end

---The size a group's display is built at: a bar's height, a picture's height, or an icon's side.
---Every shape sizes what it holds (fonts, the bar's leading icon) from this one number.
---@param group PersonalAuraGroup
---@return number
function M:GetSize(group)
	if M:DrawsTexture(group) then
		return group.Texture.Height
	end

	return M:DrawsBars(group) and group.Icons.BarHeight or group.Icons.Size
end

---The layer a group's frames are pinned to, or nil to follow whatever they hang off.
---@param group PersonalAuraGroup
---@return string?
function M:GetStrata(group)
	return group.Strata ~= STRATA_AUTO and group.Strata or nil
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
---@param group PersonalAuraGroup
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

---Which aura types a unit choice can carry. A split unit allows one, and self and pet allow both,
---subject to the spell-id rule below.
---@param unit string
---@param auraType string
---@param trackingMode string?
---@param soundOnly boolean? True for a group that draws nothing, which lifts every rule below. The
---engine drops a spell-id filter for the display on the wrong side of the identity gate, while
---AddAuraSound keys on the bare spell id and honours it on any unit whatever its reaction.
---@return boolean
function M:SupportsAuraType(unit, auraType, trackingMode, soundOnly)
	local info = UNIT_INFO[unit]

	if not info then
		return false
	end

	if soundOnly then
		return true
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

---Which side a spell lands on. Asked of the client rather than looked up in the addon's own
---lists, so an id nobody here has ever heard of gets the same answer as a tracked one.
---@param spellId number
---@return string? HELPFUL or HARMFUL, nil when the client will not say.
function M:SpellAuraType(spellId)
	local cached = spellAuraTypes[spellId]

	if cached then
		return cached
	end

	-- Both arrived in 12.1, so an older client leaves every spell undecided rather than erroring.
	if not C_Spell.IsSpellHarmful or not C_Spell.IsSpellHelpful then
		return nil
	end

	local harmful = C_Spell.IsSpellHarmful(spellId)
	local helpful = C_Spell.IsSpellHelpful(spellId)

	-- Either both or neither. A dispel is aimed at whichever side needs it, and a spell the player
	-- cannot cast at all has no target to read a side off. Neither is something to warn about.
	if harmful == helpful then
		return nil
	end

	local auraType = harmful and HARMFUL or HELPFUL

	spellAuraTypes[spellId] = auraType

	return auraType
end

---Whether a tracked spell can ever match the group holding it. A container filters for helpful
---or harmful and nothing else, so a debuff in a buff group is invisible whatever unit it sits on.
---@param group PersonalAuraGroup
---@param spellId number
---@return boolean
function M:SpellFitsAuraType(group, spellId)
	-- A sound registration is (unit, spell id, sound file) with no filter string in it, so the
	-- aura type never enters into one. A filter group carries no spell ids to be wrong about.
	if M:IsSoundOnly(group) or not M:TracksSpells(group) then
		return true
	end

	local auraType = M:SpellAuraType(spellId)

	return auraType == nil or auraType == group.AuraType
end

---How many of a group's tracked spells are the opposite side to the one it filters for.
---@param group PersonalAuraGroup
---@return number
function M:CountWrongTypeSpells(group)
	local count = 0

	for _, spellId in ipairs(group.Spells) do
		if not M:SpellFitsAuraType(group, spellId) then
			count = count + 1
		end
	end

	return count
end

---Whether a group is in a state that can never show anything, and why. The options page says so
---rather than letting the display quietly budget it to zero.
---
---A spell on the wrong side is not a refusal. The client's answer is about what the spell can be
---cast at, which is a hair off what its aura counts as, so the group runs with a warning on it.
---@param group PersonalAuraGroup
---@return boolean supported
---@return string? reason Key the options page maps to a message.
function M:Supports(group)
	local soundOnly = M:IsSoundOnly(group)

	-- Nameplates and arena frames are excluded because neither is ever always-assistable, so the
	-- only anchors that can land here are the screen and the unit frames.
	if group.Anchor ~= NAMEPLATE and group.Anchor ~= ARENA
		and not M:SupportsAuraType(group.Unit, group.AuraType, group.TrackingMode, soundOnly) then
		return false, group.Anchor == FRAMES and "HARMFUL_ON_GROUP" or "HARMFUL_ON_FRIENDLY"
	end

	-- No reason given, since the empty spell list says it already. A filter group has nothing it
	-- must carry, because the aura type alone is already a working filter string.
	if M:TracksSpells(group) and #group.Spells == 0 then
		return false
	end

	-- Same again for a texture group with no picture chosen yet. It is a group still being built,
	-- and the empty swatch on the appearance tab already says so.
	if M:DrawsTexture(group) and group.Texture.Asset == "" then
		return false
	end

	-- A sound-only group is its sounds, and the engine plays those per spell id, so a filter group
	-- could never ask for one either. No reason given, like the empty spell list above.
	if soundOnly and not (M:TracksSpells(group) and M:HasSound(group)) then
		return false
	end

	return true
end

---Whether the player's combat state is one the group asked to show in. Separate from Supports
---because this answer changes minute to minute, where Supports is about how a group is configured.
---@param group PersonalAuraGroup
---@param inCombat boolean
---@return boolean
function M:ShowsInCombat(group, inCombat)
	if group.ShowWhen == SHOW_WHEN.InCombat then
		return inCombat
	elseif group.ShowWhen == SHOW_WHEN.OutOfCombat then
		return not inCombat
	end

	return true
end

---Whether any group is conditional on combat, which is what decides whether the module has to
---listen for the regen events at all.
---@param options PersonalAurasModuleOptions
---@return boolean
function M:AnyCombatConditional(options)
	for _, group in ipairs(options.Groups) do
		if group.ShowWhen == SHOW_WHEN.InCombat or group.ShowWhen == SHOW_WHEN.OutOfCombat then
			return true
		end
	end

	return false
end

---A caveat worth showing next to a group that is legal but will only show on some units.
---@param group PersonalAuraGroup
---@return string? reason
function M:GetWarning(group)
	local info = UNIT_INFO[group.Unit]

	-- Only the split units have a reaction to wait for. Self and pet are always there, and a unit
	-- frame holds a group member while an arena frame holds an opponent, so neither side is
	-- something the user is waiting on.
	if not info or info.Friendly == nil or info.Frames or info.ArenaFrames then
		return nil
	end

	-- Both of these are about what gets shown, and a sound-only group shows nothing.
	if M:IsSoundOnly(group) then
		return nil
	end

	return info.Friendly and "HELPFUL_FRIENDLY_ONLY" or "HARMFUL_HOSTILE_ONLY"
end

---Whether the group's filters care who cast the aura: the caster choice, the PLAYER component,
---or the from-my-side flag.
---@param group PersonalAuraGroup
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
---@param group PersonalAuraGroup
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
	-- group member outside the player's visible world. A check it cannot evaluate is skipped
	-- rather than failed, so the group would show the aura from everyone.
	if DependsOnCaster(group) and not units:IsVisible(unit) then
		return false
	end

	-- A filter string and the flag filters are honoured whatever the unit is, so the group shows on
	-- every unit it is pointed at.
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
---@param group PersonalAuraGroup
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
---the engine's assist rule, and everything else here applies on any unit.
---Returns a fresh table each time, because the engine keeps the reference it is handed.
---@param group PersonalAuraGroup
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
---@param group PersonalAuraGroup
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
---@param group PersonalAuraGroup
---@return number
function M:GetFilterGeneration(group)
	filterStamp:Begin(group.Id)
	-- The mode itself, not just what it produces. Switching between a spell list and a set of
	-- components that happen to build the same string still has to reach the engine, because only
	-- one of the two sends an includeSpellIDs map at all.
	filterStamp:Add(group.TrackingMode)
	filterStamp:Add(M:BuildFilterString(group))
	filterStamp:Add(group.Sort)

	local spells = group.Spells

	filterStamp:Add(#spells)

	for index = 1, #spells do
		filterStamp:Add(spells[index])
	end

	for _, flag in ipairs(CANDIDATE_FLAGS) do
		filterStamp:Add(group.Candidates[flag] or false)
	end

	return filterStamp:Commit()
end

---Drops what a deleted group's filters were last built from.
---@param groupId string
function M:ForgetFilterGeneration(groupId)
	filterStamp:Forget(groupId)
end

---@class PersonalAuraGroup
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
---@field Strata string "AUTO", or a frame strata the group's frames are pinned to.
---@field Icons { Size: number, Spacing: number, TextScale: number, Glow: boolean, Border: boolean, Pandemic: boolean, PandemicColor: table, ReverseCooldown: boolean, HideSwipe: boolean, HideNumbers: boolean, CenterStacks: boolean, ShowTooltips: boolean, Color: table, ColorText: boolean, TextColor: table, Display: string, BarWidth: number, BarHeight: number, BarTexture: string, SpellName: boolean }
---@field Texture { Asset: string|number, Width: number, Height: number, Rotation: number, Opacity: number, Mirror: boolean, Desaturate: boolean, Additive: boolean } Texture display only; Asset is a file id or a path, and empty draws nothing.
---@field Sound { Applied: string, Removed: string, Stacks: string, Channel: string } Empty means silent.
---@field TrackingMode string "SPELLS" narrows to a spell list, "FILTERS" to a filter string.
---@field Filters table<string, string> Filter component to "REQUIRE"|"FORBID". Filter mode only.
---@field Candidates table<string, string> Aura flag to "REQUIRE"|"FORBID", applied in both modes.
---@field Caster string "ANY"|"MINE"|"OTHERS"
---@field Sort string "OLDEST"|"LONGEST"|"SHORTEST"
---@field ShowWhen string "ALWAYS"|"INCOMBAT"|"OUTOFCOMBAT"
---@field Spells number[]
