-- The personal aura options page, built against a db that already has a group in it. The smoke
-- test never lays this page out, and luacheck cannot catch a nil global here because the addon's
-- config suppresses undefined globals so real WoW globals stay quiet.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

-- Two curated ids given real names, because the spell picker's suggestions are named by the
-- client rather than by the shipped index, which is what makes them work outside English. The
-- mock names every spell "Spell <id>", so without this the arrow-key tests have nothing to walk.
local ARCANE_TORRENT = 33390
local KIDNEY_SHOT = 408

---Installs those names over the mock's default. Has to sit between the client install and login:
---the install replaces C_Spell, and login is already enough to make the picker build its index.
local function NameFixtureSpells()
	local realGetSpellName = _G.C_Spell.GetSpellName
	local names = {
		[ARCANE_TORRENT] = "Arcane Torrent",
		[KIDNEY_SHOT] = "Arcane Barrage",
	}

	_G.C_Spell.GetSpellName = function(spellId)
		return names[spellId] or realGetSpellName(spellId)
	end
end

---@return table addon
---@return table group
local function LoadWithGroup(spells)
	_G.MiniAurasDB = nil

	-- harness.Run's two halves, so the spell names can be installed in between.
	local context = harness.Load("MiniAuras", {})
	NameFixtureSpells()
	context.LoginResult = harness.Login(context)

	local addon = context.Addon
	local db = addon.Framework:GetSavedVars()
	local groups = addon.Modules.PersonalAuras.Groups
	local options = db.Modules.PersonalAuras
	local group = groups:NewGroup(options, "Test Group")

	group.Spells = spells or {}
	groups:Normalise(group)
	options.Groups[1] = group

	return addon, group
end

---Drives the page the way the tab framework does when the tab is selected. The page opens with
---nothing selected, so a group to edit has to be clicked the way a user would.
---@param addon table
---@param group table? The group to select once the page is built.
---@return table content
local function ShowPage(addon, group)
	-- The window and its pages are built on the first ask, which for a player is opening the
	-- options. Nothing exists to drive before that.
	addon.Config:EnsureWindow()

	local content = addon.Config.TabController:GetContent("PersonalAuras")

	fw.not_nil(content, "the personal auras tab exists")

	local onShow = content:GetScript("OnShow")

	fw.not_nil(onShow, "the page rebuilds itself on show")
	onShow(content)

	if group then
		local tile

		for _, frame in ipairs(WowMock.Frames) do
			if frame.GroupId == group.Id then
				tile = frame
			end
		end

		fw.not_nil(tile, "the group has a tile to click")
		tile:GetScript("OnClick")(tile)
	end

	return content
end

---The clickable row the recorder strip built for a spell, found by walking the mock's frame
---registry: the panel keeps them to itself and there is no other way in.
---@param spellId number
---@return table?
local function RecordedRow(spellId)
	for _, frame in ipairs(WowMock.Frames) do
		if frame.SpellId == spellId and frame.GetScript and frame:GetScript("OnClick") then
			return frame
		end
	end

	return nil
end

---The grid tile drawing one group, found the same way.
---@param groupId string
---@return table?
local function TileFor(groupId)
	for _, frame in ipairs(WowMock.Frames) do
		if frame.GroupId == groupId then
			return frame
		end
	end

	return nil
end

---The slider spanning exactly this range, which is how each of the three is told apart without
---the panel handing out references to them.
---@param minimum number
---@param maximum number
---@return table?
local function SliderFor(minimum, maximum)
	for _, frame in ipairs(WowMock.Frames) do
		if frame.GetMinMaxValues then
			local low, high = frame:GetMinMaxValues()

			if low == minimum and high == maximum then
				return frame
			end
		end
	end

	return nil
end

