-- The Unhalted Unit Frames provider. Its party frames are named globals and its raid ones are
-- secure header children, so the two halves are found in different ways and each can break alone.
-- The pinned frames are the awkward part: they draw a second copy of a unit the raid frames
-- already show, and they come and go with a list of names no event announces.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

local addon = {
	Utils = {},
	Core = {},
	Modules = {},
	Config = {},
	Framework = {
		GetSavedVars = function()
			return {}
		end,
		NotifyWithPrefix = function() end,
	},
}

local function loadFile(path)
	assert(loadfile(path))("MiniAuras", addon)
end

loadFile("src/Core/Frames/Frames.lua")
loadFile("src/Core/Frames/UUF.lua")

local frames = addon.Core.Frames

-- A frame carrying just the surface the provider reads: its children, its unit, whether it is on
-- screen, and the show/hide scripts the pinned-frame hook rides on. The shared frame stub has no
-- children or scripts, and this file is the only one that needs them.
---@param name string?
---@param unit string?
---@param parent table?
---@return table
local function NewFrame(name, unit, parent)
	local frame = {
		unit = unit,
		__children = {},
		__scripts = {},
		__shown = true,
	}

	function frame:GetChildren()
		return unpack(self.__children)
	end

	function frame:IsForbidden()
		return false
	end

	function frame:IsVisible()
		return self.__shown
	end

	function frame:HookScript(script, handler)
		local handlers = self.__scripts[script] or {}
		self.__scripts[script] = handlers
		handlers[#handlers + 1] = handler
	end

	function frame:SetShown(shown)
		self.__shown = shown

		for _, handler in ipairs(self.__scripts[shown and "OnShow" or "OnHide"] or {}) do
			handler(self)
		end
	end

	if name then
		_G[name] = frame
	end

	if parent then
		parent.__children[#parent.__children + 1] = frame
	end

	return frame
end

local function ClearFrames()
	for _, name in ipairs({
		"UUF_Party1", "UUF_Party2", "UUF_Party3", "UUF_Party4", "UUF_PartyPlayer",
		"UUF_RaidHeader1", "UUF_AugmentationRaidHeader",
	}) do
		_G[name] = nil
	end
end

fw.describe("Frames - Unhalted Unit Frames", function()
	fw.before_each(ClearFrames)

	fw.it("contributes nothing when the addon is not there", function()
		local found = {}
		frames:UUFFrames(true, found)
		frames:UUFPinnedFrames(true, found)

		assert(#found == 0, "an empty client must cost nothing, got " .. #found)
	end)

	fw.it("takes the party frames, the player's own among them", function()
		local party1 = NewFrame("UUF_Party1", "party1")
		local partyPlayer = NewFrame("UUF_PartyPlayer", "player")

		local found = {}
		frames:UUFFrames(true, found)

		assert(#found == 2, "both party frames, got " .. #found)
		assert(found[1] == party1, "the numbered slot comes first")
		assert(found[2] == partyPlayer, "and the player's own frame after it")
	end)

	fw.it("descends into the raid headers rather than taking them", function()
		local header = NewFrame("UUF_RaidHeader1")
		local button = NewFrame(nil, "raid1", header)

		local found = {}
		frames:UUFFrames(true, found)

		assert(#found == 1, "the header itself is no anchor, only its button; got " .. #found)
		assert(found[1] == button, "and the button is what came through")
	end)

	fw.it("leaves out an empty header child", function()
		local header = NewFrame("UUF_RaidHeader1")
		NewFrame(nil, nil, header)

		local found = {}
		frames:UUFFrames(true, found)

		assert(#found == 0, "a child with no unit is not a unit button, got " .. #found)
	end)

	fw.it("leaves out a hidden party frame when only the visible ones are wanted", function()
		local party1 = NewFrame("UUF_Party1", "party1")
		party1:SetShown(false)

		local found = {}
		frames:UUFFrames(true, found)
		assert(#found == 0, "hidden means out, got " .. #found)

		wipe(found)
		frames:UUFFrames(false, found)
		assert(#found == 1, "and in again when the caller wants them all, got " .. #found)
	end)

	fw.it("anchors a pinned unit twice, once per frame showing it", function()
		local header = NewFrame("UUF_RaidHeader1")
		local raidButton = NewFrame(nil, "raid1", header)

		local pinnedHeader = NewFrame("UUF_AugmentationRaidHeader")
		local pinnedButton = NewFrame(nil, "raid1", pinnedHeader)

		local found = {}
		frames:UUFFrames(true, found)
		frames:UUFPinnedFrames(true, found)

		assert(#found == 2, "one anchor per frame on screen, not per unit; got " .. #found)
		assert(found[1] == raidButton, "the raid frame first")
		assert(found[2] == pinnedButton, "the pinned copy after it")
	end)

	fw.it("tells its listeners when a pinned frame comes or goes", function()
		local calls = 0
		frames:HookUUFPinnedVisibility(function()
			calls = calls + 1
		end)

		local pinnedHeader = NewFrame("UUF_AugmentationRaidHeader")
		local pinnedButton = NewFrame(nil, "raid1", pinnedHeader)

		-- The hook only goes on once the header has spawned the button, which is the first time a
		-- walk sees it. There is nothing to listen to before then.
		frames:UUFPinnedFrames(false, {})

		pinnedButton:SetShown(false)
		pinnedButton:SetShown(true)

		assert(calls == 2, "one call per show and hide, got " .. calls)

		-- A second walk must not stack another hook on the same button.
		frames:UUFPinnedFrames(false, {})
		pinnedButton:SetShown(false)

		assert(calls == 3, "the hook goes on once per frame, got " .. calls .. " calls")
	end)
end)
