---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L

local WIDTH = 180
local HEIGHT = 104
local BOX_WIDTH = 52
local BOX_LEFT = 38
local NUDGE_SIZE = 20
-- One pixel a press: the whole point of typing a number here is the placement a drag cannot hit.
local STEP = 1
-- How often the editor checks that what it is placing can still be placed. A group's preview can
-- end without test mode stopping, and the numbers would then be writing to something off screen.
local GUARD_INTERVAL = 0.25
local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local editor
---@type PositionBinding?
local binding
local sinceGuard = 0

---@class PositionEditor
local M = {}
addon.Core.PositionEditor = M

---The bound offsets, rounded: the drag path writes whole pixels and the boxes only take whole
---numbers, so a fractional value would show as one number and save as another.
---@return number x
---@return number y
local function ReadOffset()
	if not binding then
		return 0, 0
	end

	local x, y = binding.Get()

	return math.floor((tonumber(x) or 0) + 0.5), math.floor((tonumber(y) or 0) + 0.5)
end

---@param x number
---@param y number
local function WriteOffset(x, y)
	if not binding then
		return
	end

	binding.Set(x, y)
	-- A module can re-pin its anchor as it saves, which moves the numbers; show what landed
	-- rather than what was typed.
	editor.Fields:MiniRefresh()
end

---@param axis string "X" or "Y"
---@param step number
local function Nudge(axis, step)
	local x, y = ReadOffset()

	if axis == "X" then
		WriteOffset(x + step, y)
	else
		WriteOffset(x, y + step)
	end
end

---The axis name is the label: "X" and "Y" read the same in every language the addon ships, and
---the translated "Offset X" runs past the editor's edge in half of them.
---@param parent table
---@param axis string "X" or "Y"
---@param y number
---@return table box
local function CreateAxisRow(parent, axis, y)
	local row = mini:EditBox({
		Parent = parent,
		LabelText = axis,
		Numeric = true,
		AllowNegatives = true,
		Width = BOX_WIDTH,
		GetValue = function()
			local x, yValue = ReadOffset()

			return axis == "X" and x or yValue
		end,
		SetValue = function(value)
			local typed = tonumber(value)

			if not typed then
				return
			end

			typed = math.floor(typed + 0.5)

			local x, yValue = ReadOffset()

			if axis == "X" then
				WriteOffset(typed, yValue)
			else
				WriteOffset(x, typed)
			end
		end,
	})

	local box = row.EditBox
	box:SetPoint("TOPLEFT", parent, "TOPLEFT", BOX_LEFT, y)
	row.Label:SetPoint("RIGHT", box, "LEFT", -10, 0)

	local minus = mini:Button({
		Parent = parent,
		Text = "-",
		Width = NUDGE_SIZE,
		Height = NUDGE_SIZE,
		OnClick = function()
			Nudge(axis, -STEP)
		end,
	})
	minus:SetPoint("LEFT", box, "RIGHT", 8, 0)

	local plus = mini:Button({
		Parent = parent,
		Text = "+",
		Width = NUDGE_SIZE,
		Height = NUDGE_SIZE,
		OnClick = function()
			Nudge(axis, STEP)
		end,
	})
	plus:SetPoint("LEFT", minus, "RIGHT", 4, 0)

	return box
end

---@param frame table
local function PlaceAtCursor(frame)
	local x, y = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()

	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale + 16, y / scale - 8)
end

local function OnGuard(_, elapsed)
	sinceGuard = sinceGuard + elapsed

	if sinceGuard < GUARD_INTERVAL then
		return
	end

	sinceGuard = 0

	if not binding or (binding.IsActive and not binding.IsActive()) then
		M:Close()
	end
end

