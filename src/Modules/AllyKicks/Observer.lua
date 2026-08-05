---@type string, Addon
local _, addon = ...
local unitUtil = addon.Utils.Units

addon.Modules.AllyKicks = addon.Modules.AllyKicks or {}

-- The two halves of a cast ending early. Neither names the interrupter in anything we are allowed
-- to read, but the GUID they carry still resolves to a name the client will let us draw.
local INTERRUPT_EVENTS = { "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_STOP" }
-- Only nameplates are watched. The client reports one interrupt under every token the mob holds -
-- its nameplate, your target, your soft target - and nothing shared between those tokens can be
-- read to tell the repeats apart: the cast GUID and the mob's own GUID are both secret inside an
-- instance, so neither can be compared or used as a key. One token per mob is the only dedup
-- left, and the nameplate is the one every enemy worth showing has.
local NAMEPLATE_PREFIX = "^nameplate"
-- A mob just seen kicked ignores further reports for this long, since the repeats above arrive
-- spread out rather than all in one frame.
local REPEAT_WINDOW = 0.5
-- Past this the oldest row goes. More than a screenful is not worth keeping around.
local MAX_RECORDS = 10

---@type AllyKickRecord[]
local records = {}
-- When each mob's last interrupt was recorded, which is what the repeats are measured against.
---@type table<string, number>
local lastRecordedAt = {}
local recordDuration = 15
local watching = false
local debugEnabled = false
local interruptFrame
---@type fun()?
local recordCallback

---@class AllyKickObserver
local M = {}
addon.Modules.AllyKicks.Observer = M

---@param fmt string
local function DebugLog(fmt, ...)
	if debugEnabled then
		addon.Framework:Notify("[Kicks] " .. fmt, ...)
	end
end

---Describes a value for the log without reading it: a secret cannot be compared or concatenated,
---and tostring on one can throw.
---@param value any
---@return string
local function Describe(value)
	if value == nil then
		return "nil"
	end

	return issecretvalue(value) and "secret" or tostring(value)
end

---@param event string
---@param unit string  the unit whose cast was cut short
---@param interruptedSpellId number?  secret when the spell is an enemy's
---@param interruptedBy string?  GUID of the interrupter, secret inside an instance
local function OnInterrupted(event, unit, interruptedSpellId, interruptedBy)
	-- Both events also fire for a cast that merely ended - a channel running its course, a cast
	-- its owner cancelled - and those arrive constantly in a dungeon. The interrupter field is
	-- what separates a real kick from one of those; it is tested for nil, never read.
	if interruptedBy == nil then
		return
	end

	if not unit or not unit:find(NAMEPLATE_PREFIX) then
		return
	end

	-- Allies get interrupted too, and their attacker's kick is nothing to do with our group.
	if not unitUtil:CanAttack(unit) then
		return
	end

	local now = GetTime()
	local last = lastRecordedAt[unit]

	if last and (now - last) <= REPEAT_WINDOW then
		return
	end

	lastRecordedAt[unit] = now

	-- All four are secret inside an instance. Handing a secret to these is fine - they take one
	-- and hand a secret back. What is not fine is reading the answer, so none of it is compared
	-- or used as a table key: each goes straight to the widget setter that knows how to take one.
	-- That is the whole trick - the kicker cannot be identified, but they can be drawn.
	local name = UnitNameFromGUID(interruptedBy)
	local _, class = UnitClassFromGUID(interruptedBy)
	local icon = C_Spell.GetSpellTexture(interruptedSpellId)
	local marker = GetRaidTargetIndex(unit)

	records[#records + 1] = {
		Name = name,
		Class = class,
		Icon = icon,
		Marker = marker,
		ExpireAt = now + recordDuration,
		Duration = recordDuration,
	}

	while #records > MAX_RECORDS do
		table.remove(records, 1)
	end

	DebugLog("%s on %s: name=%s class=%s icon=%s marker=%s", event:gsub("UNIT_SPELLCAST_", ""),
		tostring(unit), Describe(name), Describe(class), Describe(icon), Describe(marker))

	if recordCallback then
		recordCallback()
	end
end

---The watcher is unit-agnostic - any enemy in the world can be the one interrupted - so it is one
---frame listening broadly rather than one per roster slot.
---@param active boolean
local function SetInterruptWatchActive(active)
	if not interruptFrame then
		interruptFrame = CreateFrame("Frame")
		interruptFrame:SetScript("OnEvent", function(_, event, unit, _, spellId, interruptedBy)
			OnInterrupted(event, unit, spellId, interruptedBy)
		end)
	end

	for _, event in ipairs(INTERRUPT_EVENTS) do
		if active then
			interruptFrame:RegisterEvent(event)
		else
			interruptFrame:UnregisterEvent(event)
		end
	end
end

-- Public

---Registers a function to call whenever an interrupt is recorded, which is what a consumer wakes
---its refresh loop on.
---@param fn fun()
function M:SetRecordCallback(fn)
	recordCallback = fn
end

---The interrupts seen recently, oldest first. The table is the observer's own and is rebuilt in
---place, so callers must not hold onto it across a prune.
---@return AllyKickRecord[]
function M:GetRecords()
	return records
end

---How long a row stays on screen. The kicker's own cooldown cannot be used here: identifying them
---is exactly what is not allowed, so neither their class nor which interrupt they pressed is known.
---@param seconds number
function M:SetRecordDuration(seconds)
	recordDuration = seconds
end

---Drops the rows whose lifetime has run out. True when the list actually changed, which is what
---tells the caller to re-lay-out rather than merely repaint.
---@param now number
---@return boolean
function M:Prune(now)
	local removed = false

	for index = #records, 1, -1 do
		if records[index].ExpireAt <= now then
			table.remove(records, index)
			removed = true
		end
	end

	return removed
end

---Drops every row, e.g. when a match starts and the last zone's kicks stop being interesting.
function M:Clear()
	wipe(records)
	wipe(lastRecordedAt)
end

---Turns the interrupt log on or off. Every recorded kick is reported while it is on, which is the
---only way to see whether the events arrive at all.
---@param value boolean
---@return boolean
function M:SetDebugging(value)
	debugEnabled = value and true or false

	return debugEnabled
end

---@return boolean
function M:IsDebugging()
	return debugEnabled
end

---True once the watcher is live, which it is not while the module is disabled.
---@return boolean
function M:IsWatching()
	return watching
end

function M:Start()
	if watching then
		return
	end

	watching = true
	SetInterruptWatchActive(true)
end

function M:Stop()
	if not watching then
		return
	end

	watching = false
	SetInterruptWatchActive(false)
	self:Clear()
end

---One interrupt seen. Every field but the timings can be a secret value: they are only ever handed
---to a widget setter, never read, compared or used as a key.
---@class AllyKickRecord
---@field Name string?  the kicker's name
---@field Class string?  the kicker's class token
---@field Icon string|number|nil  the interrupted spell's texture
---@field Marker number?  raid target index of the mob whose cast was cut short
---@field ExpireAt number  when the row leaves the list
---@field Duration number  how long the row was given, so the bar can drain over it
