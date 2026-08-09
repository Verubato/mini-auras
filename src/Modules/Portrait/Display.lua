---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local kickTracker = addon.Core.KickTracker
local kickSlot = addon.Core.KickSlot
local testSpellData = addon.Core.TestSpells
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
-- TEMPORARY: units and auras only serve GetFirstImportantBuff; both die with the 12.0 path.
local units = addon.Utils.Units
local auras = addon.Utils.Auras

addon.Modules.Portrait = addon.Modules.Portrait or {}

---@class PortraitDisplay
local M = {}
addon.Modules.Portrait.Display = M

-- 12.1 path: a portrait shows ONE icon, but which aura wins has to be decided by the engine
-- (aura presence is secret), so it gets FOUR single-icon containers stacked on top of each other -
-- one per category, cc / big defensive / external defensive / important. The legacy strict
-- priority becomes frame levels: kick (IconSlotContainer, topmost) > cc > big > external >
-- important. A higher-priority container's button simply covers the ones below it, and a
-- container with no matching aura hides its own button secretly, revealing the next one down.
-- The distinct levels are load-bearing: same-level siblings draw in an ARBITRARY order (verified
-- live 2026-08-07, WoW picked a random winner), so priority cannot ride on creation order.
-- The Blizzard nameplate buffList scan for important buffs is replaced by the HELPFUL|IMPORTANT
-- container.
--
-- Not AuraSlots, despite those being the documented fit for "one icon, top-priority aura":
-- a 4-slot portrait container rendered NOTHING on the 12.1 PTR - no errors, AddAuraSlot existed
-- and returned buttons, and groups worked on the same client. No known addon uses slots, so
-- there is no outside verification either. RULE: don't reach for AuraSlots until they are proven
-- on a live build; a group with maxFrameCount = 1 is the same thing on the verified API.
-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

-- Priority stack for the portrait icon, LOWEST first: a higher-priority display simply covers
-- the ones below it, and an empty one hides its button secretly. The filters are the shared
-- partitioned ones, so an aura that qualifies for several categories only ever lands in the
-- highest of them.
local PORTRAIT_CATEGORIES = { "Important", "ExternalDefensive", "BigDefensive", "CrowdControl" }

---@type Db
local db
local testModeActive = false
-- True whenever the module is off or paused; the live render paths bail on it. Starts true:
-- the module is not enabled until its first Refresh.
local suspended = true
---@type IconSlotContainer[]
local containers = {}
---@type TestSpell?
local testSpell
-- 12.1 scratch: kick slot options, rebuilt on every kick event and expiry timer. SetSlot reads
-- it synchronously and keeps nothing.
local kickSlotScratch = {}

local function AddMask(tex, mask)
	tex:AddMaskTexture(mask)
end

---The button style every portrait display takes: cooldown direction from the options, and never
---a border, glow or mouse input. Returned in the wrapper's shared scratch, so use it and hand it
---straight to SetStyle.
---@return AuraDisplayStyle
local function BuildPortraitStyle()
	-- No Icons options table here: the cooldown direction lives on the module options root.
	local style = auraContainerDisplay:BuildStandardStyle(nil)
	style.ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown or false
	style.ShowTooltips = false

	return style
end

