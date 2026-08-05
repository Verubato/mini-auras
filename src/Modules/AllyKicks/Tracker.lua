---@type string, Addon
local _, addon = ...
local kickData = addon.Core.KickData
local inspectorFacade = addon.Core.InspectorFacade
local unitUtil = addon.Utils.Units

addon.Modules.AllyKicks = addon.Modules.AllyKicks or {}

-- Cast detection runs off UNIT_SPELLCAST_SUCCEEDED rather than the combat log: the unit tokens
-- are already known here, it needs no GUID comparisons (which are secret for group members in
-- some 12.1 contexts), and it is the same route the kick timer uses for friendly casts.
local CAST_EVENT = "UNIT_SPELLCAST_SUCCEEDED"
-- The other half of an interrupt: the target's cast being cut short. It carries no interrupter
-- we can read, but it does say which unit was interrupted, and so which raid marker to show.
local INTERRUPT_EVENTS = { "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_STOP" }
-- How far apart the cast and the interrupt it caused are allowed to land. They are the same
-- moment as far as the server is concerned, but the two events are not guaranteed an order, so
-- the pairing works in both directions inside this window.
local MARKER_WINDOW = 0.3
-- How long a kick keeps explaining the interrupt events that follow it. The client reports one
-- interrupt under every token the mob holds - its nameplate, your target, your soft target - and
-- those repeats arrive spread out, so this stays generous where the pairing window does not.
local REPEAT_WINDOW = 2
-- Stand-in for a member with nothing resolvable at all, so the entry builder has fields to read.
local EMPTY_ENTRY = {}
-- Warlocks press Spell Lock on the pet, so the cast arrives on the pet token; both are watched
-- and credited to the owner. Which of the three IDs the cast reports depends on how it was
-- pressed (pet bar, the player-side Command Demon, or the felhunter's own ability), so all
-- three count as the same interrupt.
local WARLOCK_PET_SPELL_ID = 132409
local WARLOCK_SPELL_LOCK_IDS = { 132409, 119910, 19647 }
-- Fallback shown for a member whose interrupt can't be resolved yet.
local GENERIC_KICK_ICON = C_Spell.GetSpellTexture(1766) -- rogue Kick
-- Anything shorter is the global cooldown rather than the interrupt's own cooldown.
local MIN_REPORTED_COOLDOWN = 2
-- Stand-in for an interrupt seen being cast that carries no cooldown in the spec data. Every
-- interrupt in the game is at least this long, and watching them press it again trims it.
local DEFAULT_COOLDOWN = 15
-- How far below the book cooldown an observed one is allowed to pull the estimate. Talents trim
-- a few interrupts (Mind Freeze drops to 12s with one), but nothing halves them, so a shorter
-- gap than this is a cast we missed rather than a cooldown we had wrong.
local LEARNED_COOLDOWN_FLOOR = 0.6
-- Stand-in roster while ungrouped, so the bar still works solo and in test mode.
local SOLO_UNITS = { "player" }

-- Every interrupt MiniCC knows about, so a cast is recognised even before the caster's spec is.
---@type table<number, boolean>
local INTERRUPT_SPELL_IDS = {}
-- The cooldown to assume while the caster's spec is unknown. Specs that share an interrupt do
-- not always share its cooldown (Wind Shear is 12s for Elemental and 30s for Restoration), and
-- calling a kick ready early is worse than calling it ready late, so the longest one wins.
---@type table<number, number>
local FALLBACK_COOLDOWNS = {}

---@type AllyKickEntry[]
local entries = {}
---@type table<string, AllyKickEntry>
local entryByUnit = {}
-- Every group member worth watching, whether or not we can name their interrupt yet. A spec that
-- has not resolved leaves us unable to say which one someone has - and for Druids, Hunters and
-- Priests the class alone never says, since it depends on the spec - so watching only the members
-- we could name one for means never seeing the rest press theirs, and never finding out.
---@type string[]
local candidateUnits = {}
-- A member's own token and their pet's both map to the member, so a pet-cast interrupt finds its
-- owner even before that owner has an entry.
---@type table<string, string>
local ownerByToken = {}
-- One frame per roster slot, reused across rebuilds so a roster change costs no frames.
---@type table[]
local castFrames = {}
local watching = false
local debugEnabled = false
-- The last marker seen with no cooldown to hang it on yet, and the last cooldown started with no
-- marker yet: whichever event arrives second pairs them up.
---@type number?
local pendingMarker
local pendingMarkerTime = 0
---@type AllyKickEntry?
local unmarkedEntry
local unmarkedEntryTime = 0
local interruptFrame
---@type fun()?
local rosterCallback
---@type fun()?
local cooldownCallback

---@class AllyKickTracker
local M = {}
addon.Modules.AllyKicks.Tracker = M

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

---@param fmt string
local function DebugLog(fmt, ...)
	if debugEnabled then
		addon.Framework:Notify("[Kicks] " .. fmt, ...)
	end
end

---@param unit string
---@return string
local function PetUnitFor(unit)
	local index = unit:match("^party(%d)$")

	if index then
		return "partypet" .. index
	end

	index = unit:match("^raid(%d+)$")

	if index then
		return "raidpet" .. index
	end

	return "pet"
end

---The name a unit is going by, or nil where the client will not say. Group member names are
---secret in some 12.1 contexts, where they can be handed to secure setters but never read or
---compared. Read fresh each time rather than cached with the roster: a member who joined a moment
---ago, and a pet summoned since, both read as nameless at rebuild time and only settle later.
---@param unit string
---@return string?
local function ReadableName(unit)
	local name = UnitName(unit)

	if name == nil or issecretvalue(name) then
		return nil
	end

	return name
end

---A label for a member's bar, falling back to their group slot where the name cannot be read, so
---the bar still identifies who it belongs to.
---@param unit string
---@return string
local function MemberLabel(unit)
	local name = ReadableName(unit)

	if name then
		return name
	end

	local index = unit:match("^party(%d)$") or unit:match("^raid(%d+)$")

	return index and ((PARTY or "Party") .. " " .. index) or unit
end

---The interrupt a member is expected to press, from their spec where it is known and their
---class otherwise.
---@param unit string
---@return number? spellId
---@return number? cooldown
local function ResolveInterrupt(unit)
	local specId = inspectorFacade:GetUnitSpecId(unit)

	if specId then
		local specData = kickData.SpecData[specId]

		-- A resolved spec with no interrupt is authoritative: healers and Augmentation Evokers
		-- have nothing to track, so they get no bar rather than a class-guessed one.
		if specData then
			return specData.SpellId, specData.KickCd
		end
	end

	local _, classToken = UnitClass(unit)
	local spellId = classToken and kickData.ClassInterruptSpell[classToken]

	return spellId, spellId and FALLBACK_COOLDOWNS[spellId]
end

---@param unit string
---@return AllyKickEntry?
local function BuildEntry(unit)
	local spellId, cooldown = ResolveInterrupt(unit)

	if not spellId or not cooldown then
		return nil
	end

	local _, classToken = UnitClass(unit)

	return {
		Unit = unit,
		PetUnit = PetUnitFor(unit),
		Name = MemberLabel(unit),
		Class = (classToken and not issecretvalue(classToken)) and classToken or nil,
		SpellId = spellId,
		Texture = C_Spell.GetSpellTexture(spellId) or GENERIC_KICK_ICON,
		Cooldown = cooldown,
		BaseCooldown = cooldown,
		StartTime = 0,
	}
end

---Builds an entry for a member who has just been seen pressing an interrupt. Their spec never
---resolved, or their class alone does not say which interrupt they have, so this cast is the
---first hard evidence of what to track for them.
---@param unit string
---@param spellId number
---@return AllyKickEntry
local function BuildEntryFromCast(unit, spellId)
	local _, classToken = UnitClass(unit)
	local cooldown = FALLBACK_COOLDOWNS[spellId] or DEFAULT_COOLDOWN

	return {
		Unit = unit,
		PetUnit = PetUnitFor(unit),
		Name = MemberLabel(unit),
		Class = (classToken and not issecretvalue(classToken)) and classToken or nil,
		SpellId = spellId,
		Texture = C_Spell.GetSpellTexture(spellId) or GENERIC_KICK_ICON,
		Cooldown = cooldown,
		BaseCooldown = cooldown,
		StartTime = 0,
	}
end

---The real remaining cooldown of one of the local player's own spells, which beats the table
---value because it already accounts for talents and any reset that has happened since.
---@param spellId number
---@return number? startTime
---@return number? duration
local function PlayerSpellCooldown(spellId)
	local info = C_Spell and C_Spell.GetSpellCooldown and C_Spell.GetSpellCooldown(spellId)

	if not info or not info.duration then
		return nil, nil
	end

	-- 12.1 hands every field back as a secret number. Those can be passed to secure setters but
	-- never compared or done arithmetic on, and this one feeds both, so there is nothing to be
	-- had here: the caller falls back to the cooldown from the spec data like it does for
	-- everyone else. Reading them at all is fine; touching them is what errors.
	if issecretvalue(info.duration) or issecretvalue(info.startTime) then
		return nil, nil
	end

	if info.duration < MIN_REPORTED_COOLDOWN then
		return nil, nil
	end

	return info.startTime, info.duration
end

---Shortens a member's assumed cooldown when they press their interrupt again before it should
---have been back. Their talents are not readable from here, and several interrupts have one that
---trims the cooldown, so the shortest gap actually seen is a better number than the book value.
---It only ever shrinks: a longer gap is just a member who did not press it the moment it came up.
---@param entry AllyKickEntry
---@param now number
local function LearnCooldown(entry, now)
	if entry.StartTime <= 0 then
		return
	end

	local observed = math.floor(now - entry.StartTime + 0.5)

	if observed < entry.BaseCooldown * LEARNED_COOLDOWN_FLOOR or observed >= entry.Cooldown then
		return
	end

	entry.Cooldown = observed
end

---Records which raid marker an interrupt landed on, pairing it with a cooldown that started in
---the same moment. Nothing identifies the interrupter in the event itself, so the pairing is by
---time: an interrupt lands with the cast that caused it or not at all.
---@param entry AllyKickEntry
---@param spellId number
local function StartCooldown(entry, spellId)
	-- The cast is the most reliable statement of which interrupt a member actually has, so a
	-- spec guess that disagreed with it is corrected here (e.g. a Warlock whose pet cast arrives
	-- before their spec resolves).
	if entry.SpellId ~= spellId then
		entry.SpellId = spellId
		entry.Texture = C_Spell.GetSpellTexture(spellId) or GENERIC_KICK_ICON
		entry.Cooldown = FALLBACK_COOLDOWNS[spellId] or entry.Cooldown
		entry.BaseCooldown = entry.Cooldown
	end

	local startTime, duration

	if UnitIsUnit(entry.Unit, "player") then
		-- The client knows the local player's real cooldown, talents and all - where it is
		-- willing to say, which on 12.1 it is not.
		startTime, duration = PlayerSpellCooldown(spellId)
	end

	if not duration then
		-- No exact figure to be had, so the estimate is all there is, and watching them press it
		-- is the only way it gets better.
		LearnCooldown(entry, GetTime())
	end

	local now = GetTime()

	entry.StartTime = startTime or now
	entry.Duration = duration or entry.Cooldown
	-- A new press means a new target, so an old marker never lingers.
	entry.Marker = (pendingMarker and (now - pendingMarkerTime) <= MARKER_WINDOW) and pendingMarker or nil
	pendingMarker = nil
	unmarkedEntry = entry.Marker and nil or entry
	unmarkedEntryTime = now
end

---Starts a member's cooldown, building them a bar first if they never had one. The spell is
---whatever the caller could establish: the cast's own ID where it was readable, and otherwise
---the one their spec says they carry.
---@param owner string
---@param spellId number?
local function CreditInterrupt(owner, spellId)
	local entry = entryByUnit[owner]
	local adopted = false

	if not entry then
		-- Either their spec never resolved, or it did and said they had no interrupt. Pressing
		-- one settles the argument.
		entry = BuildEntryFromCast(owner, spellId or (BuildEntry(owner) or EMPTY_ENTRY).SpellId)
		entries[#entries + 1] = entry
		entryByUnit[owner] = entry
		adopted = true
		DebugLog("%s turns out to have an interrupt - adding a bar", entry.Name)
	end

	StartCooldown(entry, spellId or entry.SpellId)

	-- A bar that did not exist a moment ago is a roster change, not just a cooldown.
	if adopted and rosterCallback then
		rosterCallback()
	end

	if cooldownCallback then
		cooldownCallback()
	end
end

---True when a member's interrupt is off cooldown as far as we know.
---@param owner string
---@return boolean
local function IsReady(owner)
	local entry = entryByUnit[owner]

	if not entry or entry.StartTime <= 0 then
		return true
	end

	return GetTime() >= entry.StartTime + (entry.Duration or entry.Cooldown)
end

---The watched member an interrupter's GUID belongs to. The name is asked for first: the client
---will name a group member whose GUID it refuses to turn into a unit token, which is why asking
---for the token alone left every ally's kick unattributed. Both calls are wrapped, because a
---secret GUID is only good for handing to a secure API and these two are not that; and a reply
---that comes back secret is dropped rather than compared, since comparing one aborts the handler.
---@param guid string  possibly secret
---@return string? owner
local function OwnerFromGuid(guid)
	if UnitNameFromGUID then
		local ok, name = pcall(UnitNameFromGUID, guid)

		if ok and name ~= nil and not issecretvalue(name) then
			-- Every watched token, pets included, so a Spell Lock finds the warlock who owns it.
			for token, owner in pairs(ownerByToken) do
				if ReadableName(token) == name then
					return owner
				end
			end
		end
	end

	if UnitTokenFromGUID then
		local ok, token = pcall(UnitTokenFromGUID, guid)

		if ok and token ~= nil and not issecretvalue(token) then
			return ownerByToken[token]
		end
	end

	return nil
end

---Names the member who cut a cast short. The event's own interrupter field is the direct answer
---where the client gives one. Failing that, a member seen casting in the same instant is the only
---one it can have been; that is the whole use of a cast whose spell ID we were not allowed to read.
---@param interruptedBy string?  GUID of the interrupter, possibly secret
---@return string? owner
local function ResolveInterrupter(interruptedBy)
	local owner = interruptedBy and OwnerFromGuid(interruptedBy)

	if owner then
		return owner
	end

	-- Everything below this point is a guess, and there is nothing to guess at once a cooldown
	-- has just started: this interrupt is that same kick being reported again. The client repeats
	-- one under every token the mob holds - its nameplate, your target, your soft target - so the
	-- repeats land here too. Skipping them is what stops a bystander being credited for the kick
	-- somebody else has already been given.
	for _, entry in ipairs(entries) do
		if entry.StartTime > 0 and (GetTime() - entry.StartTime) <= REPEAT_WINDOW then
			return nil
		end
	end

	-- All that is left is who it can still have been.
	--
	-- The local player is never in that pool. Their own casts arrive fully readable, so their
	-- kicks are known exactly and one of theirs would already have been credited above; leaving
	-- them in would only ever add a candidate and talk us out of a call we could safely make.
	--
	-- With one ally's interrupt up it was theirs by elimination. With two there is nothing left
	-- to tell them apart - their spells are sealed, and their instant casts raise no event at
	-- all - so nobody is credited rather than the wrong person.
	local only
	local readyCount = 0

	for _, unit in ipairs(candidateUnits) do
		if entryByUnit[unit] and not UnitIsUnit(unit, "player") and IsReady(unit) then
			readyCount = readyCount + 1
			only = unit
		end
	end

	if readyCount == 1 then
		DebugLog("only %s could have done it", only)
		return only
	end

	DebugLog("%d allies could have done it - not guessing", readyCount)

	return nil
end

---How one of the two GUID lookups answered, for the log. Which of them gave a plain reply, and
---which came back secret, is the first thing to know when nothing is being attributed.
---@param guid string
---@param resolver (fun(guid: string): string?)?
---@return string
local function DescribeLookup(guid, resolver)
	if not resolver then
		return "missing"
	end

	local ok, value = pcall(resolver, guid)

	if not ok then
		return "error"
	elseif value == nil then
		return "nil"
	end

	return issecretvalue(value) and "secret" or tostring(value)
end

---@param event string
---@param unit string  the unit whose cast was cut short
---@param interruptedBy string?  GUID of whoever interrupted it
local function OnTargetInterrupted(event, unit, interruptedBy)
	-- Allies get interrupted too, and their attacker's kick is nothing to do with our group.
	if not unitUtil:CanAttack(unit) then
		return
	end

	-- Both events fire for casts that simply ended - a channel running its course, a cast the
	-- caster cancelled - and those arrive constantly in a dungeon. The interrupter field is what
	-- separates a real interrupt from a cast that merely stopped, so no field means no kick.
	if interruptedBy == nil then
		return
	end

	local owner = ResolveInterrupter(interruptedBy)

	-- Each route fails differently - no GUID at all, or one naming nobody we can read - and
	-- which it is decides what could be done about it.
	if debugEnabled then
		DebugLog("%s on %s: by=%s name=%s token=%s -> %s", event:gsub("UNIT_SPELLCAST_", ""),
			tostring(unit), issecretvalue(interruptedBy) and "secret" or "present",
			DescribeLookup(interruptedBy, UnitNameFromGUID),
			DescribeLookup(interruptedBy, UnitTokenFromGUID),
			owner or "UNATTRIBUTED")
	end

	if owner then
		local entry = entryByUnit[owner]
		-- The interrupt and the cast that caused it arrive together, so a cooldown that just
		-- started is this same kick reported twice rather than a second one.
		local settled = entry and entry.StartTime > 0 and (GetTime() - entry.StartTime) <= REPEAT_WINDOW

		if not settled then
			DebugLog("interrupt attributed to %s", owner)
			CreditInterrupt(owner, nil)
		end
	end

	local marker = GetRaidTargetIndex(unit)

	if not marker or issecretvalue(marker) or marker <= 0 then
		return
	end

	local now = GetTime()

	if unmarkedEntry and (now - unmarkedEntryTime) <= MARKER_WINDOW then
		unmarkedEntry.Marker = marker
		unmarkedEntry = nil
		DebugLog("marker %d paired with the cooldown just started", marker)

		if cooldownCallback then
			cooldownCallback()
		end

		return
	end

	pendingMarker = marker
	pendingMarkerTime = now
end

---@param unit string
---@param spellId number
local function OnInterruptCast(unit, spellId)
	local owner = ownerByToken[unit]

	if not owner then
		return
	end

	-- Anyone but the local player gets a secret spell ID, which cannot be compared or used as a
	-- key, so there is no telling what this cast was. Nor is there anything to be gained from
	-- noting that they cast something: a party member's INSTANT casts raise no event at all
	-- since 12.0.1, so an interrupt never appears here in the first place. What does arrive is
	-- their non-instant casts, and pairing one of those with an interrupt would be matching the
	-- kick to whatever they happened to be casting instead.
	if issecretvalue(spellId) then
		DebugLog("cast from %s with a secret spell id - nothing to be read from it", tostring(unit))
		return
	end

	if not INTERRUPT_SPELL_IDS[spellId] then
		-- Logged rather than dropped silently: seeing the casts that arrive is what tells you
		-- whether the event reaches us at all, which is the first thing to check when a bar
		-- never counts down.
		DebugLog("cast %s from %s - not an interrupt%s", tostring(spellId), tostring(unit),
			owner and "" or " (and the unit is not watched)")
		return
	end

	DebugLog("interrupt %s from %s - starting the cooldown", tostring(spellId), tostring(unit))
	CreditInterrupt(owner, spellId)
end

local function ClearCastFrames()
	for _, frame in ipairs(castFrames) do
		frame:UnregisterAllEvents()
	end
end

---The interrupt watcher is unit-agnostic - any enemy in the world can be the one interrupted -
---so it is one frame listening broadly rather than one per roster slot.
---@param active boolean
local function SetInterruptWatchActive(active)
	if not interruptFrame then
		interruptFrame = CreateFrame("Frame")
		interruptFrame:SetScript("OnEvent", function(_, event, unit, _, _, interruptedBy)
			OnTargetInterrupted(event, unit, interruptedBy)
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

local function RegisterCastFrames()
	ClearCastFrames()

	if not watching then
		return
	end

	for index, unit in ipairs(candidateUnits) do
		local frame = castFrames[index]

		if not frame then
			frame = CreateFrame("Frame")
			frame:SetScript("OnEvent", function(_, _, castUnit, _, spellId)
				OnInterruptCast(castUnit, spellId)
			end)
			castFrames[index] = frame
		end

		frame:RegisterUnitEvent(CAST_EVENT, unit, PetUnitFor(unit))
	end
end

-- Public

---Registers a function to call whenever the tracked roster changes, i.e. whenever the set of
---entries handed back by GetEntries is a different one.
---@param fn fun()
function M:SetRosterCallback(fn)
	rosterCallback = fn
end

---Registers a function to call whenever a tracked member's interrupt goes on cooldown. Nothing
---else moves the entries, so this is what a consumer wakes its refresh loop on.
---@param fn fun()
function M:SetCooldownCallback(fn)
	cooldownCallback = fn
end

---The members currently tracked, in group order. The table is the tracker's own and is rebuilt
---in place, so callers must not hold onto it across a rebuild.
---@return AllyKickEntry[]
function M:GetEntries()
	return entries
end

---Rebuilds the roster from the current group, preserving any cooldown already running for a
---member who is still in it.
---@param includePlayer boolean
function M:Rebuild(includePlayer)
	local previousByUnit = {}

	for _, entry in ipairs(entries) do
		previousByUnit[entry.Unit] = entry
	end

	wipe(entries)
	wipe(entryByUnit)
	wipe(candidateUnits)
	wipe(ownerByToken)

	local candidates = unitUtil:FriendlyUnits()

	-- Solo, so there is no group to read: the player's own interrupt is still worth a bar.
	if #candidates == 0 then
		candidates = SOLO_UNITS
	end

	local playerTracked = false

	for _, unit in ipairs(candidates) do
		local isPlayer = UnitIsUnit(unit, "player")
		-- The player owns a raid token as well as "player", so a raid roster would otherwise
		-- produce two bars for them. Pets appear in the list too, but they are watched through
		-- their owner's entry rather than carrying one of their own.
		local skip = unitUtil:IsPetOrMinion(unit) or (isPlayer and (playerTracked or not includePlayer))

		if not skip then
			-- Watched whether or not an interrupt can be named for them yet; a cast is the
			-- fallback way of finding out, and it only arrives if we are listening.
			playerTracked = playerTracked or isPlayer
			candidateUnits[#candidateUnits + 1] = unit
			ownerByToken[unit] = unit
			ownerByToken[PetUnitFor(unit)] = unit

			local entry = BuildEntry(unit)

			if entry then
				local previous = previousByUnit[unit]

				if previous then
					entry.StartTime = previous.StartTime
					entry.Duration = previous.Duration

					-- A cooldown learned from watching them press it outlives roster churn,
					-- as long as it is still the same interrupt.
					if previous.SpellId == entry.SpellId then
						entry.Cooldown = math.min(entry.Cooldown, previous.Cooldown)
					end
				end

				entries[#entries + 1] = entry
				entryByUnit[entry.Unit] = entry
			end
		end
	end

	RegisterCastFrames()
	DebugLog("roster rebuilt: %d bars, %d watched of %d candidates", #entries, #candidateUnits,
		#candidates)

	for _, entry in ipairs(entries) do
		DebugLog("  %s (%s) spell %s, %ss, watching %s + %s", entry.Name, tostring(entry.Class),
			tostring(entry.SpellId), tostring(entry.Cooldown), entry.Unit, entry.PetUnit)
	end

	if rosterCallback then
		rosterCallback()
	end
end

---Drops every running cooldown, e.g. when a match starts and everything is off cooldown again.
function M:ClearCooldowns()
	for _, entry in ipairs(entries) do
		entry.StartTime = 0
		entry.Duration = nil
		entry.Marker = nil
	end

	-- Half-finished pairings belong to the fight that just ended, and crediting one after a zone
	-- change would put a bar on cooldown for something nobody did here.
	pendingMarker = nil
	unmarkedEntry = nil
end

---@param unit string
---@return boolean
function M:IsTracked(unit)
	return entryByUnit[unit] ~= nil
end

---True when a unit's casts are being watched, whether or not it has a bar yet.
---@param unit string
---@return boolean
function M:IsWatched(unit)
	return ownerByToken[unit] ~= nil
end

---The group members being listened to, which is a longer list than the one with bars.
---@return string[]
function M:GetWatchedUnits()
	return candidateUnits
end

---Turns the cast/roster log on or off. Every spell cast by a tracked member is reported while
---it is on, which is deliberately noisy - it is the only way to see whether the events arrive.
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

---True once the cast watchers are live, which they are not while the module is disabled.
---@return boolean
function M:IsWatching()
	return watching
end

function M:Start()
	if watching then
		return
	end

	watching = true
	RegisterCastFrames()
	SetInterruptWatchActive(true)
end

function M:Stop()
	if not watching then
		return
	end

	watching = false
	ClearCastFrames()
	SetInterruptWatchActive(false)
	pendingMarker = nil
	unmarkedEntry = nil
	wipe(entries)
	wipe(entryByUnit)
	wipe(candidateUnits)
	wipe(ownerByToken)
end

---@class AllyKickEntry
---@field Unit string
---@field PetUnit string  the token a pet-cast interrupt (Spell Lock) arrives on
---@field Name string
---@field Class string?  class token, nil when it is secret
---@field SpellId number
---@field Texture string|number
---@field Cooldown number  the interrupt's cooldown, which observed casts can shorten
---@field BaseCooldown number  the cooldown from spec/class data, which Cooldown is bounded by
---@field Marker number?  raid target index of whatever this interrupt landed on
---@field StartTime number  0 while the interrupt is ready
---@field Duration number?  the cooldown actually running, which can beat Cooldown for the player
