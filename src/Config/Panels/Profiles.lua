---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local profileManager = addon.Core.ProfileManager
local migrator = addon.Config.Migrator

---@class ProfilesConfig
local M = {}
addon.Config.Profiles = M

local NONE_LABEL = "(none)"
local ROW_HEIGHT = 28
local SPEC_COL_W = 160

-- The payload is deflated CBOR, then Base64. Early 5.0 alphas handed out the same payload as
-- "!MiniAuras:2!", so a format change bumps to :3, not :2.
-- The Version stamp is not a format change. A build that predates it drops the extra key.
local PROFILE_PREFIX    = "!MiniAuras:1!"
-- Strings handed out under the old addon name, carrying the same payload uncompressed.
-- "!MiniCC!" is older still and carries the whole saved-vars table.
local MINICC_PREFIX     = "!MiniCC:2!"
local MINICC_V1_PREFIX  = "!MiniCC!"
local profileIOWindow

local function ExportCurrentProfile()
	profileManager:SaveCurrentProfile()
	local db = mini:GetSavedVars()
	local profileData = db.Profiles and db.Profiles[db.ActiveProfile]
	if not profileData then return "" end

	-- Stamped so an import into a later build knows which migrations the payload still needs.
	local payload = mini:CopyValueOrTable(profileData)
	payload.Version = db.Version

	local serialized = C_EncodingUtil.SerializeCBOR(payload)
	local compressed = C_EncodingUtil.CompressString(serialized,
		Enum.CompressionMethod.Deflate, Enum.CompressionLevel.OptimizeForSize)
	return PROFILE_PREFIX .. C_EncodingUtil.EncodeBase64(compressed)
end

