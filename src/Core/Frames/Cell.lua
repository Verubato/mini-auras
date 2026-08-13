local _, addon = ...
local M = addon.Core.Frames
local childScratch = {}
local headers = {}

---Appends the Cell party/raid unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:CellFrames(visibleOnly, frames)
	if not CellPartyFrameHeader and not CellRaidFrameHeader0 then
		return
	end

	wipe(headers)

	-- Appended rather than placed, so a missing party header cannot leave a hole that stops
	-- ipairs before it reaches the raid ones.
	headers[#headers + 1] = CellPartyFrameHeader
	headers[#headers + 1] = CellSoloFrame

	for i = 0, 8 do
		headers[#headers + 1] = _G["CellRaidFrameHeader" .. i]
	end

	for _, header in ipairs(headers) do
		M:AppendUnitChildren(childScratch, header, visibleOnly, frames)
	end
end

---Appends the Cell spotlight unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:CellSpotlightFrames(visibleOnly, frames)
	if not _G["CellSpotlightFrameUnitButton1"] then
		return
	end

	for i = 1, 15 do
		local frame = _G["CellSpotlightFrameUnitButton" .. i]
		if not frame then
			break
		end
		if not frame.IsForbidden or not frame:IsForbidden() then
			frames[#frames + 1] = frame
		end
	end
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
