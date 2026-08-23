---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local moduleUtil = addon.Utils.ModuleUtil
local wowEx = addon.Utils.WoWEx
local frames = addon.Core.Frames
local eventGate = addon.Core.EventGate
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local iconSlotContainer = addon.Core.IconSlotContainer
local pixels = addon.Core.Pixels
local sweep = addon.Core.Sweep
local testSpells = addon.Core.TestSpells
local spells = addon.Modules.FrameAuras.Spells

-- Stands in for Blizzard's own buff and debuff rows on the party and raid frames. Each side is a
-- display of its own, with its own switch, so replacing the debuffs does not also take the buffs.
--
-- Blizzard's frames only. Every other unit frame addon draws its own auras and has its own
-- settings for them, and the cvars below only reach the stock frames.

local BUFF_GROUP = "FrameBuffs"
local BUFF_PANDEMIC_GROUP = "FrameBuffsPandemic"
local DEBUFF_GROUP = "FrameDebuffs"
local BUFF_GROUP_KEYS = { BUFF_PANDEMIC_GROUP, BUFF_GROUP }
local DEBUFF_GROUP_KEYS = { DEBUFF_GROUP }
-- The categories the game flags never come into the buff row: what reaches the corner is decided
-- by the switches on its own page. The token is the coarse half of "only what you cast".
local BUFF_FILTER = "HELPFUL"
local BUFF_FILTER_MINE = "HELPFUL|PLAYER"
local DEBUFF_FILTER = "HARMFUL"
-- The flagged categories Important Auras draws its own row of. Kept out of these rows by negating
-- the game's own token, which is the only filter weighed on every unit: a spell-id map would be
-- skipped for a helpful aura on an enemy and for a harmful one on a friendly, and the frames this
-- draws on are exactly the friendly half.
local EXCLUDE_IMPORTANT = "|!IMPORTANT"
local EXCLUDE_DEFENSIVE = "|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE"
local EXCLUDE_CROWD_CONTROL = "|!CROWD_CONTROL"
-- What "under a minute" means to the engine: a bound on an aura's whole duration rather than on
-- what is left of it. Any value at all also drops the auras that never run out.
local SHORT_AURA_SECONDS = 60
-- Where each row sits. Fixed rather than a setting: these rows stand in for Blizzard's own, so a
-- corner is the frame's answer rather than the player's. The offsets hold the row far enough in
-- to clear the frame's own edge, and the grow wraps a second line upwards, away from the frame
-- below this one.
local PLACEMENT = {
	Buffs = { Point = "BOTTOMRIGHT", Grow = "LEFT_UP", OffsetX = -2, OffsetY = 2 },
	Debuffs = { Point = "BOTTOMLEFT", Grow = "RIGHT_UP", OffsetX = 2, OffsetY = 2 },
}
local ICON_SPACING = 1
-- How many frames' worth of rows to have ready before a group turns up. A party is five, which is
-- the size a solo player is most likely to become; past that the walker keeps up with the frames
-- appearing, because a raid fills in over several seconds anyway.
local PREWARM_FRAMES = 5
-- Icons take a share of the frame's height rather than a fixed size, because a raid profile and a
-- party profile size their frames very differently. This is what one falls back to when the client
-- will not say how tall the frame is.
local FALLBACK_ICON_SIZE = 14
-- The shipped budgets a profile written before a key existed falls back to. Spelled out rather
-- than read off the defaults table, which loads after the modules do.
local DEFAULT_MAX_ICONS = { Buffs = 6, Debuffs = 3 }
local DEFAULT_PER_ROW = 3
local DEFAULT_SIZE_PERCENT = 35
-- The Masque sub-group these rows are skinned under. One name for both sides: a player picking a
-- skin for the frame auras means the lot of them.
local MASQUE_GROUP = "Frame Auras"

-- Blizzard's own party and raid frame auras, switched off while this draws its own in their place.
local CVARS = { Buffs = "raidFramesDisplayBuffs", Debuffs = "raidFramesDisplayDebuffs" }
local CVAR_HIDDEN = "0"
-- What a side hands back when nothing was remembered: the value a fresh install has.
local CVAR_SHOWN = "1"
-- One dedupe key per side, so a toggle flipped twice in a fight only applies once.
local CVAR_WORK_KEY = "MiniAuras_FrameAurasCVar_"

local SIDES = { "Buffs", "Debuffs" }
-- Where each side's preview row is kept on an entry. The engine decides what an AuraContainer
-- shows, so a fake aura cannot be fed to one; the preview draws its own icons instead.
local TEST_FIELDS = { Buffs = "TestBuffs", Debuffs = "TestDebuffs" }

addon.Modules.FrameAuras = addon.Modules.FrameAuras or {}

---@class FrameAurasGroupAuras
local M = {}

addon.Modules.FrameAuras.GroupAuras = M

