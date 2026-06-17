---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local rules = addon.Modules.Cooldowns.Rules
local fcdTalents = addon.Modules.Cooldowns.Talents

addon.Modules.EnemyCooldowns = addon.Modules.EnemyCooldowns or {}

---@class EnemyCooldownDisplay
local D = {}
addon.Modules.EnemyCooldowns.Display = D

---@type Db
local db
local testModeActive = false
-- Default opacity for always-show icons that are not currently on cooldown.
local defaultInactiveAlpha = 0.6
-- Scratch table reused by UpdateDisplay to avoid per-call allocation.
local slotsScratch = {}
-- Pool of reusable slot descriptor tables indexed by slot position.
-- SetSlot reads these synchronously and does not store references, so pooling is safe.
local slotTablePool = {}

-- Test-mode preview cooldowns.
-- Inactive=true entries preview the always-show faded state when that option is enabled.
local testSpells = {
	{ SpellId = 45438,   StartOffset = 30, Cooldown = 240 }, -- Ice Block        (defensive)
	{ SpellId = 642,     StartOffset = 15, Cooldown = 300, Inactive = true }, -- Divine Shield (defensive)
	{ SpellId = 31224,   StartOffset = 10, Cooldown = 60  }, -- Cloak of Shadows (defensive)
	{ SpellId = 48792,   StartOffset = 45, Cooldown = 180, Inactive = true }, -- Icebound Fortitude (defensive)
	{ SpellId = 47585,   StartOffset = 5,  Cooldown = 120 }, -- Dispersion       (defensive)
	{ SpellId = 22812,   StartOffset = 20, Cooldown = 60  }, -- Barkskin         (defensive)
	{ SpellId = 871,     StartOffset = 60, Cooldown = 240, Inactive = true }, -- Shield Wall (defensive)
	{ SpellId = 33206,   StartOffset = 8,  Cooldown = 120 }, -- Pain Suppression (external defensive)
}

---Returns true when a committed cooldown entry is currently counting down.
---Multi-charge entries are active while any charge is recharging; single-charge entries are
---active until StartTime + Cooldown elapses.
local function IsCooldownActive(cd, now)
	if cd.UsedCharges then
		return #cd.UsedCharges > 0
	end
	return now < cd.StartTime + cd.Cooldown
end

-- C_Spell.GetSpellInfo follows talent overrides locally; use originalIconID to get the
-- canonical icon unaffected by the viewing player's own talent replacements.
local function GetSpellIcon(spellId)
	local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellId)
	return (info and info.originalIconID) or C_Spell.GetSpellTexture(spellId)
end

local function GetOptions()
	return db and db.Modules.EnemyCooldownTrackerModule
end

---Returns the arena enemy frame for the given index, checking known frame addons in order:
---sArena Reloaded (sArenaEnemyFrame1/2/3), ElvUI (ElvUF_Arena1/2/3),
---then Blizzard (CompactArenaFrame.memberUnitFrames[index]).
---@param index number
---@return table?
local function GetArenaEnemyFrame(index)
	local sArena = _G["sArenaEnemyFrame" .. index]
	if sArena then
		return sArena
	end
	local elvui = _G["ElvUF_Arena" .. index]
	if elvui then
		return elvui
	end
	local blizz = CompactArenaFrame and CompactArenaFrame.memberUnitFrames
	return blizz and blizz[index]
end

local function GetSlotTable(idx)
	local t = slotTablePool[idx]
	if not t then t = {}; slotTablePool[idx] = t else wipe(t) end
	return t
end

