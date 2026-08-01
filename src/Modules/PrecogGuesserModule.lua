---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
-- 12.1 path: the whole guess ("~4 second IMPORTANT self buff") maps directly onto an
-- AuraContainer group: HELPFUL|IMPORTANT filter + a maxDuration candidate filter. The secret
-- curve/EvaluateColorValueFromBoolean dance is only needed on the legacy path. The
-- IconSlotContainer is kept for test mode. TEMPORARY dual path: remove the legacy branch once
-- 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local testModeActive = false
local paused = false
local classHasPrecog
local precogCurve
---@type Db
local db
---@type table
local anchor
---@type IconSlotContainer
local container
---@type Watcher?
local watcher
---@type AuraContainerDisplay?
local display
---@type TestSpell
local testSpell

---@class PrecogGuesserModule : IModule
local M = {}
addon.Modules.PrecogGuesserModule = M

local function UpdateAnchorSize()
	if not anchor or not container then
		return
	end

	local options = db.Modules.PrecogGuesserModule
	local iconSize = tonumber(options.Icons.Size) or 40
	anchor:SetSize(iconSize, iconSize)
end

local function ScanAndDisplay()
	if paused then
		return
	end

	local buffState = watcher:GetBuffState()

	if #buffState == 0 then
		container:ResetAllSlots()
		anchor:Hide()
		return
	end

	local options = db.Modules.PrecogGuesserModule
	if not options then
		return
	end

	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow

	container:ResetAllSlots()

	-- Stack every self-buff onto the single slot and let the icons fight over visibility via
	-- their alpha; only precog (and Preservation Evoker's Nullifying Shroud) ends up visible.
	--
	-- Precog is "any ~4 second IMPORTANT self buff", so the alpha is the logical AND of two
	-- secret values that can't be read or compared in Lua:
	--   * the 4-second duration check - EvaluateTotalDuration maps the aura's total duration
	--     through precogCurve to 1 only at ~4s (or 3s for Evoker), else 0.
	--   * C_Spell.IsSpellImportant - whether the game flags the spell as important.
	-- C_CurveUtil.EvaluateColorValueFromBoolean merges them securely (the duration value is
	-- gated by the important boolean), and the result feeds straight into SetAlphaFromBoolean.
	for i, entry in ipairs(buffState) do
		if entry.SpellIcon and entry.SpellId and entry.DurationObject then
			local durationValue = entry.DurationObject:EvaluateTotalDuration(precogCurve)
			local isImportant = C_Spell.IsSpellImportant(entry.SpellId)
			-- AND the two secret values: use the 4-second duration result when the spell is
			-- important, otherwise force alpha 0. Signature is (boolean, valueIfTrue, valueIfFalse).
			local alpha = C_CurveUtil.EvaluateColorValueFromBoolean(isImportant, durationValue, 0)

			container:SetSlot(1, {
				Texture = entry.SpellIcon,
				DurationObject = entry.DurationObject,
				Alpha = alpha,
				ReverseCooldown = iconsReverse,
				Glow = iconsGlow,
				FontScale = db.FontScale,
				Layer = i,
			})
		end
	end

	anchor:Show()
end

local function RefreshTestIcons()
	local options = db.Modules.PrecogGuesserModule
	if not options then
		return
	end

	local texture = C_Spell.GetSpellTexture(testSpell.SpellId)

	if texture then
		container:SetSlot(1, {
			Texture = texture,
			DurationObject = wowEx:CreateDuration(GetTime(), 15),
			Alpha = true,
			ReverseCooldown = options.Icons.ReverseCooldown,
			Glow = options.Icons.Glow,
			FontScale = db.FontScale,
		})
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

-- Lifecycle

---@return PrecogGuesserModuleOptions?
local function GetOptions()
	-- The anchor and container are built in Init; without them there is nothing to configure.
	if not db or not anchor or not container then
		return nil
	end

	return db.Modules.PrecogGuesserModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.PrecogGuesser) and classHasPrecog == true
end

---The legacy watcher is the module's only event source, so enabling/disabling it is the gate.
---@param active boolean
local function SetEventsActive(active)
	if not watcher then
		return
	end

	if active and not watcher:IsEnabled() then
		watcher:Enable()
	elseif not active and watcher:IsEnabled() then
		watcher:Disable()
		watcher:ClearState(true)
	end
end

local function Teardown()
	if display then
		display:SetEnabled(false)
	end

	anchor:Hide()
end

local function EnsureFrames()
	if display then
		display:SetEnabled(true)
	end
end

---@param options PrecogGuesserModuleOptions
local function ApplyOptions(options)
	anchor:ClearAllPoints()
	anchor:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	local iconSize = tonumber(options.Icons.Size) or 40
	container:SetIconSize(iconSize)
	container:SetCount(1)
	-- Single icon, so spacing never applies; kept at the default.
	container:SetSpacing(2)

	if display then
		display:SetIconSize(iconSize)

		local style = auraContainerDisplay:GetStyleScratch()
		style.ReverseCooldown = options.Icons.ReverseCooldown
		style.Glow = options.Icons.Glow
		style.FontScale = db.FontScale
		style.ShowTooltips = false
		display:SetStyle(style)
	end

	UpdateAnchorSize()
end

