---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local iconSlotContainer = addon.Core.IconSlotContainer
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local testModeActive = false
local paused = false
local enabled = false
local maxAuras = 40
---@type table<number, any>
local auraAlphas = {}
---@type Db
local db
---@type table
local anchor
---@type IconSlotContainer
local container
local eventFrame
---@type TestSpell
local testSpell
local precogCurve

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

	local options = db.Modules.PrecogGuesserModule
	if not options then
		return
	end

	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local activeAuras = {}

	for i = 1, maxAuras do
		local auraData = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL|IMPORTANT|PLAYER")

		if not auraData then
			break
		end

		activeAuras[#activeAuras + 1] = auraData
	end

	if #activeAuras == 0 then
		container:ResetAllSlots()
		anchor:Hide()
		auraAlphas = {}
		return
	end

	-- Clean up cached alphas for auras that are no longer active
	local activeIds = {}

	for _, auraData in ipairs(activeAuras) do
		activeIds[auraData.auraInstanceID] = true
	end

	for id in pairs(auraAlphas) do
		if not activeIds[id] then
			auraAlphas[id] = nil
		end
	end

	container:ResetAllSlots()

	for i, auraData in ipairs(activeAuras) do
		local durationInfo = C_UnitAuras.GetAuraDuration("player", auraData.auraInstanceID)
		local start = durationInfo and durationInfo:GetStartTime()
		local duration = durationInfo and durationInfo:GetTotalDuration()

		-- Evaluate alpha only once when the aura is first detected
		-- because we actually need the total duration, not the remaining duration
		-- it's just there isn't a way to pipe the total duration through a curve
		if not auraAlphas[auraData.auraInstanceID] then
			auraAlphas[auraData.auraInstanceID] = durationInfo and durationInfo:EvaluateRemainingDuration(precogCurve)
		end

		local alpha = auraAlphas[auraData.auraInstanceID] or 0

		if start and duration then
			container:SetSlot(1, {
				Texture = auraData.icon,
				StartTime = start,
				Duration = duration,
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

	local texture = spellCache:GetSpellTexture(testSpell.SpellId)

	if texture then
		container:SetSlot(1, {
			Texture = texture,
			StartTime = GetTime(),
			Duration = 15,
			Alpha = true,
			ReverseCooldown = options.Icons.ReverseCooldown,
			Glow = options.Icons.Glow,
			FontScale = db.FontScale,
		})
	end
end

local function OnEvent(_, event, unit)
	if event == "UNIT_AURA" and unit == "player" then
		ScanAndDisplay()
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

function M:Enable()
	if eventFrame then
		return
	end

	enabled = true
	paused = false

	eventFrame = CreateFrame("Frame")
	eventFrame:SetScript("OnEvent", OnEvent)
	eventFrame:RegisterUnitEvent("UNIT_AURA", "player")
end

function M:Disable()
	enabled = false
	paused = true

	if eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame:SetScript("OnEvent", nil)
		eventFrame = nil
	end

	auraAlphas = {}

	if container then
		container:ResetAllSlots()
	end

	if anchor then
		anchor:Hide()
	end
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

	auraAlphas = {}

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

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.PrecogGuesser)

	if moduleEnabled and not enabled then
		M:Enable()
	elseif not moduleEnabled and enabled then
		M:Disable()
	end

	if not moduleEnabled then
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
	container:SetSpacing(db.IconSpacing or 2)

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
	container = iconSlotContainer:New(anchor, 1, iconSize, db.IconSpacing or 2, "Precognition")
	container.Frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)
	container.Frame:Show()

	precogCurve = C_CurveUtil.CreateCurve()
	precogCurve:SetType(Enum.LuaCurveType.Step)
	precogCurve:AddPoint(0, 0)
	-- precog is 4 seconds
	precogCurve:AddPoint(4, 1)
	precogCurve:AddPoint(5, 0)

	M:Refresh()
end

---@class PrecogGuesserModule
---@field Init fun(self: PrecogGuesserModule)
---@field Enable fun(self: PrecogGuesserModule)
---@field Disable fun(self: PrecogGuesserModule)
---@field Refresh fun(self: PrecogGuesserModule)
---@field StartTesting fun(self: PrecogGuesserModule)
---@field StopTesting fun(self: PrecogGuesserModule)
