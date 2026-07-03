---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
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
---@type Watcher
local watcher
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

function M:StartTesting()
	Pause()
	testModeActive = true

	if anchor then
		anchor:EnableMouse(true)
		anchor:SetMovable(true)
		anchor:Show()
	end

	M:Refresh()
end

function M:StopTesting()
	testModeActive = false
	Resume()

	if container then
		container:ResetAllSlots()
	end

	if anchor then
		anchor:EnableMouse(false)
		anchor:SetMovable(false)
		anchor:Hide()
	end
end

function M:Refresh()
	if not anchor or not container then
		return
	end

	local options = db.Modules.PrecogGuesserModule
	if not options then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.PrecogGuesser) and classHasPrecog

	if moduleEnabled and not watcher:IsEnabled() then
		watcher:Enable()
	elseif not moduleEnabled and watcher:IsEnabled() then
		watcher:Disable()
		watcher:ClearState(true)
	end

	if not moduleEnabled then
		anchor:Hide()
		return
	end

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

	UpdateAnchorSize()

	if testModeActive then
		anchor:Show()
		RefreshTestIcons()
	else
		ScanAndDisplay()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	classHasPrecog = not ({
		WARRIOR = true,
		DEATHKNIGHT = true,
		ROGUE = true,
		DEMONHUNTER = true,
		HUNTER = true,
	})[UnitClassBase("player")]

	testSpell = { SpellId = 377360 }

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

	-- Step curve mapping an aura's total duration to an alpha: 1 only at the precog window
	-- (~4s, plus ~3s for Preservation Evoker's Nullifying Shroud), 0 everywhere else.
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

	M:Refresh()
end

---@class PrecogGuesserModule
---@field Init fun(self: PrecogGuesserModule)
---@field Refresh fun(self: PrecogGuesserModule)
---@field StartTesting fun(self: PrecogGuesserModule)
---@field StopTesting fun(self: PrecogGuesserModule)
