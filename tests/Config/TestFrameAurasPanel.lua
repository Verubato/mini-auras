-- The frame auras options page. Its switches are declared as a table of labels and keys, so the
-- only thing worth driving is that a switch actually reaches the setting it names.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

-- Two curated ids from the shipped list: one the row reads under the client's name, one the
-- addon renames because the client calls it the same thing as the spell it copies.
local REJUVENATION = 774
local GERMINATION = 155777

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Whether a frame hangs off the page. Every module page carries a switch by this name, so the
---lookup below has to be scoped or it finds one of those first.
---@param frame table
---@param page table
---@return boolean
local function Inside(frame, page)
	local parent = frame.GetParent and frame:GetParent()

	while parent do
		if parent == page then
			return true
		end

		parent = parent.GetParent and parent:GetParent()
	end

	return false
end

---The switch on the frame auras page carrying a given label. The panel keeps no references to
---them, so it is found the way a player reads it.
---@param addon table
---@param labelText string
---@return table?
local function SwitchFor(addon, labelText)
	local page = addon.Config.TabController:GetContent("FrameAuras")

	fw.not_nil(page, "the frame auras tab exists")

	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

---The switch carrying a label on one particular tab of the frame auras page. Both aura rows offer
---the countdown switch under the same label, so the tab is named by a switch only it has. Every
---switch on a tab is built as a direct child of that tab's own page.
---@param addon table
---@param labelText string
---@param tabLabel string A label carried by one tab and no other.
---@return table?
local function SwitchOnTabWith(addon, labelText, tabLabel)
	local page = addon.Config.TabController:GetContent("FrameAuras")
	local sibling = SwitchFor(addon, tabLabel)

	fw.not_nil(sibling, "the page offers " .. tabLabel .. ", which names the tab")

	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page)
			and frame:GetParent() == sibling:GetParent()
		then
			return frame
		end
	end

	return nil
end

fw.describe("Frame Auras page - the debuff row's switches", function()
	fw.it("offers the dispel colours, and writes them where the row reads them", function()
		local addon = Load()

		-- The window and its pages are built on the first ask, which for a player is opening the
		-- options. Nothing exists to drive before that.
		addon.Config:EnsureWindow()

		local switch = SwitchFor(addon, addon.L["Dispel colours"])

		fw.not_nil(switch, "the debuff row offers the dispel colours")

		local options = addon.Framework:GetSavedVars().Modules.FrameAuras.Debuffs

		assert(options.ColorByDispelType == true, "they ship on")

		switch:GetScript("OnClick")(switch)

		assert(options.ColorByDispelType == false, "and the switch turns them off")
	end)
end)

fw.describe("Frame Auras page - the countdown numbers on each row", function()
	fw.it("gives each tab a switch that writes its own row and not the other", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		-- Mine belongs to the buff tab and Dispellable to the debuff tab, so each names the tab
		-- its switch has to be sitting on.
		local buffs = SwitchOnTabWith(addon, addon.L["Show numbers"], addon.L["Mine"])
		local debuffs = SwitchOnTabWith(addon, addon.L["Show numbers"], addon.L["Dispellable"])

		fw.not_nil(buffs, "the buff tab offers the numbers switch")
		fw.not_nil(debuffs, "and so does the debuff tab")
		assert(buffs ~= debuffs, "each tab has one of its own")

		local frameAuras = addon.Framework:GetSavedVars().Modules.FrameAuras

		assert(frameAuras.Buffs.EnableNumbers == false and frameAuras.Debuffs.EnableNumbers == false,
			"both rows ship without their numbers")

		buffs:GetScript("OnClick")(buffs)

		assert(frameAuras.Buffs.EnableNumbers == true, "the buff tab's switch writes the buff row")
		assert(frameAuras.Debuffs.EnableNumbers == false, "and leaves the debuff row bare")

		debuffs:GetScript("OnClick")(debuffs)

		assert(frameAuras.Debuffs.EnableNumbers == true, "the debuff tab's switch writes the debuff row")
	end)
end)

fw.describe("Frame Auras page - the buff row's switches", function()
	fw.it("names the defensives switch in the plural, and writes it where the row reads it", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local switch = SwitchFor(addon, addon.L["Defensives"])

		fw.not_nil(switch, "the buff row offers the defensives")

		local options = addon.Framework:GetSavedVars().Modules.FrameAuras.Buffs

		assert(options.ShowDefensives == false, "they ship off")

		switch:GetScript("OnClick")(switch)

		assert(options.ShowDefensives == true, "and the switch turns them on")
	end)
end)

