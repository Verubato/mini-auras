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
local kickTracker = addon.Core.KickTracker
local kickSlot = addon.Core.KickSlot
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
local DEBUFF_DISPEL_GROUP = "FrameDebuffsDispel"
local DEBUFF_ROLE_GROUP = "FrameDebuffsRole"
local BUFF_GROUP_KEYS = { BUFF_PANDEMIC_GROUP, BUFF_GROUP }
local DEBUFF_GROUP_KEYS = { DEBUFF_ROLE_GROUP, DEBUFF_CROWD_CONTROL_GROUP, DEBUFF_DISPEL_GROUP, DEBUFF_GROUP }
-- The groups that lose their countdown when the numbers are kept to the head of the row.
local DEBUFF_PLAIN_GROUP_KEYS = { DEBUFF_DISPEL_GROUP, DEBUFF_GROUP }
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
-- Narrows to what anybody in the group can take off.
local REQUIRE_DISPELLABLE = "|DISPELLABLE"
-- The game's own token for what the player can take off, spec and talents included.
local REQUIRE_PLAYER_DISPELLABLE = "|RAID"
local EXCLUDE_PLAYER_DISPELLABLE = "|!RAID"
-- Neither the plain group nor the role group ever draws crowd control, whatever the switch says.
local DEBUFF_PLAIN_FILTER = DEBUFF_FILTER .. EXCLUDE_CROWD_CONTROL
local DEBUFF_CROWD_CONTROL_FILTER = DEBUFF_FILTER .. "|CROWD_CONTROL"
-- Where each part sits in the row. Spelled out because the crowd control and dispel groups are
-- declared after the others when they are added mid-session, and the engine falls back to the order
-- groups were declared in.
local DEBUFF_ROLE_INDEX = 1
local DEBUFF_CROWD_CONTROL_INDEX = 2
local DEBUFF_DISPEL_INDEX = 3
local DEBUFF_PLAIN_INDEX = 4
local DEFAULT_LEAD_SCALE = 1.4
-- The groups drawn at the lead size. A stun or a boss and role debuff on a party member is worth
-- more than the debuff beside it.
local LEAD_GROUP_KEYS = { DEBUFF_ROLE_GROUP, DEBUFF_CROWD_CONTROL_GROUP }
-- The point on a kick icon a row hangs off, keyed by the point of the row that does.
local MIRRORED_POINT = {
	TOPLEFT = "TOPRIGHT",
	TOPRIGHT = "TOPLEFT",
	BOTTOMLEFT = "BOTTOMRIGHT",
	BOTTOMRIGHT = "BOTTOMLEFT",
}
-- The most icons the head of the row holds. Its own cap rather than the row's, because three stuns
-- at once on one member is already unusual.
local MAX_CROWD_CONTROL_ICONS = 3
-- The same cap on the boss and role auras leading the row, and for the same reason.
local MAX_ROLE_ICONS = 3
-- What "under a minute" means to the engine: a bound on an aura's whole duration rather than on
-- what is left of it. Any value at all also drops the auras that never run out.
local SHORT_AURA_SECONDS = 60
-- Where each row sits when a profile has never held a placement of its own. Spelled out rather
-- than read off the defaults table, which loads after the modules do.
local DEFAULT_PLACEMENT = {
	Buffs = { Anchor = "BOTTOMRIGHT", Grow = "LEFT_UP", Offset = { X = -2, Y = 2 } },
	Debuffs = { Anchor = "BOTTOMLEFT", Grow = "RIGHT_UP", Offset = { X = 2, Y = 2 } },
}
-- The points a row may hang off. An imported or hand-edited profile can hold anything, and a
-- point the client does not know throws out of SetPoint and takes the module down with it.
local ANCHOR_POINTS = {
	TOPLEFT = true,
	TOP = true,
	TOPRIGHT = true,
	LEFT = true,
	CENTER = true,
	RIGHT = true,
	BOTTOMLEFT = true,
	BOTTOM = true,
	BOTTOMRIGHT = true,
}
-- UP and DOWN are left out on purpose. They run the live row down a column, which the preview row
-- draws across instead, so a profile holding one would preview somewhere it will not appear.
local GROW_DIRECTIONS = {
	LEFT = true,
	RIGHT = true,
	CENTER = true,
	LEFT_UP = true,
	RIGHT_UP = true,
}
-- The gap a profile written before the slider existed falls back to.
local DEFAULT_PADDING = 1
local MIN_PADDING = 0
local MAX_PADDING = 5
-- Icons take a share of the frame's height rather than a fixed size, because a raid profile and a
-- party profile size their frames very differently. This is what one falls back to when the client
-- has never once said how tall the frame is.
-- Erring large, because a row that is too big is something the player can see and correct.
local FALLBACK_ICON_SIZE = 30
-- The shipped budgets a profile written before a key existed falls back to. Spelled out rather
-- than read off the defaults table, which loads after the modules do.
local DEFAULT_MAX_ICONS = { Buffs = 6, Debuffs = 2 }
local DEFAULT_PER_ROW = 3
local DEFAULT_SIZE_PERCENT = 35
local DEFAULT_FONT_SCALE = 1.0
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
-- What a stand-in icon shows for a centred stack count, where a live icon shows the real one.
local PREVIEW_STACK_COUNT = "3"

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
-- Last size each side measured on each frame, so a frame the client can't measure right now keeps
-- the size it actually has instead of jumping to the fallback.
local lastIconSize = setmetatable({}, { __mode = "k" })
-- Frame and side each display was built for, so the walker can re-measure right before it declares
-- a group rather than trust what New saw.
local groupSource = setmetatable({}, { __mode = "k" })
-- The filters the displays currently hold, one set between them all. The engine keeps the
-- reference it is handed, and handing the same one back costs nothing.
local pandemicCandidates
local plainCandidates
local roleDebuffCandidates
local restDebuffCandidates
local crowdControlDebuffCandidates
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
-- The kick icon's slot options, refilled per kick so no event allocates.
local kickScratch = {}
-- Assigned once ApplyToAll exists. The events that drive it all burst, and the one that matters
-- most fires while the frames it walks are still settling.
local QueueApplyToAll
-- Set by whatever can put a new player behind a token a frame already holds, and spent by the next
-- walk, which re-reads every frame because the engine ignores a token it already has.
local occupantsMoved = false
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
	local size = pixels:ShareOfHeight(frame, percent)
	local sides = lastIconSize[frame]

	if size then
		sides = sides or {}
		sides[side] = size
		lastIconSize[frame] = sides

		return size
	end

	return (sides and sides[side]) or FALLBACK_ICON_SIZE