-- Whether each side is drawing right now.
local active = { Buffs = false, Debuffs = false }
local testModeActive = false
-- What each side last told the client about Blizzard's own row, so the cvar is only ever written
-- on the edge. Nil until the first refresh settles it, which is what keeps a side that was already
-- off at login from handing Blizzard's row back to a player who turned it off themselves.
local cvarState = { Buffs = nil, Debuffs = nil }
-- Bumped on every refresh. An entry stamped with the current one is already drawn to the current
-- settings, so a re-point can skip the geometry and only tell its displays who they are now.
local generation = 0
-- Unit frame -> its two displays. The frames are Blizzard's own and live for the session, so an
-- entry lives as long as they do; there is nothing to clear.
local watchers = {}
-- The filters the displays currently hold, one set between them all: the engine keeps the
-- reference it is handed, and handing the same one back costs nothing.
local pandemicCandidates
local plainCandidates
local bossDebuffCandidates
local plainDebuffCandidates
local eventsFrame
---@type EventGate?
local rosterGate
local hooked = false
-- Refilled per pass rather than built per pass: the frame list is asked for on every refresh, and
-- a raid is forty of them.
local frameScratch = {}
-- Refilled per call, for the same reason: the preview list is rebuilt per side per frame.
local testListScratch = {}
-- TEMPORARY build accounting, for working out where this module's start-up cost goes. Read with
-- /miniauras fa. Nothing reads these but the report; they exist to be printed.
local audit = {
	Built = 0,
	Spares = 0,
	Taken = 0,
	Buttons = 0,
	SkipHidden = 0,
	SkipUnknownUnit = 0,
	SkipEmpty = 0,
}
-- The first builds of a session, in order, so a reload can be read back afterwards.
local auditLog = {}
local AUDIT_LOG_MAX = 60
local auditStart = GetTime()
-- Spare displays built before any frame has asked for one, so a group forming does not have to
-- wait out the walker for its rows. Held on the screen until a frame takes one.
local spares = { Buffs = {}, Debuffs = {} }
-- The spare currently being finished, so its groups are declared one per turn like every other
-- build. Only ever one at a time: spares are the lowest-priority work the addon does.
local prewarmBuilding
local prewarmSweep = sweep:New(1)
-- Background walker declaring the aura groups of the displays as they are built. Urgent: these sit
-- on unit frames the player is looking at. The engine allocates a batch of buttons the moment a
-- group is declared, so a party converting to a raid would otherwise build eighty of them at once.
local buildSweep = sweep:New(1, true)

---@return FrameAurasModuleOptions?
local function Options()
	local db = mini:GetSavedVars()

	return db and db.Modules and db.Modules.FrameAurasModule or nil
end

---@param side "Buffs"|"Debuffs"
---@return table?
local function SideOptions(side)
	local options = Options()

	return options and options[side] or nil
end

---Blizzard's COMPACT party and raid member frames, and nothing else. Refilled in place.
---
---The standard party frames are deliberately left out. The two cvars below only reach the compact
---ones, so a row drawn on a standard frame would sit on top of Blizzard's own rather than in place
---of it, which is the one thing this module exists to avoid.
---@return table[]
local function BlizzardFrames()
	for index = #frameScratch, 1, -1 do
		frameScratch[index] = nil
	end

	-- DandersFrames replaces the compact frames outright, so there is nothing of Blizzard's left
	-- to stand in for. The same guard Core/Frames applies when it collects anchors.
	if wowEx:IsDandersEnabled() then
		return frameScratch
	end

	frames:BlizzardFrames(false, frameScratch)

	-- The stand-ins test mode puts up for a solo player. Without them a preview outside a group
	-- has nothing to draw on, because the client's own frames are all empty.
	if testModeActive then
		mini:Append(frames:GetTestFrames(), frameScratch)
	end

	return frameScratch
end

---The unit a frame is showing, or nil when the client will not say.
---@param frame table
---@return string?
local function UnitFor(frame)
	local unit = frame.unit or (frame.GetAttribute and frame:GetAttribute("unit"))

	if unit == nil or mini:IsSecret(unit) or type(unit) ~= "string" then
		return nil
	end

	return unit
end

---Whether a frame's unit is really there. All forty raid frames exist from the moment the client
---starts, most of them pointed at nobody, and a display for one of those is a batch of buttons the
---engine allocates for nothing. An unreadable answer counts as occupied: this is an optimisation,
---so it only ever skips a frame the client says outright is empty.
---@param unit string?
---@return boolean
local function HasUnit(unit)
	if not unit then
		return false
	end

	local exists = UnitExists(unit)

	-- The secret check leads: comparing a secret value is what aborts the whole handler.
	return mini:IsSecret(exists) or exists == true
end

---Whether a frame's unit is DEFINITELY there. The question HasUnit asks fails open, which is right
---for deciding whether to show a row that already exists and wrong for deciding whether to build
---one: building is a batch of buttons the engine allocates on the spot and can never free.
---
---This is what a reload with the module on used to cost. While a loading screen is up the client
---answers about units secretly, so every one of the forty raid frames and five party frames it
---pre-creates looked occupied, and each got two containers. Switching the module on later, with the
---world settled, built two - the same end state for a fraction of the work. A frame the client will
---not answer for yet is simply built later, by the refresh or the visibility hook that follows.
---@param unit string?
---@return boolean
local function HasUnitForSure(unit)
	if not unit then
		return false
	end

	local exists = UnitExists(unit)

	return not mini:IsSecret(exists) and exists == true
end

---The icon size for one side on one frame, as a share of the frame's own height.
---
---In the frame's OWN units, not screen pixels: the row scales with its host (see AnchorSide), so
---the size has to be measured in the same space the host is drawn in or the icons come out the
---wrong fraction of the frame at any UI scale but 1.
---@param frame table
---@param side "Buffs"|"Debuffs"
---@return number
local function IconSize(frame, side)
	local options = SideOptions(side)
	local percent = options and options.Size or DEFAULT_SIZE_PERCENT

	if not frame then
		return FALLBACK_ICON_SIZE
	end

	return pixels:ShareOfHeight(frame, percent, FALLBACK_ICON_SIZE)
end

