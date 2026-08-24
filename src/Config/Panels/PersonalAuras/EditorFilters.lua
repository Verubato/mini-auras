---@type string, Addon
local _, addon = ...
local L = addon.L
local groups = addon.Modules.PersonalAuras.Groups
local ui = addon.Config.PersonalAurasUI
local CASTER_OPTIONS = { "ANY", "MINE", "OTHERS" }

---Builds the filters tab: the caster narrowing plus the aura-flag tri-states, both of which
---apply whichever way the group tracks.
---@param ctx PersonalAurasEditorContext
---@return fun(shown: boolean?) refreshFlags
function ui.BuildFiltersTab(ctx)
	local filtersPanel = ctx.FiltersPanel
	local casterRow = ctx.NewRow(filtersPanel, ui.DropdownRowHeight)
	local flagsRow = ctx.NewRow(filtersPanel, 1, 4)

	ctx.Dropdown(L["Cast by"], {
		Items = CASTER_OPTIONS,
		GetText = function(value)
			if value == groups.Caster.Mine then
				return L["Me"]
			elseif value == groups.Caster.Others then
				return L["Anyone else"]
			end

			return L["Anyone"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.Caster or groups.Caster.Any
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Caster = value
				ui.Apply()
			end
		end,
	}, casterRow, 0)

	-- Labels for the engine's own aura flags. Kept as plain lookups so a flag Blizzard adds
	-- later shows its raw token rather than nothing at all.
	local flagLabels = {
		isFromPlayerOrPlayerPet = L["From me or my pet"],
		isBossAura = L["Cast by a boss"],
		isStealable = L["Stealable"],
		isPriorityAura = L["Priority aura"],
		canApplyAura = L["I could apply it"],
	}

	local refreshFlags, flagsHeight =
		ui.TriStateGrid(filtersPanel, flagsRow, groups.CandidateFlags, flagLabels, "Candidates")

	flagsRow:SetHeight(flagsHeight)

	return refreshFlags
end