end

---The engine's own answer to "can I dispel this", which it works out per aura from the player's
---spec. Asked for each time because the aura data it comes from is not guaranteed to be there by
---the time this file loads.
---@return number?
local function DispelType()
	return AuraUtil and AuraUtil.AuraUpdateChangedType and AuraUtil.AuraUpdateChangedType.Dispel
end

---Default, because the raid frame order compares a field the dispel pass may leave unset, and throws.
---@return number?
local function DebuffSort()
	return AuraContainerSortMethod and AuraContainerSortMethod.Default
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

---Whether the raid half of the dispellable switch is on. It covers the "by me" half, which goes
---quiet while it is.
---@return boolean
local function DispellableByRaidOn()
	local options = SideOptions("Debuffs")

	return options ~= nil and options.DispellableByRaid == true
end

---The debuff filters, built the same way and for the same reason.
---
---The boss and role partition is made here rather than in a filter string, because the game
---answers isBossOrRoleAura on the aura itself and nothing negates that in a string. It is always
---set, so none of them can come back nil.
---
---Crowd control gets its own table with no dispel-type filter, because a spec's inability to
---dispel a stun is not a reason to hide it. It carries no boss and role flag either, since the game
---can flag a stun as a role aura and its own group has to catch it whichever way that goes.
---@return table role Feeds the group leading the row.
---@return table rest Feeds the plain group behind crowd control.
---@return table crowdControl Feeds the crowd control group.
local function DebuffCandidates()
	if roleDebuffCandidates then
		return roleDebuffCandidates, restDebuffCandidates, crowdControlDebuffCandidates
	end

	local options = SideOptions("Debuffs") or {}
	local maxDuration = options.ShortOnly == true and SHORT_AURA_SECONDS or nil
	local dispellable = options.DispellableByMe == true and not DispellableByRaidOn() and DispelType() or nil

	roleDebuffCandidates = {
		maxDuration = maxDuration,
		processedAuraType = dispellable,
		isBossOrRoleAura = true,
	}
	restDebuffCandidates = {
		maxDuration = maxDuration,
		processedAuraType = dispellable,
		isBossOrRoleAura = false,
	}
	crowdControlDebuffCandidates = {
		maxDuration = maxDuration,
	}

	return roleDebuffCandidates, restDebuffCandidates, crowdControlDebuffCandidates
end

---Whether the debuff displays have to classify each aura for the dispellable filter. Asking for a
---classification nothing reads is a pass per aura for nothing.
---@return boolean
local function ClassifiesDebuffs()
	local options = SideOptions("Debuffs")

	return options ~= nil and options.DispellableByMe == true and not DispellableByRaidOn() and DispelType() ~= nil
end

---Whether the debuffs the player can dispel lead the plain group. With Dispellable by me on the
---plain group already holds nothing else, so a second group would only be emptied by its filter.
---@return boolean
local function SortsDispellableFirst()
	return not ClassifiesDebuffs()
end

---@param side "Buffs"|"Debuffs"
---@return number
local function MaxIcons(side)
	local options = SideOptions(side)

	return tonumber(options and options.MaxIcons) or DEFAULT_MAX_ICONS[side]
end

---What the head of the debuff row is drawn at, as a share of the rest of it.
---@return number
local function LeadScale()
	local options = SideOptions("Debuffs")
	local scale = tonumber(options and options.LeadScale)

	return scale and scale > 0 and scale or DEFAULT_LEAD_SCALE
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

---Whether the debuff row leads with a kick icon. It rides the crowd control switch, since a kick
---reads as crowd control to the player.
---@return boolean
local function ShowsKicks()
	local options = SideOptions("Debuffs")

	return active.Debuffs and options ~= nil and options.ShowCrowdControl == true
end

---The boss and role group's filter. Always closed to crowd control, which has its own group, and
---narrows to what the raid can dispel when the Dispellable by raid switch is on.
---@return string
local function RoleFilter()
	local filter = DEBUFF_PLAIN_FILTER

	if DispellableByRaidOn() then
		filter = filter .. REQUIRE_DISPELLABLE
	end

	return filter
end

