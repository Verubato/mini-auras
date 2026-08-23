---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local eventGate = addon.Core.EventGate
local frames = addon.Core.Frames
local pixels = addon.Core.Pixels
local classBuffs = addon.Core.ClassBuffs

-- Marks a party or raid frame whose member is missing the group buff the player's own class
-- brings. The mark is the buff's own icon drained of colour, so it reads as absent rather than as
-- one more thing that is up.

local FALLBACK_ICON_SIZE = 14
-- Trims the silver frame baked into the spell art, so the icon reaches the mark's own edge.
local ICON_CROP = 0.08
local DEFAULT_SIZE_PERCENT = 35
-- Which corner the mark sits in, and how far in from it. Fixed rather than a setting: the mark
-- stands in for something the game would have drawn itself, so the corner is the frame's answer
-- rather than the player's. Top right is the one Blizzard leaves free on a compact frame.
local ANCHOR = "TOPRIGHT"
local OFFSET_X = -2
local OFFSET_Y = -2

addon.Modules.FrameAuras = addon.Modules.FrameAuras or {}

---@class FrameAurasClassBuff
local M = {}

addon.Modules.FrameAuras.ClassBuff = M

local active = false
-- The buff the player brings, or nil for a class that brings none. Fixed for the session: a
-- character's class does not change.
local playerBuff
-- Compact frame -> its mark. Frames are created once and reused, so an entry lives as long as the
-- session does; there is nothing to clear.
local marks = {}
-- Unit token -> the frames showing it, so UNIT_AURA does not walk forty frames to find one. The
-- main tank and assist frames can show a unit a second time, so this is a set per token.
local framesByUnit = {}
-- What each frame was last pointed at, so it can be taken out of that token's set when it moves.
local unitByFrame = {}
---@type EventGate?
local watcher
local eventsFrame
local hooked = false
-- Refilled per pass rather than built per pass: the frame list is asked for on every refresh.
local frameScratch = {}

---@return FrameAurasClassBuffOptions?
local function Options()
	local db = mini:GetSavedVars()

	return db and db.Modules and db.Modules.FrameAurasModule
		and db.Modules.FrameAurasModule.ClassBuff or nil
end

---Blizzard's own party and raid member frames, and nothing else. Refilled in place.
---@return table[]
local function BlizzardFrames()
	for index = #frameScratch, 1, -1 do
		frameScratch[index] = nil
	end

	if wowEx:IsDandersEnabled() then
		return frameScratch
	end

	frames:BlizzardFrames(false, frameScratch)
	frames:BlizzardPartyFrames(false, frameScratch)

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

---Files a frame under the token it is showing now, taking it out of whatever it was under before.
---@param frame table
---@param unit string?
local function Index(frame, unit)
	local previous = unitByFrame[frame]

	if previous == unit then
		return
	end

	if previous and framesByUnit[previous] then
		framesByUnit[previous][frame] = nil
	end

	unitByFrame[frame] = unit

	if not unit then
		return
	end

	framesByUnit[unit] = framesByUnit[unit] or {}
	framesByUnit[unit][frame] = true
end

---The player's own class buff, worked out once.
---@return ClassBuff?
local function PlayerBuff()
	local _, class = UnitClass("player")

	return class and classBuffs[class] or nil
end

---Whether a unit is a group member worth marking. Pets never get a class buff, and a frame with
---nobody on it has nothing to be missing.
---@param unit string?
---@return boolean
local function IsMarkable(unit)
	if not unit then
		return false
	end

	if unit:find("pet", 1, true) then
		return false
	end

	if not (unit == "player" or unit:match("^party%d+$") or unit:match("^raid%d+$")) then
		return false
	end

	local exists = UnitExists(unit)

	if mini:IsSecret(exists) or exists ~= true then
		return false
	end

	-- Nothing to remind anyone about until they are back up.
	return not (UnitIsDeadOrGhost and UnitIsDeadOrGhost(unit))
end

