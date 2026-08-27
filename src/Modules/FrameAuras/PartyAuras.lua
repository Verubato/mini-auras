---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local moduleUtil = addon.Utils.ModuleUtil
local wowEx = addon.Utils.WoWEx
local units = addon.Utils.UnitUtil
local frames = addon.Core.Frames
local growAnchors = addon.Core.GrowAnchors
local eventGate = addon.Core.EventGate
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local iconSlotContainer = addon.Core.IconSlotContainer
local pixels = addon.Core.Pixels
local sweep = addon.Core.Sweep
local testSpells = addon.Core.TestSpells
local unitStatePoller = addon.Core.UnitStatePoller
local spells = addon.Modules.FrameAuras.Spells

-- Stands in for Blizzard's own buff and debuff rows on the party and raid frames. Each side is a
-- display of its own, with its own switch.
--
-- Blizzard's frames only. Every other unit frame addon draws its own auras, and the cvars below
-- only reach the stock frames.

local BUFF_GROUP = "FrameBuffs"
local BUFF_PANDEMIC_GROUP = "FrameBuffsPandemic"
local DEBUFF_GROUP = "FrameDebuffs"
local DEBUFF_CROWD_CONTROL_GROUP = "FrameDebuffsCrowdControl"
local DEBUFF_PRIORITY_GROUP = "FrameDebuffsPriority"
local BUFF_GROUP_KEYS = { BUFF_PANDEMIC_GROUP, BUFF_GROUP }
local DEBUFF_GROUP_KEYS = { DEBUFF_CROWD_CONTROL_GROUP, DEBUFF_PRIORITY_GROUP, DEBUFF_GROUP }
local BUFF_FILTER = "HELPFUL"
local BUFF_FILTER_MINE = "HELPFUL|PLAYER"
local DEBUFF_FILTER = "HARMFUL"
-- The flagged categories Important Auras draws its own row of. Kept out by negating the game's own
-- token, which is the only filter weighed on every unit. A spell-id map would be skipped for a
-- helpful aura on an enemy and for a harmful one on a friendly, and these frames are the friendly
-- half.
local EXCLUDE_IMPORTANT = "|!IMPORTANT"
local EXCLUDE_DEFENSIVE = "|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE"
local EXCLUDE_CROWD_CONTROL = "|!CROWD_CONTROL"
-- The debuff row's parts. Everything behind the crowd control group negates that token, so no aura
-- lands in two of them.
local DEBUFF_PLAIN_FILTER = DEBUFF_FILTER .. EXCLUDE_CROWD_CONTROL
local DEBUFF_CROWD_CONTROL_FILTER = DEBUFF_FILTER .. "|CROWD_CONTROL"
-- Identical to the plain string. What tells the two groups apart is in DebuffCandidates.
local DEBUFF_PRIORITY_FILTER = DEBUFF_PLAIN_FILTER
-- Where each part sits in the row. Spelled out because the crowd control group is declared after
-- the others when the player switches it on mid-session, and the engine falls back to the order
-- groups were declared in.
local DEBUFF_CROWD_CONTROL_INDEX = 1
local DEBUFF_PRIORITY_INDEX = 2
local DEBUFF_PLAIN_INDEX = 3
-- What the front of the debuff row is drawn at, as a share of the rest of it. A stun or a priority
-- debuff on a party member is worth more than the debuff beside it.
local LEAD_SIZE_SCALE = 1.25
-- The most icons the head of the row holds. Its own cap rather than the row's, because two stuns
-- at once on one member is already unusual.
local MAX_CROWD_CONTROL_ICONS = 2
-- The same cap on the priority debuffs behind them, and for the same reason. Two of those at once
-- on one member is as unusual as two stuns.
local MAX_PRIORITY_ICONS = 2
-- What "under a minute" means to the engine: a bound on an aura's whole duration rather than on
-- what is left of it. Any value at all also drops the auras that never run out.
local SHORT_AURA_SECONDS = 60
-- Where each row sits. The offsets hold the row far enough in to clear the frame's own edge, and
-- the grow wraps a second line upwards, away from the frame below this one.
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
local DEFAULT_MAX_ICONS = { Buffs = 6, Debuffs = 2 }
local DEFAULT_PER_ROW = 3
local DEFAULT_SIZE_PERCENT = 35
-- An icon sized off a party frame is about eighteen pixels, where the shared ratio leaves a count
-- of six points.
local STACK_COEFFICIENT = 0.4
-- The Masque sub-group these rows are skinned under. One name for both sides, since a player
-- picking a skin for the frame auras means the lot of them.
local MASQUE_GROUP = "Frame Auras"

