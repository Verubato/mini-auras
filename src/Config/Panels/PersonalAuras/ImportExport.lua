---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.PersonalAuras.Groups
local ui = addon.Config.PersonalAurasUI
-- Every exported string starts with this, so an import can reject a profile string or a bad
-- paste before decoding. The payload is deflated CBOR, then Base64. The trailing number is
-- the payload schema, checked separately.
local IMPORT_PREFIX = "!MiniAuras:Auras:1!"
-- Strings handed out under the old addon name. Same payload but not compressed.
local MINICC_PREFIX = "!MiniCCAuras:1!"
local SCHEMA_VERSION = 1

local importWindow

---@param list PersonalAuraGroup[]
---@return string
local function Encode(list)
	local payload = { V = SCHEMA_VERSION, Groups = list }
	local compressed = C_EncodingUtil.CompressString(
		C_EncodingUtil.SerializeCBOR(payload),
		Enum.CompressionMethod.Deflate,
		Enum.CompressionLevel.OptimizeForSize)

	return IMPORT_PREFIX .. C_EncodingUtil.EncodeBase64(compressed)
end

---@param text string
---@return PersonalAuraGroup[]? imported
---@return string? error
local function Decode(text)
	text = text:gsub("%s+", "")

	local prefix
	local compressed = false
	if text:sub(1, #IMPORT_PREFIX) == IMPORT_PREFIX then
		prefix = IMPORT_PREFIX
		compressed = true
	elseif text:sub(1, #MINICC_PREFIX) == MINICC_PREFIX then
		prefix = MINICC_PREFIX
	else
		return nil, L["That is not a MiniAuras aura string."]
	end

	local decoded = C_EncodingUtil.DecodeBase64(text:sub(#prefix + 1))

	if not decoded or decoded == "" then
		return nil, L["Failed to decode the aura string."]
	end

	if compressed then
		local inflated
		local ok, result = pcall(C_EncodingUtil.DecompressString, decoded, Enum.CompressionMethod.Deflate)
		if ok then inflated = result end

		if not inflated or inflated == "" then
			return nil, L["The aura string is corrupted."]
		end

		decoded = inflated
	end

	local ok, payload = pcall(C_EncodingUtil.DeserializeCBOR, decoded)

	if not ok or type(payload) ~= "table" or type(payload.Groups) ~= "table" then
		return nil, L["The aura string is corrupted."]
	end

	-- A string from a newer version is refused rather than half-read.
	if (tonumber(payload.V) or 0) > SCHEMA_VERSION then
		return nil, L["That aura string was made by a newer version of MiniAuras."]
	end

	return payload.Groups
end

---@param text string
---@return boolean ok
---@return string message
local function ImportGroups(text)
	local imported, err = Decode(text)

	if not imported then
		return false, err
	end

	local options = ui.Options()
	local count = 0

	for _, group in ipairs(imported) do
		if type(group) == "table" then
			-- Ids are re-issued so an import cannot collide with an existing group.
			group.Id = nil
			local fresh = groups:NewGroup(options)

			for key, value in pairs(group) do
				if key ~= "Id" then
					fresh[key] = value
				end
			end

			groups:Normalise(fresh)
			options.Groups[#options.Groups + 1] = fresh
			ui.SelectedId = fresh.Id
			count = count + 1
		end
	end

	if count == 0 then
		return false, L["The aura string is corrupted."]
	end

	return true, string.format(L["Imported %d aura group(s)."], count)
end

---@return table
local function GetOrCreateImportWindow()
	if importWindow then
		return importWindow
	end

	local win = CreateFrame("Frame", addonName .. "AuraIOWindow", UIParent, "BackdropTemplate")
	win:SetSize(520, 250)
	win:SetFrameStrata("FULLSCREEN_DIALOG")
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:Hide()
	win:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	win:SetBackdropColor(0, 0, 0, 0.9)

	local innerWidth = 520 - 32

	local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", win, "TOP", 0, -10)
	title:SetText(L["Import/Export Auras"])
	title:SetTextColor(1, 0.82, 0)

	local exportLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	exportLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -42)
	exportLabel:SetText(L["Export"])

	local exportBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(exportBox)
	exportBox:SetHeight(28)
	exportBox:SetWidth(innerWidth)
	exportBox:SetPoint("TOPLEFT", exportLabel, "BOTTOMLEFT", 0, -6)
	exportBox:SetAutoFocus(false)
	exportBox:SetMaxLetters(0)
	exportBox:SetScript("OnEscapePressed", function() win:Hide() end)
	exportBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

	local importLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	importLabel:SetPoint("TOPLEFT", exportBox, "BOTTOMLEFT", 0, -18)
	importLabel:SetText(L["Import"])

	local importBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(importBox)
	importBox:SetHeight(28)
	importBox:SetWidth(innerWidth)
	importBox:SetPoint("TOPLEFT", importLabel, "BOTTOMLEFT", 0, -6)
	importBox:SetAutoFocus(false)
	importBox:SetMaxLetters(0)
	importBox:SetScript("OnEscapePressed", function() win:Hide() end)

	local importBtn = mini:Button({
		Parent = win,
		Text = L["Import"],
		Width = 100,
		OnClick = function()
			local ok, message = ImportGroups(importBox:GetText())

			mini:NotifyWithPrefix(message)

			if ok then
				importBox:SetText("")
				ui.Populate()
				ui.Apply()
				win:Hide()
			end
		end,
	})
	importBtn:SetPoint("TOPRIGHT", importBox, "BOTTOMRIGHT", 0, -14)

	local closeBtn = mini:Button({
		Parent = win,
		Text = CLOSE,
		Width = 80,
		OnClick = function() win:Hide() end,
	})
	closeBtn:SetPoint("TOPRIGHT", importBtn, "TOPLEFT", -8, 0)

	win.ExportBox = exportBox
	win.ImportBox = importBox
	importWindow = win

	return win
end

---@param list PersonalAuraGroup[]
function ui.ShowImportWindow(list)
	local win = GetOrCreateImportWindow()

	win.ExportBox:SetText(#list > 0 and Encode(list) or "")
	win.ImportBox:SetText("")
	win:ClearAllPoints()
	win:SetPoint("CENTER", UIParent, "CENTER")
	win:Show()
end