fw.describe("Frame Auras page - the spell list's rows", function()
	fw.it("puts each spell's id in brackets behind its name", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local named = _G.C_Spell.GetSpellName(REJUVENATION) .. " |cff888888(" .. REJUVENATION .. ")|r"

		fw.not_nil(SwitchFor(addon, named), "a row named by the client carries its id")
		fw.not_nil(SwitchFor(addon, "Germination |cff888888(" .. GERMINATION .. ")|r"),
			"and so does one the addon names itself")
	end)

	fw.it("still carries the id for a name the client has not loaded yet", function()
		local addon = Load()
		local realGetSpellName = _G.C_Spell.GetSpellName

		_G.C_Spell.GetSpellName = function()
			return nil
		end

		addon.Config:EnsureWindow()

		_G.C_Spell.GetSpellName = realGetSpellName

		fw.not_nil(SwitchFor(addon, "? |cff888888(" .. REJUVENATION .. ")|r"),
			"the row stands in a question mark and keeps the id")
	end)
end)

fw.describe("Frame Auras page - the spell picker", function()
	---The picker's edit box on the spells tab, which is the only box on the page that hands a
	---spell to a callback.
	---@param addon table
	---@return table?
	local function Picker(addon)
		local page = addon.Config.TabController:GetContent("FrameAuras")

		for _, frame in ipairs(WowMock.Frames) do
			if frame.OnAccept and frame:GetScript("OnArrowPressed") and Inside(frame, page) then
				return frame
			end
		end

		return nil
	end

	---@param box table
	---@param query string
	local function Type(box, query)
		box:SetText(query)
		box:GetScript("OnTextChanged")(box, true)
	end

	fw.it("puts a spell back on the list from its name alone", function()
		_G.MiniAurasDB = nil

		-- harness.Run's two halves, so a real name can be installed in between: the suggestions
		-- are named by the client, and login is already enough to build the search index.
		local context = harness.Load("MiniAuras", {})
		local realGetSpellName = _G.C_Spell.GetSpellName

		_G.C_Spell.GetSpellName = function(spellId)
			return spellId == REJUVENATION and "Rejuvenation" or realGetSpellName(spellId)
		end

		harness.Login(context)

		local addon = context.Addon
		local spells = addon.Modules.FrameAuras.Spells

		assert(spells:IsTracked(REJUVENATION), "the curated spell ships tracked")
		spells:SetTracked(REJUVENATION, false)

		addon.Config:EnsureWindow()

		local box = Picker(addon)

		fw.not_nil(box, "the spells tab offers the picker")

		Type(box, "rejuven")
		box:GetScript("OnEnterPressed")(box)

		fw.truthy(spells:IsTracked(REJUVENATION), "half its name was enough to track it")
	end)

	fw.it("tracks a typed id the client cannot even name", function()
		local addon = Load()
		local realGetSpellName = _G.C_Spell.GetSpellName
		-- Past anything the shipped index carries, and nameless on top of that, so no suggestion
		-- can be offered for it at all.
		local unknown = 9999999

		_G.C_Spell.GetSpellName = function(spellId)
			if spellId == unknown then
				return nil
			end

			return realGetSpellName(spellId)
		end

		addon.Config:EnsureWindow()

		local box = Picker(addon)

		Type(box, tostring(unknown))
		box:GetScript("OnEnterPressed")(box)

		_G.C_Spell.GetSpellName = realGetSpellName

		fw.truthy(addon.Modules.FrameAuras.Spells:IsTracked(unknown),
			"the id was taken as typed")
	end)

	fw.it("reads a typed id as digits, not as the number Lua would make of it", function()
		local addon = Load()
		local spells = addon.Modules.FrameAuras.Spells
		-- What tonumber makes of "0x10" and "1e3", neither of which anyone typing an id means.
		local hex, exponent = 16, 1000

		assert(not spells:IsTracked(hex) and not spells:IsTracked(exponent),
			"neither ships tracked, so tracking one can only have come from the box")

		addon.Config:EnsureWindow()

		local box = Picker(addon)

		for _, typed in ipairs({ "0x10", "1e3" }) do
			Type(box, typed)
			box:GetScript("OnEnterPressed")(box)
		end

		fw.falsy(spells:IsTracked(hex), "the hex form tracked nothing")
		fw.falsy(spells:IsTracked(exponent), "and neither did the exponent form")
	end)

	fw.it("hangs its suggestions outside the scroll frames that would cut them off", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local box = Picker(addon)
		local popup

		for _, frame in ipairs(WowMock.Frames) do
			if frame:GetNumPoints() > 0 then
				local _, relativeTo = frame:GetPoint(1)

				if relativeTo == box then
					popup = frame
				end
			end
		end

		fw.not_nil(popup, "the picker has a popup anchored under its box")

		local parent = popup:GetParent()

		while parent do
			fw.truthy(parent:GetObjectType() ~= "ScrollFrame",
				"nothing between the popup and the screen clips it")
			parent = parent:GetParent()
		end
	end)
end)