---The plain group's filter, which narrows to what the raid can dispel the same way the role
---group's does. Leaves out what the player can dispel while the dispel group shows it.
---@param split boolean Whether the dispel group is drawing.
---@return string
local function PlainFilter(split)
	local filter = DEBUFF_PLAIN_FILTER

	if DispellableByRaidOn() then
		filter = filter .. REQUIRE_DISPELLABLE
	end

	if split then
		filter = filter .. EXCLUDE_PLAYER_DISPELLABLE
	end

	return filter
end

---The dispel group's filter, the player's half of what PlainFilter splits.
---@return string
local function DispelFilter()
	local filter = DEBUFF_PLAIN_FILTER

	if DispellableByRaidOn() then
		filter = filter .. REQUIRE_DISPELLABLE
	end

	return filter .. REQUIRE_PLAYER_DISPELLABLE
end

---How many icons the boss and role group at the head of the row may draw. Never gated on a
---setting, because a boss or role aura has to be on the row whatever the player switched off.
---Still never more than the row's own budget.
---@return number
local function RoleIcons()
	return math.min(MaxIcons("Debuffs"), MAX_ROLE_ICONS)
end

---Whether the debuff row is ringed in the game's dispel colours. The one switch on the row governs
---all three of its groups.
---@return boolean
local function DebuffDispelColors()
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

	if key == DEBUFF_ROLE_GROUP then
		return RoleIcons()
	end

	if key == DEBUFF_DISPEL_GROUP then
		return SortsDispellableFirst() and MaxIcons(side) or 0
	end

	return MaxIcons(side)
end

---@param side "Buffs"|"Debuffs"
---@return number
local function PerRow(side)
	local options = SideOptions(side)

	return tonumber(options and options.PerRow) or DEFAULT_PER_ROW
end

---The gap one row leaves between one icon and the next. An imported or hand-edited profile can
---hold anything, and a gap wider than the frame would push the row off it.
---@param side "Buffs"|"Debuffs"
---@return number
local function Padding(side)
	local options = SideOptions(side)
	local padding = tonumber(options and options.Padding)

	if not padding then
		return DEFAULT_PADDING
	end

	return math.min(math.max(padding, MIN_PADDING), MAX_PADDING)
end

---The point of the frame one row hangs off. The same point is used on both sides of the anchor,
---so a corner holds the row inside the frame rather than half over its edge.
---@param side "Buffs"|"Debuffs"
---@return string
local function AnchorPoint(side)
	local options = SideOptions(side)
	local anchor = options and options.Anchor

	return ANCHOR_POINTS[anchor] and anchor or DEFAULT_PLACEMENT[side].Anchor
end

---Which way one row runs, and which way a wrapped line stacks.
---@param side "Buffs"|"Debuffs"
---@return string
local function Grow(side)
	local options = SideOptions(side)
	local grow = options and options.Grow

	return GROW_DIRECTIONS[grow] and grow or DEFAULT_PLACEMENT[side].Grow
end

---How far one row sits off the point it hangs from.
---@param side "Buffs"|"Debuffs"
---@return number x
---@return number y
local function Offset(side)
	local options = SideOptions(side)
	local offset = options and options.Offset
	local shipped = DEFAULT_PLACEMENT[side].Offset

	return tonumber(offset and offset.X) or shipped.X, tonumber(offset and offset.Y) or shipped.Y
end

---What one row multiplies its text size by.
---@param side "Buffs"|"Debuffs"
---@return number
local function FontScale(side)
	local options = SideOptions(side)

	return tonumber(options and options.FontScale) or DEFAULT_FONT_SCALE
end

---Whether one row puts the stack count where the countdown goes.
---@param side "Buffs"|"Debuffs"
---@return boolean
local function CentersStacks(side)
	local options = SideOptions(side)

	return options ~= nil and options.CenterStacks == true
end

---Which way one row's cooldown swipe runs.
---@param side "Buffs"|"Debuffs"
---@return boolean
local function ReversesCooldown(side)
	local options = SideOptions(side)

	return options == nil or options.ReverseCooldown ~= false
end

---Whether one row drops its countdown text. The display's own vocabulary is the negative one, so
---the row's positive switch is turned round here.
---@param side "Buffs"|"Debuffs"
---@return boolean
local function HidesNumbers(side)
	local options = SideOptions(side)

	return options ~= nil and options.EnableNumbers == false
end

---Whether the plain debuffs drop their countdown while crowd control and the boss and role auras
---ahead of them keep theirs.
---@return boolean
local function PlainHidesNumbers()
	local options = SideOptions("Debuffs")

	return options ~= nil and options.LeadNumbersOnly == true
end

