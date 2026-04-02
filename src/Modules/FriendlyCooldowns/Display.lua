---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local trinketsTracker = addon.Core.TrinketsTracker
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames

-- Loaded before this file in TOC order.
local fcdTalents = addon.Modules.FriendlyCooldowns.Talents
local rules = addon.Modules.FriendlyCooldowns.Rules

addon.Modules.FriendlyCooldowns = addon.Modules.FriendlyCooldowns or {}

---@class FriendlyCooldownDisplay
local D = {}
addon.Modules.FriendlyCooldowns.Display = D

---@type Db
local db
local testModeActive = false

local function GetAnchorOptions()
	local m = db and db.Modules.FriendlyCooldownTrackerModule
	if not m then
		return nil
	end
	return instanceOptions:IsRaid() and m.Raid or m.Default
end

-- Scratch table reused by UpdateDisplay to avoid per-call allocation.
local slotsScratch = {}

-- Cache: unit -> { specId, result } — invalidated by the talent callback.
local staticAbilitiesCache = {}

local function IsInArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "arena"
end

---@class FcdStaticAbility
---@field SpellId number
---@field IsOffensive boolean

---Returns ordered list of abilities for a unit's known spells (spec rules first, then class fallback).
---Used to populate static icon slots that are always visible regardless of cooldown state.
---@param unit string
---@return FcdStaticAbility[]
local function GetStaticAbilities(unit)
	local _, classToken = UnitClass(unit)
	if not classToken then
		return {}
	end

	local specId = fcdTalents:GetUnitSpecId(unit)

	local cached = staticAbilitiesCache[unit]
	if cached and cached.specId == specId then
		return cached.result
	end

	local seen = {}
	local result = {}

	local disabledSpells = db and db.Modules and db.Modules.FriendlyCooldownTrackerModule and db.Modules.FriendlyCooldownTrackerModule.DisabledSpells or {}

	local function addRules(ruleList)
		if not ruleList then
			return
		end
		for _, rule in ipairs(ruleList) do
			if rule.SpellId and not seen[rule.SpellId] and not disabledSpells[rule.SpellId] then
				local excluded = false
				if rule.ExcludeIfTalent then
					if type(rule.ExcludeIfTalent) == "table" then
						for _, talentId in ipairs(rule.ExcludeIfTalent) do
							if fcdTalents:UnitHasTalent(unit, talentId, specId) then excluded = true; break end
						end
					else
						excluded = fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
					end
				end
				local required = rule.RequiresTalent and not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
				if not excluded and not required then
					seen[rule.SpellId] = true
					result[#result + 1] =
						{ SpellId = rule.SpellId, IsOffensive = rules.OffensiveSpellIds[rule.SpellId] == true }
				end
			end
		end
	end

	addRules(specId and rules.BySpec[specId])
	addRules(rules.ByClass[classToken])

	staticAbilitiesCache[unit] = { specId = specId, result = result }
	return result
end

---Builds the slot list shown in test mode.
local function BuildTestSlots(showTrinket, showTooltips, iconOptions)
	local now = GetTime()
	local slots = {}
	if showTrinket then
		slots[#slots + 1] = {
			Texture = trinketsTracker:GetDefaultIcon(),
			DurationObject = wowEx:CreateDuration(now - 45, 120),
			Alpha = 1,
			ReverseCooldown = false,
			Glow = false,
			FontScale = db.FontScale,
		}
	end
	local testSpells = {
		{ SpellId = 642,    StartOffset = 60,  Cooldown = 300 }, -- Divine Shield
		{ SpellId = 33206,  StartOffset = 30,  Cooldown = 180 }, -- Pain Suppression
		{ SpellId = 45438,  StartOffset = 120, Cooldown = 240 }, -- Ice Block
		{ SpellId = 190319, StartOffset = 10,  Cooldown = 120 }, -- Combustion
	}
	for _, t in ipairs(testSpells) do
		local texture = C_Spell.GetSpellTexture(t.SpellId)
		if texture then
			slots[#slots + 1] = {
				Texture = texture,
				SpellId = showTooltips and t.SpellId or nil,
				DurationObject = wowEx:CreateDuration(now - t.StartOffset, t.Cooldown),
				Alpha = 1,
				ReverseCooldown = iconOptions.ReverseCooldown,
				FontScale = db.FontScale,
			}
		end
	end
	return slots
end

---Appends always-visible static ability slots, with a cooldown swipe when active.
local function AppendStaticSlots(slots, entry, now, showTooltips, iconOptions)
	local staticAbilities = GetStaticAbilities(entry.Unit)
	for _, ability in ipairs(staticAbilities) do
		local texture = C_Spell.GetSpellTexture(ability.SpellId)
		local cd = entry.ActiveCooldowns[ability.SpellId]
		if texture then
			local durationObject = nil
			if cd and now < cd.StartTime + cd.Cooldown then
				durationObject = wowEx:CreateDuration(cd.StartTime, cd.Cooldown)
			end
			slots[#slots + 1] = {
				Texture = texture,
				SpellId = showTooltips and ability.SpellId or nil,
				DurationObject = durationObject,
				Alpha = 1,
				ReverseCooldown = iconOptions.ReverseCooldown,
				FontScale = db.FontScale,
			}
		end
	end
end

---Appends string-keyed (non-static) active-cooldown slots, pruning expired entries.
local function AppendDynamicSlots(slots, entry, now, showTooltips, iconOptions)
	for cdKey, cd in pairs(entry.ActiveCooldowns) do
		if type(cdKey) == "string" then
			if now >= cd.StartTime + cd.Cooldown then
				entry.ActiveCooldowns[cdKey] = nil
			else
				local texture = C_Spell.GetSpellTexture(cd.SpellId)
				if texture then
					slots[#slots + 1] = {
						Texture = texture,
						SpellId = showTooltips and cd.SpellId or nil,
						DurationObject = wowEx:CreateDuration(cd.StartTime, cd.Cooldown),
						Alpha = 1,
						ReverseCooldown = iconOptions.ReverseCooldown,
						FontScale = db.FontScale,
					}
				end
			end
		end
	end
end

---Populates an entry's icon container with the current cooldown/trinket slots.
---@param entry FcdWatchEntry
local function UpdateDisplay(entry)
	local anchorOptions = GetAnchorOptions()
	if not anchorOptions then
		return
	end

	-- ExcludeSelf: container is intentionally hidden; don't populate it.
	if anchorOptions.ExcludeSelf and UnitIsUnit(entry.Unit, "player") then
		return
	end

	local container = entry.Container
	local showTooltips = anchorOptions.ShowTooltips
	local iconOptions = anchorOptions.Icons
	local showTrinket = anchorOptions.ShowTrinket ~= false

	if testModeActive then
		local testSlots = BuildTestSlots(showTrinket, showTooltips, iconOptions)
		local usedCount = math.min(#testSlots, container.Count)
		for i = 1, usedCount do
			container:SetSlot(i, testSlots[i])
		end
		for i = usedCount + 1, container.Count do
			container:SetSlotUnused(i)
		end
		return
	end

	-- Reuse the scratch table to avoid per-call allocation.
	local slots = slotsScratch
	for i = 1, #slots do
		slots[i] = nil
	end

	local now = GetTime()

	-- Trinket: always slot 1 in arena so it lands at the priority position determined by InvertLayout.
	if showTrinket and IsInArena() then
		local durationData = trinketsTracker:GetUnitDuration(entry.Unit)
		slots[1] = {
			Texture = trinketsTracker:GetDefaultIcon(),
			DurationObject = durationData or wowEx:CreateDuration(0, 0),
			Alpha = true,
			ReverseCooldown = false,
			Glow = false,
			FontScale = db.FontScale,
		}
	end

	AppendStaticSlots(slots, entry, now, showTooltips, iconOptions)
	AppendDynamicSlots(slots, entry, now, showTooltips, iconOptions)

	local usedCount = math.min(#slots, container.Count)
	for i = 1, usedCount do
		container:SetSlot(i, slots[i])
	end
	for i = usedCount + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---Positions an entry's container frame relative to its anchor.
---@param entry FcdWatchEntry
local function AnchorContainer(entry)
	local options = GetAnchorOptions()
	if not options then
		return
	end

	local frame = entry.Container.Frame
	local anchor = entry.Anchor

	frame:ClearAllPoints()
	frame:SetAlpha(1)
	local strata = frames:IsBlizzardPartyFrame(anchor)
		and frames:GetNextStrata(anchor:GetFrameStrata())
		or anchor:GetFrameStrata()
	frame:SetFrameStrata(strata)
	frame:SetFrameLevel(anchor:GetFrameLevel() + 10)

	local rowsEnabled = options.Icons.Rows and options.Icons.Rows > 1

	if rowsEnabled then
		-- For multi-row, anchor the container's top edge so that the first row appears at
		-- the same position as the single-row icon (vertically centred on the party frame).
		-- Adding half an icon height to the Y offset achieves this because the top of the
		-- container sits half an icon above the first row's centre.
		local size = tonumber(options.Icons.Size) or 32
		local yOffset = options.Offset.Y + size / 2

		if options.Grow == "LEFT" then
			frame:SetPoint("TOPRIGHT", anchor, "LEFT", options.Offset.X, yOffset)
		elseif options.Grow == "RIGHT" then
			frame:SetPoint("TOPLEFT", anchor, "RIGHT", options.Offset.X, yOffset)
		elseif options.Grow == "DOWN" then
			frame:SetPoint("TOP", anchor, "BOTTOM", options.Offset.X, options.Offset.Y)
		else
			frame:SetPoint("TOP", anchor, "CENTER", options.Offset.X, yOffset)
		end
	else
		if options.Grow == "LEFT" then
			frame:SetPoint("RIGHT", anchor, "LEFT", options.Offset.X, options.Offset.Y)
		elseif options.Grow == "RIGHT" then
			frame:SetPoint("LEFT", anchor, "RIGHT", options.Offset.X, options.Offset.Y)
		elseif options.Grow == "DOWN" then
			frame:SetPoint("TOP", anchor, "BOTTOM", options.Offset.X, options.Offset.Y)
		else
			frame:SetPoint("CENTER", anchor, "CENTER", options.Offset.X, options.Offset.Y)
		end
	end

	entry.Container:SetGrowDown(options.Grow == "DOWN")
end

---Must be called once from M:Init before any display functions are used.
function D:Init()
	db = mini:GetSavedVars()
end

---@param active boolean
function D:SetTestMode(active)
	testModeActive = active
end

---@param entry FcdWatchEntry
function D:UpdateDisplay(entry)
	UpdateDisplay(entry)
end

---@param entry FcdWatchEntry
function D:AnchorContainer(entry)
	AnchorContainer(entry)
end

---Invalidates the static-abilities cache for a unit so the next UpdateDisplay rebuilds it.
---@param unit string
function D:InvalidateStaticAbilitiesCache(unit)
	staticAbilitiesCache[unit] = nil
end

---Clears the entire static-abilities cache (e.g. on PLAYER_SPECIALIZATION_CHANGED).
function D:ResetStaticAbilitiesCache()
	staticAbilitiesCache = {}
end
