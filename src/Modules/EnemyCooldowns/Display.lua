---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local rules = addon.Modules.Cooldowns.Rules

addon.Modules.EnemyCooldowns = addon.Modules.EnemyCooldowns or {}

---@class EnemyCooldownDisplay
local D = {}
addon.Modules.EnemyCooldowns.Display = D

---@type Db
local db
local testModeActive = false
-- Scratch table reused by UpdateDisplay to avoid per-call allocation.
local slotsScratch = {}
-- Pool of reusable slot descriptor tables indexed by slot position.
-- SetSlot reads these synchronously and does not store references, so pooling is safe.
local slotTablePool = {}

-- Test-mode preview cooldowns.  In Split mode the filter routes offensives to the linear bar
-- and the remainder to the arena-frame containers, so a couple of offensives are included.
local testSpells = {
	{ SpellId = 45438,   StartOffset = 30, Cooldown = 240 }, -- Ice Block        (defensive)
	{ SpellId = 642,     StartOffset = 15, Cooldown = 300 }, -- Divine Shield    (defensive)
	{ SpellId = 31224,   StartOffset = 10, Cooldown = 60  }, -- Cloak of Shadows (defensive)
	{ SpellId = 48792,   StartOffset = 45, Cooldown = 180 }, -- Icebound Fortitude (defensive)
	{ SpellId = 47585,   StartOffset = 5,  Cooldown = 120 }, -- Dispersion       (defensive)
	{ SpellId = 22812,   StartOffset = 20, Cooldown = 60  }, -- Barkskin         (defensive)
	{ SpellId = 871,     StartOffset = 60, Cooldown = 240 }, -- Shield Wall      (defensive)
	{ SpellId = 33206,   StartOffset = 8,  Cooldown = 120 }, -- Pain Suppression (external defensive)
	{ SpellId = 31884,   StartOffset = 12, Cooldown = 120 }, -- Avenging Wrath   (offensive)
	{ SpellId = 190319,  StartOffset = 35, Cooldown = 120 }, -- Combustion       (offensive)
	{ SpellId = 288613,  StartOffset = 50, Cooldown = 120 }, -- Trueshot         (offensive)
}

---Returns true when the cooldown belongs to the Offensive spell set (used by Split mode to route
---offensives to the linear bar and everything else to the arena-frame containers).
local function IsOffensiveCooldown(cd)
	return cd.SpellId ~= nil and rules.OffensiveSpellIds[cd.SpellId] == true
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
---@param container IconSlotContainer
---@param options table  options snapshot (showTooltips, iconOptions, etc.)
---@param filter fun(cd):boolean?  nil = include everything
local function RenderTestSpells(container, options, filter)
	local now          = GetTime()
	local showTooltips = options.ShowTooltips
	local iconOptions  = options.Icons
	local usedCount    = 0
	for _, t in ipairs(testSpells) do
		if not filter or filter(t) then
			local texture = GetSpellIcon(t.SpellId)
			if texture and usedCount < container.Count then
				usedCount = usedCount + 1
				container:SetSlot(usedCount, {
					Texture = texture,
					SpellId = showTooltips and t.SpellId or nil,
					DurationObject = wowEx:CreateDuration(now - t.StartOffset, t.Cooldown),
					Alpha = 1,
					ReverseCooldown = iconOptions.ReverseCooldown,
					FontScale = db.FontScale,
				})
			end
		end
	end
	for i = usedCount + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---Builds the slot list for one entry's ActiveCooldowns, optionally filtered.  Expired entries
---are pruned from ActiveCooldowns as a side effect (existing behaviour).  Returns the populated
---scratch table; callers must not retain references to entries.
---@param entry EcdWatchEntry
---@param options table
---@param filter fun(cd):boolean?
local function CollectSlots(entry, options, filter)
	local slots = slotsScratch
	for i = 1, #slots do
		slots[i] = nil
	end

	local now            = GetTime()
	local showTooltips   = options.ShowTooltips
	local iconOptions    = options.Icons
	local disabledSpells = options.DisabledSpells or {}

	for cdKey, cd in pairs(entry.ActiveCooldowns) do
		if cd.UsedCharges then
			-- Multi-charge entry: visible while at least one charge is recharging.
			local usedCount = #cd.UsedCharges
			if usedCount > 0 then
				local texture = cd.SpellId and not disabledSpells[cd.SpellId]
					and (not filter or filter(cd))
					and GetSpellIcon(cd.SpellId)
				if texture then
					local startTime = cd.UsedCharges[1].Expiry - cd.Cooldown
					local idx = #slots + 1
					local s = GetSlotTable(idx)
					s.Texture         = texture
					s.SpellId         = showTooltips and cd.SpellId or nil
					s.DurationObject  = wowEx:CreateDuration(startTime, cd.Cooldown)
					s.Alpha           = 1
					s.ReverseCooldown = iconOptions.ReverseCooldown
					s.FontScale       = db.FontScale
					s.ChargeText      = tostring(cd.MaxCharges - usedCount)
					slots[idx] = s
				end
			end
		elseif now < cd.StartTime + cd.Cooldown then
			local texture = cd.SpellId and not disabledSpells[cd.SpellId]
				and (not filter or filter(cd))
				and GetSpellIcon(cd.SpellId)
			if texture then
				local idx = #slots + 1
				local s = GetSlotTable(idx)
				s.Texture         = texture
				s.SpellId         = showTooltips and cd.SpellId or nil
				s.DurationObject  = wowEx:CreateDuration(cd.StartTime, cd.Cooldown)
				s.Alpha           = 1
				s.ReverseCooldown = iconOptions.ReverseCooldown
				s.FontScale       = db.FontScale
				slots[idx] = s
			end
		else
			entry.ActiveCooldowns[cdKey] = nil
		end
	end
	return slots
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
---Shows committed cooldowns (buff has expired, CD timer running).
---@param entry EcdWatchEntry
---@param filter fun(cd):boolean?  optional cooldown filter (used by Split mode)
local function UpdateDisplay(entry, filter)
	local options = GetOptions()
	if not options then return end

	if testModeActive then
		RenderTestSpells(entry.Container, options, filter)
		return
	end
	ApplySlotsToContainer(entry.Container, CollectSlots(entry, options, filter))
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

