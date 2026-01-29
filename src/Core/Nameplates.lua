---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local manager = addon.HeaderManager
---@type Db
local db
local eventsFrame

---@class NameplateManager
local M = {}
addon.NameplateManager = M

local function EnsureHeader(unit, nameplate)
	local header = manager:EnsureHeader(nameplate, unit)

	if not header then
		return
	end

	manager:AnchorHeader(header, nameplate, db.Nameplates.Anchor)

	local instanceOptions = manager:GetCurrentInstanceOptions()

	if not instanceOptions then
		return
	end

	manager:ShowHideHeader(header, nameplate, false, instanceOptions)
end

local function OnEvent(event, unit)
	if event == "NAME_PLATE_UNIT_ADDED" then
		local nameplate = unit and C_NamePlate.GetNamePlateForUnit(unit)

		if nameplate then
			EnsureHeader(unit, nameplate)
		end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		if unit then
			manager:ReleaseHeader(unit)
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	eventsFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
end

function M:Refresh()
	for _, nameplate in ipairs(C_NamePlate.GetNamePlates(false) or {}) do
		if nameplate and nameplate.UnitFrame and nameplate.UnitFrame.unit then
			EnsureHeader(nameplate.UnitFrame.unit, nameplate)
		end
	end
end