---The engine's own answer to "can I dispel this", which it works out per aura from the player's
---spec. Asked for each time rather than kept: the aura data it comes from is not guaranteed to be
---there by the time this file loads.
---@return number?
local function DispelType()
	return AuraUtil and AuraUtil.AuraUpdateChangedType and AuraUtil.AuraUpdateChangedType.Dispel
end

---Blizzard's own raid frame debuff order, which is what ranks a group's own matches against each
---other. The engine has to do it: an aura's spell id is secret, so nothing can reorder a group
---once it has rendered.
---@return number?
local function DebuffSort()
	if not AuraContainerSortMethod then
		return nil
	end

	return AuraContainerSortMethod.UnitFrameDebuff or AuraContainerSortMethod.Default
end

---The aura filter string the buff groups run under. The "mine" token is the coarse half of that
---switch: it and the candidate filter are weighed separately, so an aura has to satisfy both.
---@return string
local function BuffFilter()
	local options = SideOptions("Buffs") or {}
	local filter = options.Mine ~= false and BUFF_FILTER_MINE or BUFF_FILTER

	if options.ShowImportant ~= true then
		filter = filter .. EXCLUDE_IMPORTANT
	end

	if options.ShowDefensives ~= true then
		filter = filter .. EXCLUDE_DEFENSIVE
	end

	return filter
end

---The aura filter string the debuff groups run under.
---@return string
local function DebuffFilter()
	local options = SideOptions("Debuffs") or {}

	if options.ShowCC == true then
		return DEBUFF_FILTER
	end

	return DEBUFF_FILTER .. EXCLUDE_CROWD_CONTROL
end

---The tracked ids as the engine wants them, built on first use and again after any refresh.
---@return table pandemic, table plain
local function BuffCandidates()
	if pandemicCandidates then
		return pandemicCandidates, plainCandidates
	end

	local pandemic, plain = spells:BuildSpellSets()
	local options = SideOptions("Buffs") or {}
	-- Absent rather than false when the filter is off: the booleans match an aura's field exactly,
	-- so false here would mean "only the ones somebody else cast".
	local mine = options.Mine ~= false or nil
	local maxDuration = options.ShortOnly == true and SHORT_AURA_SECONDS or nil
	local filtered = options.Filtered ~= false

	-- The glow group keeps its ids either way: which spells light up is fixed, so it is always the
	-- tracked ones that do.
	pandemicCandidates = {
		includeSpellIDs = pandemic,
		isFromPlayerOrPlayerPet = mine,
		maxDuration = maxDuration,
	}
	plainCandidates = {
		includeSpellIDs = filtered and plain or nil,
		-- Off the list, this group takes everything the glow group did not, or a spell that lights
		-- up would be drawn by both of them.
		excludeSpellIDs = not filtered and pandemic or nil,
		isFromPlayerOrPlayerPet = mine,
		maxDuration = maxDuration,
	}

	return pandemicCandidates, plainCandidates
end

---The debuff filters, built the same way and for the same reason.
---
---Encounter mechanics and role auras lead the row, and the debuffs the game itself flags as
---priority follow. Two groups because a candidate filter can only ever narrow: there is no flag
---meaning "boss or priority", and the booleans combine with AND like everything else. The boss flag
---partitions them, so an aura that is both is drawn once rather than twice, and each group carries
---its own budget. Everything the player set applies to both.
---@return table boss, table plain
local function DebuffCandidates()
	if bossDebuffCandidates then
		return bossDebuffCandidates, plainDebuffCandidates
	end

	local options = SideOptions("Debuffs") or {}
	local maxDuration = options.ShortOnly == true and SHORT_AURA_SECONDS or nil
	local dispellable = options.Dispellable == true and DispelType() or nil
	-- The priority list gives way to the dispel filter rather than stacking with it. Both only
	-- narrow, and a debuff you can take off is worth an icon whether the game calls it priority or
	-- not, so asking for both would only ever take icons away.
	local priority = nil

	if not dispellable then
		priority = true
	end

	bossDebuffCandidates = {
		isBossOrRoleAura = true,
		maxDuration = maxDuration,
		processedAuraType = dispellable,
	}
	plainDebuffCandidates = {
		isBossOrRoleAura = false,
		isPriorityAura = priority,
		maxDuration = maxDuration,
		processedAuraType = dispellable,
	}

	return bossDebuffCandidates, plainDebuffCandidates
end

---Whether the debuff displays have to classify each aura for the dispellable filter. Asking for a
---classification nothing reads is a pass per aura for nothing.
---@return boolean
local function ClassifiesDebuffs()
	local options = SideOptions("Debuffs")

	return options ~= nil and options.Dispellable == true and DispelType() ~= nil
end

---@param side "Buffs"|"Debuffs"
---@return number
local function MaxIcons(side)
	local options = SideOptions(side)

	return tonumber(options and options.MaxIcons) or DEFAULT_MAX_ICONS[side]
end

---The glow group's budget, which is not the row's. That group only ever matches spells that light
---up on refresh, and the engine allocates a group's buttons from the count it is declared with, so
---giving it the whole row's budget builds five buttons per frame that nothing can ever fill. One
---spell carries the reveal today, and a raid is forty frames.
---@return number
local function PandemicIcons()
	return math.min(MaxIcons("Buffs"), spells:PandemicCount())
end

---@param side "Buffs"|"Debuffs"
---@return number
local function PerRow(side)
	local options = SideOptions(side)

	return tonumber(options and options.PerRow) or DEFAULT_PER_ROW
end