---Renders the test-mode preview spells into the given container, optionally filtered.
---When always-show is enabled, Inactive=true entries preview the faded (no-swipe) state.
---@param container IconSlotContainer
---@param options table  options snapshot (showTooltips, iconOptions, etc.)
---@param filter fun(spellId:number):boolean?  nil = include everything
local function RenderTestSpells(container, options, filter)
	local now           = GetTime()
	local showTooltips  = options.ShowTooltips
	local iconOptions   = options.Icons
	local alwaysShow    = options.AlwaysShow
	local inactiveAlpha = defaultInactiveAlpha
	local usedCount     = 0
	for _, t in ipairs(testSpells) do
		if not filter or filter(t.SpellId) then
			local texture = GetSpellIcon(t.SpellId)
			if texture and usedCount < container.Count then
				usedCount = usedCount + 1
				local faded = alwaysShow and t.Inactive
				container:SetSlot(usedCount, {
					Texture = texture,
					SpellId = showTooltips and t.SpellId or nil,
					DurationObject = (not faded) and wowEx:CreateDuration(now - t.StartOffset, t.Cooldown) or nil,
					Alpha = faded and inactiveAlpha or 1,
					ReverseCooldown = iconOptions.ReverseCooldown,
					Desaturate = iconOptions.DesaturateOnCooldown and not faded,
					FontScale = db.FontScale,
				})
			end
		end
	end
	for i = usedCount + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---Appends a single display slot to `slots` for the given spell.