---@return table
local function GetOrCreateEditor()
	if editor then
		return editor
	end

	editor = CreateFrame("Frame", nil, UIParent, mini.GUI.BackdropTemplate)
	editor:SetSize(WIDTH, HEIGHT)
	editor:SetFrameStrata("DIALOG")
	editor:SetClampedToScreen(true)
	editor:SetMovable(true)
	editor:EnableMouse(true)
	editor:RegisterForDrag("LeftButton")
	editor:SetScript("OnDragStart", editor.StartMoving)
	editor:SetScript("OnDragStop", editor.StopMovingOrSizing)
	editor:SetScript("OnUpdate", OnGuard)
	editor:Hide()

	mini.GUI.ApplyBackdrop(editor, BACKDROP, 0, 0, 0, 0.9)

	local title = editor:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", editor, "TOPLEFT", 10, -9)
	title:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -28, -9)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)
	title:SetTextColor(1, 0.82, 0)

	local divider = editor:CreateTexture(nil, "ARTWORK")
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", editor, "TOPLEFT", 8, -26)
	divider:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -8, -26)
	mini.GUI.SetSolid(divider, 1, 1, 1, 0.15)

	local close = mini:Button({
		Parent = editor,
		Text = "x",
		Width = 18,
		Height = 18,
		OnClick = function()
			M:Close()
		end,
	})
	close:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -6, -6)

	local fields = CreateFrame("Frame", nil, editor)
	fields:SetPoint("TOPLEFT", editor, "TOPLEFT", 0, -30)
	fields:SetPoint("BOTTOMRIGHT", editor, "BOTTOMRIGHT", 0, 0)

	editor.Title = title
	editor.Fields = fields
	editor.XBox = CreateAxisRow(fields, "X", -12)
	editor.YBox = CreateAxisRow(fields, "Y", -40)

	return editor
end

---Shows the editor bound to one draggable, at the cursor.
---@param newBinding PositionBinding
function M:Open(newBinding)
	if not newBinding then
		return
	end

	-- Before the widgets are built: their first read of the offsets goes through whatever is
	-- bound, and a half-built editor showing the last draggable's numbers is worse than none.
	binding = newBinding
	sinceGuard = 0

	local frame = GetOrCreateEditor()

	frame.Title:SetText(newBinding.Title or L["Position"])
	frame.Fields:MiniRefresh()
	PlaceAtCursor(frame)
	frame:Show()
	frame:Raise()
end

---Opens the editor, or closes it when it is already bound to this same draggable, so the click
---that opened it also puts it away.
---@param newBinding PositionBinding
function M:Toggle(newBinding)
	if newBinding and self:IsOpenFor(newBinding.Key) then
		self:Close()
		return
	end

	self:Open(newBinding)
end

---Shows the editor for a draggable that has just been dropped: opened at the cursor when it is
---not already up, and left where the user parked it when it is.
---@param newBinding PositionBinding
function M:OpenOrRefresh(newBinding)
	if not newBinding then
		return
	end

	if self:IsOpenFor(newBinding.Key) then
		self:Refresh(newBinding.Key)
		return
	end

	self:Open(newBinding)
end

---Re-reads the bound offsets, for a drag that moved what the editor is showing.
---@param key any
function M:Refresh(key)
	if not self:IsOpenFor(key) then
		return
	end

	-- Never over a half-typed number: the drop is behind the user, what they are typing is not.
	if editor.XBox:HasFocus() or editor.YBox:HasFocus() then
		return
	end

	editor.Fields:MiniRefresh()
end

function M:Close()
	binding = nil

	if editor then
		editor:Hide()
	end
end

---@param key any
---@return boolean
function M:IsOpenFor(key)
	return editor ~= nil and editor:IsShown() and binding ~= nil and binding.Key == key
end

---One thing that can be placed by hand: how to read its offsets, how to write them back, and
---whether it is still there to place. Callers keep one binding per draggable rather than building
---one per click, so the editor can tell a second click on the same draggable from a first click
---on another.
---@class PositionBinding
---@field Key any Identity of the draggable, compared to spot a repeat click.
---@field Title string? Shown as the editor's heading; the draggable's test caption.
---@field Get fun(): number, number
---@field Set fun(x: number, y: number)
---@field IsActive fun(): boolean? Whether the draggable can still be placed; nil means always.
