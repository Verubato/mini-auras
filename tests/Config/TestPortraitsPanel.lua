-- The portraits options page, driven the way the tab framework drives it.
--
-- The page is mostly checkboxes, but the unflagged buff list is built from a generated table and
-- has its own read/write path, with no other coverage: the smoke test never lays a page out, and
-- luacheck cannot catch a nil global here because the addon's config suppresses undefined globals
-- so real WoW globals stay quiet. Same blind spot the custom auras page test exists to close.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

-- Two of the unflagged buffs, and one flagged spell that must not be offered beside them.
local FEINT = 1966
local SPIRITWALKERS_GRACE = 79206
local KIDNEY_SHOT = 408

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

fw.describe("Config - when the options window is built", function()
	-- The window is a third of what the addon costs to start, and most sessions never open it.
	fw.it("waits for the first ask rather than building at login", function()
		local addon = Load()

		assert(addon.Config.Window == nil, "the window was built at login")
		assert(addon.Config.TabController == nil, "and its pages with it")

		addon.Config:EnsureWindow()

		assert(addon.Config.Window ~= nil, "asking for it builds it")
		assert(addon.Config.TabController ~= nil, "along with its pages")
	end)

	fw.it("builds it once, however often it is asked for", function()
		local addon = Load()
		local window = addon.Config:EnsureWindow()

		assert(addon.Config:EnsureWindow() == window, "a second ask built a second window")
	end)
end)

---The tab framework lays every page out as the window is built, so opening the tab is enough.
---@param addon table
---@return table content
local function ShowPage(addon)
	-- The window and its pages are built on the first ask, which for a player is opening the
	-- options; nothing exists to drive before that.
	addon.Config:EnsureWindow()

	local content = addon.Config.TabController:GetContent("Portraits")

	fw.not_nil(content, "the portraits tab exists")
	addon.Config.TabController:Select("Portraits")

	return content
end

---Whether a frame hangs off the page. Other pages build spell rows of their own, so every lookup
---below has to be scoped or it finds those first.
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

---The checkbox the list drew for a spell.
---@param spellId number
---@param page table
---@return table?
local function CheckboxFor(spellId, page)
	for _, frame in ipairs(WowMock.Frames) do
		if frame.SpellId == spellId and frame.MiniRefresh and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

---Toggles a checkbox the way a user does; it flips whatever the source currently says.
---@param chk table
local function Click(chk)
	chk:GetScript("OnClick")(chk)
end

---@param addon table
---@return table<number, boolean>
local function Spells(addon)
	return addon.Framework:GetSavedVars().Modules.PortraitModule.CustomSpells
end

---@param map table<number, boolean>
---@return number
local function Count(map)
	local total = 0

	for _ in pairs(map) do
		total = total + 1
	end

	return total
end

fw.describe("Portraits page - the unflagged buff list", function()
	fw.it("offers every unflagged buff and nothing that carries a flag", function()
		-- Each flagged category has its own layer over the portrait already, so the only thing
		-- left to offer is a buff the game flags as nothing.
		local addon = Load()
		local page = ShowPage(addon)
		local unflagged = addon.Core.AuraCategoryIds.Unflagged

		fw.truthy(Count(unflagged) > 0, "the generated list is not empty")

		for spellId in pairs(unflagged) do
			fw.not_nil(CheckboxFor(spellId, page), "a row for spell " .. spellId)
		end

		fw.eq(CheckboxFor(KIDNEY_SHOT, page), nil, "flagged CC is not offered")
	end)

	fw.it("starts with nothing ticked", function()
		local addon = Load()

		ShowPage(addon)

		fw.eq(Count(Spells(addon)), 0, "an unticked list out of the box")
	end)

	fw.it("ticking a buff writes it to the saved variables", function()
		local addon = Load()
		local page = ShowPage(addon)
		local chk = CheckboxFor(FEINT, page)

		fw.not_nil(chk, "Feint has a row")
		Click(chk)

		fw.eq(Spells(addon)[FEINT], true, "the tick reached the saved variables")
		fw.eq(Count(Spells(addon)), 1, "and nothing else came with it")
	end)

	fw.it("unticking clears the id rather than storing false", function()
		-- A stored false would survive the clean-up pass and read back as a key that is there,
		-- which is not what an untracked spell looks like anywhere else in the db.
		local addon = Load()
		local page = ShowPage(addon)
		local chk = CheckboxFor(SPIRITWALKERS_GRACE, page)

		Click(chk)
		Click(chk)

		fw.eq(Spells(addon)[SPIRITWALKERS_GRACE], nil, "the key is gone, not false")
		fw.eq(Count(Spells(addon)), 0, "the list is empty again")
	end)

	fw.it("names its rows when the page is opened, not when it is built", function()
		-- The whole window is built at login, where the client can still be too early to name a
		-- spell; a row named then would read as a bare id for the rest of the session.
		local addon = Load()
		local page = ShowPage(addon)
		local chk = CheckboxFor(FEINT, page)

		fw.eq(chk.Text:GetText(), C_Spell.GetSpellName(FEINT), "the row carries the spell's name")
	end)

	fw.it("reads its ticks back from the saved variables", function()
		local addon = Load()
		local page = ShowPage(addon)

		Spells(addon)[FEINT] = true

		local chk = CheckboxFor(FEINT, page)

		chk:MiniRefresh()

		fw.eq(chk:GetChecked(), true, "the row shows what the db holds")
	end)
end)
