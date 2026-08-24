---@type string, Addon
local _, addon = ...
local masque = LibStub and LibStub("Masque", true)

-- Masque skinning for 12.1 AuraButtons, which live on frames the engine owns and the addon is only
-- borrowing.

-- Group names whose skinning has already been reported as failed. Keyed by name, so one module
-- giving up does not silence the report for every other one.
local warned = {}

---@class AuraMasque
local M = {}

addon.Core.AuraMasque = M

local function NoOp() end

---Masque re-parents the icon it is handed to the button that icon already belongs to. The call
---changes nothing, but SetIcon has put a ChangeParent restriction on the texture, and the refusal
---takes down the engine mid-batch.
---A field on the texture shadows the method for anything calling it from Lua, which is only ever
---Masque. The engine reaches the texture from the other side. A wrapper cannot stand in, because
---Masque also hands the icon to SetPoint as the anchor for the regions it builds around it.
---@param texture table
local function BlockIconReparent(texture)
	texture.SetParent = NoOp
end

---Masque fits its art to the size a button already has, which it reads with GetSize. That value
---is secret for anything living inside a nameplate, and the arithmetic Masque does on it would
---abort the whole skin pass, so a button whose size cannot be read plainly is left alone.
---@param button table
---@return boolean
local function CanReadButtonSize(button)
	local width = button:GetWidth()

	return width ~= nil and not issecretvalue(width)
end

---Result check for a Masque call. Skinning runs inside the engine's frame-creation callback, so
---an error thrown by a third party there would abort the whole display rather than just its
---artwork. The display gives up on skinning instead, and says so once per session.
---@param instance AuraContainerDisplay
---@param ok boolean
---@param err any
---@return boolean ok
local function Guard(instance, ok, err)
	if ok then
		return true
	end

	local name = instance.MasqueGroupName or "?"

	instance.MasqueGroup = nil

	if not warned[name] then
		warned[name] = true
		addon.Framework:NotifyWithPrefix("Masque could not skin the %s icons, carrying on without them: %s",
			name, tostring(err))
	end

	return false
end

---@param instance AuraContainerDisplay
---@param groupName string?
---@return table?
function M:ResolveGroup(instance, groupName)
	if not masque or not groupName then
		return nil
	end

	-- A skin owns the icon's crop, its mask and the border art, so displays that bring their own or
	-- that are not icons at all stay off the skinning path.
	if instance.Bar or instance.Label or instance.Texture or instance.IconMask then
		return nil
	end

	-- Same addon and sub-group names the legacy containers use, so a skin picked on one path is
	-- already applied on the other.
	return masque:Group("MiniAuras", groupName)
end

---Hands one button to Masque. Called from initializeFrame, after the button has been sized and
---all of its regions registered with the engine.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
function M:RegisterButton(instance, button, widgets)
	local group = instance.MasqueGroup

	if not group then
		return
	end

	-- The icons come out unskinned either way, and which of the two reasons it was matters when
	-- working out why.
	if not CanReadButtonSize(button) then
		local width = button:GetWidth()

		Guard(instance, false, width == nil and "this button has no size yet"
			or "this button's size is secret here")
		return
	end

	BlockIconReparent(widgets.Icon)

	-- Strict, so only the regions listed here are skinned. Masque otherwise probes the button for
	-- region names an engine-created one cannot have.
	-- Normal is left out so Masque builds and owns the skin's border texture, which leaves the
	-- dispel-coloured ring registered with the engine untouched.
	if not Guard(instance, pcall(group.AddButton, group, button, {
		Icon = widgets.Icon,
		Cooldown = widgets.Cooldown,
		Count = widgets.Stacks,
	}, "Aura", true)) then
		return
	end

	widgets.Masqued = true
end

---Re-fits the skin to every button this display owns, after a size change.
---@param instance AuraContainerDisplay
function M:ReSkinButtons(instance)
	local group = instance.MasqueGroup

	if not group then
		return
	end

	for _, button in ipairs(instance.Buttons) do
		local widgets = instance.ButtonWidgets[button]

		if widgets and widgets.Masqued and CanReadButtonSize(button)
			and not Guard(instance, pcall(group.ReSkin, group, button)) then
			return
		end
	end
end
