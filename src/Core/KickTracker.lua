---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx
local kickData = addon.Core.KickData
local GetTimePreciseSec = GetTimePreciseSec

local kickIcon = C_Spell.GetSpellTexture(1766) -- fallback: rogue Kick

local defaultKickDuration = 3
local playerKickTolerance = 0.15

local kickColor = { r = 1.0, g = 0.2, b = 0.2 }

-- Set when the local player successfully casts a kick spell; consumed by the first interrupt that
-- fires within playerKickTolerance seconds, replacing the default icon with the player's own spell.
local pendingPlayerKick = nil -- { Texture, Duration, Time, Timer }

-- Returns the interrupt spell ID for a party unit, using spec if known, class otherwise.
-- Returns nil if the unit has no interrupt or can't be determined.
local function GetAllyInterruptSpellId(unit)
	local specId = addon.Core.InspectorFacade:GetUnitSpecId(unit)
	if specId and specId > 0 then
		local specData = kickData.SpecData[specId]
		if specData then
			return specData.SpellId
		end
	end
	local _, classToken = UnitClass(unit)
	return classToken and kickData.ClassInterruptSpell[classToken]
end

-- When the local player did not cast the interrupt, infer which ally kicked.
-- Returns texture, duration. Falls back to the generic rogue icon when ambiguous.
local function InferAllyKick()
	local candidates = {}
	for i = 1, 4 do
		local unit = "party" .. i
		if UnitExists(unit) then
			local spellId = GetAllyInterruptSpellId(unit)
			if spellId then
				candidates[#candidates + 1] = spellId
			end
		end
	end

	if #candidates == 1 then
		local spellId = candidates[1]
		local texture = C_Spell.GetSpellTexture(spellId) or kickIcon
		local duration = kickData.SpellLockoutDuration[spellId] or defaultKickDuration
		return texture, duration
	end

	return kickIcon, defaultKickDuration
end

---@class KickEntry
---@field Texture string
---@field DurationObject table
---@field Color table
---@field StartTime number
---@field Duration number

---@class KickUnitData
---@field EventFrame table
---@field Entry KickEntry?
---@field EntryTimer table?
---@field Kicked boolean
---@field Callbacks table<number, function>
---@field NextKey number

---@type table<string, KickUnitData>
local tracked = {}

---@class KickTracker
local M = {}
addon.Core.KickTracker = M

local function FireCallbacks(data)
	for _, fn in pairs(data.Callbacks) do
		fn()
	end
end

local function CreateEntry(unitToken, texture, duration)
	local data = tracked[unitToken]
	if not data then
		return
	end

	if data.EntryTimer then
		data.EntryTimer:Cancel()
		data.EntryTimer = nil
	end

	local startTime = GetTimePreciseSec()
	data.Entry = {
		Texture = texture,
		DurationObject = wowEx:CreateDuration(startTime, duration),
		Color = kickColor,
		StartTime = startTime,
		Duration = duration,
	}
	data.EntryTimer = C_Timer.NewTimer(duration, function()
		data.Entry = nil
		data.EntryTimer = nil
		FireCallbacks(data)
	end)

	FireCallbacks(data)
end

local function OnInterrupted(unitToken)
	local data = tracked[unitToken]
	if not data then
		return
	end

	-- Anti-double-trigger: UNIT_SPELLCAST_INTERRUPTED and UNIT_SPELLCAST_CHANNEL_STOP can
	-- both fire for the same interrupt; only process the first one.
	if data.Kicked then
		return
	end
	data.Kicked = true

	local texture = kickIcon
	local duration = defaultKickDuration

	-- InferAllyKick looks at friendly party member specs to guess who kicked the enemy.
	-- It must not run when the interrupted unit is friendly — in that case an enemy did the
	-- kicking and party specs are irrelevant, so we just show the generic rogue icon.
	if not UnitIsFriend(unitToken, "player") then
		local pending = pendingPlayerKick
		if pending and (GetTimePreciseSec() - pending.Time) <= playerKickTolerance then
			texture = pending.Texture
			duration = pending.Duration
		else
			texture, duration = InferAllyKick()
		end
	end

	CreateEntry(unitToken, texture, duration)
end

local function OnUnitEvent(unitToken, event, ...)
	local data = tracked[unitToken]
	if not data then
		return
	end

	if event == "UNIT_SPELLCAST_START"
		or event == "UNIT_SPELLCAST_CHANNEL_START"
		or event == "UNIT_SPELLCAST_EMPOWER_START"
	then
		data.Kicked = false
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		local kickedBy = select(4, ...)
		if kickedBy then
			OnInterrupted(unitToken)
		end
	elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
		-- interruptedBy is arg 5 (arg 4 is "complete")
		local kickedBy = select(5, ...)
		if kickedBy then
			OnInterrupted(unitToken)
		end
	end
end

local function OnResetEvent(unitToken)
	local data = tracked[unitToken]
	if not data then
		return
	end

	data.Kicked = false

	if data.EntryTimer then
		data.EntryTimer:Cancel()
		data.EntryTimer = nil
	end

	-- When a dynamic token (target/focus) changes, the new unit may already have an active
	-- interrupt tracked under a different token (e.g. a nameplate token). Sync it over.
	for otherToken, otherData in pairs(tracked) do
		if otherToken ~= unitToken and otherData.Entry and UnitIsUnit(otherToken, unitToken) then
			local remaining = (otherData.Entry.StartTime + otherData.Entry.Duration) - GetTimePreciseSec()
			if remaining > 0 then
				data.Entry = otherData.Entry
				data.EntryTimer = C_Timer.NewTimer(remaining, function()
					data.Entry = nil
					data.EntryTimer = nil
					FireCallbacks(data)
				end)
				FireCallbacks(data)
				return
			end
			break
		end
	end

	if data.Entry then
		data.Entry = nil
		FireCallbacks(data)
	end
end

---Start tracking interrupts for a unit.
---@param unitToken string
---@param resetEvents string[]? WoW events that immediately clear the kick entry (e.g. PLAYER_TARGET_CHANGED)
function M:Watch(unitToken, resetEvents)
	if tracked[unitToken] then
		return
	end

	local data = {
		EventFrame = CreateFrame("Frame"),
		Entry = nil,
		EntryTimer = nil,
		Kicked = false,
		Callbacks = {},
		NextKey = 1,
	}
	tracked[unitToken] = data

	local resetSet = {}
	if resetEvents then
		for _, event in ipairs(resetEvents) do
			resetSet[event] = true
		end
	end

	local frame = data.EventFrame
	frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unitToken)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", unitToken)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", unitToken)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unitToken)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", unitToken)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", unitToken)

	for event in pairs(resetSet) do
		frame:RegisterEvent(event)
	end

	frame:SetScript("OnEvent", function(_, event, ...)
		if resetSet[event] then
			OnResetEvent(unitToken)
		else
			OnUnitEvent(unitToken, event, ...)
		end
	end)