---The whole budget, since the live row wraps onto a second line.
---@param side "Buffs"|"Debuffs"
---@return number
local function TestIconCount(side)
	return math.max(1, MaxIcons(side))
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
	else
		-- One slot is kept for a plain debuff, or the preview cannot show what the row is mostly
		-- made of.
		local room = TestIconCount(side) - 1
		local crowdControl = options.ShowCrowdControl == true and room >= 1
		local role = room >= (crowdControl and 2 or 1)

		-- Drawn in the live row's group order, whichever of them won the room.
		if role then
			testListScratch[#testListScratch + 1] = set.Role
		end

		if crowdControl then
			testListScratch[#testListScratch + 1] = set.CrowdControl
		end
	end

	local leading = #testListScratch

	for _, spellId in ipairs(set[side]) do
		testListScratch[#testListScratch + 1] = spellId
	end

	return testListScratch, leading
end

---@param side "Buffs"|"Debuffs"
---@return AuraDisplayStyle
local function BuildStyle(side)
	local options = SideOptions(side) or {}
	local style = auraContainerDisplay:BuildStandardStyle()

	style.Stacks = true
	style.StackCoefficient = STACK_COEFFICIENT
	style.ReverseCooldown = ReversesCooldown(side)
	-- Only ever adds to the global Disable Numbers switch, which the display resolves for itself.
	style.HideNumbers = HidesNumbers(side)
	style.FontScale = FontScale(side)
	style.CenterStacks = CentersStacks(side)

	if side == "Buffs" then
		style.Pandemic = options.PandemicGlow == true
		style.PandemicColor = moduleUtil:GetColorRGB(options.PandemicColor)
	end

	-- A physical debuff carries no dispel type, so without this a stun would go unringed wherever
	-- on the row it landed.
	style.BorderWithoutDispelType = side == "Debuffs"

	return style
end

---One display's next group, from the walker. A display is created with none of them, so this is
---what puts its icons on screen.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	local source = groupSource[display]

	if source then
		-- The frame is usually not laid out when the display is built, and a button is born at
		-- whatever size the display carries now.
		display:SetIconSize(IconSize(source.Frame, source.Side))
	end

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

	local display = auraContainerDisplay:New(frame, unit or "none", groups, IconSize(frame, "Buffs"), Padding("Buffs"), MASQUE_GROUP, {
		Style = BuildStyle("Buffs"),
		MasqueGroup = MASQUE_GROUP,
		Pandemic = true,
		PerLine = PerRow("Buffs"),
		-- The groups are declared by the walker, one per turn. A raid turning up builds one of
		-- these per frame at once, and each group costs a batch of buttons the engine allocates
		-- on the spot.
		DeferGroups = true,
	})

	groupSource[display] = { Frame = frame, Side = "Buffs" }

	return display
end

---The crowd control group at the head of the debuff row. Built fresh each time because a display
---stamps its own state on the spec it is handed and keeps the reference.
---@return AuraDisplayGroupSpec
local function CrowdControlGroup()
	local _, _, crowdControl = DebuffCandidates()

	return {
		Key = DEBUFF_CROWD_CONTROL_GROUP,
		FilterString = DEBUFF_CROWD_CONTROL_FILTER,
		MaxIcons = CrowdControlIcons(),
		CandidateFilters = crowdControl,
		SizeScale = LeadScale(),
		LayoutIndex = DEBUFF_CROWD_CONTROL_INDEX,
	}
end

---The group of debuffs the player can dispel, ahead of the plain group. It has its own budget,
---because no group can see how full another one is.
---@return AuraDisplayGroupSpec
local function DispelGroup()
	local _, rest = DebuffCandidates()

	return {
		Key = DEBUFF_DISPEL_GROUP,
		FilterString = DispelFilter(),
		MaxIcons = GroupIcons("Debuffs", DEBUFF_DISPEL_GROUP),
		CandidateFilters = rest,
		LayoutIndex = DEBUFF_DISPEL_INDEX,
	}
end

---The boss and role group leading the debuff row, ahead of crowd control.
---@return AuraDisplayGroupSpec
local function RoleGroup()
	local role = DebuffCandidates()

	return {
		Key = DEBUFF_ROLE_GROUP,
		FilterString = RoleFilter(),
		MaxIcons = RoleIcons(),
		CandidateFilters = role,
		SizeScale = LeadScale(),
		LayoutIndex = DEBUFF_ROLE_INDEX,
	}
end

---@param frame table As BuildBuffs.
---@param unit string?
---@return AuraContainerDisplay
local function BuildDebuffs(frame, unit)
	local _, rest = DebuffCandidates()
	local groups = {}

	-- The game's own boss and role auras lead the row, unconditionally, so nothing ordinary can ever
	-- push one of them off.
	groups[#groups + 1] = RoleGroup()

	-- Crowd control follows, in a group of its own because an icon's size is fixed per group and
	-- this one is drawn larger than the rest. Left out until the player asks for it.
	if CrowdControlIcons() > 0 then
		groups[#groups + 1] = CrowdControlGroup()
	end

	if SortsDispellableFirst() then
		groups[#groups + 1] = DispelGroup()
	end

	groups[#groups + 1] = {
		Key = DEBUFF_GROUP,
		FilterString = PlainFilter(false),
		MaxIcons = MaxIcons("Debuffs"),
		CandidateFilters = rest,
		LayoutIndex = DEBUFF_PLAIN_INDEX,
	}

	local display = auraContainerDisplay:New(frame, unit or "none", groups, IconSize(frame, "Debuffs"), Padding("Debuffs"), MASQUE_GROUP, {
		Style = BuildStyle("Debuffs"),
		MasqueGroup = MASQUE_GROUP,
		PerLine = PerRow("Debuffs"),
		DeferGroups = true,
	})

	groupSource[display] = { Frame = frame, Side = "Debuffs" }

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

---Gives a debuff row a group the player has just made wanted. Nothing frees a display, so a row
---built before the change would otherwise stay without one until a reload.
---@param display AuraContainerDisplay
---@param key string
---@param build fun(): AuraDisplayGroupSpec
---@param wanted boolean
local function AddLateGroup(display, key, build, wanted)
	-- Nothing is built for a row that is switched off, however its own switches are set. The
	-- refresh that turns the row back on is what builds this.
	if not active.Debuffs or not wanted or display:HasGroup(key) then
		return
	end

	-- Whatever the display already owes is on the walker, and one item walks the lot.
	local walking = display:HasPendingGroups()

	display:AddPendingGroup(build())

	local sort = DebuffSort()

	if sort then
		display:SetSortMethod(key, sort)
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

---How far a row hanging off a given point has to rise to clear the power bar. Only a bottom point
---sits in the space the bar takes, and only a row stacking up over that point stays in it.
---@param frame table
---@param point string
---@param pin string The point of the row itself that hangs off `point`.
---@return number
local function PowerBarLift(frame, point, pin)
	if not point:find("BOTTOM") or not pin:find("BOTTOM") then
		return 0
	end

	return PowerBarInset(frame)
end

---Scales a row with its frame and puts it over the frame's own artwork.
---@param containerFrame table
---@param frame table
local function LayerOverHost(containerFrame, frame)
	-- At any UI scale but 1, a row that ignored the frame's scale would take the wrong fraction of
	-- it and its corner inset would not line up with the frame's own edge.
	containerFrame:SetIgnoreParentScale(false)

	local hostLevel = pixels:Number(frame:GetFrameLevel())

	-- Buttons draw at the container's own level, so a level equal to the host's loses to its artwork.
	if hostLevel then
		containerFrame:SetFrameLevel(hostLevel + 1)
	end
end

---Hangs one side's row off its corner of the frame. With a kick icon leading the row, the row
---starts against the icon's far edge instead.
---@param rowFrame table
---@param frame table
---@param side "Buffs"|"Debuffs"
---@param kickFrame table? The kick icon's frame while one leads the row.
local function PinRow(rowFrame, frame, side, kickFrame)
	local point = AnchorPoint(side)
	local grow = Grow(side)
	local pin = growAnchors:GetFlowPin(grow)
	local offsetX, offsetY = Offset(side)

	rowFrame:ClearAllPoints()

	if not kickFrame then
		rowFrame:SetPoint(pin, frame, point, offsetX, offsetY + PowerBarLift(frame, point, pin))

		return
	end

	-- A centred row has no side to chain from, so the kick sits left of the anchor.
	local rowPin = pin == "TOP" and "TOPLEFT" or pin
	local gap = Padding(side)

	rowFrame:SetPoint(rowPin, kickFrame, MIRRORED_POINT[rowPin], growAnchors:FillsLeftward(grow) and -gap or gap, 0)
end

---Puts the kick icon where the debuff row's first icon would sit.
---@param kickFrame table
---@param frame table
local function PinKick(kickFrame, frame)
	local point = AnchorPoint("Debuffs")
	local pin = growAnchors:GetFlowPin(Grow("Debuffs"))
	local offsetX, offsetY = Offset("Debuffs")
	local kickPin = pin == "TOP" and "TOPRIGHT" or pin

	kickFrame:ClearAllPoints()
	kickFrame:SetPoint(kickPin, frame, point, offsetX, offsetY + PowerBarLift(frame, point, pin))
end

---Pins one side's row into its corner of the frame. Parented to the frame, so the row fades and
---hides with the unit frame the way Blizzard's own row did.
---@param display AuraContainerDisplay
---@param frame table
---@param side "Buffs"|"Debuffs"
local function AnchorSide(display, frame, side)
	display:SetGrow(Grow(side))
	LayerOverHost(display.Frame, frame)
	PinRow(display.Frame, frame, side)
end

---Skipped while the kick has not appeared or ended, since a re-point invalidates the layout of
---every button and a kick event reaches every frame on screen.
---@param entry FrameAurasEntry
---@param force boolean? Set after the settings pass, which pins the row in its corner itself.
local function AnchorDebuffRow(entry, force)
	if not entry.Debuffs or not entry.KickContainer then
		return
	end

	local kickActive = entry.KickActive == true

	if not force and (entry.KickAnchored == true) == kickActive then
		return
	end

	entry.KickAnchored = kickActive

	local kickFrame = entry.KickContainer.Frame

	PinKick(kickFrame, entry.Frame)
	PinRow(entry.Debuffs.Frame, entry.Frame, "Debuffs", kickActive and kickFrame or nil)
end

---The kick's size, taken from the size the row's buttons actually carry. That lags the requested
---size while a restyle is held back, and a frame with no row has only the requested one.
---@param entry FrameAurasEntry
---@return number
local function KickSize(entry)
	local display = entry.Debuffs
	local size = display and display.Size or IconSize(entry.Frame, "Debuffs")
	local scale = display and display:GetGroupSizeScale(DEBUFF_ROLE_GROUP)

	return size * (scale or LeadScale())
end

---@param entry FrameAurasEntry
local function SyncKickSize(entry)
	entry.KickContainer:SetIconSize(KickSize(entry))
end

---Draws the entry's kick, or clears the slot when there is none, and moves the row around it.
---@param entry FrameAurasEntry
---@param expired boolean? Set when the kick's own timer ended, so a hidden frame is cleared too.
local function UpdateKick(entry, expired)
	local container = entry.KickContainer

	if not container or testModeActive then
		return
	end

	SyncKickSize(entry)

	-- Frames the client left dark keep their subscriptions, so a kick on the player reaches all of
	-- them and nothing they draw can be seen. An expiry still has to clear the slot.
	if not expired and entry.Frame.IsVisible and not entry.Frame:IsVisible() then
		return
	end

	local kickEntry = entry.KickKey and entry.DebuffsWanted and kickTracker:GetKick(entry.KickUnit) or nil
	local slotOptions

	if kickEntry then
		slotOptions = kickScratch
		slotOptions.Texture = kickEntry.Texture
		slotOptions.DurationObject = kickEntry.DurationObject
		slotOptions.Alpha = true
		slotOptions.Glow = false
		slotOptions.ReverseCooldown = ReversesCooldown("Debuffs")
		-- The kick is a lead, so only the row's own switch hides its numbers.
		slotOptions.HideNumbers = HidesNumbers("Debuffs")
		slotOptions.FontScale = FontScale("Debuffs")

		local dispelColors = DebuffDispelColors()

		slotOptions.Color = dispelColors and kickEntry.Color or nil
		slotOptions.Border = dispelColors or nil
	end

	entry.KickTimer = kickSlot:Render(container, kickEntry, slotOptions, entry.KickTimer, entry.OnKickExpired)
	entry.KickActive = kickEntry ~= nil

	AnchorDebuffRow(entry)
end

---The entry's one-slot kick container, built the first time a kick is wanted.
---@param entry FrameAurasEntry
---@return IconSlotContainer
local function EnsureKickContainer(entry)
	local container = entry.KickContainer

	if container then
		return container
	end

	local frame = entry.Frame

	container = iconSlotContainer:New(
		frame,
		1,
		KickSize(entry),
		Padding("Debuffs"),
		MASQUE_GROUP,
		nil,
		MASQUE_GROUP
	)
	entry.KickContainer = container
	entry.OnKick = function()
		UpdateKick(entry)
	end
	entry.OnKickExpired = function()
		entry.KickTimer = nil
		UpdateKick(entry, true)
	end

	LayerOverHost(container.Frame, frame)
	PinKick(container.Frame, frame)

	-- Sized off a frame that may not be laid out yet, so the settings pass measures it again.
	entry.Generation = nil

	return container
end

---@param entry FrameAurasEntry
local function ReleaseKick(entry)
	if not entry.KickKey then
		return
	end

	-- Never Unwatch. The tracker keeps no count, so it would end the other modules' subscriptions
	-- on the same token.
	kickTracker:Unsubscribe(entry.KickUnit, entry.KickKey)
	entry.KickKey = nil
	entry.KickUnit = nil
end

---Keeps the entry's kick subscription on the unit it is showing, and drawn or cleared to match.
---@param entry FrameAurasEntry
---@param wanted boolean Whether the debuff row is on show.
local function SyncKick(entry, wanted)
	local unit = entry.Unit

	entry.DebuffsWanted = wanted

	-- A pet never shows one, so its row never has to chain past it.
	if entry.Debuffs and ShowsKicks() and unit and (entry.KickUnit == unit or not units:IsPetOrMinion(unit)) then
		EnsureKickContainer(entry)

		if entry.KickUnit ~= unit then
			ReleaseKick(entry)
			kickTracker:Watch(unit)
			entry.KickUnit = unit
			entry.KickKey = kickTracker:Subscribe(unit, entry.OnKick)
		end
	else
		ReleaseKick(entry)
	end

	local container = entry.KickContainer

	if not container then
		return
	end

	if wanted then
		container.Frame:Show()
	else
		container.Frame:Hide()
	end

	UpdateKick(entry)
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
			Padding(side),
			MASQUE_GROUP,
			nil,
			MASQUE_GROUP
		)
		entry[field] = container
	end

	return container
end

---Wipes the kick stand-in, and only a stand-in. The same container carries a live kick, which a
---refresh must not blank.
---@param entry FrameAurasEntry
local function ClearKickPreview(entry)
	if entry.KickPreviewed then
		entry.KickPreviewed = nil
		entry.KickContainer:ResetAllSlots()
	end
end

---Draws the stand-in for a kick at the head of the debuff preview, or clears it when the row
---would draw none.
---@param entry FrameAurasEntry
---@return table? kickFrame The frame the preview row has to chain after.
local function ApplyKickPreview(entry)
	if not ShowsKicks() then
		ClearKickPreview(entry)

		return nil
	end

	local container = EnsureKickContainer(entry)
	local frame = entry.Frame
	local dispelColors = DebuffDispelColors()

	container:SetIconSize(IconSize(frame, "Debuffs") * LeadScale())
	testSpells:FillContainer(container, { testSpells.FrameAuras.Kick }, 1, {
		ReverseCooldown = ReversesCooldown("Debuffs"),
		HideNumbers = HidesNumbers("Debuffs"),
		Glow = false,
		Border = dispelColors or nil,
		FontScale = FontScale("Debuffs"),
		Count = 1,
	})
	PinKick(container.Frame, frame)
	container.Frame:Show()
	entry.KickPreviewed = true

	return container.Frame
end

---Draws one side's preview, or clears it for a side that is switched off. A row nobody asked for
---draws nothing in play, so it previews nothing either.
---@param entry FrameAurasEntry
---@param side "Buffs"|"Debuffs"
local function ApplyTestSide(entry, side)
	local container = entry[TEST_FIELDS[side]]

	if not active[side] then
		ClearTestRow(container)

		if side == "Debuffs" then
			ClearKickPreview(entry)
		end

		return
	end

	container = EnsureTestContainer(entry, side)

	local frame = entry.Frame
	local grow = Grow(side)
	local flow = growAnchors:GetFlow(grow)
	local containerFrame = container.Frame
	local count = TestIconCount(side)

	container:SetIconSize(IconSize(frame, side))
	-- A container built on an earlier pass keeps the gap it was made with, so the slider only
	-- reaches an existing preview through here.
	container:SetSpacing(Padding(side))
	container:SetCount(count)
	-- Which way a wrapped line stacks, the same answer the live row's flow layout gets.
	container:SetGrowUp(flow.Vertical == "Up")
	container:SetGrowDown(flow.Vertical ~= "Up")
	-- The grid sizes the row to its full column width, so a budget that never reaches one line
	-- would leave the frame wider than the icons in it.
	container:SetColumns(math.min(PerRow(side), count), growAnchors:FillsLeftward(grow))

	local list, leading = TestSpellList(side)

	-- The live row hands its lead debuffs groups of their own so they can be drawn larger, which a
	-- preview row of one container has to reproduce a slot at a time.
	container:SetLeadScale(side == "Debuffs" and leading > 0 and LeadScale() or nil, leading)
	-- The stand-ins have to fold this in themselves, where a live button gets it from the display.
	local centersStacks = CentersStacks(side)
	local hideNumbers = HidesNumbers(side) or centersStacks
	local plainHides = side == "Debuffs" and PlainHidesNumbers()
	local fillOptions = {
		ReverseCooldown = ReversesCooldown(side),
		HideNumbers = hideNumbers or plainHides,
		Glow = false,
		-- Buffs carries no switch for this, and the debuff row's own reaches every stand-in on it.
		ColorByDispelType = side == "Debuffs" and DebuffDispelColors(),
		DispelColors = side == "Debuffs" and testSpells.FrameAuras.DispelColors or nil,
		-- The live buttons round their corners under the ring, so the stand-ins do too.
		Border = side == "Debuffs" and DebuffDispelColors() or nil,
		CenterStackText = centersStacks and PREVIEW_STACK_COUNT or nil,
		FontScale = FontScale(side),
		Stagger = true,
		Count = count,
		Repeat = true,
		LeadCount = leading,
	}
	local nextSlot = testSpells:FillContainer(container, list, 1, fillOptions)

	-- The head of the live row keeps its countdown, so its stand-ins are drawn again with theirs.
	if plainHides and not hideNumbers and leading > 0 then
		fillOptions.HideNumbers = false
		fillOptions.Count = leading
		fillOptions.Repeat = false
		testSpells:FillContainer(container, list, 1, fillOptions)
	end

	for slot = nextSlot, container.Count do
		container:SetSlotUnused(slot)
	end

	-- The same coordinate space and the same corner the live row takes, so the preview stands
	-- exactly where the icons will be.
	LayerOverHost(containerFrame, frame)
	PinRow(containerFrame, frame, side, side == "Debuffs" and ApplyKickPreview(entry) or nil)
	containerFrame:Show()
end

---@param entry FrameAurasEntry
local function ClearTestIcons(entry)
	for _, side in ipairs(SIDES) do
		ClearTestRow(entry[TEST_FIELDS[side]])
	end

	ClearKickPreview(entry)
end

---Hands the lead groups of a built display the current lead size. A display keeps the size its
---groups were declared with.
---@param display AuraContainerDisplay
local function SyncLeadScale(display)
	display:SetGroupSizeScale(LEAD_GROUP_KEYS, LeadScale())
end

---Pushes one side's settings at its display: geometry first, then what the groups may draw.
---@param display AuraContainerDisplay
---@param frame table
---@param side "Buffs"|"Debuffs"
---@param groupKeys string[]
local function ApplySide(display, frame, side, groupKeys)
	display:SetPerLine(PerRow(side))
	display:ApplyConfig(IconSize(frame, side), Padding(side), BuildStyle(side))

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
		AddLateGroup(entry.Debuffs, DEBUFF_CROWD_CONTROL_GROUP, CrowdControlGroup, CrowdControlIcons() > 0)
		AddLateGroup(entry.Debuffs, DEBUFF_DISPEL_GROUP, DispelGroup, SortsDispellableFirst())
		ApplySide(entry.Debuffs, frame, "Debuffs", DEBUFF_GROUP_KEYS)
		SyncLeadScale(entry.Debuffs)

		-- The policy first, since a group asking for a classification the display is not making
		-- matches nothing at all.
		entry.Debuffs:SetProcessingPolicy(ClassifiesDebuffs())

		-- A display already built keeps the group it was created with, so the switch only reaches
		-- the row it is on this way.
		entry.Debuffs:SetGroupColorByDispelTypes(DEBUFF_GROUP_KEYS, DebuffDispelColors())
		entry.Debuffs:SetGroupHideNumbers(DEBUFF_PLAIN_GROUP_KEYS, PlainHidesNumbers())

		-- The boss and role flag is what keeps the leading group apart from the plain group behind
		-- it. Crowd control is kept apart by its own filter string instead.
		local role, rest, crowdControl = DebuffCandidates()

		entry.Debuffs:SetFilterString(DEBUFF_ROLE_GROUP, RoleFilter())
		entry.Debuffs:SetCandidateFilters(DEBUFF_ROLE_GROUP, role)

		if entry.Debuffs:HasGroup(DEBUFF_CROWD_CONTROL_GROUP) then
			entry.Debuffs:SetCandidateFilters(DEBUFF_CROWD_CONTROL_GROUP, crowdControl)
		end

		if entry.Debuffs:HasGroup(DEBUFF_DISPEL_GROUP) then
			entry.Debuffs:SetCandidateFilters(DEBUFF_DISPEL_GROUP, rest)
		end

		-- SyncDispelSplit writes the filter strings, once it sees the settings have moved.
		entry.DispelSplit = nil
		entry.Debuffs:SetCandidateFilters(DEBUFF_GROUP, rest)

		if entry.KickContainer then
			-- The restyle above is refused while auras are secret, so sizing the kick on its own would
			-- leave it at a size the rest of the row never reached.
			SyncKickSize(entry)
			AnchorDebuffRow(entry, true)
		end
	end
end

---Splits the plain group from the dispel group for one entry, or undoes the split.
---
---Outside the visible world the engine may stop weighing the player's dispel token, so the split is
---undone there.
---@param entry FrameAurasEntry
local function SyncDispelSplit(entry)
	local display = entry.Debuffs

	if not display then
		return
	end

	local hasGroup = display:HasGroup(DEBUFF_DISPEL_GROUP)
	local split = hasGroup and SortsDispellableFirst() and entry.Unit ~= nil and units:IsVisible(entry.Unit) == true

	-- Urgent, because a unit out of view emits no aura events.
	if hasGroup then
		display:SetMaxIcons(DEBUFF_DISPEL_GROUP, split and GroupIcons("Debuffs", DEBUFF_DISPEL_GROUP) or 0, true)
	end

	-- The display bounces on every filter write, so only write on a change.
	if entry.DispelSplit == split then
		return
	end

	entry.DispelSplit = split

	if hasGroup then
		display:SetFilterString(DEBUFF_DISPEL_GROUP, DispelFilter())
	end

	display:SetFilterString(DEBUFF_GROUP, PlainFilter(split))
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

	SyncDispelSplit(entry)

	-- A container the client is still tracking weighs every aura on the unit against its groups
	-- whether or not anything is drawn, and a raid is forty frames of that.
	if entry.Buffs then
		local wanted = active.Buffs and occupied
		entry.Buffs:SetEnabled(wanted)
		entry.Buffs:SetShown(wanted)
	end

	local debuffsWanted = active.Debuffs and occupied

	if entry.Debuffs then
		entry.Debuffs:SetEnabled(debuffsWanted)
		entry.Debuffs:SetShown(debuffsWanted)
	end

	SyncKick(entry, debuffsWanted)
end

---The entry for a frame, built the first time the frame is seen. A side switched on after the entry
---exists gets its display then, and one switched off keeps it, because the engine can free neither
---display nor the buttons under it.
---@param frame table
---@param occupantMoved boolean? A new player may be behind the token the frame already holds.
---@return FrameAurasEntry?
local function EnsureEntry(frame, occupantMoved)
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
	elseif entry.Unit ~= unit or occupantMoved then
		entry.Unit = unit

		for _, side in ipairs(SIDES) do
			local display = entry[side]

			if display then
				display:SetUnit(unit or "none")

				-- Urgent, because a roster reshuffled mid-fight has no aura event coming that would
				-- clear the last player's icons.
				if unit then
					display:RequestRefresh()
				end
			end
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
---@param occupantMoved boolean?
local function ApplyToFrame(frame, occupantMoved)
	local entry = EnsureEntry(frame, occupantMoved)

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
	local occupantMoved = occupantsMoved

	occupantsMoved = false

	for _, frame in ipairs(BlizzardFrames()) do
		ApplyToFrame(frame, occupantMoved)

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

---Queues a walk that makes every frame re-read its unit, whether or not the token moved.
local function QueueOccupantPass()
	occupantsMoved = true
	QueueApplyToAll()
end

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
	eventsFrame:SetScript("OnEvent", QueueOccupantPass)

	-- A frame passed over for having nobody on it gets no set-unit call of its own when someone
	-- turns up under a token it was already holding, so the roster is what says to look again.
	-- With both sides off there is nothing here to do, so a disabled module pays for no dispatch.
	--
	-- The loading screen ending is in there because building needs a definite answer about who is
	-- on a frame, and the client gives none while one is up. This is the pass that builds what the
	-- world-entering pass had to skip.
	--
	-- Every one of them can also seat a new player behind a token a frame keeps.
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
		-- the display on its own, so every re-point queues a walk that treats it as a new unit.
		OnSetUnit = function(frame)
			if AnySideActive() then
				ApplyToFrame(frame)
				QueueOccupantPass()
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
	roleDebuffCandidates = nil
	restDebuffCandidates = nil
	crowdControlDebuffCandidates = nil

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
---@field DispelSplit boolean? Whether the plain filter last left out what the player can dispel.
---@field KickContainer IconSlotContainer? One slot for the kick icon leading the debuff row.
---@field KickKey number? The kick tracker subscription, nil while none is held.
---@field KickUnit string? The token that subscription is on.
---@field KickTimer table? Clears the kick icon when its lockout ends.
---@field KickActive boolean? Whether a kick icon is showing.
---@field KickAnchored boolean? Whether the debuff row was last placed after the kick icon.
---@field KickPreviewed boolean? Whether the kick container holds a test stand-in.
---@field DebuffsWanted boolean? Whether the debuff row is on show.
---@field OnKick fun()? The subscription callback, built once.
---@field OnKickExpired fun()? The expiry callback, built once.