---The appearance tab's two offset boxes, in the order they were built: X first, then Y. They are
---the only edit boxes on the page that span exactly this width.
---@return table? offsetX
---@return table? offsetY
local function OffsetBoxes()
	local found = {}

	for _, frame in ipairs(WowMock.Frames) do
		if frame:IsObjectType("EditBox") and frame:GetWidth() == 70 then
			found[#found + 1] = frame
		end
	end

	return found[1], found[2]
end

---@param box table
---@param text string
local function TypeInto(box, text)
	box:SetText(text)
	box:GetScript("OnEnterPressed")(box)
end

fw.describe("Personal auras page - typing a group's offset", function()
	fw.it("shows the screen position of a group anchored to the screen", function()
		local addon, group = LoadWithGroup({ 45438 })

		group.Position.X = 123
		group.Position.Y = -45

		ShowPage(addon, group)

		local offsetX, offsetY = OffsetBoxes()

		fw.not_nil(offsetX, "the offset X box exists")
		fw.not_nil(offsetY, "the offset Y box exists")
		fw.eq(offsetX:GetText(), "123", "X shows the group's screen position")
		fw.eq(offsetY:GetText(), "-45", "Y shows it too")
	end)

	fw.it("writes what was typed back to the screen position", function()
		local addon, group = LoadWithGroup({ 45438 })

		ShowPage(addon, group)

		local offsetX, offsetY = OffsetBoxes()

		TypeInto(offsetX, "-200")
		TypeInto(offsetY, "80")

		fw.eq(group.Position.X, -200, "X was written to the group")
		fw.eq(group.Position.Y, 80, "and so was Y")
	end)

	-- The same two boxes drive a different pair of fields, because a nameplate group is placed by
	-- an offset from the plate rather than a point on the screen.
	fw.it("writes to the frame offset for a group anchored to nameplates", function()
		local addon, group = LoadWithGroup({ 118 })
		local groups = addon.Modules.PersonalAuras.Groups

		group.Unit = "nameplate"
		group.AuraType = "HARMFUL"
		groups:Normalise(group)

		ShowPage(addon, group)

		local offsetX = OffsetBoxes()

		TypeInto(offsetX, "35")

		fw.eq(group.Offset.X, 35, "the plate offset took the value")
		fw.eq(group.Position.X, 0, "the screen position was left alone")
	end)

	fw.it("keeps the old value when the text is not a number", function()
		local addon, group = LoadWithGroup({ 45438 })

		group.Position.X = 60

		ShowPage(addon, group)

		local offsetX = OffsetBoxes()

		TypeInto(offsetX, "-")

		fw.eq(group.Position.X, 60, "garbage does not move the group")
		fw.eq(offsetX:GetText(), "60", "and the box snaps back to it")
	end)
end)

fw.describe("Personal auras page - controls inside a tab", function()
	-- Every control registers for refresh against its parent, so the ones inside a tab are on
	-- the tab's list, not the editor's. Refreshing only the editor left them showing the values
	-- they were built with, which is the state before any group existed.
	fw.it("shows the selected group's values on the appearance sliders", function()
		local addon, group = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups

		group.Icons.Size = 64
		group.Icons.Spacing = 9
		groups:Normalise(group)

		ShowPage(addon, group)

		local iconSize = SliderFor(groups.MinIconSize, groups.MaxIconSize)
		local spacing = SliderFor(0, 50)

		fw.not_nil(spacing, "the icon padding slider exists")
		fw.eq(spacing:GetValue(), 9, "padding shows the group's value")

		fw.not_nil(iconSize, "the icon size slider exists")
		fw.eq(iconSize:GetValue(), 64, "icon size shows the group's value")
	end)
end)

fw.describe("Personal auras page - the cast recorder", function()
	fw.it("adds the spell when a recorded cast is clicked", function()
		local addon, group = LoadWithGroup({})
		local recorder = addon.Modules.PersonalAuras.Recorder
		local spellId = 45438

		ShowPage(addon, group)

		recorder:Start()
		WowMock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", spellId)
		ShowPage(addon, group)

		local row = RecordedRow(spellId)

		fw.not_nil(row, "the recorded cast has a row to click")

		row:GetScript("OnClick")(row)

		fw.eq(#group.Spells, 1, "clicking it added the spell")
		fw.eq(group.Spells[1], spellId, "and it is the one that was clicked")
		fw.truthy(not recorder:IsRecording(), "picking one stops the recording")
	end)
end)

fw.describe("Personal auras page - a group saved by an older version", function()
	-- Config:Init builds this page before any module's Init, so NormaliseGroups has not run yet.
	-- A group stored before the filter settings existed therefore reaches the page with no
	-- Filters, Candidates or Exclude table at all, and the page indexes all three directly.
	fw.it("lays out a group that predates the filter settings", function()
		local addon = LoadWithGroup({ 45438 })
		local options = addon.Framework:GetSavedVars().Modules.PersonalAuras
		local group = options.Groups[1]

		group.Filters = nil
		group.Candidates = nil
		group.TrackingMode = nil
		group.Caster = nil
		group.Sort = nil

		ShowPage(addon, group)

		fw.eq(type(group.Filters), "table", "the page filled the missing tables in")
		fw.eq(type(group.Candidates), "table", "including the aura flags")
	end)

	fw.it("lays out a second, unselected group that is also missing them", function()
		-- Only the selected group goes through the editor, so the grid tiles have to be safe too.
		local addon = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups
		local options = addon.Framework:GetSavedVars().Modules.PersonalAuras
		local second = groups:NewGroup(options, "Older")

		options.Groups[2] = second
		second.Filters = nil
		second.Candidates = nil

		ShowPage(addon)

		fw.eq(type(second.Filters), "table", "the unselected group was filled in as well")
	end)
end)

fw.describe("Personal auras page - the two tracking modes", function()
	---Every tri-state button the components grid built, found by the marker only they carry.
	---@return table[]
	local function ComponentButtons(groups)
		local wanted = {}

		for _, key in ipairs(groups.FilterComponents) do
			wanted[key] = true
		end

		local found = {}

		for _, frame in ipairs(WowMock.Frames) do
			if frame.StateKey and wanted[frame.StateKey] then
				found[#found + 1] = frame
			end
		end

		return found
	end

	---@param buttons table[]
	---@return number
	local function ShownCount(buttons)
		local count = 0

		for _, button in ipairs(buttons) do
			if button:IsShown() then
				count = count + 1
			end
		end

		return count
	end

	-- The buttons are anchored to their row but parented to the panel, so collapsing the row to a
	-- pixel leaves all nine drawn on top of the message and the spell list underneath.
	fw.it("hides the filter components while the group tracks spell ids", function()
		local addon, group = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups

		group.TrackingMode = groups.TrackingMode.Spells
		groups:Normalise(group)
		ShowPage(addon, group)

		local buttons = ComponentButtons(groups)

		fw.truthy(#buttons > 0, "the grid was built")
		fw.eq(ShownCount(buttons), 0, "none of the component buttons are on screen")
	end)

	fw.it("shows them again once the group tracks by filter", function()
		local addon, group = LoadWithGroup({})
		local groups = addon.Modules.PersonalAuras.Groups

		group.TrackingMode = groups.TrackingMode.Filters
		groups:Normalise(group)
		ShowPage(addon, group)

		fw.eq(ShownCount(ComponentButtons(groups)), #groups.FilterComponents,
			"every component is offered")
	end)
end)

fw.describe("Personal auras page - walking the suggestions with the arrow keys", function()
	---The spell picker's edit box, found by the placeholder only it carries.
	---@return table?
	local function Picker()
		for _, frame in ipairs(WowMock.Frames) do
			if frame.OnAccept and frame:GetScript("OnArrowPressed") then
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

	fw.it("adds the highlighted suggestion rather than the best match", function()
		local addon, group = LoadWithGroup({})

		ShowPage(addon, group)

		local box = Picker()

		fw.not_nil(box, "the spell picker exists")

		Type(box, "arcane")

		local first = addon.Core.SpellSearch:Search("arcane", 8)[1]
		local second = addon.Core.SpellSearch:Search("arcane", 8)[2]

		fw.not_nil(second, "the query offers more than one suggestion")

		-- Down twice lands on the second, which is not what Enter would have taken on its own.
		box:GetScript("OnArrowPressed")(box, "DOWN")
		box:GetScript("OnArrowPressed")(box, "DOWN")
		box:GetScript("OnEnterPressed")(box)

		fw.eq(group.Spells[1], second.Id, "the second suggestion was added")
		fw.truthy(second.Id ~= first.Id, "and it really was not the best match")
	end)

	fw.it("wraps from the top of the list round to the bottom", function()
		local addon, group = LoadWithGroup({})

		ShowPage(addon, group)

		local box = Picker()
		local results = addon.Core.SpellSearch:Search("arcane", 8)

		Type(box, "arcane")

		-- Up from nothing enters the list at the last row.
		box:GetScript("OnArrowPressed")(box, "UP")
		box:GetScript("OnEnterPressed")(box)

		fw.eq(group.Spells[1], results[#results].Id, "the last suggestion was added")
	end)

	fw.it("falls back to the best match when the arrows were never used", function()
		local addon, group = LoadWithGroup({})

		ShowPage(addon, group)

		local box = Picker()

		Type(box, "arcane")
		box:GetScript("OnEnterPressed")(box)

		fw.eq(group.Spells[1], addon.Core.SpellSearch:Search("arcane", 1)[1].Id,
			"Enter alone still takes the top suggestion")
	end)

	fw.it("forgets where the arrows were once the query changes", function()
		local addon, group = LoadWithGroup({})

		ShowPage(addon, group)

		local box = Picker()

		Type(box, "arcane")
		box:GetScript("OnArrowPressed")(box, "DOWN")
		box:GetScript("OnArrowPressed")(box, "DOWN")

		-- A new query rebuilds the list, so the old position means nothing.
		Type(box, "arcane t")
		box:GetScript("OnEnterPressed")(box)

		fw.eq(group.Spells[1], addon.Core.SpellSearch:Search("arcane t", 1)[1].Id,
			"Enter took the new best match, not the old second row")
	end)
end)

fw.describe("Personal auras page - selecting and deselecting", function()
	---@param addon table
	---@return boolean
	local function EditorShown(addon)
		-- The editor is the frame the tab strip lives on, found through one of its tab panels.
		for _, frame in ipairs(WowMock.Frames) do
			if frame.SelectTab then
				return frame:IsShown()
			end
		end

		return false
	end

	fw.it("opens with nothing selected, so the settings are put away", function()
		local addon = LoadWithGroup({ 45438 })

		ShowPage(addon)

		fw.truthy(not EditorShown(addon), "no group is selected until one is clicked")
	end)

	fw.it("shows the settings once a group is clicked", function()
		local addon, group = LoadWithGroup({ 45438 })

		ShowPage(addon, group)

		fw.truthy(EditorShown(addon), "clicking a tile opens its settings")
	end)

	fw.it("puts them away again when the space around the tiles is clicked", function()
		local addon, group = LoadWithGroup({ 45438 })

		ShowPage(addon, group)

		local background = _G["MiniAurasPersonalAuraGrid"]

		fw.not_nil(background, "the grid takes the clicks its tiles do not")
		background:GetScript("OnClick")(background)

		fw.truthy(not EditorShown(addon), "the settings are hidden again")
	end)
end)

fw.describe("Personal auras page - reordering the grid", function()
	-- Two tiles in a row, laid out the way the grid does it: 56 wide, 12 apart. The mock gives
	-- every frame the same rect, so the drop hit test needs real ones to mean anything.
	local TILE, GAP = 56, 12

	---@param tile table
	---@param slot number Zero based position in the row.
	local function PlaceTile(tile, slot)
		local left = slot * (TILE + GAP)

		tile.GetLeft = function() return left end
		tile.GetRight = function() return left + TILE end
		tile.GetBottom = function() return 0 end
		tile.GetTop = function() return TILE end
	end

	local realCursorPosition = _G.GetCursorPosition

	---@param x number
	local function PutCursorAt(x)
		_G.GetCursorPosition = function() return x, TILE / 2 end
	end

	---@return table addon
	---@return table options
	---@return table second
	local function TwoGroups()
		local addon = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups
		local options = addon.Framework:GetSavedVars().Modules.PersonalAuras
		local second = groups:NewGroup(options, "Second")

		second.Spells = { 118 }
		groups:Normalise(second)
		options.Groups[2] = second

		ShowPage(addon)

		return addon, options, second
	end

	---@param dragged table
	local function Drag(dragged)
		dragged:GetScript("OnDragStart")(dragged)
		-- The ghost and the drop bar are built on the first frame of the drag, not up front.
		dragged:GetScript("OnUpdate")(dragged)
		dragged:GetScript("OnDragStop")(dragged)

		_G.GetCursorPosition = realCursorPosition
	end

	-- The tiles carry the id of the group they draw, and the drop handler reads it off both the
	-- dragged tile and the one under the cursor. It was never assigned, so every drop was a no-op.
	fw.it("moves a group when its tile is dropped on another", function()
		local _, options, second = TwoGroups()
		local first, last = TileFor(options.Groups[1].Id), TileFor(second.Id)

		fw.not_nil(first, "the first group has a tile")
		fw.not_nil(last, "the second group has a tile")

		PlaceTile(first, 0)
		PlaceTile(last, 1)
		PutCursorAt(TILE / 2)

		Drag(last)

		fw.eq(options.Groups[1].Id, second.Id, "the dragged group took the first slot")
	end)

	-- The gap between two tiles is 12 wide. Requiring a direct hit meant a drop landing there did
	-- nothing, so the group had to be dropped exactly on top of its neighbour.
	fw.it("moves a group dropped in the gap between two tiles", function()
		local _, options, second = TwoGroups()
		local first, last = TileFor(options.Groups[1].Id), TileFor(second.Id)

		PlaceTile(first, 0)
		PlaceTile(last, 1)
		PutCursorAt(TILE + GAP / 2)

		Drag(last)

		fw.eq(options.Groups[1].Id, second.Id, "the nearest tile took the drop")
	end)

	fw.it("leaves the order alone when the drop is nowhere near the grid", function()
		local _, options, second = TwoGroups()
		local first, last = TileFor(options.Groups[1].Id), TileFor(second.Id)
		local before = options.Groups[1].Id

		PlaceTile(first, 0)
		PlaceTile(last, 1)
		PutCursorAt(2000)

		Drag(last)

		fw.eq(options.Groups[1].Id, before, "a drop off the grid is not a reorder")
	end)
end)

---Any font string on the page whose text holds this fragment, found by walking the mock's frame
---registry: the editor keeps its labels to itself.
---@param fragment string
---@return table?
local function FontStringSaying(fragment)
	for _, frame in ipairs(WowMock.Frames) do
		for index = 1, frame:GetNumRegions() do
			local region = select(index, frame:GetRegions())
			local text = region and region.GetText and region:GetText()

			if text and text:find(fragment, 1, true) then
				return region
			end
		end
	end

	return nil
end

---The editor's tab buttons, keyed the way the strip keys them.
---@return table<string, table>
local function EditorTabs()
	local found = {}

	for _, frame in ipairs(WowMock.Frames) do
		if frame.Key and frame.Underline then
			found[frame.Key] = frame
		end
	end

	return found
end

fw.describe("Personal auras page - tabs a group cannot use", function()
	fw.it("hides the three display tabs for a sound-only group", function()
		local addon, group = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups

		group.Icons.Display = groups.DisplayStyle.SoundOnly
		groups:Normalise(group)

		ShowPage(addon, group)

		local tabs = EditorTabs()

		fw.truthy(tabs.trigger:IsShown(), "the trigger tab stays, and carries the way back out")
		fw.truthy(tabs.sounds:IsShown(), "so do the sounds it is there for")
		fw.falsy(tabs.filters:IsShown(), "the filters reach nothing a sound-only group has")
		fw.falsy(tabs.appearance:IsShown(), "nor does the appearance tab")
		fw.falsy(tabs.layout:IsShown(), "nor the layout one")
	end)

	fw.it("closes the gap the hidden tabs leave", function()
		local addon, group = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups

		group.Icons.Display = groups.DisplayStyle.SoundOnly
		groups:Normalise(group)

		ShowPage(addon, group)

		local tabs = EditorTabs()
		local _, _, _, triggerX = tabs.trigger:GetPoint(1)
		local _, _, _, soundsX = tabs.sounds:GetPoint(1)

		fw.eq(soundsX - triggerX, 124, "sounds sits in the second slot, not the fifth")
	end)

	fw.it("puts them all back for a group that draws icons", function()
		local addon, group = LoadWithGroup({ 45438 })

		ShowPage(addon, group)

		local tabs = EditorTabs()

		for _, key in ipairs({ "trigger", "filters", "appearance", "layout", "sounds" }) do
			fw.truthy(tabs[key]:IsShown(), key .. " is on the strip")
		end
	end)
end)

fw.describe("Personal auras page - sounds the filters cannot reach", function()
	fw.it("says so for a group that only wants its own casts", function()
		local addon, group = LoadWithGroup({ 45438 })

		group.Caster = addon.Modules.PersonalAuras.Groups.Caster.Mine
		group.Sound.Applied = "Sonar"

		ShowPage(addon, group)

		fw.not_nil(FontStringSaying("Sounds ignore the filters"), "the caveat is on the page")
	end)

	fw.it("says nothing for a group whose sound already matches its filters", function()
		local addon, group = LoadWithGroup({ 45438 })

		group.Sound.Applied = "Sonar"

		ShowPage(addon, group)

		fw.is_nil(FontStringSaying("Sounds ignore the filters"), "nothing narrows this one")
	end)
end)

fw.describe("Personal auras page - with a group configured", function()
	fw.it("lays the page out without touching anything that is not there", function()
		local addon = LoadWithGroup({ 45438, 118 })

		ShowPage(addon)
	end)

	fw.it("opens the editor for a group with no spells yet", function()
		-- The state a group is in for the first few seconds of its life, which is also the one
		-- that shows the "add at least one spell" message.
		local addon = LoadWithGroup({})

		ShowPage(addon)
	end)

	fw.it("survives a group pointed at nameplates", function()
		local addon, group = LoadWithGroup({ 118 })

		group.Unit = "nameplate"
		group.AuraType = "HARMFUL"
		addon.Modules.PersonalAuras.Groups:Normalise(group)

		ShowPage(addon)
	end)

	fw.it("lays out every display shape", function()
		-- The appearance tab collapses and reinstates a row per shape, so the page has to be
		-- measurable for each of them, including the sound-only one that empties it entirely.
		local addon, group = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups

		local shapes = {
			groups.DisplayStyle.Bars,
			groups.DisplayStyle.Icons,
			groups.DisplayStyle.Texture,
			groups.DisplayStyle.SoundOnly,
		}

		for _, shape in ipairs(shapes) do
			group.Icons.Display = shape
			groups:Normalise(group)
			ShowPage(addon)
		end
	end)

	fw.it("survives every unit the dropdown offers", function()
		local addon, group = LoadWithGroup({ 45438 })
		local groups = addon.Modules.PersonalAuras.Groups

		for _, unit in ipairs(groups.Units) do
			group.Unit = unit
			groups:Normalise(group)
			ShowPage(addon)
		end
	end)
end)