-- Blizzard's own party and raid frame auras, switched off while this draws its own in their place.
local CVARS = { Buffs = "raidFramesDisplayBuffs", Debuffs = "raidFramesDisplayDebuffs" }
local CVAR_HIDDEN = "0"
-- What a side hands back, whatever the player had before.
local CVAR_SHOWN = "1"
-- One dedupe key per side, so a toggle flipped twice in a fight only applies once.
local CVAR_WORK_KEY = "MiniAuras_FrameAurasCVar_"

-- Stands in for the generation on an entry drawn behind a loading screen. A string, so it can never
-- match the counter and the pass after the screen always draws the entry again.
local LOADING_GENERATION = "loading"

local SIDES = { "Buffs", "Debuffs" }
-- Where each side's preview row is kept on an entry. The engine decides what an AuraContainer
-- shows, so a fake aura cannot be fed to one and the preview draws its own icons instead.
local TEST_FIELDS = { Buffs = "TestBuffs", Debuffs = "TestDebuffs" }

addon.Modules.FrameAuras = addon.Modules.FrameAuras or {}

---@class FrameAurasPartyAuras
local M = {}

addon.Modules.FrameAuras.PartyAuras = M

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
-- Unit frame -> its two displays. The frames are Blizzard's own and live for the session, so there
-- is nothing to clear.
local watchers = {}
-- The filters the displays currently hold, one set between them all. The engine keeps the
-- reference it is handed, and handing the same one back costs nothing.
local pandemicCandidates
local plainCandidates
local debuffCandidates
local priorityDebuffCandidates
local plainDebuffCandidates
-- Whether the debuff sets have been worked out yet. Its own flag because the crowd control answer
-- is nil under stock settings, and testing the set itself would rebuild it on every call.
local debuffCandidatesBuilt
local eventsFrame
---@type EventGate?
local rosterGate
---@type UnitStatePollerSubscriber?
local stateSub
local hooked = false
-- Refilled per pass because the frame list is asked for on every refresh, and a raid is forty of
-- them.
local frameScratch = {}
-- Refilled per call for the same reason. The preview list is rebuilt per side per frame.
local testListScratch = {}
-- Assigned once ApplyToAll exists. The events that drive it all burst, and the one that matters
-- most fires while the frames it walks are still settling.
local QueueApplyToAll
-- Background walker declaring the aura groups of the displays as they are built, urgent because
-- these sit on unit frames the player is looking at. The engine allocates a batch of buttons the
-- moment a group is declared, so a party converting to a raid would build eighty of them at once.
local buildSweep = sweep:New(true)

---@return FrameAurasModuleOptions?
local function Options()
	local db = mini:GetSavedVars()

	return db and db.Modules and db.Modules.FrameAuras or nil
end

---@param side "Buffs"|"Debuffs"
---@return table?
local function SideOptions(side)
	local options = Options()

	return options and options[side] or nil
end

---The compact party and raid member frames the client is showing, and nothing else. Refilled in
---place.
---
---The standard party frames are left out. The two cvars below only reach the compact ones, so a
---row drawn on a standard frame would sit on top of Blizzard's own rather than in place of it.
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

	frames:BlizzardFrames(true, frameScratch)

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
---engine allocates for nothing. An unreadable answer counts as occupied, so this only ever skips a
---frame the client says outright is empty.
---@param unit string?
---@return boolean
local function HasUnit(unit)
	if not unit then
		return false
	end

	local exists = UnitExists(unit)

	-- The secret check leads because comparing a secret value aborts the whole handler.
	return mini:IsSecret(exists) or exists == true
end

---Whether a frame's unit is definitely there. The question HasUnit asks fails open, which is right
---for deciding whether to show a row that already exists and wrong for deciding whether to build
---one. Building is a batch of buttons the engine allocates on the spot and can never free.
---
---A frame the client will not answer for yet is simply built later, by the refresh or the
---visibility hook that follows.
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
---In the frame's own units rather than screen pixels. The row scales with its host, so a size
---measured in any other space comes out the wrong fraction of the frame at any UI scale but 1.
---@param frame table
---@param side "Buffs"|"Debuffs"
---@return number
local function IconSize(frame, side)
	local options = SideOptions(side)
	local percent = options and options.Size or DEFAULT_SIZE_PERCENT

	return pixels:ShareOfHeight(frame, percent, FALLBACK_ICON_SIZE)
end

---The engine's own answer to "can I dispel this", which it works out per aura from the player's
---spec. Asked for each time because the aura data it comes from is not guaranteed to be there by
---the time this file loads.
---@return number?
local function DispelType()
	return AuraUtil and AuraUtil.AuraUpdateChangedType and AuraUtil.AuraUpdateChangedType.Dispel
