---@type string, Addon
local _, addon = ...
local kickData = addon.Core.KickData
local kickEvents = addon.Core.KickEvents
local inspectorFacade = addon.Core.InspectorFacade
local unitUtil = addon.Utils.Units

addon.Modules.AllyKickTracker = addon.Modules.AllyKickTracker or {}

-- Our own casts, which unlike anybody else's arrive with a spell ID we are allowed to read. That
-- is the whole reason the player can have a readiness bar when nobody else can.
local CAST_EVENT = "UNIT_SPELLCAST_SUCCEEDED"
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
-- How long a history row stays on screen. The kicker's own cooldown cannot be used: identifying
-- them is exactly what is not allowed, so neither their class nor which interrupt they pressed is
-- known. This is a display lifetime and nothing more.
local RECORD_DURATION = 15
-- Anything shorter is the global cooldown rather than the interrupt's own.
local MIN_REPORTED_COOLDOWN = 2
-- Stand-in for an interrupt with no cooldown in the spec data. Every one in the game is at least
-- this long.
local DEFAULT_COOLDOWN = 15
-- Warlocks press Spell Lock on the pet, so the cast arrives on the pet token. Which of the three
-- IDs it reports depends on how it was pressed: the pet bar, the player-side Command Demon, or
-- the felhunter's own ability.
local WARLOCK_PET_SPELL_ID = 132409
local WARLOCK_SPELL_LOCK_IDS = { 132409, 119910, 19647 }

-- Every interrupt MiniAuras knows about, so the player's cast is recognised even before their spec is.
---@type table<number, boolean>
local INTERRUPT_SPELL_IDS = {}
-- The cooldown to assume while the spec is unknown. Specs that share an interrupt do not always
-- share its cooldown (Wind Shear is 12s for Elemental and 30s for Restoration), and calling a kick
-- ready early is worse than calling it ready late, so the longest one wins.
---@type table<number, number>
local FALLBACK_COOLDOWNS = {}

---@type AllyKickRecord[]
local records = {}
-- When each mob's last interrupt was recorded, which is what the repeats are measured against.
---@type table<string, number>
local lastRecordedAt = {}
-- The player's own row, which is a readiness bar rather than a history entry: it stays put and
-- counts down, because their own name, class, interrupt and cooldown are all readable.
---@type AllyKickRecord?
local ownRecord
local watching = false
local interruptFrame
local castFrame
---@type fun()?
local recordCallback

---@class AllyKickObserver
local M = {}
addon.Modules.AllyKickTracker.Observer = M

for _, specData in pairs(kickData.SpecData) do
	local spellId, cooldown = specData.SpellId, specData.KickCd

	if spellId and cooldown then
		INTERRUPT_SPELL_IDS[spellId] = true
		FALLBACK_COOLDOWNS[spellId] = math.max(FALLBACK_COOLDOWNS[spellId] or 0, cooldown)
	end
end

for _, spellId in ipairs(WARLOCK_SPELL_LOCK_IDS) do
	INTERRUPT_SPELL_IDS[spellId] = true
	FALLBACK_COOLDOWNS[spellId] = FALLBACK_COOLDOWNS[WARLOCK_PET_SPELL_ID]
end

---Nothing here names the interrupter in anything we are allowed to read, but the GUID the stop
---events carry still resolves to a name the client will let us draw.
---@param unit string  the unit whose cast was cut short
---@param interruptedSpellId number?  secret when the spell is an enemy's
---@param interruptedBy string  GUID of the interrupter, secret inside an instance
local function OnInterrupted(unit, interruptedSpellId, interruptedBy)
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
	records[#records + 1] = {
		Name = UnitNameFromGUID(interruptedBy),
		Class = select(2, UnitClassFromGUID(interruptedBy)),
		Icon = C_Spell.GetSpellTexture(interruptedSpellId),
		Marker = GetRaidTargetIndex(unit),
		ExpireAt = now + RECORD_DURATION,
		Duration = RECORD_DURATION,
	}

	while #records > MAX_RECORDS do
		table.remove(records, 1)
	end

	if recordCallback then
		recordCallback()
	end
end

---The interrupt the player is expected to press, from their spec where it is known and their class
---otherwise.
---@return number? spellId
---@return number? cooldown
local function ResolvePlayerInterrupt()
	local specId = inspectorFacade:GetUnitSpecId("player")

	if specId then
		local specData = kickData.SpecData[specId]

		-- A resolved spec with no interrupt is authoritative: healers and Augmentation Evokers
		-- have nothing to show rather than a class-guessed bar.
		if specData then
			return specData.SpellId, specData.KickCd
		end
	end

	local _, classToken = UnitClass("player")
	local spellId = classToken and kickData.ClassInterruptSpell[classToken]

	return spellId, spellId and FALLBACK_COOLDOWNS[spellId]
end

---@param spellId number
---@param cooldown number
---@return AllyKickRecord
local function BuildOwnRecord(spellId, cooldown)
	local _, classToken = UnitClass("player")

	return {
		Name = UnitName("player"),
		Class = classToken,
		Icon = C_Spell.GetSpellTexture(spellId),
		SpellId = spellId,
		Cooldown = cooldown,
		ExpireAt = 0,
		Duration = cooldown,
		IsOwn = true,
	}
end

