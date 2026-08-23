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
local BOSS_DEBUFF_GROUP = "FrameBossDebuffs"
local DEBUFF_GROUP = "FrameDebuffs"
local BUFF_GROUP_KEYS = { BUFF_PANDEMIC_GROUP, BUFF_GROUP }
local DEBUFF_GROUP_KEYS = { BOSS_DEBUFF_GROUP, DEBUFF_GROUP }
-- The categories the game flags never come into the buff row: what reaches the corner is decided
-- by the switches on its own page. The token is the coarse half of "only what you cast".
local BUFF_FILTER = "HELPFUL"
local BUFF_FILTER_MINE = "HELPFUL|PLAYER"
local DEBUFF_FILTER = "HARMFUL"
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

---The aura filter string the buff groups run under. The token is the coarse half of "mine": it and
---the candidate filter below are weighed separately, so an aura has to satisfy both.
---@return string
local function BuffFilter()
	local options = SideOptions("Buffs")

	return (options and options.Mine ~= false) and BUFF_FILTER_MINE or BUFF_FILTER
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

---@param side "Buffs"|"Debuffs"
---@return number
local function PerRow(side)
	local options = SideOptions(side)

	return tonumber(options and options.PerRow) or DEFAULT_PER_ROW
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

---One display's next group, from the walker. A display is created with none of them, so this is
---what puts its icons on screen.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	if display:AddNextGroup() and display:HasPendingGroups() then
		return sweep.Verdict.Unfinished
	end
end

---@param frame table
---@param unit string?
---@return AuraContainerDisplay
local function BuildBuffs(frame, unit)
	local pandemic, plain = BuffCandidates()
	local filter = BuffFilter()
	local maxIcons = MaxIcons("Buffs")

	return auraContainerDisplay:New(frame, unit or "none", {
		-- The spells that light up lead the row. Two groups because the reveal is registered on a
		-- button when it is built and driven by a window nothing can read, so which spells get one
		-- can only be decided by which group they land in.
		{ Key = BUFF_PANDEMIC_GROUP, FilterString = filter, MaxIcons = maxIcons, CandidateFilters = pandemic },
		{ Key = BUFF_GROUP, FilterString = filter, MaxIcons = maxIcons, CandidateFilters = plain },
	}, IconSize(frame, "Buffs"), ICON_SPACING, MASQUE_GROUP, {
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

---@param frame table
---@param unit string?
---@return AuraContainerDisplay
local function BuildDebuffs(frame, unit)
	local boss, priority = DebuffCandidates()
	local maxIcons = MaxIcons("Debuffs")

	local display = auraContainerDisplay:New(frame, unit or "none", {
		-- Declared boss first: groups render in the order they are declared, so its icons take the
		-- row before anything the priority group matched.
		{ Key = BOSS_DEBUFF_GROUP, FilterString = DEBUFF_FILTER, MaxIcons = maxIcons, CandidateFilters = boss },
		{ Key = DEBUFF_GROUP, FilterString = DEBUFF_FILTER, MaxIcons = maxIcons, CandidateFilters = priority },
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
	local nextSlot = testSpells:FillContainer(container, testSpells.FrameAuras[side], 1, {
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
		display:SetMaxIcons(key, MaxIcons(side))
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

		entry.Buffs:SetFilterString(BUFF_PANDEMIC_GROUP, filter)
		entry.Buffs:SetFilterString(BUFF_GROUP, filter)
		entry.Buffs:SetCandidateFilters(BUFF_PANDEMIC_GROUP, pandemic)
		entry.Buffs:SetCandidateFilters(BUFF_GROUP, plain)
	end

	if entry.Debuffs then
		ApplySide(entry.Debuffs, frame, "Debuffs", DEBUFF_GROUP_KEYS)

		local boss, priority = DebuffCandidates()

		-- The policy first: a group asking for a classification the display is not making matches
		-- nothing at all.
		entry.Debuffs:SetProcessingPolicy(ClassifiesDebuffs())
		entry.Debuffs:SetCandidateFilters(BOSS_DEBUFF_GROUP, boss)
		entry.Debuffs:SetCandidateFilters(DEBUFF_GROUP, priority)
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
	local unit = UnitFor(frame)

	-- Only the first pass is gated. Once a frame has displays they are kept and re-pointed.
	--
	-- Test mode lets a frame through with nobody on it, because the stand-ins name units the player
	-- does not have - but only one that is actually on screen. Without that second half a single
	-- test run leaves an entry behind for all forty spare raid frames, and every refresh after it
	-- builds them a display and its batch of buttons.
	if not entry and not HasUnit(unit)
		and not (testModeActive and frames:IsAnchorUsable(frame)) then
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

	if active.Buffs and not entry.Buffs then
		entry.Buffs = BuildBuffs(frame, entry.Unit)
		buildSweep:Append(entry.Buffs, DeclareNextGroup)
		entry.Generation = nil
	end

	if active.Debuffs and not entry.Debuffs then
		entry.Debuffs = BuildDebuffs(frame, entry.Unit)
		buildSweep:Append(entry.Debuffs, DeclareNextGroup)
		entry.Generation = nil
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
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" })

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
		OnUpdateVisible = function(frame)
			local entry = watchers[frame]

			if entry then
				ApplyEntry(entry)
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

		return
	end

	if rosterGate then
		rosterGate:SetActive(false)
	end

	for _, entry in pairs(watchers) do
		ApplyEntry(entry)
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