local function ImportAsProfile(str, name)
	local encoded
	local isLegacy = false
	local compressed = false
	if str:sub(1, #PROFILE_PREFIX) == PROFILE_PREFIX then
		encoded = str:sub(#PROFILE_PREFIX + 1)
		compressed = true
	elseif str:sub(1, #MINICC_PREFIX) == MINICC_PREFIX then
		encoded = str:sub(#MINICC_PREFIX + 1)
	elseif str:sub(1, #MINICC_V1_PREFIX) == MINICC_V1_PREFIX then
		encoded = str:sub(#MINICC_V1_PREFIX + 1)
		isLegacy = true
	else
		return false, L["Invalid profile string."]
	end

	local decoded = C_EncodingUtil.DecodeBase64(encoded)
	if not decoded or decoded == "" then
		return false, L["Failed to decode profile string."]
	end

	if compressed then
		local inflated
		local ok, result = pcall(C_EncodingUtil.DecompressString, decoded, Enum.CompressionMethod.Deflate)
		if ok then inflated = result end

		if not inflated or inflated == "" then
			return false, L["Profile string is corrupted."]
		end

		decoded = inflated
	end
	local ok, data = pcall(C_EncodingUtil.DeserializeCBOR, decoded)
	if not ok or type(data) ~= "table" then
		return false, L["Profile string is corrupted."]
	end

	-- Without this a setting the addon has since moved lands under a key nothing reads, and the
	-- next login prunes it away for good. A legacy string is the whole saved-vars table, so it
	-- goes through whole.
	local profileData = data
	local migrated, isNewer = migrator:MigrateProfilePayload(profileData, data.Version)

	if isNewer then
		return false, L["This profile was exported by a newer version of the addon."]
	end

	if not migrated then
		if isLegacy then
			profileData = {}
			for _, k in ipairs(addon.Core.ProfileManager.PayloadKeys) do
				if data[k] ~= nil then profileData[k] = data[k] end
			end
		end

		profileData.Version = nil
		-- A string too old to carry a version gets the module renames alone, which is the part
		-- that loses a whole page of settings at a time.
		migrator:RenameLegacyModuleKeys(profileData)
	end

	local db = mini:GetSavedVars()
	db.Profiles = db.Profiles or {}
	if db.Profiles[name] then
		return false, string.format(L['A profile named "%s" already exists.'], name)
	end
	db.Profiles[name] = profileData
	return true
end

local function GetOrCreateProfileIOWindow()
	if profileIOWindow then
		return profileIOWindow
	end

	local win = CreateFrame("Frame", "MiniAurasProfileIOWindow", UIParent, "BackdropTemplate")
	win:SetSize(500, 310)
	win:SetFrameStrata("DIALOG")
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

	local innerWidth = 500 - 32

	local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", win, "TOP", 0, -10)
	title:SetText(L["Import/Export Profile"])
	title:SetTextColor(1, 0.82, 0)

	local divider1 = win:CreateTexture(nil, "ARTWORK")
	divider1:SetHeight(1)
	divider1:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -28)
	divider1:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -28)
	divider1:SetColorTexture(1, 1, 1, 0.15)

	local exportLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	exportLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -42)
	exportLabel:SetText(L["Export Profile"])

	local exportBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(exportBox)
	exportBox:SetHeight(28)
	exportBox:SetWidth(innerWidth)
	exportBox:SetPoint("TOPLEFT", exportLabel, "BOTTOMLEFT", 0, -6)
	exportBox:SetAutoFocus(false)
	exportBox:SetMaxLetters(0)
	exportBox:SetScript("OnEscapePressed", function() win:Hide() end)
	exportBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

	local divider2 = win:CreateTexture(nil, "ARTWORK")
	divider2:SetHeight(1)
	divider2:SetPoint("TOPLEFT", exportBox, "BOTTOMLEFT", 0, -12)
	divider2:SetPoint("TOPRIGHT", exportBox, "BOTTOMRIGHT", 0, -12)
	divider2:SetColorTexture(1, 1, 1, 0.15)

	local importSectionLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	importSectionLabel:SetPoint("TOPLEFT", divider2, "BOTTOMLEFT", 0, -12)
	importSectionLabel:SetText(L["Import Profile"])

	local nameLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	nameLabel:SetPoint("TOPLEFT", importSectionLabel, "BOTTOMLEFT", 0, -10)
	nameLabel:SetText(L["Profile Name"])

	local nameBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(nameBox)
	nameBox:SetHeight(28)
	nameBox:SetWidth(innerWidth)
	nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -4)
	nameBox:SetAutoFocus(false)
	nameBox:SetMaxLetters(64)
	nameBox:SetScript("OnEscapePressed", function() win:Hide() end)

	local stringLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	stringLabel:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", 0, -10)
	stringLabel:SetText(L["Profile String"])

	local importBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	mini:FlattenEditBox(importBox)
	importBox:SetHeight(28)
	importBox:SetWidth(innerWidth)
	importBox:SetPoint("TOPLEFT", stringLabel, "BOTTOMLEFT", 0, -4)
	importBox:SetAutoFocus(false)
	importBox:SetMaxLetters(0)
	importBox:SetScript("OnEscapePressed", function() win:Hide() end)

	local importBtn = mini:Button({
		Parent = win,
		Text = L["Import"],
		Width = 100,
	})
	importBtn:SetPoint("TOPRIGHT", importBox, "BOTTOMRIGHT", 0, -12)
	importBtn:SetScript("OnClick", function()
		local str = importBox:GetText():gsub("%s+", "")
		local name = nameBox:GetText():match("^%s*(.-)%s*$")
		if str == "" then
			mini:NotifyWithPrefix(L["Please paste a profile string to import."])
			return
		end
		if name == "" then
			mini:NotifyWithPrefix(L["Please enter a profile name."])
			return
		end
		local ok, err = ImportAsProfile(str, name)
		if not ok then
			mini:NotifyWithPrefix(err)
			return
		end
		profileManager:SwitchProfile(name)
		mini:NotifyWithPrefix(L["Profile imported successfully."])
		win:Hide()
	end)

	local closeBtn = mini:Button({
		Parent = win,
		Text = CLOSE,
		Width = 80,
		OnClick = function() win:Hide() end,
	})
	closeBtn:SetPoint("TOPRIGHT", importBtn, "TOPLEFT", -8, 0)

	win.ExportBox = exportBox
	win.ImportBox = importBox
	win.NameBox = nameBox
	profileIOWindow = win
	return win
end

local function ShowProfileIOWindow()
	local win = GetOrCreateProfileIOWindow()
	win.ExportBox:SetText(ExportCurrentProfile())
	win.ImportBox:SetText("")
	win.NameBox:SetText(profileManager:GetActiveProfile() .. " (2)")
	win:ClearAllPoints()
	win:SetPoint("CENTER", UIParent, "CENTER")
	win:Show()
end

StaticPopupDialogs["MINIAURAS_PROFILE_NAME"] = {
	text = "%s",
	button1 = OKAY,
	button2 = CANCEL,
	hasEditBox = true,
	editBoxWidth = 220,
	OnShow = function(self, data)
		self.EditBox:SetText(data and data.Default or "")
		self.EditBox:HighlightText()
		self.EditBox:SetFocus()
	end,
	OnAccept = function(self, data)
		local text = self.EditBox:GetText():match("^%s*(.-)%s*$")
		if text ~= "" and data and data.OnAccept then
			data.OnAccept(text)
		end
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		local data = parent.data
		local text = self:GetText():match("^%s*(.-)%s*$")
		if text ~= "" and data and data.OnAccept then
			data.OnAccept(text)
		end
		parent:Hide()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function MakeButton(parent, text, width, danger)
	return mini:Button({
		Parent = parent,
		Text = text,
		Width = width or 80,
		Danger = danger,
	})
end

function M:Build(panel)
	local db = mini:GetSavedVars()

	local activeLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	activeLabel:SetText(L["Active Profile"])
	activeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local profileItems = {}
	for _, name in ipairs(profileManager:GetProfileNames()) do
		profileItems[#profileItems + 1] = name
	end

	local activeDd, isModern = mini:Dropdown({
		Parent = panel,
		Items = profileItems,
		GetValue = function()
			return profileManager:GetActiveProfile()
		end,
		SetValue = function(value)
			profileManager:SwitchProfile(value)
		end,
	})
	activeDd:SetWidth(160)
	activeDd:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", isModern and 0 or -16, -4)

	local newBtn = MakeButton(panel, L["New"], 70)
	newBtn:SetPoint("TOPLEFT", activeLabel, "BOTTOMLEFT", 170, -3)

	local renameBtn = MakeButton(panel, L["Rename"], 70)
	renameBtn:SetPoint("LEFT", newBtn, "RIGHT", 4, 0)
	renameBtn:SetPoint("TOP", newBtn, "TOP")

	local cloneBtn = MakeButton(panel, L["Clone"], 70)
	cloneBtn:SetPoint("LEFT", renameBtn, "RIGHT", 4, 0)
	cloneBtn:SetPoint("TOP", renameBtn, "TOP")

	local deleteBtn = MakeButton(panel, L["Delete"], 70, true)
	deleteBtn:SetPoint("LEFT", cloneBtn, "RIGHT", 4, 0)
	deleteBtn:SetPoint("TOP", cloneBtn, "TOP")

	newBtn:SetScript("OnClick", function()
		StaticPopup_Show("MINIAURAS_PROFILE_NAME", L["New Profile"], nil, {
			Default = "",
			OnAccept = function(name)
				if db.Profiles and db.Profiles[name] then
					mini:NotifyWithPrefix(L['A profile named "%s" already exists.'], name)
					return
				end
				profileManager:SaveCurrentProfile()
				profileManager:CreateProfile(name, profileManager:GetActiveProfile())
				profileManager:SwitchProfile(name)
			end,
		})
	end)

	cloneBtn:SetScript("OnClick", function()
		local current = profileManager:GetActiveProfile()
		StaticPopup_Show("MINIAURAS_PROFILE_NAME", L["Clone Profile"], nil, {
			Default = current .. " (2)",
			OnAccept = function(name)
				if db.Profiles and db.Profiles[name] then
					mini:NotifyWithPrefix(L['A profile named "%s" already exists.'], name)
					return
				end
				profileManager:SaveCurrentProfile()
				profileManager:CreateProfile(name, current)
				profileManager:SwitchProfile(name)
			end,
		})
	end)

	renameBtn:SetScript("OnClick", function()
		local current = profileManager:GetActiveProfile()
		StaticPopup_Show("MINIAURAS_PROFILE_NAME", L["Rename Profile"], nil, {
			Default = current,
			OnAccept = function(newName)
				if newName == current then return end
				if db.Profiles and db.Profiles[newName] then
					mini:NotifyWithPrefix(L['A profile named "%s" already exists.'], newName)
					return
				end
				profileManager:RenameProfile(current, newName)
			end,
		})
	end)

	deleteBtn:SetScript("OnClick", function()
		if #profileManager:GetProfileNames() <= 1 then
			mini:NotifyWithPrefix(L["Cannot delete the last profile."])
			return
		end
		local current = profileManager:GetActiveProfile()
		StaticPopup_Show("MINIAURAS_CONFIRM",
			string.format(L['Delete profile "%s"?'], current), nil, {
				OnYes = function()
					profileManager:DeleteProfile(current)
				end,
			})
	end)

	local resetBtn = MakeButton(panel, L["Reset"], 90)
	resetBtn:SetPoint("TOPLEFT", newBtn, "BOTTOMLEFT", 0, -4)
	resetBtn:SetScript("OnClick", function()
		local current = profileManager:GetActiveProfile()
		StaticPopup_Show("MINIAURAS_CONFIRM",
			string.format(L['Reset profile "%s" to defaults?'], current), nil, {
				OnYes = function()
					profileManager:ResetCurrentProfileToDefaults()
					local tabController = addon.Config.TabController
					if tabController then
						for i = 1, #tabController.Tabs do
							local content = tabController:GetContent(tabController.Tabs[i].Key)
							mini.GUI.RefreshPanelTree(content)
						end
					end
					addon:Refresh()
					mini:NotifyWithPrefix(L["Profile reset to defaults."])
				end,
			})
	end)

	local importExportBtn = MakeButton(panel, L["Import/Export"], 140)
	importExportBtn:SetPoint("LEFT", resetBtn, "RIGHT", 4, 0)
	importExportBtn:SetPoint("TOP", resetBtn, "TOP")
	importExportBtn:SetScript("OnClick", function()
		ShowProfileIOWindow()
	end)

	-- Spacer anchored below the second button row so the divider always
	-- has a clean anchor regardless of dropdown height differences.
	local spacer = CreateFrame("Frame", nil, panel)
	spacer:SetHeight(16)
	spacer:SetPoint("TOPLEFT", resetBtn, "BOTTOMLEFT", 0, 0)
	spacer:SetPoint("RIGHT", panel, "RIGHT")

	local autoDiv = mini:Divider({
		Parent = panel,
		Text = L["Auto-Switch"],
	})
	autoDiv:SetPoint("LEFT", panel, "LEFT")
	autoDiv:SetPoint("RIGHT", panel, "RIGHT")
	autoDiv:SetPoint("TOP", spacer, "BOTTOM", 0, 0)

	local noteText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	noteText:SetText(L["Automatically switch profiles based on your specialization."])
	noteText:SetPoint("TOPLEFT", autoDiv, "BOTTOMLEFT", 0, -4)
	noteText:SetWidth(mini.ContentWidth or 600)
	noteText:SetJustifyH("LEFT")

	-- Spec rows are built on first panel show, since spec data is not ready until PLAYER_LOGIN.
	local specRows = {}
	local specRowsBuilt = false
	local prevRow = noteText

	local function BuildSpecRows()
		if specRowsBuilt then return end
		specRowsBuilt = true

		local wowEx = addon.Utils.WoWEx
		local numSpecs = wowEx:GetNumSpecializations()
		for specIdx = 1, numSpecs do
			local specId, specName, _, specIcon = wowEx:GetSpecializationInfo(specIdx)
			if specId then
				local capturedSpecId = specId
				local thisItems = { NONE_LABEL }

				local row = CreateFrame("Frame", nil, panel)
				row:SetHeight(ROW_HEIGHT)
				row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -8)
				row:SetPoint("RIGHT", panel, "RIGHT")

				local icon = row:CreateTexture(nil, "ARTWORK")
				icon:SetSize(20, 20)
				icon:SetTexture(specIcon)
				icon:SetPoint("LEFT", row, "LEFT", 0, 0)
				icon:SetPoint("TOP", row, "TOP", 0, -4)

				local lbl = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
				lbl:SetText(specName)
				lbl:SetPoint("TOPLEFT", icon, "TOPRIGHT", 4, 0)
				lbl:SetWidth(SPEC_COL_W - 28)

				local dd, ddIsModern = mini:Dropdown({
					Parent = panel,
					Items = thisItems,
					GetValue = function()
						return profileManager:GetAutoSwitchRule(capturedSpecId) or NONE_LABEL
					end,
					SetValue = function(value)
						profileManager:SetAutoSwitchRule(
							capturedSpecId,
							value == NONE_LABEL and nil or value)
					end,
				})
				dd:SetWidth(160)
				dd:SetPoint("TOPLEFT", row, "TOPLEFT",
					SPEC_COL_W + (ddIsModern and 0 or -16),
					ddIsModern and 0 or 4)

				specRows[specIdx] = { dd = dd, items = thisItems }
				prevRow = row
			end
		end
	end

	-- The panel's parent scroll container fires OnShow each time the tab is selected.
	panel:SetScript("OnShow", function()
		BuildSpecRows()
		if panel.OnMiniRefresh then panel:OnMiniRefresh() end
	end)

	panel.OnMiniRefresh = function()
		for i = #profileItems, 1, -1 do profileItems[i] = nil end
		for _, name in ipairs(profileManager:GetProfileNames()) do
			profileItems[#profileItems + 1] = name
		end

		local allItems = { NONE_LABEL }
		for _, name in ipairs(profileManager:GetProfileNames()) do
			allItems[#allItems + 1] = name
		end
		for _, rowData in pairs(specRows) do
			local items = rowData.items
			for i = #items, 1, -1 do items[i] = nil end
			for _, v in ipairs(allItems) do items[#items + 1] = v end
			rowData.dd:MiniRefresh()
		end

		if #profileManager:GetProfileNames() > 1 then
			deleteBtn:Enable()
		else
			deleteBtn:Disable()
		end

		activeDd:MiniRefresh()
	end

	panel.OnMiniRefresh()

	-- Refresh all panels whenever the active profile changes.
	profileManager:RegisterOnProfileChanged("ConfigUI", function()
		local tabController = addon.Config.TabController
		if not tabController then return end
		for i = 1, #tabController.Tabs do
			mini.GUI.RefreshPanelTree(tabController:GetContent(tabController.Tabs[i].Key))
		end
	end)
end
