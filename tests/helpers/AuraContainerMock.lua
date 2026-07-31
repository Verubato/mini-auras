-- Mock environment for testing the 12.1 AuraContainer path (Core/AuraContainerDisplay.lua)
-- without a WoW client. Provides:
--
--   * A rich CreateFrame replacement (superset of wow_api's stub) with parent tracking,
--     SetPoint/SetSize/Show/Hide recording, and child region/animation mocks.
--   * CreateFrame("AuraContainer", ...) frames implementing the container inbound API:
--     AddAuraGroup batch-creates buttons through initializeFrame (mirroring the client's
--     10-per-batch pre-creation), plus the group setters as recorders.
--   * AuraButton mocks with the display-element APIs (SetIcon, SetDurationCooldown, ...).
--   * The RESTRICTION model: while M.restricted is true, calling any method on an aura
--     button OR anything created beneath one raises the client's forbidden-object error.
--     (Confirmed live behavior: even Hide() on an addon-created child errors in combat.)
--   * Deterministic C_Timer.NewTicker/NewTimer with manual pumps (M.tickAll / M.runTimers).
--
-- Call M.setup() after wow_api.setup(); then M.loadDisplay() returns the real
-- AuraContainerDisplay module loaded against a mock addon table.

local M = {}

M.restricted = false
M.batchSize = 10

local FORBIDDEN_ERROR = "Attempt to access forbidden object from code tainted by an AddOn"

local tickers = {}
local timers = {}

-- Registry of every frame created through the mock, so tests can reach event frames that
-- modules create internally (KickTracker watchers, module eventsFrames, ...).
M.frames = {}

---Returns the most recently created frame that has the given script set (default "OnEvent").
function M.lastFrameWithScript(scriptName)
	scriptName = scriptName or "OnEvent"
	for i = #M.frames, 1, -1 do
		if M.frames[i]._scripts and M.frames[i]._scripts[scriptName] then
			return M.frames[i]
		end
	end
	return nil
end

---Returns the most recently created frame registered for the given event.
function M.lastFrameForEvent(event)
	for i = #M.frames, 1, -1 do
		local registered = M.frames[i]._events
		if registered and registered[event] then
			return M.frames[i]
		end
	end
	return nil
end

-- Frame factory

local frameCount = 0

local function IsUnderAuraButton(frame)
	local current = frame
	while current do
		if current._isAuraButton then
			return true
		end
		current = current._parent
	end
	return false
end

-- Wraps every function on a frame so calls error while restricted, matching the client's
-- forbidden-object behavior for aura buttons and their descendants.
local function GuardRestricted(frame)
	for key, value in pairs(frame) do
		if type(value) == "function" then
			frame[key] = function(...)
				if M.restricted and IsUnderAuraButton(frame) then
					error(FORBIDDEN_ERROR .. " - Usage: self:" .. key .. "()")
				end
				return value(...)
			end
		end
	end
end

local function NewAnimationGroup(owner)
	local anim = { _playing = false, _owner = owner }
	function anim:Play()
		anim._playing = true
	end
	function anim:Stop()
		anim._playing = false
	end
	function anim:IsPlaying()
		return anim._playing
	end
	function anim:SetLooping() end
	function anim:CreateAnimation()
		local a = {}
		local function noop() end
		setmetatable(a, { __index = function() return noop end })
		return a
	end
	return anim
end

local function NewRegion(parent, regionType)
	local region = {
		_parent = parent,
		_type = regionType,
		_shown = true,
		_calls = {},
	}

	-- _calls counts invocations; _lastArgs keeps the most recent argument list per method so
	-- tests can assert on what was actually applied (e.g. which texture asset).
	region._lastArgs = {}

	local function record(name)
		region[name] = function(_, ...)
			region._calls[name] = (region._calls[name] or 0) + 1
			region._lastArgs[name] = { ... }
			return nil
		end
	end

	for _, name in ipairs({
		"SetAllPoints", "SetPoint", "ClearAllPoints", "SetTexture", "SetTexCoord",
		"AddMaskTexture", "SetVertexColor", "SetBlendMode", "SetDesaturated", "SetScale",
		"SetText", "SetFont", "SetTextColor", "SetShadowColor", "SetShadowOffset",
		"SetJustifyH", "SetDrawLayer",
	}) do
		record(name)
	end

	function region:GetFont()
		return "MockFont", 10, ""
	end
	function region:GetStringWidth()
		return 0
	end
	function region:GetStringHeight()
		return 10
	end

	function region:Show()
		region._shown = true
	end
	function region:Hide()
		region._shown = false
	end
	function region:IsShown()
		return region._shown
	end

	if IsUnderAuraButton(parent) then
		GuardRestricted(region)
	end

	return region
end

function M.NewFrame(frameType, name, parent, template)
	frameCount = frameCount + 1
	local frame = {
		_type = frameType,
		_name = name or ("MockFrame" .. frameCount),
		_parent = parent,
		_template = template,
		_shown = true,
		_points = {},
		_level = parent and parent._level or 1,
		_width = 0,
		_height = 0,
		_scripts = {},
		_calls = {},
	}

	frame._events = {}

	function frame:SetScript(event, fn)
		frame._scripts[event] = fn
	end
	function frame:GetScript(event)
		return frame._scripts[event]
	end
	function frame:TriggerEvent(event, ...)
		if frame._scripts.OnEvent then
			frame._scripts.OnEvent(frame, event, ...)
		end
	end
	function frame:RegisterEvent(event)
		frame._events[event] = true
	end
	function frame:RegisterUnitEvent(event, unit)
		frame._events[event] = unit or true
	end
	function frame:UnregisterAllEvents()
		frame._events = {}
	end

	function frame:Show()
		frame._shown = true
	end
	function frame:Hide()
		frame._shown = false
	end
	function frame:SetShown(shown)
		frame._shown = shown and true or false
	end
	function frame:IsShown()
		return frame._shown
	end
	function frame:IsVisible()
		local current = frame
		while current do
			if not current._shown then
				return false
			end
			current = current._parent
		end
		return true
	end

	function frame:SetParent(newParent)
		frame._parent = newParent
	end
	function frame:GetParent()
		return frame._parent
	end
	function frame:GetName()
		return frame._name
	end

	function frame:SetPoint(point, relativeTo, relativePoint, x, y)
		frame._points[#frame._points + 1] = {
			point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y,
		}
	end
	function frame:SetAllPoints(target)
		frame._points[#frame._points + 1] = { point = "ALL", relativeTo = target }
	end
	function frame:ClearAllPoints()
		frame._points = {}
	end
	function frame:GetPoint(index)
		local p = frame._points[index or 1]
		if not p then
			return nil
		end
		return p.point, p.relativeTo, p.relativePoint, p.x, p.y
	end

	function frame:SetSize(w, h)
		frame._calls.SetSize = (frame._calls.SetSize or 0) + 1
		frame._width, frame._height = w, h or w
	end
	function frame:GetWidth()
		return frame._width
	end
	function frame:GetHeight()
		return frame._height
	end
	-- Rect queries return nil (frames are never laid out here); anchor-normalization code
	-- treats that as "rect unavailable" and skips.
	function frame:GetLeft() end
	function frame:GetRight() end
	function frame:GetCenter() end
	function frame:SetFrameLevel(level)
		frame._level = level
	end
	function frame:GetFrameLevel()
		return frame._level
	end
	function frame:SetFrameStrata() end
	function frame:GetFrameStrata()
		return "MEDIUM"
	end
	function frame:SetIgnoreParentScale() end
	function frame:SetIgnoreParentAlpha() end
	function frame:SetFlattensRenderLayers() end
	function frame:SetAlpha() end
	function frame:SetAlphaFromBoolean() end
	function frame:HookScript() end
	function frame:RegisterForDrag() end
	function frame:SetMovable() end
	function frame:IsMovable()
		return false
	end
	function frame:SetClampedToScreen() end
	function frame:StartMoving() end
	function frame:StopMovingOrSizing() end
	function frame:GetEffectiveScale()
		return 1
	end
	function frame:EnableMouse(enabled)
		frame._calls.EnableMouse = (frame._calls.EnableMouse or 0) + 1
		frame._mouseEnabled = enabled
	end

	M.frames[#M.frames + 1] = frame

	function frame:CreateTexture(_, layer)
		return NewRegion(frame, "Texture")
	end
	function frame:CreateFontString()
		return NewRegion(frame, "FontString")
	end
	function frame:CreateAnimationGroup()
		return NewAnimationGroup(frame)
	end

	-- Cooldown widget surface (CooldownFrameTemplate)
	if frameType == "Cooldown" then
		for _, methodName in ipairs({
			"SetDrawEdge", "SetDrawBling", "SetHideCountdownNumbers", "SetSwipeColor",
			"SetReverse", "SetDrawSwipe", "SetCountdownMillisecondsThreshold",
			"SetCooldownFromDurationObject", "Clear", "SetSwipeTexture",
		}) do
			frame[methodName] = function(_, ...)
				frame._calls[methodName] = (frame._calls[methodName] or 0) + 1
			end
		end
		frame.GetFont = function()
			return "MockFont", 10, ""
		end
		frame.SetFont = function() end
	end

	return frame
end

-- AuraButton mock

local function NewAuraButton(container, groupKey)
	local button = M.NewFrame("Button", nil, container)
	button._isAuraButton = true
	button._group = groupKey

	for _, methodName in ipairs({
		"SetIcon", "SetDurationCooldown", "SetApplicationCount", "SetSpellName",
		"AddDispelTypeTexture", "ClearDispelTypeTextures", "SetDispelTypeText",
		"SetTooltipAnchorPoint", "SetHideTooltipInCombat", "SetCancelAuraButtons",
	}) do
		button[methodName] = function(_, ...)
			button._calls[methodName] = (button._calls[methodName] or 0) + 1
		end
	end

	GuardRestricted(button)
	return button
end

-- AuraContainer mock

local function NewAuraContainer(name, parent, template)
	local container = M.NewFrame("AuraContainer", name, parent, template)
	container._groups = {}
	container._unit = "none"
	container._enabled = true
	container._buttons = {}

	function container:SetUnit(unit)
		container._unit = unit
	end
	function container:GetUnit()
		return container._unit
	end
	function container:SetEnabled(enabled)
		container._enabled = enabled
	end
	function container:IsEnabled()
		return container._enabled
	end
	function container:UpdateAllAuras()
		container._calls.UpdateAllAuras = (container._calls.UpdateAllAuras or 0) + 1
	end

	function container:AddAuraGroup(groupKey, filterString, options)
		assert(container._groups[groupKey] == nil, "aura group already exists: " .. tostring(groupKey))
		local group = {
			filterString = filterString,
			options = options,
			maxFrameCount = options.maxFrameCount,
			layout = options.layout,
			buttons = {},
		}
		container._groups[groupKey] = group

		-- Mirror the client: a batch of buttons is created up-front, each initialized.
		for _ = 1, M.batchSize do
			local button = NewAuraButton(container, groupKey)
			group.buttons[#group.buttons + 1] = button
			container._buttons[#container._buttons + 1] = button
			if options.initializeFrame then
				options.initializeFrame(button)
			end
		end
	end

	function container:HasAuraGroup(groupKey)
		return container._groups[groupKey] ~= nil
	end
	function container:GetAuraGroupFrameCount(groupKey)
		local group = container._groups[groupKey]
		return group and #group.buttons or 0
	end
	function container:GetAuraGroupFrame(groupKey, index)
		local group = container._groups[groupKey]
		return group and group.buttons[index] or nil
	end
	function container:SetAuraGroupMaxFrameCount(groupKey, count)
		local group = assert(container._groups[groupKey], "no group " .. tostring(groupKey))
		group.maxFrameCount = count
		group.maxFrameCountSets = (group.maxFrameCountSets or 0) + 1
	end
	function container:SetAuraGroupCandidateFilters(groupKey, filters)
		local group = assert(container._groups[groupKey], "no group " .. tostring(groupKey))
		group.candidateFilters = filters
	end
	function container:SetAuraGroupLayout(groupKey, layout)
		local group = assert(container._groups[groupKey], "no group " .. tostring(groupKey))
		group.layout = layout
	end

	function container:SetFlowLayoutAxis(axis)
		container._flowAxis = axis
	end
	function container:SetFlowLayoutAnchorPoint(point)
		container._flowAnchorPoint = point
	end
	function container:SetFlowLayoutGrowthDirection(h, v)
		container._flowGrowth = { h = h, v = v }
	end

	return container
end

-- Deterministic timers

function M.tickAll(times)
	for _ = 1, times or 1 do
		for _, ticker in ipairs(tickers) do
			if not ticker.cancelled then
				ticker.fn()
			end
		end
	end
end

function M.runTimers()
	-- Snapshot: callbacks may schedule new timers.
	local due = {}
	for _, timer in ipairs(timers) do
		if not timer.cancelled and not timer.fired then
			due[#due + 1] = timer
		end
	end
	for _, timer in ipairs(due) do
		timer.fired = true
		timer.fn()
	end
end

function M.pendingTimerCount()
	local count = 0
	for _, timer in ipairs(timers) do
		if not timer.cancelled and not timer.fired then
			count = count + 1
		end
	end
	return count
end

function M.reset()
	M.restricted = false
	tickers = {}
	timers = {}
	M.frames = {}
end

-- Environment installation

function M.setup()
	local previousCreateFrame = _G.CreateFrame

	_G.CreateFrame = function(frameType, name, parent, template)
		if frameType == "AuraContainer" then
			return NewAuraContainer(name, parent, template)
		end
		local frame = M.NewFrame(frameType, name, parent, template)
		-- Anything created beneath an aura button inherits the restriction model.
		if parent and IsUnderAuraButton(parent) then
			frame._underAuraButton = true
			GuardRestricted(frame)
		end
		return frame
	end
	M._previousCreateFrame = previousCreateFrame

	_G.C_Timer = _G.C_Timer or {}
	_G.C_Timer.After = _G.C_Timer.After or function(_, fn) fn() end
	_G.C_Timer.NewTicker = function(interval, fn)
		local ticker = { interval = interval, fn = fn, cancelled = false }
		function ticker:Cancel()
			ticker.cancelled = true
		end
		tickers[#tickers + 1] = ticker
		return ticker
	end
	_G.C_Timer.NewTimer = function(delay, fn)
		local timer = { delay = delay, fn = fn, cancelled = false, fired = false }
		function timer:Cancel()
			timer.cancelled = true
		end
		timers[#timers + 1] = timer
		return timer
	end

	_G.AuraContainerSortMethod = _G.AuraContainerSortMethod or {
		Default = 0, BigDefensive = 1, UnitFrameDebuff = 2, ImportantOnly = 3,
		Expiration = 4, ExpirationOnly = 5, Name = 6, NameOnly = 7, AuraInstanceIDOnly = 8,
	}
	_G.AuraContainerSortDirection = _G.AuraContainerSortDirection or { Normal = 0, Reverse = 1 }
	_G.Enum = _G.Enum or {}
	_G.Enum.CustomAuraButtonDispelTypeTextureStyle = _G.Enum.CustomAuraButtonDispelTypeTextureStyle
		or { Border = 0, BorderWithIcon = 1, Icon = 2, PreserveAsset = 3, CustomAsset = 4 }
	_G.AnchorUtil = _G.AnchorUtil or {
		FlowLayoutAxis = { Horizontal = 0, Vertical = 1 },
		FlowDirection = { Left = 0, Right = 1, Up = 2, Down = 3 },
	}
	_G.UIParent = _G.UIParent or M.NewFrame("Frame", "UIParent")
	_G.GetTime = _G.GetTime or function() return 0 end
	_G.InCombatLockdown = _G.InCombatLockdown or function() return false end
	_G.issecretvalue = _G.issecretvalue or function() return false end
end

-- Notifications raised by the loaded modules (e.g. SetMaxIcons on an unknown group key), so
-- tests can assert that a misuse is reported rather than swallowed.
M.notifications = {}

-- Loads the real AuraContainerDisplay - and the Core modules it now depends on - against a mock
-- addon table. Returns the display module and the mock addon (mockDb is live-editable; the
-- sibling modules are on addon.Core.Pool / .GrowAnchors / .AuraFilters / .KickSlot).
function M.loadDisplay()
	local mockDb = { DisableSwipe = false, MillisecondsThreshold = 3, GlowType = "Proc Glow" }
	local addon = {
		Utils = {
			FontUtil = {
				UpdateCooldownFontSize = function() end,
			},
			WoWEx = {
				IsAuraStylingRestricted = function()
					return M.restricted
				end,
			},
		},
		Core = {
			Framework = {
				GetSavedVars = function()
					return mockDb
				end,
				Notify = function(_, message, ...)
					M.notifications[#M.notifications + 1] = string.format(message, ...)
				end,
			},
		},
	}

	for _, path in ipairs({
		"src/Core/Pool.lua",
		"src/Core/GrowAnchors.lua",
		"src/Core/AuraFilters.lua",
		"src/Core/KickSlot.lua",
		"src/Core/AuraContainerDisplay.lua",
	}) do
		assert(loadfile(path))("MiniCC", addon)
	end

	return addon.Core.AuraContainerDisplay, addon, mockDb
end

return M