---@param entry EcdWatchEntry
function D:UpdateSplitArenaDisplay(entry)
	UpdateDisplay(entry, function(cd) return not IsOffensiveCooldown(cd) end)
end

---Renders combined cooldowns from a set of entries into a target container.
---@param targetContainer IconSlotContainer  the destination container
---@param entries table<string, EcdWatchEntry>  source entries to aggregate from
---@param filter fun(cd):boolean?  nil = include everything
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

	local now            = GetTime()
	local showTooltips   = options.ShowTooltips
	local iconOptions    = options.Icons
	local disabledSpells = options.DisabledSpells or {}

	for _, entry in pairs(entries) do
		for cdKey, cd in pairs(entry.ActiveCooldowns) do
			if cd.UsedCharges then
				local usedCount = #cd.UsedCharges
				if usedCount > 0 then
					local texture = cd.SpellId and not disabledSpells[cd.SpellId]
						and (not filter or filter(cd))
						and GetSpellIcon(cd.SpellId)
					if texture then
						local startTime = cd.UsedCharges[1].Expiry - cd.Cooldown
						local idx = #slots + 1
						local s = GetSlotTable(idx)
						s.Texture         = texture
						s.SpellId         = showTooltips and cd.SpellId or nil
						s.DurationObject  = wowEx:CreateDuration(startTime, cd.Cooldown)
						s.Alpha           = 1
						s.ReverseCooldown = iconOptions.ReverseCooldown
						s.FontScale       = db.FontScale
						s.ChargeText      = tostring(cd.MaxCharges - usedCount)
						slots[idx] = s
					end
				end
			elseif now < cd.StartTime + cd.Cooldown then
				local texture = cd.SpellId and not disabledSpells[cd.SpellId]
					and (not filter or filter(cd))
					and GetSpellIcon(cd.SpellId)
				if texture then
					local idx = #slots + 1
					local s = GetSlotTable(idx)
					s.Texture         = texture
					s.SpellId         = showTooltips and cd.SpellId or nil
					s.DurationObject  = wowEx:CreateDuration(cd.StartTime, cd.Cooldown)
					s.Alpha           = 1
					s.ReverseCooldown = iconOptions.ReverseCooldown
					s.FontScale       = db.FontScale
					slots[idx] = s
				end
			else
				entry.ActiveCooldowns[cdKey] = nil
			end
		end
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

---Populates the dedicated Split-mode linear container with offensive cooldowns aggregated
---from all watch entries.  The defensive (non-offensive) cooldowns continue to render into
---each entry's own container via UpdateSplitArenaDisplay.
---@param splitLinearEntry table  { Container = IconSlotContainer }
---@param entries table<string, EcdWatchEntry>
function D:UpdateSplitLinearDisplay(splitLinearEntry, entries)
	if not splitLinearEntry then return end
	RenderAggregate(splitLinearEntry.Container, entries, IsOffensiveCooldown)
end

---@param entry EcdWatchEntry
---@param index number
---@param prevEntry EcdWatchEntry?
function D:AnchorContainer(entry, index, prevEntry)
	local options = GetOptions()
	if not options then return end

	-- Linear mode: arena1 is the only visible per-unit container; arena2/3 stack below it.
	-- Split / ArenaFrames mode: each per-unit container anchors to its corresponding arena frame.
	if options.DisplayMode == "Linear" then
		AnchorContainerLinear(entry, index, prevEntry)
	else
		AnchorContainerArenaFrames(entry, index)
	end
end

---Anchors the dedicated Split-mode linear container to the saved Linear position.  Reuses the
---same options.Linear.X/Y/Point as Linear mode so a single drag updates both surfaces.
---@param splitLinearEntry table  { Container = IconSlotContainer }
function D:AnchorSplitLinearContainer(splitLinearEntry)
	local options = GetOptions()
	if not options or not splitLinearEntry then return end
	local frame = splitLinearEntry.Container.Frame
	frame:ClearAllPoints()
	frame:SetFrameStrata("MEDIUM")
	frame:SetFrameLevel(100)
	frame:SetAlpha(1)
	local relTo = _G[options.Linear.RelativeTo] or UIParent
	frame:SetPoint(
		options.Linear.Point or "CENTER",
		relTo,
		options.Linear.RelativePoint or "CENTER",
		options.Linear.X or 0,
		options.Linear.Y or 200
	)
end

---@param index number
---@return table?
function D:GetArenaEnemyFrame(index)
	return GetArenaEnemyFrame(index)
end