---@param options PrecogGuesserModuleOptions
local function UpdateContent(options)
	if testModeActive then
		if display then
			display:Hide()
		end
		anchor:Show()
		RefreshTestIcons()
		return
	end

	if not display then
		ScanAndDisplay()
		return
	end

	-- 12.1: the container decides visibility per aura internally; the anchor just has to be
	-- shown (it is invisible itself, and mouse input is disabled outside test mode).
	container:ResetAllSlots()
	display:Show()
	anchor:Show()
end

---Visibility is left to Refresh: on 12.1 no watcher callback exists to re-show the
---container-driven display, so hiding here would blank it until the next addon-wide Refresh.
---@param active boolean
local function SetAnchorInteractive(active)
	if not anchor then
		return
	end

	anchor:EnableMouse(active)
	anchor:SetMovable(active)

	if active then
		anchor:Show()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active

	if active then
		Pause()
	else
		if container then
			container:ResetAllSlots()
		end
		Resume()
	end

	M:Refresh()
	SetAnchorInteractive(active)
end

local function CreateTestData()
	classHasPrecog = not ({
		WARRIOR = true,
		DEATHKNIGHT = true,
		ROGUE = true,
		DEMONHUNTER = true,
		HUNTER = true,
	})[UnitClassBase("player")]

	testSpell = { SpellId = 377360 }
end

local function CreateFrames()
	local options = db.Modules.PrecogGuesserModule

	anchor = CreateFrame("Frame", addonName .. "PrecogGuesser")
	anchor:Hide()
	anchor:EnableMouse(false)
	anchor:SetMovable(false)
	anchor:SetClampedToScreen(true)
	anchor:RegisterForDrag("LeftButton")
	anchor:SetIgnoreParentScale(true)
	anchor:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	anchor:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		db.Modules.PrecogGuesserModule.Point = point
		db.Modules.PrecogGuesserModule.RelativePoint = relativePoint
		db.Modules.PrecogGuesserModule.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		db.Modules.PrecogGuesserModule.Offset.X = x
		db.Modules.PrecogGuesserModule.Offset.Y = y
	end)

	local iconSize = tonumber(options.Icons.Size) or 40
	-- Single icon, so spacing never applies; kept at the default.
	container = iconSlotContainer:New(anchor, 1, iconSize, 2, "Precognition", nil, "Precognition")
	container.Frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)
	container.Frame:Show()

	if not USE_AURA_CONTAINERS then
		return
	end

	-- 12.1: IMPORTANT + a short maxDuration expresses "precog-length important self buff"
	-- natively. maxDuration 4.1 covers both the 4s precog window and the Evoker's 3s
	-- Nullifying Shroud (it is an upper bound, not an exact match like the legacy curve,
	-- so other sub-4s important buffs would also show - acceptably rare).
	-- The spell-ID map is the out-of-range garbage-buff workaround shared by every category
	-- display (see Core/AuraFilters); it has to be spliced in here rather than reused from
	-- AuraFilters.CandidateFilters because this group needs maxDuration alongside it.
	display = auraContainerDisplay:New(anchor, "player", {
		{
			Key = "precog",
			FilterString = auraFilters.Filter.ImportantOnly,
			MaxIcons = 1,
			CandidateFilters = { maxDuration = 4.1, includeSpellIDs = auraFilters.SpellIds.ImportantOnly },
		},
	}, iconSize, 2, "Precognition")
	display.Frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)
end

local function CreateEvents()
	if USE_AURA_CONTAINERS then
		-- The container tracks its own auras; no watcher and no events of our own.
		return
	end

	-- Step curve mapping an aura's total duration to an alpha: 1 only at the precog window
	-- (~4s, plus ~3s for Preservation Evoker's Nullifying Shroud), 0 everywhere else.
	-- Legacy path only; the 12.1 container expresses the window via a maxDuration filter.
	precogCurve = C_CurveUtil.CreateCurve()
	precogCurve:SetType(Enum.LuaCurveType.Step)
	precogCurve:AddPoint(0, 0)
	-- Preservation Evoker Nullifying Shroud is 3 seconds
	if UnitClassBase("player") == "EVOKER" then
		precogCurve:AddPoint(2.9, 0)
		precogCurve:AddPoint(3, 1)
		precogCurve:AddPoint(3.1, 0)
	end
	-- precog is 4 seconds
	precogCurve:AddPoint(3.9, 0)
	precogCurve:AddPoint(4, 1)
	precogCurve:AddPoint(4.1, 0)

	-- Watch every helpful self-buff (ungated); ScanAndDisplay narrows them down to the precog
	-- buff per aura via the duration curve + C_Spell.IsSpellImportant, so there's no need to
	-- filter by spell id or duration here (and duration is a secret value that can't be anyway).
	watcher = unitWatcher:New("player", nil, {
		Buffs = true,
	})

	watcher:RegisterCallback(function()
		ScanAndDisplay()
	end)
end

local function ApplyInitialState()
	M:Refresh()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local options = GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		Teardown()
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent(options)
end

function M:Init()
	db = mini:GetSavedVars()

	CreateTestData()
	CreateFrames()
	CreateEvents()
	ApplyInitialState()
end

---@class PrecogGuesserModule
---@field Init fun(self: PrecogGuesserModule)
---@field Refresh fun(self: PrecogGuesserModule)
---@field StartTesting fun(self: PrecogGuesserModule)
---@field StopTesting fun(self: PrecogGuesserModule)