---Whether the unit already has the buff. Three answers, not two: the client hides aura data
---outright while a match or a key is running, and a "no" it never actually gave would put a mark on
---every frame in the group. Unknown reads the same as having it.
---
---Asked once for the whole client rather than per spell. The per-spell exemption is an enum whose
---name is not something to guess at, and branching on an aura the client answered secretly is what
---aborts a handler outright - so while auras are secret this says nothing at all. A group buff is
---cast before the pull, which is exactly where the answer is readable.
---@param unit string
---@return boolean? nil when the client will not say
local function HasBuff(unit)
	if not C_UnitAuras or not C_UnitAuras.GetUnitAuraBySpellID then
		return nil
	end

	if C_Secrets and C_Secrets.ShouldAurasBeSecret and C_Secrets.ShouldAurasBeSecret() then
		return nil
	end

	for spellId in pairs(playerBuff.Auras) do
		if C_UnitAuras.GetUnitAuraBySpellID(unit, spellId) then
			return true
		end
	end

	return false
end

---Builds a frame's mark the first time it needs one. Nothing is built for a frame that has never
---been missing the buff, which in a buffed group is all of them.
---@param frame table
---@return table
local function EnsureMark(frame)
	local mark = marks[frame]

	if mark then
		return mark
	end

	mark = CreateFrame("Frame", nil, frame)

	local icon = mark:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(mark)
	icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
	icon:SetTexture(C_Spell.GetSpellTexture(playerBuff.Icon) or "")
	icon:SetDesaturated(true)

	mark.Icon = icon
	mark:Hide()

	marks[frame] = mark

	return mark
end

---@param mark table
---@param frame table
local function Place(mark, frame)
	local options = Options()

	if not options then
		return
	end

	local size = pixels:ShareOfHeight(frame, options.Size or DEFAULT_SIZE_PERCENT, FALLBACK_ICON_SIZE)

	mark:SetSize(size, size)
	mark:ClearAllPoints()
	mark:SetPoint(ANCHOR, frame, ANCHOR, OFFSET_X, OFFSET_Y)
end

---@param frame table
local function ApplyToFrame(frame)
	if not frame or mini:IsSecret(frame) then
		return
	end

	local mark = marks[frame]

	if not active or not playerBuff then
		if mark then
			mark:Hide()
		end

		return
	end

	local unit = UnitFor(frame)

	Index(frame, unit)

	if not IsMarkable(unit) or HasBuff(unit) ~= false then
		if mark then
			mark:Hide()
		end

		return
	end

	mark = EnsureMark(frame)

	Place(mark, frame)
	mark:Show()
end

local function ApplyToAll()
	for _, frame in ipairs(BlizzardFrames()) do
		ApplyToFrame(frame)
	end
end

---@param unit string?
local function ApplyToUnit(unit)
	local set = unit and framesByUnit[unit]

	if not set then
		return
	end

	for frame in pairs(set) do
		ApplyToFrame(frame)
	end
end

---@return EventGate
local function Watcher()
	if watcher then
		return watcher
	end

	-- Gated rather than switched off inside the handler: UNIT_AURA is the busiest event the client
	-- has, and this is optional, so a player who never turns it on should not pay for the dispatch.
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, unit)
		-- The aura event names the unit it is about, so a raid of forty is not re-checked because
		-- one person got a buff.
		if event == "UNIT_AURA" then
			ApplyToUnit(unit)

			return
		end

		ApplyToAll()
	end)

	watcher = eventGate:New(eventsFrame, { "UNIT_AURA", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" })

	return watcher
end

---The frame hooks, which cannot be taken off again, so each gates itself on the mark being on.
local function InstallHooks()
	if hooked then
		return
	end

	hooked = true

	frames:InstallUnitFrameHooks(eventsFrame, {
		OnSetUnit = function(frame)
			if active then
				ApplyToFrame(frame)
			end
		end,
		OnUpdateVisible = function(frame)
			if active then
				ApplyToFrame(frame)
			end
		end,
		OnSorted = function()
			if active then
				ApplyToAll()
			end
		end,
		OnVisibilityChanged = function()
			if active then
				ApplyToAll()
			end
		end,
	})
end

---Re-reads the setting and marks every frame that needs it, or clears the lot when it has been
---switched off.
function M:Refresh()
	local options = Options()

	if not options then
		return
	end

	active = options.Enabled == true

	if active and not playerBuff then
		playerBuff = PlayerBuff()
	end

	-- The watcher owns the event frame the hooks are installed against, so it comes first.
	Watcher():SetActive(active)

	if active then
		InstallHooks()
	end

	ApplyToAll()
end