---The real remaining cooldown of one of the player's own spells, which beats the table value
---because it already accounts for talents and any reset since. 12.1 hands the fields back as
---secret numbers, and this one feeds both a comparison and arithmetic, so a secret means falling
---back to the spec data. Reading them is fine; touching them is what errors.
---@param spellId number
---@return number? startTime
---@return number? duration
local function PlayerSpellCooldown(spellId)
	local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellId)

	if not info or not info.duration then
		return nil, nil
	end

	if issecretvalue(info.duration) or issecretvalue(info.startTime) then
		return nil, nil
	end

	if info.duration < MIN_REPORTED_COOLDOWN then
		return nil, nil
	end

	return info.startTime, info.duration
end

---@param spellId number?
local function OnOwnCast(spellId)
	-- The player's own spell IDs are readable, unlike everybody else's. The guard is for the pet
	-- token, where indexing the lookup with a secret would be a hard error rather than a miss.
	if spellId == nil or issecretvalue(spellId) or not INTERRUPT_SPELL_IDS[spellId] then
		return
	end

	-- Pressing it settles which interrupt they have, which a spec that never resolved could not.
	if not ownRecord or ownRecord.SpellId ~= spellId then
		ownRecord = BuildOwnRecord(spellId, FALLBACK_COOLDOWNS[spellId] or DEFAULT_COOLDOWN)
	end

	local startTime, duration = PlayerSpellCooldown(spellId)
	local now = GetTime()

	ownRecord.Duration = duration or ownRecord.Cooldown
	ownRecord.ExpireAt = (startTime or now) + ownRecord.Duration

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
		interruptFrame:SetScript("OnEvent", function(_, event, ...)
			-- The stop events also fire for a cast that merely ended - a channel running its
			-- course, a cast its owner cancelled - and those arrive constantly in a dungeon. The
			-- interrupter is what separates a real kick; it is tested for nil, never read.
			local interruptedBy, interruptedSpellId = kickEvents:GetInterrupter(event, ...)
			if interruptedBy == nil then
				return
			end

			local unit = ...
			OnInterrupted(unit, interruptedSpellId, interruptedBy)
		end)
	end

	for _, event in ipairs(kickEvents.StopEvents) do
		if active then
			interruptFrame:RegisterEvent(event)
		else
			interruptFrame:UnregisterEvent(event)
		end
	end
end

---@param active boolean
local function SetOwnCastWatchActive(active)
	if not castFrame then
		castFrame = CreateFrame("Frame")
		castFrame:SetScript("OnEvent", function(_, _, _, _, spellId)
			OnOwnCast(spellId)
		end)
	end

	if active then
		castFrame:RegisterUnitEvent(CAST_EVENT, "player", "pet")
	else
		castFrame:UnregisterEvent(CAST_EVENT)
	end
end

---Registers a function to call whenever an interrupt is recorded or the player's own goes on
---cooldown, which is what a consumer wakes its refresh loop on.
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

---The player's own readiness row, or nil when their spec has no interrupt to show.
---@return AllyKickRecord?
function M:GetOwnRecord()
	return ownRecord
end

---Rebuilds what the player's own row says about them, keeping a cooldown already running as long
---as it is still the same interrupt. Their spec arrives after login and can change, and it decides
---both whether they have one and which it is.
function M:RefreshOwn()
	local spellId, cooldown = ResolvePlayerInterrupt()

	if not spellId then
		ownRecord = nil
		return
	end

	local previous = ownRecord

	ownRecord = BuildOwnRecord(spellId, cooldown or DEFAULT_COOLDOWN)

	if previous and previous.SpellId == spellId then
		ownRecord.ExpireAt = previous.ExpireAt
		ownRecord.Duration = previous.Duration
	end
end

---Drops the rows whose lifetime has run out. True when the list actually changed, which is what
---tells the caller to re-lay-out rather than merely repaint. The player's own row is never dropped.
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

---Drops every history row and puts the player's own interrupt back up, e.g. when a match starts
---and the last zone's kicks stop being interesting.
function M:Clear()
	wipe(records)
	wipe(lastRecordedAt)

	if ownRecord then
		ownRecord.ExpireAt = 0
	end
end

---True once the watchers are live, which they are not while the module is disabled.
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
	SetOwnCastWatchActive(true)
	self:RefreshOwn()
end

function M:Stop()
	if not watching then
		return
	end

	watching = false
	SetInterruptWatchActive(false)
	SetOwnCastWatchActive(false)
	self:Clear()
	ownRecord = nil
end

---One row in the list. A history row's Name, Class, Icon and Marker can all be secret values: they
---are only ever handed to a widget setter, never read, compared or used as a key. The player's own
---row is the exception - everything about them is readable - and it carries the extra fields.
---@class AllyKickRecord
---@field Name string?  the kicker's name
---@field Class string?  the kicker's class token
---@field Icon string|number|nil  the interrupted spell's texture, or the player's own interrupt
---@field Marker number?  raid target index of the mob whose cast was cut short
---@field ExpireAt number  when a history row leaves the list, or when the player's interrupt is up
---@field Duration number  the span the bar drains over
---@field SpellId number?  the player's own interrupt, so a cast can tell it apart from another
---@field Cooldown number?  the player's interrupt cooldown from the spec data
---@field IsOwn boolean?  true for the player's own row, which stays put and shows a ready state