---12.1 path: builds the layered single-icon display stack over a portrait. Each display is
---parented to the kick container's frame so it follows the per-addon frame level adjustments the
---attach functions apply afterwards (child levels shift with the parent).
---@param kickFrame table The kick IconSlotContainer's frame (already anchored over the portrait).
---@param unit string
---@param texCoord table? {left, right, top, bottom} icon crop, per unit-frame addon.
---@param mask table? MaskTexture for round portraits (Blizzard frames).
---@param iconSize number
---@return { Displays: AuraContainerDisplay[] }
local function CreatePortraitAuraDisplay(kickFrame, unit, texCoord, mask, iconSize)
	-- One single-icon aura GROUP container per category. AuraSlots would be the natural fit,
	-- but they silently failed to render on the 12.1 PTR and no known addon exercises them -
	-- single-icon groups are the same thing ("slots" are documented as groups with
	-- maxFrameCount 1) built on the verified-working group API.
	--
	-- Levels stack UP from unitFrame+1 (the kick frame is at unitFrame-1, baseLevel two above
	-- it). The buttons render at the display's OWN level, so the lowest display must clear
	-- the unit frame itself: at the unit frame's level the frame's ring art covers every icon
	-- (ARTWORK beats our BACKGROUND icons within a level), and below it the portrait texture
	-- hides them entirely (PTR: TargetFrame at 500 hid displays at 494-497). Distinct levels
	-- are the only reliable priority - same-level siblings draw in an arbitrary order - so
	-- the top category unavoidably sits at unitFrame+4, covering art the legacy path drew
	-- under. Displays are children of the kick frame so per-addon level adjustments shift
	-- the whole stack together.
	--
	-- These go through AuraContainerDisplay like every other container in the addon: it owns
	-- the Edit Mode placeholder-aura suppression (a hand-rolled container would happily show
	-- Blizzard's fake auras over the portrait) and the deferred restyling that re-applies
	-- option changes made while aura styling was restricted.
	local baseLevel = (kickFrame:GetFrameLevel() or 0) + 2
	local displays = {}

	for index, category in ipairs(PORTRAIT_CATEGORIES) do
		local display = auraContainerDisplay:New(kickFrame, unit, {
			auraFilters:GroupSpec(category, 1, {
				-- Reverse instance-id order = newest aura first, matching the legacy Reverse sort.
				SortDirection = AuraContainerSortDirection.Reverse,
			}),
		}, iconSize, 0, "Portraits", {
			IconTexCoord = texCoord,
			IconMask = mask,
			-- Portrait icons carry no dispel border and no glow.
			Minimal = true,
			-- Seeded rather than styled afterwards. A portrait display is built the moment its
			-- unit frame turns up, and a restyle is refused for as long as auras are secret, so
			-- one created mid-arena would keep the unstyled look, mouse input and all.
			Style = BuildPortraitStyle(),
		})

		local frame = display.Frame
		frame:SetAllPoints(kickFrame)
		frame:SetIgnoreParentAlpha(true)
		-- Scale with the portrait, unlike the free-standing displays elsewhere.
		frame:SetIgnoreParentScale(false)
		frame:SetFrameLevel(baseLevel + index - 1)

		displays[#displays + 1] = display
	end

	return { Displays = displays }
end

-- TEMPORARY: only serves the legacy OnAuraInfo render; dies with the 12.0 path.
-- Returns the aura data for the unit's first important nameplate buff, or nil. These come from
-- Blizzard's own nameplate buff list, so the unit needs a visible nameplate (e.g. an enemy target
-- in range); the player's own portrait only shows one if self-nameplates are enabled. Friendly
-- nameplate buff lists aren't pre-curated to the important ones, so for friendly units an extra
-- nameplate aura filter drops the non-important junk.
local function GetFirstImportantBuff(unit)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if not (af and af.buffList and af.buffList.Iterate and not (af.IsForbidden and af:IsForbidden())) then
		return nil
	end

	local friendlyFilter = units:IsFriend(unit)
		and "HELPFUL|INCLUDE_NAME_PLATE_ONLY|RAID_IN_COMBAT|PLAYER"
		or nil

	local firstId
	af.buffList:Iterate(function(auraInstanceID)
		if firstId ~= nil then
			return
		end
		if friendlyFilter and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, friendlyFilter) then
			return
		end
		-- Drop purgeable non-defensive buffs (the non-important garbage Blizzard's enemy list bundles
		-- in); purgeable defensives like magic barriers are kept.
		if auras:IsPurgeableNonDefensive(unit, auraInstanceID) then
			return
		end
		firstId = auraInstanceID
	end)

	if not firstId then
		return nil
	end
	return C_UnitAuras.GetAuraDataByAuraInstanceID(unit, firstId)
end

function M:GetPortraitMask(unitFrame)
	-- player
	if unitFrame.PlayerFrameContainer and unitFrame.PlayerFrameContainer.PlayerPortraitMask then
		return unitFrame.PlayerFrameContainer.PlayerPortraitMask
	end

	-- target/focus
	if unitFrame.TargetFrameContainer and unitFrame.TargetFrameContainer.PortraitMask then
		return unitFrame.TargetFrameContainer.PortraitMask
	end

	-- target of target and pet frame
	if unitFrame.PortraitMask then
		return unitFrame.PortraitMask
	end

	return nil
end

function M:CreatePortraitMask(portrait)
	local parent = portrait:GetParent()
	if not parent then
		return nil
	end

	local mask = parent:CreateMaskTexture()
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(portrait)
	return mask
end

