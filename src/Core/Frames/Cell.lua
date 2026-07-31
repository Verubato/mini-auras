local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of Cell party/raid unit frames.
---@param visibleOnly boolean
---@return table
function M:CellFrames(visibleOnly)
	if not CellPartyFrameHeader and not CellRaidFrameHeader0 then
		return {}
	end

	local frames = {}
	local headers = { CellPartyFrameHeader, CellSoloFrame }

	for i = 0, 8 do
		local header = _G["CellRaidFrameHeader" .. i]
		if header then
			headers[#headers + 1] = header
		end
	end

	for _, header in ipairs(headers) do
		if header then
			for _, child in ipairs({ header:GetChildren() }) do
				local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

				if unit and unit ~= "" then
					if (not child.IsForbidden or not child:IsForbidden()) and (child:IsVisible() or not visibleOnly) then
						frames[#frames + 1] = child
					end
				end
			end
		end
	end

	return frames
end

---Retrieves a list of Cell spotlight unit frames.
---@param visibleOnly boolean
---@return table
function M:CellSpotlightFrames(visibleOnly)
	if not _G["CellSpotlightFrameUnitButton1"] then
		return {}
	end

	local frames = {}

	for i = 1, 15 do
		local frame = _G["CellSpotlightFrameUnitButton" .. i]
		if not frame then
			break
		end
		if not frame.IsForbidden or not frame:IsForbidden() then
			frames[#frames + 1] = frame
		end
	end

	return frames
end

---Hooks OnShow/OnHide on all 15 Cell spotlight unit buttons, calling callback() on each change.
---Safe to call even if Cell is not loaded (buttons simply won't exist).
---@param callback fun()
function M:HookCellSpotlightVisibility(callback)
	for i = 1, 15 do
		local btn = _G["CellSpotlightFrameUnitButton" .. i]
		if btn then
			btn:HookScript("OnShow", callback)
			btn:HookScript("OnHide", callback)
		end
	end
end