end

---Blizzard's own raid frame debuff order, which is what ranks a group's own matches against each
---other. The engine has to do it because an aura's spell id is secret, so nothing can reorder a
---group once it has rendered.
---@return number?
local function DebuffSort()
	if not AuraContainerSortMethod then
		return nil
	end

	return AuraContainerSortMethod.UnitFrameDebuff or AuraContainerSortMethod.Default
end

---The aura filter string the buff groups run under. The "mine" token is the coarse half of that
---switch. It and the candidate filter are weighed separately, so an aura has to satisfy both.
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

---The tracked ids as the engine wants them, built on first use and again after any refresh.
---@return table pandemic, table plain
local function BuffCandidates()
	if pandemicCandidates then
		return pandemicCandidates, plainCandidates
	end

	local pandemic, plain = spells:BuildSpellSets()
	local options = SideOptions("Buffs") or {}
	-- Absent rather than false when the filter is off. The booleans match an aura's field exactly,
	-- so false here would mean "only the ones somebody else cast".
	local mine = options.Mine ~= false or nil
	local maxDuration = options.ShortOnly == true and SHORT_AURA_SECONDS or nil
	local filtered = options.Filtered ~= false

	-- The glow group keeps its ids either way, since which spells light up is fixed.
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
---The two switches on the page narrow all three sets. They are about the row rather than about a
---category of it, so a stun the player cannot dispel is dropped exactly as a debuff would be.
---
---The priority flag on the last two sets is what tells those groups apart. Nothing else narrows
---the row, which is ranked by the game's own raid frame debuff order.
---@return table? crowdControl Nil when the row is not narrowed, which the engine reads as
---"everything".
---@return table priority
---@return table plain
local function DebuffCandidates()
	if debuffCandidatesBuilt then
		return debuffCandidates, priorityDebuffCandidates, plainDebuffCandidates
	end

	local options = SideOptions("Debuffs") or {}
	local maxDuration = options.ShortOnly == true and SHORT_AURA_SECONDS or nil
	local dispellable = options.Dispellable == true and DispelType() or nil

	debuffCandidatesBuilt = true
	debuffCandidates = nil

	if maxDuration or dispellable then
		debuffCandidates = {
			maxDuration = maxDuration,
			processedAuraType = dispellable,
		}
	end

	-- The two halves behind crowd control are told apart here rather than in their filter strings,
	-- because the game flags a priority aura with no token a string can negate.
	--
	-- The engine compares the flag against these, so an answer that is neither true nor false is
	-- turned away by both halves. A debuff row showing nothing behind the crowd control is the
	-- shape that failure takes, and no partition can be written without a boolean.
	priorityDebuffCandidates = {
		maxDuration = maxDuration,
		processedAuraType = dispellable,
		isPriorityAura = true,
	}
	plainDebuffCandidates = {
		maxDuration = maxDuration,
		processedAuraType = dispellable,
		isPriorityAura = false,
	}

	return debuffCandidates, priorityDebuffCandidates, plainDebuffCandidates
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

---How many icons the crowd control group at the head of the row may draw, and none at all until
---the player asks for it. Never more than the row's own budget.
---@return number
local function CrowdControlIcons()
	local options = SideOptions("Debuffs")

	if not options or options.ShowCrowdControl ~= true then
		return 0
	end

	return math.min(MaxIcons("Debuffs"), MAX_CROWD_CONTROL_ICONS)
end

---How many icons the priority group behind the crowd control may draw. Capped for the same reason,
---and never more than the row's own budget.
---@return number
local function PriorityIcons()
	return math.min(MaxIcons("Debuffs"), MAX_PRIORITY_ICONS)
end

---Whether the crowd control at the head of the debuff row is ringed in the game's dispel colours.
---Only that group asks.
---@return boolean
local function CrowdControlDispelColors()
	local options = SideOptions("Debuffs")

	return options ~= nil and options.ColorByDispelType == true
end

---The budget one group draws on. A group that leads a row carries its own, so what it draws is not
---taken out of the row behind it.
---@param side "Buffs"|"Debuffs"
---@param key string
---@return number
local function GroupIcons(side, key)
	if key == BUFF_PANDEMIC_GROUP then
		return PandemicIcons()
	end

	if key == DEBUFF_CROWD_CONTROL_GROUP then
		return CrowdControlIcons()
	end

	if key == DEBUFF_PRIORITY_GROUP then
		return PriorityIcons()
	end

	return MaxIcons(side)
end