---When `cd` is supplied the icon shows full opacity with a running swipe (and charge text for
---multi-charge entries); when `cd` is nil the icon is faded (always-show "off cooldown" state).
---No-op when the spell has no icon, is disabled, or fails the filter.
---@param slots table
---@param spellId number
---@param cd EcdCooldownEntry?  active cooldown, or nil for the faded state
---@param ctx table  { showTooltips, reverseCooldown, disabledSpells, filter, inactiveAlpha }
local function AppendSlot(slots, spellId, cd, ctx)
	if not spellId or ctx.disabledSpells[spellId] then return end
	if ctx.filter and not ctx.filter(spellId) then return end
	local texture = GetSpellIcon(spellId)
	if not texture then return end

	local idx = #slots + 1
	local s = GetSlotTable(idx)
	s.Texture         = texture
	s.SpellId         = ctx.showTooltips and spellId or nil
	s.ReverseCooldown = ctx.reverseCooldown
	s.FontScale       = db.FontScale
	if cd then
		s.Alpha = 1
		s.Desaturate = ctx.desaturateOnCooldown
		if cd.UsedCharges then
			s.DurationObject = wowEx:CreateDuration(cd.UsedCharges[1].Expiry - cd.Cooldown, cd.Cooldown)
			s.ChargeText     = tostring(cd.MaxCharges - #cd.UsedCharges)
		else
			s.DurationObject = wowEx:CreateDuration(cd.StartTime, cd.Cooldown)
		end
	else
		s.Alpha          = ctx.inactiveAlpha
		s.Desaturate     = false
		s.DurationObject  = nil
	end
	slots[idx] = s
end

---Builds an options-derived context table reused by AppendSlot for one render pass.
local function BuildSlotContext(options, filter)
	return {
		showTooltips         = options.ShowTooltips,
		reverseCooldown      = options.Icons.ReverseCooldown,
		desaturateOnCooldown = options.Icons.DesaturateOnCooldown,
		disabledSpells       = options.DisabledSpells or {},
		filter               = filter,
		inactiveAlpha        = defaultInactiveAlpha,
	}
end

---Resolves an enemy unit's class token, deriving it from the spec ID when UnitClass is nil.
---During arena prep the enemy unit tokens (arena1-3) don't exist yet, so UnitClass returns nil
---even though the spec - and therefore the class - is known via GetArenaOpponentSpec.  Without
---this fallback the always-show list would drop every ByClass cooldown until the gates open.
---@param unit string
---@param specId number?
---@return string? classToken
local function ResolveClassToken(unit, specId)
	local _, classToken = UnitClass(unit)
	return classToken or rules.GetClassForSpec(specId)
end

---Appends one entry's display slots to `slots`.
---Always-show mode: renders the entry's full spec/class spell set, faded when off cooldown and
---  full-opacity with a swipe when active; active cooldowns outside the spec list are appended too.
---Normal mode: renders only active cooldowns and prunes expired single-charge entries.
---@param entry EcdWatchEntry
---@param options table
---@param ctx table  slot context from BuildSlotContext
---@param slots table
---@param now number
local function CollectEntrySlots(entry, options, ctx, slots, now)
	-- Always-show: drive the icon set from the enemy's spec/class so every possible cooldown is
	-- visible.  Falls back to active-only rendering until spec/class data is available.
	if options.AlwaysShow then
		local specId = fcdTalents:GetUnitSpecId(entry.Unit)
		local classToken = ResolveClassToken(entry.Unit, specId)
		local trackable = rules.GetTrackableSpellIds(specId, classToken)
		if #trackable > 0 then
			local emitted = {}
			for _, spellId in ipairs(trackable) do
				emitted[spellId] = true
				local cd = entry.ActiveCooldowns[spellId]
				AppendSlot(slots, spellId, (cd and IsCooldownActive(cd, now)) and cd or nil, ctx)
			end
			-- Active cooldowns not represented in the spec list (e.g. cross-class attribution).
			for cdKey, cd in pairs(entry.ActiveCooldowns) do
				local spellId = cd.SpellId
				if spellId and not emitted[spellId] then
					if IsCooldownActive(cd, now) then
						AppendSlot(slots, spellId, cd, ctx)
					elseif not cd.UsedCharges then
						entry.ActiveCooldowns[cdKey] = nil
					end
				end
			end
			return
		end
	end

	-- Normal mode: active cooldowns only, pruning expired single-charge entries.
	for cdKey, cd in pairs(entry.ActiveCooldowns) do
		if IsCooldownActive(cd, now) then
			AppendSlot(slots, cd.SpellId, cd, ctx)
		elseif not cd.UsedCharges then
			entry.ActiveCooldowns[cdKey] = nil
		end
	end
end

---Writes a slot list into a container, padding unused slots.
local function ApplySlotsToContainer(container, slots)
	local usedCount = math.min(#slots, container.Count)
	for i = 1, usedCount do
		container:SetSlot(i, slots[i])
	end
	for i = usedCount + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---Populates an entry's icon container with the current enemy cooldown state.
---@param entry EcdWatchEntry
---@param filter fun(spellId:number):boolean?  optional spell filter
local function UpdateDisplay(entry, filter)
	local options = GetOptions()
	if not options then return end

	if testModeActive then
		RenderTestSpells(entry.Container, options, filter)
		return
	end
	local slots = slotsScratch
	for i = 1, #slots do
		slots[i] = nil
	end
	CollectEntrySlots(entry, options, BuildSlotContext(options, filter), slots, GetTime())
	ApplySlotsToContainer(entry.Container, slots)
end

---Positions an entry's container in Linear display mode.
---arena1 uses the saved drag position; arena2/3 stack below the previous entry's frame.
---Skips re-anchoring if the anchor parameters haven't changed since the last call.
---@param entry EcdWatchEntry
---@param index number  1=arena1, 2=arena2, 3=arena3
---@param prevEntry EcdWatchEntry?  the entry above this one in the stack (nil for arena1)
local function AnchorContainerLinear(entry, index, prevEntry)
	local options = GetOptions()
	if not options then
		return
	end

	local entrySpacing = tonumber(options.EntrySpacing) or 4

	local frame = entry.Container.Frame
	frame:ClearAllPoints()
	frame:SetFrameStrata("MEDIUM")
	frame:SetFrameLevel(100)
	frame:SetAlpha(1)

	if index == 1 or not prevEntry then
		local relTo = _G[options.Linear.RelativeTo] or UIParent
		frame:SetPoint(
			options.Linear.Point or "CENTER",
			relTo,
			options.Linear.RelativePoint or "CENTER",
			options.Linear.X or 0,
			options.Linear.Y or 200
		)
	else
		frame:SetPoint("TOP", prevEntry.Container.Frame, "BOTTOM", 0, -entrySpacing)
	end

end

---Positions an entry's container anchored to its corresponding enemy arena frame.
---Skips re-anchoring if the anchor parameters haven't changed since the last call.
---@param entry EcdWatchEntry
---@param index number  1=arena1, 2=arena2, 3=arena3
local function AnchorContainerArenaFrames(entry, index)
	local options = GetOptions()
	if not options then
		return
	end

	local arenaFrame = GetArenaEnemyFrame(index)
	if not arenaFrame then
		return
	end

	local grow = options.ArenaFrames.Grow or "LEFT"
	local xOff = options.ArenaFrames.Offset and options.ArenaFrames.Offset.X or 0
	local yOff = options.ArenaFrames.Offset and options.ArenaFrames.Offset.Y or 0

	local frame = entry.Container.Frame
	frame:ClearAllPoints()

	local strata = arenaFrame:GetFrameStrata()
	frame:SetFrameStrata(strata)
	frame:SetFrameLevel(arenaFrame:GetFrameLevel() + 10)
	frame:SetAlpha(1)

	if grow == "LEFT" then
		frame:SetPoint("RIGHT", arenaFrame, "LEFT", xOff, yOff)
	elseif grow == "RIGHT" then
		frame:SetPoint("LEFT", arenaFrame, "RIGHT", xOff, yOff)
	elseif grow == "DOWN" then
		frame:SetPoint("TOP", arenaFrame, "BOTTOM", xOff, yOff)
	else
		frame:SetPoint("CENTER", arenaFrame, "CENTER", xOff, yOff)
	end

end

---Must be called once from M:Init before any display functions are used.
function D:Init()
	db = mini:GetSavedVars()
end

---@param active boolean
function D:SetTestMode(active)
	testModeActive = active
end

---@param entry EcdWatchEntry
function D:UpdateDisplay(entry)
	UpdateDisplay(entry)
end

---Renders combined cooldowns from a set of entries into a target container.
---Honours always-show (each source entry contributes its full spec/class set) and the optional
---filter.
---@param targetContainer IconSlotContainer  the destination container
---@param entries table<string, EcdWatchEntry>  source entries to aggregate from
---@param filter fun(spellId:number):boolean?  nil = include everything
local function RenderAggregate(targetContainer, entries, filter)
	local options = GetOptions()
	if not options then return end
	if testModeActive then
		RenderTestSpells(targetContainer, options, filter)
		return
	end

	local slots = slotsScratch
	for i = 1, #slots do
		slots[i] = nil
	end

	local now = GetTime()
	local ctx = BuildSlotContext(options, filter)
	for _, entry in pairs(entries) do
		CollectEntrySlots(entry, options, ctx, slots, now)
	end

	ApplySlotsToContainer(targetContainer, slots)
end

---Populates the arena1 container with combined cooldowns from all watch entries.
---Used in Linear mode so all enemies' cooldowns appear in one row.
---@param entries table<string, EcdWatchEntry>
function D:UpdateLinearDisplay(entries)
	local entry1 = entries["arena1"]
	if not entry1 then return end
	RenderAggregate(entry1.Container, entries, nil)
end

---@param entry EcdWatchEntry
---@param index number
---@param prevEntry EcdWatchEntry?
function D:AnchorContainer(entry, index, prevEntry)
	local options = GetOptions()
	if not options then return end

	-- Linear mode: arena1 is the only visible per-unit container; arena2/3 stack below it.
	-- ArenaFrames mode: each per-unit container anchors to its corresponding arena frame.
	if options.DisplayMode == "Linear" then
		AnchorContainerLinear(entry, index, prevEntry)
	else
		AnchorContainerArenaFrames(entry, index)
	end
end

---@param index number
---@return table?
function D:GetArenaEnemyFrame(index)
	return GetArenaEnemyFrame(index)
end