end

---Stop tracking a unit and clear any active entry.
---@param unitToken string
function M:Unwatch(unitToken)
	local data = tracked[unitToken]
	if not data then
		return
	end

	if data.EntryTimer then
		data.EntryTimer:Cancel()
	end

	data.EventFrame:UnregisterAllEvents()
	data.EventFrame:SetScript("OnEvent", nil)
	tracked[unitToken] = nil
end

---@param unitToken string
---@return KickEntry?
function M:GetKick(unitToken)
	local data = tracked[unitToken]
	return data and data.Entry or nil
end

---Register a callback fired when a kick entry is added or removed for this unit.
---@param unitToken string
---@param fn function
---@return number key Opaque key for Unsubscribe
function M:Subscribe(unitToken, fn)
	local data = tracked[unitToken]
	if not data then
		return 0
	end

	local key = data.NextKey
	data.NextKey = key + 1
	data.Callbacks[key] = fn
	return key
end

---@param unitToken string
---@param key number
function M:Unsubscribe(unitToken, key)
	local data = tracked[unitToken]
	if data then
		data.Callbacks[key] = nil
	end
end

-- Track when the local player successfully casts an interrupt spell so we can replace the default
-- rogue-kick icon with the player's actual spell icon and lockout duration.
local playerKickFrame = CreateFrame("Frame")
playerKickFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
playerKickFrame:SetScript("OnEvent", function(_, _, _, _, spellId)
	local duration = kickData.SpellLockoutDuration[spellId]
	if not duration then
		return
	end

	local texture = C_Spell.GetSpellTexture(spellId) or kickIcon

	if pendingPlayerKick and pendingPlayerKick.Timer then
		pendingPlayerKick.Timer:Cancel()
	end

	local pending = { Texture = texture, Duration = duration, Time = GetTimePreciseSec() }
	pending.Timer = C_Timer.NewTimer(playerKickTolerance, function()
		if pendingPlayerKick == pending then
			pendingPlayerKick = nil
		end
	end)
	pendingPlayerKick = pending
end)