---@param side "Buffs"|"Debuffs"
---@return number
local function PerRow(side)
	local options = SideOptions(side)

	return tonumber(options and options.PerRow) or DEFAULT_PER_ROW
end

---Whether the preview row leads with a crowd control stand-in. What draws that icon and what
---sizes it both ask this, so the two cannot drift apart.
---@param side "Buffs"|"Debuffs"
---@return boolean
local function PreviewLeadsWithCrowdControl(side)
	if side ~= "Debuffs" then
		return false
	end

	local options = SideOptions(side)

	return options ~= nil and options.ShowCrowdControl == true
end

---Whether one row drops its countdown text. The display's own vocabulary is the negative one, so
---the row's positive switch is turned round here.
---@param side "Buffs"|"Debuffs"
---@return boolean
local function HidesNumbers(side)
	local options = SideOptions(side)

	return options ~= nil and options.EnableNumbers == false
end

---The spells one side's preview draws, leading with a stand-in for each flagged category the row
---is currently letting in. Switching a category on has to move the preview with it, or the preview
---says nothing about what the switch does.
---@param side "Buffs"|"Debuffs"
---@return number[] Refilled scratch; the caller reads it before the next call.
---@return number How many entries at its head are those stand-ins.
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
	elseif PreviewLeadsWithCrowdControl(side) then
		testListScratch[#testListScratch + 1] = set.CrowdControl
	end

	local leading = #testListScratch

	for _, spellId in ipairs(set[side]) do
		testListScratch[#testListScratch + 1] = spellId
	end

	return testListScratch, leading
end

---How many icons the preview draws: the whole budget, since the live row wraps onto a second line
---rather than dropping what will not fit on the first.
---@param side "Buffs"|"Debuffs"
---@return number
local function TestIconCount(side)
	return math.max(1, MaxIcons(side))
end

---@param side "Buffs"|"Debuffs"
---@return AuraDisplayStyle
local function BuildStyle(side)
	local options = SideOptions(side) or {}
	local style = auraContainerDisplay:BuildStandardStyle()

	style.Stacks = true
	style.StackCoefficient = STACK_COEFFICIENT
	style.ReverseCooldown = true
	-- Only ever adds to the global Disable Numbers switch, which the display resolves for itself.
	style.HideNumbers = HidesNumbers(side)

	if side == "Buffs" then
		style.Pandemic = options.PandemicGlow == true
		style.PandemicColor = moduleUtil:GetColorRGB(options.PandemicColor)
	end

	-- Most crowd control is physical, which the engine gives no dispel type, so without this the
	-- stun leading the row would draw no ring.
	style.BorderWithoutDispelType = side == "Debuffs"

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

---@param frame table The frame this row will sit on, which is what sizes it.
---@param unit string?
---@return AuraContainerDisplay
local function BuildBuffs(frame, unit)
	local pandemic, plain = BuffCandidates()
	local filter = BuffFilter()
	local maxIcons = MaxIcons("Buffs")
	local groups = {}

	-- The spells that light up lead the row, in a group of their own. The reveal is registered on a
	-- button when it is built and driven by a window nothing can read, so which spells get one can
	-- only be decided by which group they land in.
	--
	-- Left out entirely when the reveal is off, or every frame in the raid pays for a batch of
	-- buttons that can never match anything.
	if PandemicIcons() > 0 then
		groups[#groups + 1] = {
			Key = BUFF_PANDEMIC_GROUP,
			FilterString = filter,
			MaxIcons = PandemicIcons(),
			CandidateFilters = pandemic,
			Pandemic = true,
		}
	end

	groups[#groups + 1] = {
		Key = BUFF_GROUP,
		FilterString = filter,
		MaxIcons = maxIcons,
		CandidateFilters = plain,
		Pandemic = false,
	}

	return auraContainerDisplay:New(frame, unit or "none", groups, IconSize(frame, "Buffs"), ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle("Buffs"),
		MasqueGroup = MASQUE_GROUP,
		Pandemic = true,
		PerLine = PerRow("Buffs"),
		-- The groups are declared by the walker, one per turn. A raid turning up builds one of
		-- these per frame at once, and each group costs a batch of buttons the engine allocates
		-- on the spot.
		DeferGroups = true,
	})
end

---The crowd control group at the head of the debuff row. Built fresh each time because a display
---stamps its own state on the spec it is handed and keeps the reference.
---@return AuraDisplayGroupSpec
local function CrowdControlGroup()
	return {
		Key = DEBUFF_CROWD_CONTROL_GROUP,
		FilterString = DEBUFF_CROWD_CONTROL_FILTER,
		MaxIcons = CrowdControlIcons(),
		CandidateFilters = DebuffCandidates(),
		SizeScale = LEAD_SIZE_SCALE,
		LayoutIndex = DEBUFF_CROWD_CONTROL_INDEX,
	}
end

---@param frame table As BuildBuffs.
---@param unit string?
---@return AuraContainerDisplay
local function BuildDebuffs(frame, unit)
	local _, priority, plain = DebuffCandidates()
	local maxIcons = MaxIcons("Debuffs")
	local groups = {}

	-- Crowd control leads the row, in a group of its own because an icon's size is fixed per group
	-- and this one is drawn larger than the rest. Left out until the player asks for it.
	if CrowdControlIcons() > 0 then
		groups[#groups + 1] = CrowdControlGroup()
	end

	-- The debuffs the game itself flags as priority follow, at the same size, because they are the
	-- ones a healer has to see before the rest of the row.
	groups[#groups + 1] = {
		Key = DEBUFF_PRIORITY_GROUP,
		FilterString = DEBUFF_PRIORITY_FILTER,
		MaxIcons = PriorityIcons(),
		CandidateFilters = priority,
		SizeScale = LEAD_SIZE_SCALE,
		LayoutIndex = DEBUFF_PRIORITY_INDEX,
	}

	groups[#groups + 1] = {
		Key = DEBUFF_GROUP,
		FilterString = DEBUFF_PLAIN_FILTER,
		MaxIcons = maxIcons,
		CandidateFilters = plain,
		LayoutIndex = DEBUFF_PLAIN_INDEX,
	}

	local display = auraContainerDisplay:New(frame, unit or "none", groups, IconSize(frame, "Debuffs"), ICON_SPACING, MASQUE_GROUP, {
		Style = BuildStyle("Debuffs"),
		MasqueGroup = MASQUE_GROUP,
		PerLine = PerRow("Debuffs"),
		DeferGroups = true,
	})

	local sort = DebuffSort()

	if sort then
		for _, key in ipairs(DEBUFF_GROUP_KEYS) do
			if display:HasGroup(key) then
				display:SetSortMethod(key, sort)
			end
		end
	end

	display:SetProcessingPolicy(ClassifiesDebuffs())

	return display
end

---Gives a debuff row the crowd control group the player has just switched on. Nothing frees a
---display, so a row built before the switch would otherwise stay without one until a reload.
---@param display AuraContainerDisplay
local function AddCrowdControlGroup(display)
	-- Nothing is built for a row that is switched off, however its own switches are set. The
	-- refresh that turns the row back on is what builds this.
	if not active.Debuffs or CrowdControlIcons() == 0 or display:HasGroup(DEBUFF_CROWD_CONTROL_GROUP) then
		return
	end

	-- Whatever the display already owes is on the walker, and one item walks the lot.
	local walking = display:HasPendingGroups()

	display:AddPendingGroup(CrowdControlGroup())

	local sort = DebuffSort()

	if sort then
		display:SetSortMethod(DEBUFF_CROWD_CONTROL_GROUP, sort)
	end

	if not walking then
		buildSweep:Append(display, DeclareNextGroup)
	end
end

---How far the power bar lifts the bottom of a compact frame's contents. The client writes this on
---each frame as it lays one out, and every bottom-anchored piece of its own adds it.
---
---The healer-only setting drops the bar per frame, so only the frame can say. Frames from other
---addons carry no field and place their own bars.
---@param frame table
---@return number
local function PowerBarInset(frame)
	return pixels:Number(frame.powerBarUsedHeight) or 0
end

---Pins one side's row into its corner of the frame, and puts it over the frame's own artwork.
---Parented to the frame, so the row fades and hides with the unit frame the way Blizzard's own row
---did.
---@param display AuraContainerDisplay
---@param frame table
---@param side "Buffs"|"Debuffs"
local function AnchorSide(display, frame, side)
	local place = PLACEMENT[side]
	local containerFrame = display.Frame

	display:SetGrow(place.Grow)

	-- Scales with the frame, unlike the free-standing displays elsewhere. At any UI scale but 1, a
	-- row that ignored it would take the wrong fraction of the frame and its corner inset would not
	-- line up with the frame's own edge.
	containerFrame:SetIgnoreParentScale(false)

	-- Buttons draw at the container's own level rather than one above it, so a container level with
	-- its host loses to the host's own artwork. The strata is left alone, since raising it would
	-- lift the icons out of the band their host draws in.
	local hostLevel = pixels:Number(frame:GetFrameLevel())

	if hostLevel then
		containerFrame:SetFrameLevel(hostLevel + 1)
	end

	containerFrame:ClearAllPoints()
	containerFrame:SetPoint(place.Point, frame, place.Point, place.OffsetX, place.OffsetY + PowerBarInset(frame))
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
		-- Both rows are anchored in a bottom corner, so a wrapped line goes up rather than over
		-- the frame below this one.
		container:SetGrowUp(true)
		entry[field] = container
	end

	return container
end

---Draws one side's preview, or clears it for a side that is switched off. A row nobody asked for
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
	-- The grid sizes the row to its full column width, so a budget that never reaches one line
	-- would leave the frame wider than the icons in it.
	container:SetColumns(math.min(PerRow(side), count), growAnchors:FillsLeftward(place.Grow))
	-- The live row hands crowd control its own group so it can be drawn larger, which a preview
	-- row of one container has to reproduce a slot at a time.
	container:SetLeadScale(PreviewLeadsWithCrowdControl(side) and LEAD_SIZE_SCALE or nil)

	local db = mini:GetSavedVars()
	local list, leading = TestSpellList(side)
	local nextSlot = testSpells:FillContainer(container, list, 1, {
		ReverseCooldown = true,
		HideNumbers = HidesNumbers(side),
		Glow = false,
		-- Only the crowd control stand-in carries a tint, so the plain spells behind it stay bare
		-- however this is set.
		ColorByDispelType = PreviewLeadsWithCrowdControl(side) and CrowdControlDispelColors(),
		FontScale = db and db.FontScale,
		Stagger = true,
		Count = count,
		Repeat = true,
		LeadCount = leading,
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
	containerFrame:SetPoint(place.Point, frame, place.Point, place.OffsetX, place.OffsetY + PowerBarInset(frame))
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
			display:SetMaxIcons(key, GroupIcons(side, key))
		end
	end

	AnchorSide(display, frame, side)
end

---Everything that depends on the settings rather than on who is on the frame. Skipped for an entry
---already drawn to the current ones. A raid sorting itself re-points every frame it has, and
---re-anchoring forty displays for settings that have not moved is the bulk of that cost.
---@param entry FrameAurasEntry
local function ApplySettings(entry)
	-- A frame behind a loading screen is still being laid out, so the geometry this reads off it is
	-- not what it settles at.
	local stamp = addon:IsLoadingScreenUp() and LOADING_GENERATION or generation

	-- The player turns the power bar on without touching anything this module owns, and the rows
	-- sit in the corner it takes. A frame already drawn for these settings still has to be looked
	-- at again when the bar comes or goes.
	local powerBarInset = PowerBarInset(entry.Frame)

	if entry.Generation == stamp and entry.PowerBarInset == powerBarInset then
		return
	end

	entry.Generation = stamp
	entry.PowerBarInset = powerBarInset

	local frame = entry.Frame

	if entry.Buffs then
		ApplySide(entry.Buffs, frame, "Buffs", BUFF_GROUP_KEYS)

		local pandemic, plain = BuffCandidates()
		local filter = BuffFilter()

		-- The glow group is only there when the reveal is on. A display built without it is never
		-- rebuilt when the switch flips, so there is nothing to publish to.
		if entry.Buffs:HasGroup(BUFF_PANDEMIC_GROUP) then
			entry.Buffs:SetFilterString(BUFF_PANDEMIC_GROUP, filter)
			entry.Buffs:SetCandidateFilters(BUFF_PANDEMIC_GROUP, pandemic)
		end

		entry.Buffs:SetFilterString(BUFF_GROUP, filter)
		entry.Buffs:SetCandidateFilters(BUFF_GROUP, plain)
	end

	if entry.Debuffs then
		-- Before the budgets go out, so a group that has just been added takes one.
		AddCrowdControlGroup(entry.Debuffs)
		ApplySide(entry.Debuffs, frame, "Debuffs", DEBUFF_GROUP_KEYS)

		-- The policy first, since a group asking for a classification the display is not making
		-- matches nothing at all.
		entry.Debuffs:SetProcessingPolicy(ClassifiesDebuffs())

		-- A display already built keeps the group it was created with, so the switch only reaches
		-- the row it is on this way.
		entry.Debuffs:SetGroupColorByDispelType(DEBUFF_CROWD_CONTROL_GROUP, CrowdControlDispelColors())

		-- The filter strings are fixed, so only the candidate filters are re-published. One set per
		-- group, since what keeps the three apart is the set rather than the string.
		local candidates, priority, plain = DebuffCandidates()

		if entry.Debuffs:HasGroup(DEBUFF_CROWD_CONTROL_GROUP) then
			entry.Debuffs:SetCandidateFilters(DEBUFF_CROWD_CONTROL_GROUP, candidates)
		end

		entry.Debuffs:SetCandidateFilters(DEBUFF_PRIORITY_GROUP, priority)
		entry.Debuffs:SetCandidateFilters(DEBUFF_GROUP, plain)
	end
end

---@param entry FrameAurasEntry
local function ApplyEntry(entry)
	if entry.Buffs or entry.Debuffs then
		ApplySettings(entry)
	end

	-- The live rows go dark for the preview. Nothing can put a fake aura in front of the engine, so
	-- the two would otherwise sit on top of each other.
	if testModeActive then
		if entry.Buffs then
			entry.Buffs:SetEnabled(false)
			entry.Buffs:SetShown(false)
		end

		if entry.Debuffs then
			entry.Debuffs:SetEnabled(false)
			entry.Debuffs:SetShown(false)
		end

		for _, side in ipairs(SIDES) do
			ApplyTestSide(entry, side)
		end

		return
	end

	ClearTestIcons(entry)

	-- Always, unlike the rest, because who is on the frame is exactly what a re-point changes.
	local occupied = HasUnit(entry.Unit) and frames:IsAnchorUsable(entry.Frame)

	-- Outside the player's visible world the engine stops weighing the category token, and a group
	-- that has nothing else to go on fills the head of the row with unrelated debuffs.
	--
	-- Urgent, because a unit that far away emits no aura events and a budget parked for combat
	-- would leave the garbage up until regen.
	if entry.Debuffs and entry.Debuffs:HasGroup(DEBUFF_CROWD_CONTROL_GROUP) then
		local budget = entry.Unit and units:IsVisible(entry.Unit) and CrowdControlIcons() or 0
		entry.Debuffs:SetMaxIcons(DEBUFF_CROWD_CONTROL_GROUP, budget, true)
	end

	-- A container the client is still tracking weighs every aura on the unit against its groups
	-- whether or not anything is drawn, and a raid is forty frames of that.
	if entry.Buffs then
		local wanted = active.Buffs and occupied
		entry.Buffs:SetEnabled(wanted)
		entry.Buffs:SetShown(wanted)
	end

	if entry.Debuffs then
		local wanted = active.Debuffs and occupied
		entry.Debuffs:SetEnabled(wanted)
		entry.Debuffs:SetShown(wanted)
	end
end

---The entry for a frame, built the first time the frame is seen. A side switched on after the entry
---exists gets its display then, and one switched off keeps it, because the engine can free neither
---display nor the buttons under it.
---@param frame table
---@return FrameAurasEntry?
local function EnsureEntry(frame)
	if not frame or mini:IsSecret(frame) then
		return nil
	end

	-- Anchoring anything to a forbidden frame taints it.
	if frame.IsForbidden and frame:IsForbidden() then
		return nil
	end

	local entry = watchers[frame]
	local unit = UnitFor(frame)

	-- Only the first pass is gated. Once a frame has displays they are kept and re-pointed.
	if not entry then
		-- A preview asks whether the frame is on screen, because the stand-ins name units the
		-- player does not have.
		local buildable

		if testModeActive then
			buildable = frames:IsAnchorUsable(frame)
		else
			buildable = HasUnitForSure(unit)
		end

		if not buildable then
			return nil
		end
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

	-- Nothing live is built for a preview. The display would be hidden the moment it existed, and
	-- the stand-ins name units it could never read. The refresh that ends test mode builds them.
	if testModeActive then
		return entry
	end

	for _, side in ipairs(SIDES) do
		if active[side] and not entry[side] then
			local build = side == "Buffs" and BuildBuffs or BuildDebuffs
			local display = build(frame, entry.Unit)

			entry[side] = display

			-- Whatever it still owes goes on the urgent lane, because a frame is holding it now.
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

---Brings every frame on screen up to date, and hands the poller the units they hold.
---
---Seeded from this walk rather than from the entries, because a frame whose unit the client will
---not answer for has no entry yet and is exactly what the poller is watching for.
local function ApplyToAll()
	-- Re-seeded per pass rather than tracked per frame, since the frames retarget constantly and a
	-- baseline for a unit nobody is on is a flip fired for nothing.
	if stateSub then
		stateSub:ClearAll()
	end

	-- A preview names units the player does not have, and a baseline for one of those is a read
	-- four times a second that can never flip.
	local seeding = stateSub and not testModeActive

	for _, frame in ipairs(BlizzardFrames()) do
		ApplyToFrame(frame)

		local unit = seeding and UnitFor(frame)

		if unit then
			stateSub:Seed(unit)
		end
	end

	-- A frame hidden by a parent fires no hook of its own and the walk above cannot see it, so
	-- its containers would keep reading a live token forever.
	for _, entry in pairs(watchers) do
		if not frames:IsAnchorUsable(entry.Frame) then
			ApplyEntry(entry)
		end
	end
end

QueueApplyToAll = moduleUtil:Coalesced(ApplyToAll)

---@return boolean
local function AnySideActive()
	return active.Buffs or active.Debuffs
end

---Tells the client whether to draw its own row for one side, but only where the answer moved.
---
---Deferred past combat, because flipping either cvar makes the client rebuild the raid frames,
---which it refuses to do mid-fight.
---@param side "Buffs"|"Debuffs"
---@param enabled boolean
local function ApplyCVar(side, enabled)
	if cvarState[side] == enabled then
		return
	end

	local wasSettled = cvarState[side] ~= nil

	cvarState[side] = enabled

	local db = mini:GetSavedVars()

	db.FrameAuraCVars = db.FrameAuraCVars or {}

	local taken = db.FrameAuraCVars

	-- The player may have turned Blizzard's own row off themselves, and this has never touched it.
	-- A flag surviving from the last session is a hand-back a reload cut short, and that one still
	-- goes out.
	if not enabled and not wasSettled and not taken[side] then
		return
	end

	local name = CVARS[side]
	local value

	if enabled then
		-- Kept in the saved variables because the row is handed back on a switch the player may
		-- not flip for weeks, long past the reload that would forget this ever took it.
		taken[side] = true
		value = CVAR_HIDDEN
	else
		-- Straight back on. A switch off is a player asking to see Blizzard's row.
		value = CVAR_SHOWN
	end

	-- Writing the value the client already holds still makes it rebuild the raid frames. At login
	-- the last session's write is still in place, so there is nothing to say.
	mini:RunWhenCombatEnds(function()
		if GetCVar(name) ~= value then
			SetCVar(name, value)
		end

		if not enabled then
			taken[side] = false
		end
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
	-- Deferred a frame, since this fires as the loading screen ends and the compact frames have not
	-- finished settling onto their real units until after it. Coalesced too, because a roster
	-- forming fires one of these per member joining.
	eventsFrame:SetScript("OnEvent", QueueApplyToAll)

	-- A frame passed over for having nobody on it gets no set-unit call of its own when someone
	-- turns up under a token it was already holding, so the roster is what says to look again.
	-- With both sides off there is nothing here to do, so a disabled module pays for no dispatch.
	--
	-- The loading screen ending is in there because building needs a definite answer about who is
	-- on a frame, and the client gives none while one is up. This is the pass that builds what the
	-- world-entering pass had to skip.
	rosterGate = eventGate:New(eventsFrame, {
		"GROUP_ROSTER_UPDATE",
		"PLAYER_ENTERING_WORLD",
		"LOADING_SCREEN_DISABLED",
	})

	-- A unit walking into the player's visible world has no event, so the client will not say for
	-- sure it is there and the row for it is never built.
	stateSub = unitStatePoller:Register(AnySideActive, QueueApplyToAll)

	frames:InstallUnitFrameHooks(eventsFrame, {
		-- Blizzard re-points frames at units constantly while a raid sorts, and the token often
		-- comes back the same one with a different member behind it. Nothing about that reaches
		-- the display on its own, so every re-point is treated as a new unit.
		OnSetUnit = function(frame)
			if AnySideActive() then
				ApplyToFrame(frame)
			end
		end,
		OnUpdateVisible = function(frame)
			if AnySideActive() then
				ApplyToFrame(frame)

				-- A frame that came on screen between passes carries a token nothing is polling
				-- yet, and the walk is what seeds it.
				if frames:IsAnchorUsable(frame) then
					QueueApplyToAll()
				end
			elseif watchers[frame] then
				-- A frame the client empties rather than hides still has to drop its rows.
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

	-- Dropped rather than rebuilt, since the walk below asks for them and a refresh that changes
	-- nothing about the tracked ids still has to hand the engine tables it will accept.
	pandemicCandidates = nil
	plainCandidates = nil
	debuffCandidates = nil
	priorityDebuffCandidates = nil
	plainDebuffCandidates = nil
	debuffCandidatesBuilt = nil

	if AnySideActive() then
		InstallHooks()
		rosterGate:SetActive(true)
		ApplyToAll()

		return
	end

	if rosterGate then
		rosterGate:SetActive(false)
	end

	-- A watched token holds a baseline every other subscriber shares, so an off module lets its
	-- own go.
	if stateSub then
		stateSub:ClearAll()
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
---@field Generation number|string? The refresh it was last drawn for, or a stand-in while a
---loading screen is up.
---@field PowerBarInset number? The power bar height the rows were last placed above.
