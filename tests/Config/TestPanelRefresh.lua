-- Re-reading an options page after a profile reset or a profile switch. A page whose controls all
-- sit on sub-tabs owns none itself, so it carries no MiniRefresh of its own.

local fw = require("Framework")
local harness = require("AddonHarness")

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Builds the shape a tabbed page has: the frame the tab controller hands out, a strip below it,
---and the sub-tab page every control actually lands on.
---@param mini table
---@return table page, function reads
local function NestedPage(mini)
	local page = CreateFrame("Frame", nil, _G.UIParent)
	local container = CreateFrame("Frame", nil, page)
	local subPage = CreateFrame("Frame", nil, container)
	local reads = 0

	mini:Checkbox({
		Parent = subPage,
		LabelText = "Nested",
		GetValue = function()
			reads = reads + 1

			return true
		end,
		SetValue = function() end,
	})

	return page, function()
		return reads
	end
end

fw.describe("Config - refreshing an options page", function()
	fw.it("re-reads a control nested below a page that owns none itself", function()
		local addon = Load()
		local mini = addon.Framework
		local page, reads = NestedPage(mini)

		assert(page.MiniRefresh == nil, "the page owns no controls, so it carries no refresh")

		local before = reads()
		mini.GUI.RefreshPanelTree(page)

		assert(reads() > before, "the nested control was re-read")
	end)

	fw.it("re-reads a page that does own its controls", function()
		local addon = Load()
		local mini = addon.Framework
		local page = CreateFrame("Frame", nil, _G.UIParent)
		local reads = 0

		mini:Checkbox({
			Parent = page,
			LabelText = "Direct",
			GetValue = function()
				reads = reads + 1

				return true
			end,
			SetValue = function() end,
		})

		local before = reads
		mini.GUI.RefreshPanelTree(page)

		assert(reads > before, "the page's own control was re-read")
	end)

	fw.it("says nothing when there is no page to refresh", function()
		local addon = Load()

		addon.Framework.GUI.RefreshPanelTree(nil)
	end)
end)