---The spells one side's preview draws, leading with a stand-in for each flagged category the row
---is currently letting in. Switching crowd control on has to put a stun in the debuff row and
---switching it off has to take that stun back out, or the preview says nothing about what the
---switch does.
---@param side "Buffs"|"Debuffs"
---@return number[] Refilled scratch; the caller reads it before the next call.
local function TestSpellList(side)
	local options = SideOptions(side) or {}
	local set = testSpells.FrameAuras

	for index = #testListScratch, 1, -1 do
		testListScratch[index] = nil
	end

	if side == "Buffs" then
		if options.ShowImportant == true then
			testListScratch[#testListScratch + 1] = set.Important
		end

		if options.ShowDefensives == true then
			testListScratch[#testListScratch + 1] = set.Defensive
		end
	elseif options.ShowCC == true then
		testListScratch[#testListScratch + 1] = set.CrowdControl
	end

	for _, spellId in ipairs(set[side]) do
		testListScratch[#testListScratch + 1] = spellId
	end

	return testListScratch
end

---How many icons the preview draws: one row's worth, capped by the budget. A single row is enough
---to show where the icons land and how big they are, and reading BOTH sliders is what makes each
---of them visibly do something while test mode is up.
---@param side "Buffs"|"Debuffs"
---@return number
local function TestIconCount(side)
	return math.max(1, math.min(MaxIcons(side), PerRow(side)))
end

---@param side "Buffs"|"Debuffs"
---@return AuraDisplayStyle
local function BuildStyle(side)
	local options = SideOptions(side) or {}
	local style = auraContainerDisplay:BuildStandardStyle()

	style.Stacks = true
	style.ReverseCooldown = true

	if side == "Buffs" then
		style.Pandemic = options.PandemicGlow == true
		style.PandemicColor = moduleUtil:GetColorRGB(options.PandemicColor)
	end

	-- No dispel-type colouring on either row. These stand in for Blizzard's own, which draws a
	-- plain icon, and a ring around every debuff is a lot of colour on a frame that already carries
	-- the Important Auras row.
	return style
end

---How many buttons a display was declared with, which is what a container actually costs: the
---engine hands out a group's batch from the count it was born with. TEMPORARY, for the report.
---@param display AuraContainerDisplay
---@return number
local function ButtonsOn(display)
	local total = 0

	for _, group in ipairs(display.Groups) do
		total = total + (group.BornMaxIcons or group.MaxIcons or 0)
	end

	return total
end

---One display's next group, from the walker. A display is created with none of them, so this is
---what puts its icons on screen.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	if display:AddNextGroup() and display:HasPendingGroups() then
		return sweep.Verdict.Unfinished
	end
end

---@param frame table? The frame this row will sit on, which is what sizes it. Nil for a spare
---built before its frame is known; it takes the fallback size and is resized when it is taken.
---@param unit string?
---@param parent table? Defaults to the frame. A spare is built on the screen instead.
---@return AuraContainerDisplay
local function BuildBuffs(frame, unit, parent)
	local pandemic, plain = BuffCandidates()
	local filter = BuffFilter()
	local maxIcons = MaxIcons("Buffs")
	local groups = {}

	-- The spells that light up lead the row, in a group of their own: the reveal is registered on a
	-- button when it is built and driven by a window nothing can read, so which spells get one can
	-- only be decided by which group they land in.
	--
	-- Left out entirely when the reveal is off. A group is a batch of buttons the engine allocates
	-- on the spot, and one that can never match anything is that batch on every frame in the raid.
	if PandemicIcons() > 0 then
		groups[#groups + 1] =
			{ Key = BUFF_PANDEMIC_GROUP, FilterString = filter, MaxIcons = PandemicIcons(), CandidateFilters = pandemic }
	end

	groups[#groups + 1] = { Key = BUFF_GROUP, FilterString = filter, MaxIcons = maxIcons, CandidateFilters = plain }

	return auraContainerDisplay:New(parent or frame, unit or "none", groups, IconSize(frame, "Buffs"), ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle("Buffs"),
		MasqueGroup = MASQUE_GROUP,
		Pandemic = true,
		PerLine = PerRow("Buffs"),
		-- The groups are declared by the walker instead, one per turn: a raid turning up builds one
		-- of these per frame at once, and each group costs a batch of buttons the engine allocates
		-- on the spot. Icons appear within a second or two of the frames themselves.
		DeferGroups = true,
	})
end

---@param frame table? As BuildBuffs.
---@param unit string?
---@param parent table? Defaults to the frame.
---@return AuraContainerDisplay
local function BuildDebuffs(frame, unit, parent)
	local candidates = DebuffCandidates()
	local maxIcons = MaxIcons("Debuffs")
	local filter = DebuffFilter()

	local display = auraContainerDisplay:New(parent or frame, unit or "none", {
		{ Key = DEBUFF_GROUP, FilterString = filter, MaxIcons = maxIcons, CandidateFilters = candidates },
	}, IconSize(frame, "Debuffs"), ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle("Debuffs"),
		MasqueGroup = MASQUE_GROUP,
		PerLine = PerRow("Debuffs"),
		DeferGroups = true,
	})

	local sort = DebuffSort()

	if sort then
		for _, key in ipairs(DEBUFF_GROUP_KEYS) do
			display:SetSortMethod(key, sort)
		end
	end

	display:SetProcessingPolicy(ClassifiesDebuffs())

	return display
end

---Pins one side's row into its corner of the frame, and puts it over the frame's own artwork.
---Parented to the frame rather than the screen, so the row fades and hides with the unit frame the
---way Blizzard's own row did. A display ignores its parent's scale, so reparenting cannot change
---the size the icons were given.
---@param display AuraContainerDisplay
---@param frame table
---@param side "Buffs"|"Debuffs"
local function AnchorSide(display, frame, side)
	local place = PLACEMENT[side]
	local containerFrame = display.Frame

	display:SetGrow(place.Grow)

	-- Scales with the frame, unlike the free-standing displays elsewhere. These rows stand in for
	-- ones Blizzard drew as children of the frame, so they have to sit in the same coordinate space
	-- it does: at any UI scale but 1, a row that ignored it would take the wrong fraction of the
	-- frame and its corner inset would not line up with the frame's own edge.
	containerFrame:SetIgnoreParentScale(false)

	-- Buttons draw at the container's own level rather than one above it, so a container level with
	-- its host loses to the host's own artwork. The strata is left alone: the row is a child of the
	-- frame now, and raising it would lift the icons out of the band their host draws in.
	local hostLevel = pixels:Number(frame:GetFrameLevel())

	if hostLevel then
		containerFrame:SetFrameLevel(hostLevel + 1)
	end

	containerFrame:ClearAllPoints()
	containerFrame:SetPoint(place.Point, frame, place.Point, place.OffsetX, place.OffsetY)
end

---@param container IconSlotContainer?
local function ClearTestRow(container)
	if not container then
		return
	end

	container:ResetAllSlots()
	container.Frame:Hide()
end

---One side's preview row on one frame, built the first time test mode asks for it. A side the
---player never previews never builds one.
---@param entry FrameAurasEntry
---@param side "Buffs"|"Debuffs"
---@return IconSlotContainer
local function EnsureTestContainer(entry, side)
	local field = TEST_FIELDS[side]
	local container = entry[field]

	if not container then
		container = iconSlotContainer:New(
			entry.Frame,
			TestIconCount(side),
			IconSize(entry.Frame, side),
			ICON_SPACING,
			MASQUE_GROUP,
			nil,
			MASQUE_GROUP
		)
		entry[field] = container
	end

	return container
end

---Draws one side's preview, or clears it for a side that is switched off: a row nobody asked for
---draws nothing in play, so it previews nothing either.
---@param entry FrameAurasEntry
---@param side "Buffs"|"Debuffs"
local function ApplyTestSide(entry, side)
	local container = entry[TEST_FIELDS[side]]

	if not active[side] then
		ClearTestRow(container)

		return
	end

	container = EnsureTestContainer(entry, side)

	local frame = entry.Frame
	local place = PLACEMENT[side]
	local containerFrame = container.Frame
	local count = TestIconCount(side)

	container:SetIconSize(IconSize(frame, side))
	container:SetCount(count)

	local db = mini:GetSavedVars()
	local nextSlot = testSpells:FillContainer(container, TestSpellList(side), 1, {
		ReverseCooldown = true,
		Glow = false,
		FontScale = db and db.FontScale,
		Stagger = true,
		Count = count,
	})

	for slot = nextSlot, container.Count do
		container:SetSlotUnused(slot)
	end

	-- The same coordinate space and the same corner the live row takes, so the preview stands
	-- exactly where the icons will be.
	containerFrame:SetIgnoreParentScale(false)

	local hostLevel = pixels:Number(frame:GetFrameLevel())

	if hostLevel then
		containerFrame:SetFrameLevel(hostLevel + 1)
	end

	containerFrame:ClearAllPoints()
	containerFrame:SetPoint(place.Point, frame, place.Point, place.OffsetX, place.OffsetY)
	containerFrame:Show()
end

---@param entry FrameAurasEntry
local function ClearTestIcons(entry)
	for _, side in ipairs(SIDES) do
		ClearTestRow(entry[TEST_FIELDS[side]])
	end
end

---Pushes one side's settings at its display: geometry first, then what the groups may draw.
---@param display AuraContainerDisplay
---@param frame table
---@param side "Buffs"|"Debuffs"
---@param groupKeys string[]
local function ApplySide(display, frame, side, groupKeys)
	display:SetPerLine(PerRow(side))
	display:ApplyConfig(IconSize(frame, side), ICON_SPACING, BuildStyle(side))

	for _, key in ipairs(groupKeys) do
		if display:HasGroup(key) then
			display:SetMaxIcons(key, key == BUFF_PANDEMIC_GROUP and PandemicIcons() or MaxIcons(side))
		end
	end

	AnchorSide(display, frame, side)
end

---Everything that depends on the settings rather than on who is on the frame. Skipped for an entry
---already drawn to the current ones: a raid sorting itself re-points every frame it has, and
---re-anchoring forty displays for settings that have not moved is the bulk of that cost.
---@param entry FrameAurasEntry
local function ApplySettings(entry)
	if entry.Generation == generation then
		return
	end

	entry.Generation = generation

	local frame = entry.Frame

	if entry.Buffs then
		ApplySide(entry.Buffs, frame, "Buffs", BUFF_GROUP_KEYS)

		local pandemic, plain = BuffCandidates()
		local filter = BuffFilter()

		-- The glow group is only there when the reveal is on; a display built without it is not
		-- rebuilt when the switch flips, it simply has nothing to publish to.
		if entry.Buffs:HasGroup(BUFF_PANDEMIC_GROUP) then
			entry.Buffs:SetFilterString(BUFF_PANDEMIC_GROUP, filter)
			entry.Buffs:SetCandidateFilters(BUFF_PANDEMIC_GROUP, pandemic)
		end

		entry.Buffs:SetFilterString(BUFF_GROUP, filter)
		entry.Buffs:SetCandidateFilters(BUFF_GROUP, plain)
	end

	if entry.Debuffs then
		ApplySide(entry.Debuffs, frame, "Debuffs", DEBUFF_GROUP_KEYS)

		-- The policy first: a group asking for a classification the display is not making matches
		-- nothing at all.
		entry.Debuffs:SetProcessingPolicy(ClassifiesDebuffs())
		entry.Debuffs:SetFilterString(DEBUFF_GROUP, DebuffFilter())
		entry.Debuffs:SetCandidateFilters(DEBUFF_GROUP, DebuffCandidates())
	end
end

---@param entry FrameAurasEntry
local function ApplyEntry(entry)
	if entry.Buffs or entry.Debuffs then
		ApplySettings(entry)
	end

	-- The live rows go dark for the preview: nothing can put a fake aura in front of the engine,
	-- so the two would otherwise sit on top of each other.
	if testModeActive then
		if entry.Buffs then
			entry.Buffs:SetShown(false)
		end

		if entry.Debuffs then
			entry.Debuffs:SetShown(false)
		end

		for _, side in ipairs(SIDES) do
			ApplyTestSide(entry, side)
		end

		-- On whichever row is actually up. Captioning the buff row regardless leaves a debuffs-only
		-- preview with no caption, and puts one over a container that was just cleared.
		local captioned = (active.Buffs and entry.TestBuffs) or (active.Debuffs and entry.TestDebuffs)

		if captioned then
			moduleUtil:SetTestLabel(captioned.Frame, L["Frame Auras"])
		end

		return
	end

	ClearTestIcons(entry)

	-- Always, unlike the rest: who is on the frame is exactly what a re-point changes.
	local occupied = HasUnit(entry.Unit) and frames:IsAnchorUsable(entry.Frame)

	if entry.Buffs then
		entry.Buffs:SetShown(active.Buffs and occupied)
	end

	if entry.Debuffs then
		entry.Debuffs:SetShown(active.Debuffs and occupied)
	end
end

---How many rows one side still wants ready: the target, less the frames already carrying one and
---the spares already waiting. Entries count because a frame holding a row is doing the job a spare
---was held for.
---@param side "Buffs"|"Debuffs"
---@return number
local function SparesWanted(side)
	if not active[side] then
		return 0
	end

	local built = 0

	for _, entry in pairs(watchers) do
		if entry[side] then
			built = built + 1
		end
	end

	return PREWARM_FRAMES - built - #spares[side]
end

---What a side's rows are shaped like right now. A spare bakes its groups and their budgets in when
---it is built, and neither can be changed afterwards: the engine hands out a group's buttons from
---the count it was declared with, and a group that was never declared cannot be added to a display
---that has already been shown. So a spare built under different settings is not a spare, and one
---handed to a frame anyway would draw the wrong row for the rest of the session.
---@param side "Buffs"|"Debuffs"
---@return string
local function ShapeOf(side)
	if side == "Buffs" then
		return MaxIcons(side) .. ":" .. PandemicIcons()
	end

	return MaxIcons(side) .. ":0"
end

---Throws away the spares that no longer match what a frame would be given today.
local function DropStaleSpares()
	for _, side in ipairs(SIDES) do
		local pool = spares[side]
		local shape = ShapeOf(side)

		for index = #pool, 1, -1 do
			if pool[index].FrameAurasShape ~= shape then
				-- Nothing releases a display; it is simply never handed out. The engine cannot
				-- free a container or the buttons under it either way.
				pool[index]:SetShown(false)
				table.remove(pool, index)
			end
		end
	end
end

---A spare rehomed onto the frame that has just asked for one, or nil when none is waiting.
---
---The one re-parent a display ever sees. It is built on the screen because a frame it could hang
---off does not exist yet, and it lives on that frame from here.
---@param side "Buffs"|"Debuffs"
---@param frame table
---@param unit string?
---@return AuraContainerDisplay?
local function TakeSpare(side, frame, unit)
	local pool = spares[side]
	local display = pool[#pool]

	if not display then
		return nil
	end

	pool[#pool] = nil

	display.Frame:SetParent(frame)
	display:SetUnit(unit or "none")

	return display
end

---One spare, a group per turn. Everything is re-read at fire time: the walk runs over seconds, in
---which the side can be switched off and the frames it was being held for can turn up on their own.
---@param side "Buffs"|"Debuffs"
---@return SweepVerdict?
local function PrewarmNext(side)
	if prewarmBuilding then
		if prewarmBuilding.Display:AddNextGroup() and prewarmBuilding.Display:HasPendingGroups() then
			return sweep.Verdict.Unfinished
		end

		local pool = spares[prewarmBuilding.Side]
		pool[#pool + 1] = prewarmBuilding.Display
		prewarmBuilding = nil

		return
	end

	if SparesWanted(side) <= 0 then
		return
	end

	-- Sized off a real frame where there is one, so a spare taken later needs no resize: a restyle
	-- is refused outright while auras are secret, and one bound mid-fight would keep whatever size
	-- it was built with.
	local sample = BlizzardFrames()[1]
	local build = side == "Buffs" and BuildBuffs or BuildDebuffs

	local display = build(sample, nil, UIParent)

	audit.Spares = audit.Spares + 1
	audit.Buttons = audit.Buttons + ButtonsOn(display)
	-- Stamped with what it was built for, so a settings change can tell it apart from a spare a
	-- frame would actually want.
	display.FrameAurasShape = ShapeOf(side)

	prewarmBuilding = { Side = side, Display = display }

	return sweep.Verdict.Unfinished
end

---Tops the spares up, if the walker is not already at it. Cheap to call from any refresh: the
---queue is only ever as long as what is still wanted.
local function QueuePrewarm()
	for _, side in ipairs(SIDES) do
		for _ = 1, math.max(0, SparesWanted(side)) do
			prewarmSweep:Append(side, PrewarmNext)
		end
	end
end

---The entry for a frame, built the first time the frame is seen. A side switched on after the entry
---exists gets its display then; one switched off keeps it, because the engine can free neither a
---display nor the buttons under it.
---@param frame table
---@return FrameAurasEntry?
local function EnsureEntry(frame)
	if not frame or mini:IsSecret(frame) then
		return nil
	end

	local entry = watchers[frame]

	-- Only the first pass is gated. Once a frame has displays they are kept and re-pointed.
	--
	-- ON SCREEN as well as occupied. A hidden compact frame can still carry the unit it last held,
	-- and the client answers for that unit whether or not the frame is showing it, so a token on
	-- its own let fifteen frames through in a solo session: five party members and the spare raid
	-- frames behind them, each paying for two displays and their batch of buttons. A frame that
	-- turns up later is built by the visibility hook, which is what fires when one appears.
	--
	-- The cheap half leads, and only a frame with nothing built on it pays for the rest: while the
	-- world loads, Blizzard points every compact frame at a unit several times over and almost all
	-- of them are still hidden, so reading the token and asking the client about it for each was
	-- most of what this module cost during a login.
	if not entry and not frames:IsAnchorUsable(frame) then
		audit.SkipHidden = audit.SkipHidden + 1

		return nil
	end

	local unit = UnitFor(frame)

	-- Test mode is the same question with the occupancy half dropped, because the stand-ins name
	-- units the player does not have.
	if not entry and not (testModeActive or HasUnitForSure(unit)) then
		if unit and mini:IsSecret(UnitExists(unit)) then
			audit.SkipUnknownUnit = audit.SkipUnknownUnit + 1
		else
			audit.SkipEmpty = audit.SkipEmpty + 1
		end

		return nil
	end

	if not entry then
		entry = { Frame = frame, Unit = unit }
		watchers[frame] = entry
	elseif entry.Unit ~= unit then
		entry.Unit = unit

		-- SetUnit re-points and bounces, which is what makes the engine re-read a token whose
		-- occupant changed without the string itself doing so.
		if entry.Buffs then
			entry.Buffs:SetUnit(unit or "none")
		end

		if entry.Debuffs then
			entry.Debuffs:SetUnit(unit or "none")
		end
	end

	-- Nothing live is built for a preview: the display would be hidden the moment it existed, and
	-- the stand-ins name units it could never read. The refresh that ends test mode builds them.
	if testModeActive then
		return entry
	end

	for _, side in ipairs(SIDES) do
		if active[side] and not entry[side] then
			local display = TakeSpare(side, frame, entry.Unit)

			if display then
				audit.Taken = audit.Taken + 1
			else
				local build = side == "Buffs" and BuildBuffs or BuildDebuffs
				display = build(frame, entry.Unit)

				audit.Built = audit.Built + 1
				audit.Buttons = audit.Buttons + ButtonsOn(display)

				if #auditLog < AUDIT_LOG_MAX then
					auditLog[#auditLog + 1] = string.format("%.1fs %s %s %s",
						GetTime() - auditStart, side, tostring(frame:GetName()), tostring(entry.Unit))
				end
			end

			entry[side] = display

			-- Whatever it still owes goes on the urgent lane, ahead of the spares: a frame is
			-- holding it now. A spare taken mid-build may still owe some of its groups.
			if display:HasPendingGroups() then
				buildSweep:Append(display, DeclareNextGroup)
			end

			entry.Generation = nil
		end
	end

	return entry
end

---@param frame table
local function ApplyToFrame(frame)
	local entry = EnsureEntry(frame)

	if entry then
		ApplyEntry(entry)
	end
end

local function ApplyToAll()
	for _, frame in ipairs(BlizzardFrames()) do
		ApplyToFrame(frame)
	end
end

---@return boolean
local function AnySideActive()
	return active.Buffs or active.Debuffs
end

---Tells the client whether to draw its own row for one side, but only where the answer moved.
---
---Deferred past combat: flipping either cvar makes the client rebuild the raid frames, which it
---refuses to do mid-fight.
---@param side "Buffs"|"Debuffs"
---@param enabled boolean
local function ApplyCVar(side, enabled)
	if cvarState[side] == enabled then
		return
	end

	local wasSettled = cvarState[side] ~= nil

	cvarState[side] = enabled

	-- Nothing to hand back on the first pass of a side that is switched off: the player may have
	-- turned Blizzard's own row off themselves, and this has never touched it.
	if not enabled and not wasSettled then
		return
	end

	local name = CVARS[side]
	local value

	local db = mini:GetSavedVars()

	db.FrameAuraCVars = db.FrameAuraCVars or {}

	local remembered = db.FrameAuraCVars

	if enabled then
		-- Remembered before it is overwritten, and kept in the saved variables rather than in
		-- memory: the row is handed back on a switch the player may not flip for weeks, long past
		-- the reload that would forget what they had.
		--
		-- Only on a switch the player threw. At login the cvar already carries this module's own
		-- write from the last session, so reading it there would remember "off" and hand that back
		-- as though the player had chosen it.
		if wasSettled and not remembered[side] then
			remembered[side] = GetCVar(name) or CVAR_SHOWN
		end

		value = CVAR_HIDDEN
	else
		value = remembered[side] or CVAR_SHOWN
		remembered[side] = false
	end

	mini:RunWhenCombatEnds(function()
		SetCVar(name, value)
	end, CVAR_WORK_KEY .. side)
end

---The hooks and events that keep the rows on frames the client re-points, re-sorts and hides.
---None of them can be taken off again, so each gates itself on the module being switched on.
local function InstallHooks()
	if hooked then
		return
	end

	hooked = true

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", ApplyToAll)

	-- A frame passed over for having nobody on it gets no set-unit call of its own when someone
	-- turns up under a token it was already holding, so the roster is what says to look again.
	-- Gated rather than answered inside the handler: with both sides off there is nothing here to
	-- do, and a disabled module should not be paying for the dispatch.
	--
	-- The loading screen ending is in there because building needs a definite answer about who is
	-- on a frame (see HasUnitForSure), and the client gives none while one is up. This is the pass
	-- that builds what the world-entering pass had to skip.
	rosterGate = eventGate:New(eventsFrame, {
		"GROUP_ROSTER_UPDATE",
		"PLAYER_ENTERING_WORLD",
		"LOADING_SCREEN_DISABLED",
	})

	frames:InstallUnitFrameHooks(eventsFrame, {
		-- Blizzard re-points frames at units constantly while a raid sorts, and the token often
		-- comes back the same one with a different member behind it. Nothing about that reaches
		-- the display on its own, so every re-point is treated as a new unit.
		OnSetUnit = function(frame)
			if AnySideActive() then
				ApplyToFrame(frame)
			end
		end,
		-- A frame the client empties rather than hides still has to drop its rows.
		-- Builds as well as re-applies: the gate in EnsureEntry turns a frame away while it is
		-- hidden, so this is where one the client has just put up gets its rows.
		OnUpdateVisible = function(frame)
			if AnySideActive() or watchers[frame] then
				ApplyToFrame(frame)
			end
		end,
		OnSorted = function()
			if AnySideActive() then
				ApplyToAll()
			end
		end,
		OnVisibilityChanged = function()
			if AnySideActive() then
				ApplyToAll()
			end
		end,
	})
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value

	-- The stand-ins drop out of the frame list the moment this goes off, so the refresh that
	-- follows would never reach the rows drawn on them.
	if not value then
		for _, entry in pairs(watchers) do
			ClearTestIcons(entry)
		end
	end
end

---Re-reads the settings, then catches up every frame that already exists. They are created once and
---reused, so the hooks alone would leave the ones on screen without displays.
function M:Refresh()
	local options = Options()

	if not options then
		return
	end

	generation = generation + 1

	for _, side in ipairs(SIDES) do
		local enabled = options[side] ~= nil and options[side].Enabled == true

		active[side] = enabled
		ApplyCVar(side, enabled)
	end

	-- A spare is only a spare while it still matches what a frame would be given.
	DropStaleSpares()

	-- Dropped rather than rebuilt: the walk below asks for them, and a refresh that changes nothing
	-- about the tracked ids still has to hand the engine tables it will accept.
	pandemicCandidates = nil
	plainCandidates = nil
	bossDebuffCandidates = nil
	plainDebuffCandidates = nil

	if AnySideActive() then
		InstallHooks()
		rosterGate:SetActive(true)
		ApplyToAll()
		-- After the frames on screen have been served: a spare is only worth building for a frame
		-- that is not there yet, and ApplyToAll is what settles how many of those there are.
		QueuePrewarm()

		return
	end

	if rosterGate then
		rosterGate:SetActive(false)
	end

	for _, entry in pairs(watchers) do
		ApplyEntry(entry)
	end
end

---TEMPORARY. Prints what this module has built this session and what it passed over, plus what it
---sees on each of Blizzard's compact frames right now. For working out where the start-up cost
---goes; remove along with the audit counters once it has answered that.
function M:Report()
	local watched, withRows = 0, 0

	for _, entry in pairs(watchers) do
		watched = watched + 1

		if entry.Buffs or entry.Debuffs then
			withRows = withRows + 1
		end
	end

	mini:Notify(string.format(
		"FrameAuras: buffs=%s debuffs=%s | built %d, spares %d (%d taken), %d buttons",
		tostring(active.Buffs), tostring(active.Debuffs),
		audit.Built, audit.Spares, audit.Taken, audit.Buttons))
	mini:Notify(string.format(
		"  skipped: %d hidden, %d unreadable unit, %d empty | watchers %d (%d with rows), spares held %d/%d",
		audit.SkipHidden, audit.SkipUnknownUnit, audit.SkipEmpty,
		watched, withRows, #spares.Buffs, #spares.Debuffs))

	for _, frame in ipairs(BlizzardFrames()) do
		local unit = UnitFor(frame)
		local exists = unit and UnitExists(unit)
		local answer = unit and (mini:IsSecret(exists) and "secret" or tostring(exists == true)) or "-"

		mini:Notify(string.format("  %s visible=%s unit=%s exists=%s rows=%s",
			tostring(frame:GetName()), tostring(frame:IsVisible() == true),
			tostring(unit), answer, tostring(watchers[frame] ~= nil)))
	end

	for _, line in ipairs(auditLog) do
		mini:Notify("  built " .. line)
	end
end

---@class FrameAurasEntry
---@field Frame table
---@field Unit string?
---@field Buffs AuraContainerDisplay?
---@field Debuffs AuraContainerDisplay?
---@field TestBuffs IconSlotContainer? The preview row, built the first time test mode wants one.
---@field TestDebuffs IconSlotContainer?
---@field Generation number? Which refresh this entry was last drawn for.