function M:ApplyMaskToLayer(layer, mask)
	if not layer then
		return
	end

	if layer.Icon then
		if mask then
			AddMask(layer.Icon, mask)
		end
		-- Crop the icon like Blizzard does
		layer.Icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
	end

	if layer.Cooldown then
		-- Keep cooldown within the portrait icon
		layer.Cooldown:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	end
end

---Builds the kick container over a portrait, with the 12.1 aura display stack underneath it.
---Returns nil when the portrait's dimensions are secret, which is the tainted-frame case.
---@return IconSlotContainer?
function M:CreateContainer(unitFrame, portrait, unit, texCoord, mask)
	-- Only 1 slot, multiple layers; no border for portrait icons
	local container = iconSlotContainer:New(unitFrame, 1, 0, 0, nil, true, "Portraits")

	-- Portrait icons are masked, and the mask texture lives on the unit frame's subtree. A
	-- flattened slot composites only its own subtree, which renders the masked icon invisible
	-- on the 12.0.7 client. One icon per portrait, so the composite saved nothing here anyway.
	local slot = container.Slots[1]
	if slot and slot.Frame then
		slot.Frame:SetFlattensRenderLayers(false)
	end

	-- Position the container over the portrait with inset
	container.Frame:SetPoint("TOPLEFT", portrait, "TOPLEFT", 2, -2)
	container.Frame:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -2, 2)
	container.Frame:SetFrameLevel(math.max(0, (unitFrame:GetFrameLevel() or 0) - 1))

	-- match the frame strata of the portrait parent
	-- some addons like ClassicFrames adjust this from LOW to MEDIUM
	-- so we want to follow it to ensure the icons are visible
	container.Frame:SetFrameStrata(portrait:GetParent():GetFrameStrata())

	-- inherit scale from portrait so icons scale with it
	container.Frame:SetIgnoreParentScale(false)

	-- Portrait icons do not fade with the parent unit frame (e.g. out of range);
	-- ignore the parent's alpha so they stay fully opaque.
	container.Frame:SetIgnoreParentAlpha(true)

	-- Skip attachment if the portrait dimensions are secret (tainted frame)
	-- seems to happen with ElvUI when their portraits are disabled
	local w = portrait:GetWidth()
	local h = portrait:GetHeight()
	if issecretvalue(w) or issecretvalue(h) then return nil end

	local size = math.min(w - 4, h - 4)
	if size <= 0 then size = 32 end

	container:SetIconSize(size)

	if USE_AURA_CONTAINERS and unit then
		-- Lift the kick slot above the whole aura display stack (displays at kick+2..+5,
		-- buttons at the display's own level) so an active kick lockout covers any aura icon.
		-- +6 leaves one level of margin in case a future build moves the buttons one above
		-- their container; the icon layer renders at slot+1. The slot frame is a child of the
		-- kick frame, so later per-addon level adjustments shift everything together and the
		-- ordering holds.
		if slot and slot.Frame then
			slot.Frame:SetFrameLevel(container.Frame:GetFrameLevel() + 6)
		end

		container.AuraDisplay = CreatePortraitAuraDisplay(container.Frame, unit, texCoord, mask, size)
		container.AuraUnit = unit
	end

	return container
end

---Adds a finished container to the render set. Kept separate from CreateContainer so the attach
---functions can apply their per-addon frame level and slot adjustments first.
---@param container IconSlotContainer
function M:AddContainer(container)
	containers[#containers + 1] = container
end

---@return IconSlotContainer[]
function M:GetContainers()
	local result = {}
	for _, container in pairs(containers) do
		result[#result + 1] = container
	end
	return result
end

---12.1 path: renders the kick icon into the kick container (the aura slots underneath handle
---everything else). Schedules a follow-up when the kick expires, since no aura event will fire
---to clear it.
---@param unit string
---@param container IconSlotContainer
function M:UpdateKickIcon(unit, container)
	if suspended then
		return
	end

	local kickEntry = kickTracker:GetKick(unit)
	local slotOptions

	if kickEntry then
		slotOptions = kickSlotScratch
		slotOptions.Texture = kickEntry.Texture
		slotOptions.DurationObject = kickEntry.DurationObject
		slotOptions.Alpha = true
		slotOptions.ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown
		slotOptions.FontScale = db.FontScale
		slotOptions.Color = kickEntry.Color
	end

	container.KickTimer = kickSlot:Render(container, kickEntry, slotOptions, container.KickTimer, function()
		container.KickTimer = nil
		M:UpdateKickIcon(unit, container)
	end)
end

---TEMPORARY: legacy 12.0 renderer; the whole portrait is drawn here, in strict priority order.
---Dies with the watcher path.
---@param unit string
---@param watcher Watcher
---@param container IconSlotContainer
function M:OnAuraInfo(unit, watcher, container)
	if suspended then
		return
	end

	local kickEntry = kickTracker:GetKick(unit)
	if kickEntry then
		container:SetSlot(1, {
			Texture = kickEntry.Texture,
			DurationObject = kickEntry.DurationObject,
			Alpha = true,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
			Color = kickEntry.Color,
		})
		return
	end

	local ccAuras = watcher:GetCcState()
	local defensiveAuras = watcher:GetDefensiveState()
	local slotIndex = 1

	-- Show the latest CC aura
	if ccAuras[1] then
		container:SetSlot(slotIndex, {
			Texture = ccAuras[1].SpellIcon,
			DurationObject = ccAuras[1].DurationObject,
			Alpha = ccAuras[1].IsCC,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show the latest defensive aura
	if defensiveAuras[1] then
		container:SetSlot(slotIndex, {
			Texture = defensiveAuras[1].SpellIcon,
			DurationObject = defensiveAuras[1].DurationObject,
			Alpha = defensiveAuras[1].IsDefensive,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show the latest important buff (read from Blizzard's nameplate buff list; lowest priority)
	local importantAura = GetFirstImportantBuff(unit)
	if importantAura then
		container:SetSlot(slotIndex, {
			Texture = importantAura.icon,
			DurationObject = C_UnitAuras.GetAuraDuration(unit, importantAura.auraInstanceID),
			-- Hide a non-important buff via alpha: IsSpellImportant is a secret boolean SetAlphaFromBoolean
			-- accepts directly. Catches the non-important garbage the purgeable filter can't (e.g. for
			-- non-dispel specs).
			Alpha = C_Spell.IsSpellImportant(importantAura.spellId),
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- No auras to display, clear the slot if it was used
	container:SetSlotUnused(slotIndex)
end

---12.1 path: re-reads every aura on the containers tracking a unit, for when the token's occupant
---changes rather than its auras.
---@param unit string
function M:RefreshUnitAuras(unit)
	for _, container in pairs(containers) do
		if container.AuraUnit == unit and container.AuraDisplay then
			for _, display in ipairs(container.AuraDisplay.Displays) do
				display:RequestRefresh()
			end
		end
	end
end

function M:RefreshTestIcons()
	local spellId = testSpell.SpellId
	local tex = C_Spell.GetSpellTexture(spellId)
	local now = GetTime()

	for _, container in pairs(containers) do
		moduleUtil:SetTestLabel(container.Frame, L["Portraits_Short"] or L["Portraits"])
		container:SetSlot(1, {
			Texture = tex,
			DurationObject = wowEx:CreateDuration(now, 15),
			Alpha = true,
			Glow = false,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
	end
end

function M:ResetAllSlots()
	for _, container in pairs(containers) do
		container:ResetAllSlots()
	end
end

---@param value boolean
function M:SetSuspended(value)
	suspended = value
end

---@param active boolean
function M:SetTestMode(active)
	testModeActive = active
end

function M:Teardown()
	for _, container in pairs(containers) do
		container:ResetAllSlots()
		if container.AuraDisplay then
			for _, display in ipairs(container.AuraDisplay.Displays) do
				display:SetEnabled(false)
				display:Hide()
			end
		end
	end
end

function M:EnsureFrames()
	for _, container in pairs(containers) do
		if container.AuraDisplay then
			for _, display in ipairs(container.AuraDisplay.Displays) do
				display:SetEnabled(true)
				display:Show()
			end
		end
	end
end

function M:ApplyOptions()
	if not USE_AURA_CONTAINERS then
		return
	end

	-- 12.1: re-apply the button style (the wrapper defers it if aura styling is currently
	-- restricted and retries once it lifts) and hide the live displays in test mode so real and
	-- fake icons don't mix.
	local style = BuildPortraitStyle()

	for _, container in pairs(containers) do
		local auraDisplay = container.AuraDisplay
		if auraDisplay then
			for _, display in ipairs(auraDisplay.Displays) do
				display:SetStyle(style)
				display:SetShown(not testModeActive)
			end
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	-- One icon, so only the first preview spell is ever shown.
	testSpell = testSpellData.CrowdControl[1]
end
