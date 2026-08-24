---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx
local kickData = addon.Core.KickData
local kickEvents = addon.Core.KickEvents
local GetTime = GetTime

local KICK_ICON = C_Spell.GetSpellTexture(1766) -- fallback: rogue Kick

local DEFAULT_KICK_DURATION = 3
local PLAYER_KICK_TOLERANCE = 0.15

local KICK_COLOR = { r = 1.0, g = 0.2, b = 0.2 }

-- Set when the local player successfully casts a kick spell; consumed by the first interrupt that
-- fires within PLAYER_KICK_TOLERANCE seconds, replacing the default icon with the player's own spell.
local pendingPlayerKick = nil -- { Texture, Duration, Time, Timer }

---@type table<string, KickUnitData>
local tracked = {}
-- Event frames by token, kept past Unwatch. Frames can never be freed, and the nameplate tokens
-- churn constantly, so a plate leaving and coming back as the camera turns would otherwise orphan
-- one frame per cycle, for the whole session.
---@type table<string, table>
local eventFrames = {}
-- The inferred ally kick, snapshotted: the party's interrupt set only moves on roster and spec
-- changes, while one mob's interrupt fires once per token watching it, and a spec lookup can
-- fall through to a tooltip scan. Spec answers can also improve through channels with no event
-- at all (another addon's inspector), so the snapshot expires on its own as a backstop.
local ALLY_KICK_SNAPSHOT_TTL = 30
-- One timestamp carries the staleness: minus infinity forces a rebuild, so the event
-- invalidations and the TTL expiry funnel through the same gate.
local allyKickBuiltAt = -math.huge
local allyKickTexture = KICK_ICON
local allyKickDuration = DEFAULT_KICK_DURATION
-- The spec-change callback can only be hooked up lazily: the Inspector loads after this file.
local specCallbackRegistered = false

---@class KickTracker
local M = {}
addon.Core.KickTracker = M

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
	if GetTime() - allyKickBuiltAt < ALLY_KICK_SNAPSHOT_TTL then
		return allyKickTexture, allyKickDuration
	end

	if not specCallbackRegistered then
		local inspector = addon.Core.Inspector
		if inspector then
			specCallbackRegistered = true
			inspector:RegisterCallback(function()
				allyKickBuiltAt = -math.huge
			end)
		end
	end

	allyKickBuiltAt = GetTime()
	allyKickTexture = KICK_ICON
	allyKickDuration = DEFAULT_KICK_DURATION

	local onlySpellId
	local candidateCount = 0
	for i = 1, 4 do
		local unit = "party" .. i
		if UnitExists(unit) then
			local spellId = GetAllyInterruptSpellId(unit)
			if spellId then
				candidateCount = candidateCount + 1
				onlySpellId = spellId
			end
		end
	end

	if candidateCount == 1 then
		local texture = C_Spell.GetSpellTexture(onlySpellId)

		-- Spell art can lag the login; stay stale so the next ask retries the lookup.
		if not texture then
			allyKickBuiltAt = -math.huge
		end

		allyKickTexture = texture or KICK_ICON
		allyKickDuration = kickData.SpellLockoutDuration[onlySpellId] or DEFAULT_KICK_DURATION
	end

	return allyKickTexture, allyKickDuration
end

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

	-- The duration object, the slot containers, and KickSlot's expiry timer all read the
	-- GetTime clock, so the entry has to be stamped on that one.
	local startTime = GetTime()
	data.Entry = {
		Texture = texture,
		DurationObject = wowEx:CreateDuration(startTime, duration),
		Color = KICK_COLOR,
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

	local texture = KICK_ICON
	local duration = DEFAULT_KICK_DURATION

	-- UnitIsEnemy covers duel opponents, arena and battleground enemies, and MC'd allies, which is
	-- every case where the local player or an ally could be the interrupter. When the interrupted
	-- unit is a genuine teammate an enemy did the kicking, so the generic rogue icon stands in.
	if UnitIsEnemy(unitToken, "player") then
		local pending = pendingPlayerKick
		if pending and (GetTime() - pending.Time) <= PLAYER_KICK_TOLERANCE then
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

	if kickEvents:IsStart(event) then
		data.Kicked = false
		return
	end

	local kickedBy = kickEvents:GetInterrupter(event, ...)
	if kickedBy then
		OnInterrupted(unitToken)
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
			local remaining = (otherData.Entry.StartTime + otherData.Entry.Duration) - GetTime()
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

-- One handler for every token's frame. A closure per Watch would be an allocation for every
-- plate that spawns, and the frames outlive the watch that made them.
local function OnFrameEvent(frame, event, ...)
	local resetEvents = frame.ResetEvents

	if resetEvents and resetEvents[event] then
		OnResetEvent(frame.UnitToken)
		return
	end

	OnUnitEvent(frame.UnitToken, event, ...)
end

---Brings a frame's caller-supplied reset events in line with what this Watch asks for. They stay
---registered between watches like the cast events, and a token is asked for the same set every
---time in practice, so this usually finds nothing to do.
---@param frame table
---@param resetEvents string[]?
local function SyncResetEvents(frame, resetEvents)
	local current = frame.ResetEvents
	local wanted = nil

	if resetEvents and #resetEvents > 0 then
		wanted = {}

		for _, event in ipairs(resetEvents) do
			wanted[event] = true
		end
	end

	if current then
		for event in pairs(current) do
			if not (wanted and wanted[event]) then
				frame:UnregisterEvent(event)
			end
		end
	end

	if wanted then
		for event in pairs(wanted) do
			if not (current and current[event]) then
				frame:RegisterEvent(event)
			end
		end
	end

	frame.ResetEvents = wanted
end

---Start tracking interrupts for a unit.
---@param unitToken string
---@param resetEvents string[]? WoW events that immediately clear the kick entry (e.g. PLAYER_TARGET_CHANGED)
---@return boolean started False when this unit was already being watched, so a caller only
---subscribes once per token however often it re-registers.
function M:Watch(unitToken, resetEvents)
	if tracked[unitToken] then
		return false
	end

	local frame = eventFrames[unitToken]

	if not frame then
		frame = CreateFrame("Frame")
		frame.UnitToken = unitToken
		frame:SetScript("OnEvent", OnFrameEvent)

		-- Registered once and never taken back. RegisterUnitEvent binds to the token, so the
		-- registration nameplate3 was given still fits whoever holds nameplate3 next, and both
		-- handlers drop an event for a token nothing is watching.
		for _, event in ipairs(kickEvents.StartEvents) do
			frame:RegisterUnitEvent(event, unitToken)
		end

		for _, event in ipairs(kickEvents.StopEvents) do
			frame:RegisterUnitEvent(event, unitToken)
		end

		eventFrames[unitToken] = frame
	end

	SyncResetEvents(frame, resetEvents)

	tracked[unitToken] = {
		Entry = nil,
		EntryTimer = nil,
		Kicked = false,
		Callbacks = {},
		NextKey = 1,
	}

	return true
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

	-- The frame keeps its registrations and goes quiet on its own, since both handlers return for
	-- a token nothing is watching. UnregisterAllEvents walks the client's whole registry, and
	-- paying that per plate that despawned cost more than everything else here put together.
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
-- rogue-kick icon with the player's actual spell icon and lockout duration. The same frame hears
-- the roster and spec events that stale the inferred-ally-kick snapshot.
local playerKickFrame = CreateFrame("Frame") -- luaconv: its handler calls functions defined above
playerKickFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
playerKickFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
playerKickFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
playerKickFrame:SetScript("OnEvent", function(_, event, _, _, spellId)
	if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_SPECIALIZATION_CHANGED" then
		allyKickBuiltAt = -math.huge
		return
	end

	local duration = kickData.SpellLockoutDuration[spellId]
	if not duration then
		return
	end

	local texture = C_Spell.GetSpellTexture(spellId) or KICK_ICON

	if pendingPlayerKick and pendingPlayerKick.Timer then
		pendingPlayerKick.Timer:Cancel()
	end

	local pending = { Texture = texture, Duration = duration, Time = GetTime() }
	pending.Timer = C_Timer.NewTimer(PLAYER_KICK_TOLERANCE, function()
		if pendingPlayerKick == pending then
			pendingPlayerKick = nil
		end
	end)
	pendingPlayerKick = pending
end)

---@class KickEntry
---@field Texture string
---@field DurationObject table
---@field Color table
---@field StartTime number
---@field Duration number

---@class KickUnitData

---@field Entry KickEntry?
---@field EntryTimer table?
---@field Kicked boolean
---@field Callbacks table<number, function>
---@field NextKey number
