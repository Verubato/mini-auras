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
-- Button methods to leave off, for the display's older-build fallbacks. Cleared by M.reset.
M.missingButtonMethods = {}

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
		"AddMaskTexture", "RemoveMaskTexture", "SetVertexColor", "SetBlendMode", "SetDesaturated", "SetScale",
		"SetAtlas",
		-- Takes a sprite index straight to the C side, so it is the only way to paint a raid
		-- marker whose index is secret.
		"SetSpriteSheetCell",
		"SetText", "SetFont", "SetTextColor", "SetShadowColor", "SetShadowOffset",
		"SetJustifyH", "SetDrawLayer", "SetColorTexture", "SetSize", "SetWordWrap",
		"SetAlpha", "SetWidth", "SetHeight",
	}) do
		record(name)
	end

	function region:GetObjectType()
		return region._type
	end
	function region:GetText()
		local args = region._lastArgs.SetText
		return args and args[1] or ""
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
	function region:SetShown(shown)
		region._shown = shown and true or false
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
		_lastArgs = {},
	}

	frame._events = {}
	-- Both tokens a unit-filtered registration covers, which is how a pet-cast interrupt
	-- reaches its owner's entry.
	frame._eventUnits = {}

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
	function frame:RegisterUnitEvent(event, unit, otherUnit)
		frame._events[event] = unit or true
		frame._eventUnits[event] = { unit, otherUnit }
	end
	function frame:UnregisterEvent(event)
		frame._events[event] = nil
	end
	function frame:UnregisterAllEvents()
		frame._events = {}
		frame._eventUnits = {}
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
	function frame:GetNumPoints()
		return #frame._points
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
	-- Rect queries return nil until a test supplies one with SetMockRect (frames are never
	-- laid out here); anchor-normalization code treats nil as "rect unavailable" and skips.
	function frame:SetMockRect(left, bottom, width, height)
		frame._rect = { left = left, bottom = bottom, width = width, height = height }
	end
	function frame:GetLeft()
		return frame._rect and frame._rect.left
	end
	function frame:GetRight()
		return frame._rect and (frame._rect.left + frame._rect.width)
	end
	function frame:GetBottom()
		return frame._rect and frame._rect.bottom
	end
	function frame:GetTop()
		return frame._rect and (frame._rect.bottom + frame._rect.height)
	end
	function frame:GetCenter()
		if not frame._rect then
			return nil
		end
		return frame._rect.left + frame._rect.width / 2, frame._rect.bottom + frame._rect.height / 2
	end
	function frame:SetFrameLevel(level)
		-- The client shifts a frame's children with it so relative levels hold; the pet
		-- portrait path depends on that when Anchors lowers the container after creation.
		local delta = level - (frame._level or 0)
		frame._level = level
		if delta ~= 0 then
			for _, other in ipairs(M.frames) do
				if other._parent == frame then
					other:SetFrameLevel((other._level or 0) + delta)
				end
			end
		end
	end
	function frame:GetFrameLevel()
		return frame._level
	end
	function frame:SetFrameStrata(strata)
		frame._strata = strata
	end
	function frame:GetFrameStrata()
		return frame._strata or "MEDIUM"
	end
	function frame:SetIgnoreParentScale() end
	function frame:SetIgnoreParentAlpha() end
	function frame:SetFlattensRenderLayers(value)
		frame._flattens = value
	end
	function frame:SetAlpha() end
	function frame:SetAlphaFromBoolean() end
	function frame:HookScript() end
	function frame:RegisterForDrag() end
	function frame:SetMovable(movable)
		frame._movable = movable and true or false
	end
	function frame:IsMovable()
		return frame._movable == true
	end
	function frame:SetClampedToScreen() end
	function frame:SetDontSavePosition() end
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

	-- Textures are kept in creation order so tests can reach a button's icon (the first one).
	frame._createdTextures = {}

	function frame:CreateTexture(_, layer)
		local texture = NewRegion(frame, "Texture")
		frame._createdTextures[#frame._createdTextures + 1] = texture
		return texture
	end
	function frame:CreateMaskTexture()
		return NewRegion(frame, "MaskTexture")
	end
	-- Unit-frame portraits are textures in the client; the mock models them as frames so they
	-- can carry a parent and a rect, which means the frame surface needs the region methods
	-- the portrait paths call.
	function frame:SetDrawLayer() end
	function frame:AddMaskTexture() end
	function frame:SetTexCoord() end
	-- Font strings are kept in creation order too, so a test can read the text a widget put on
	-- each of them (a status bar's name and countdown, for instance).
	frame._createdFontStrings = {}

	function frame:CreateFontString()
		local fontString = NewRegion(frame, "FontString")
		frame._createdFontStrings[#frame._createdFontStrings + 1] = fontString
		return fontString
	end
	-- Region enumeration mirrors creation order: textures first, then font strings. Mock
	-- template frames create no regions of their own, so a fresh Cooldown reports zero.
	function frame:GetNumRegions()
		return #frame._createdTextures + #frame._createdFontStrings
	end
	function frame:GetRegions()
		local regions = {}
		for _, texture in ipairs(frame._createdTextures) do
			regions[#regions + 1] = texture
		end
		for _, fontString in ipairs(frame._createdFontStrings) do
			regions[#regions + 1] = fontString
		end
		return unpack(regions)
	end
	function frame:CreateAnimationGroup()
		return NewAnimationGroup(frame)
	end

	-- StatusBar widget surface
	if frameType == "StatusBar" then
		frame._value = 0
		frame._minValue, frame._maxValue = 0, 1

		function frame:SetStatusBarTexture(texture)
			frame._statusBarTexture = texture
		end
		function frame:SetStatusBarColor(r, g, b, a)
			frame._color = { r, g, b, a }
		end
		function frame:SetReverseFill(reverse)
			frame._reverseFill = reverse and true or false
		end
		function frame:SetMinMaxValues(min, max)
			frame._minValue, frame._maxValue = min, max
		end
		function frame:SetValue(value)
			frame._value = value
		end
		function frame:GetValue()
			return frame._value
		end
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
				frame._lastArgs[methodName] = { ... }
			end
		end
		frame.GetFont = function()
			return "MockFont", 10, ""
		end
		frame.SetFont = function() end
		-- Kept apart from the counters: tests assert on which formatter (or nil) was installed.
		frame.SetCountdownFormatter = function(_, formatter)
			frame._calls.SetCountdownFormatter = (frame._calls.SetCountdownFormatter or 0) + 1
			frame._countdownFormatter = formatter
		end
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
		"SetDurationText", "AddPandemicRegion", "SetDurationBar", "SetApplicationBar",
	}) do
		-- Setting a name to false in M.missingButtonMethods models an older build that never had
		-- it, which is what the display's feature fallbacks are written against.
		if M.missingButtonMethods[methodName] ~= true then
			button[methodName] = function(_, ...)
				button._calls[methodName] = (button._calls[methodName] or 0) + 1
			end
		end
	end

	-- Validates like the live client: the duration-text options walk NAMED fields, and a
	-- positional {curve, property} pair errored per button at AddAuraGroup time on the PTR.
	local countedSetDurationText = button.SetDurationText
	function button:SetDurationText(fontString, options)
		if options and options.textColor then
			assert(options.textColor.curve ~= nil,
				"SetDurationText: textColor.curve must be a named field")
			assert(options.textColor.property ~= nil,
				"SetDurationText: textColor.property must be a named field")
		end
		button._durationTextOptions = options
		countedSetDurationText(self, fontString, options)
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

	-- Counted so tests can observe the hide/show bounce the display wrapper uses to arm the
	-- engine's dirty processing.
	local baseShow = container.Show
	function container:Show()
		container._calls.Show = (container._calls.Show or 0) + 1
		baseShow(container)
	end

	function container:AddAuraGroup(groupKey, filterString, options)
		assert(container._groups[groupKey] == nil, "aura group already exists: " .. tostring(groupKey))

		-- Hook for tests that care about the state a container is in while its groups are built.
		if M.onAddAuraGroup then
			M.onAddAuraGroup(container, groupKey)
		end
		local group = {
			filterString = filterString,
			options = options,
			maxFrameCount = options.maxFrameCount,
			-- Kept because the live client allocates a group's buttons from the count it was
			-- created with; raising the count afterwards does not conjure more.
			maxFrameCountAtCreation = options.maxFrameCount,
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
	function container:SetAuraGroupFilterString(groupKey, filterString)
		local group = assert(container._groups[groupKey], "no group " .. tostring(groupKey))
		group.filterString = filterString
	end
	function container:SetAuraGroupSortMethod(groupKey, method, direction)
		local group = assert(container._groups[groupKey], "no group " .. tostring(groupKey))
		group.sortMethod, group.sortDirection = method, direction
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
	M.missingButtonMethods = {}
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
	_G.Enum.LuaCurveType = _G.Enum.LuaCurveType or { Linear = 0, Step = 1 }
	_G.Enum.DurationTextBindingProperty = _G.Enum.DurationTextBindingProperty
		or { RemainingDuration = 0, RemainingPercent = 1 }
	-- Pandemic capability: the display wrapper probes these before registering regions.
	_G.C_UnitAuras = _G.C_UnitAuras or {}
	_G.C_UnitAuras.GetRefreshExtendedDuration = _G.C_UnitAuras.GetRefreshExtendedDuration
		or function() return 0 end
	_G.C_UnitAuras.GetAuraBaseDuration = _G.C_UnitAuras.GetAuraBaseDuration
		or function() return 0 end
	-- Duration-text colour curves: probed the same way before binding the countdown fontstring.
	_G.C_AuraContainerUtil = _G.C_AuraContainerUtil or {}
	_G.C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions =
		_G.C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions
		or function(options) return options end
	_G.Enum.NumericRuleFormatRounding = _G.Enum.NumericRuleFormatRounding or { Down = 0, Up = 1 }
	_G.C_StringUtil = _G.C_StringUtil or {}
	_G.C_StringUtil.CreateNumericRuleFormatter = _G.C_StringUtil.CreateNumericRuleFormatter
		or function()
			local fmt = { breakpoints = {} }
			function fmt:AddBreakpoint(breakpoint)
				fmt.breakpoints[#fmt.breakpoints + 1] = breakpoint
			end
			return fmt
		end
	_G.C_CurveUtil = _G.C_CurveUtil or {}
	_G.C_CurveUtil.CreateColorCurve = _G.C_CurveUtil.CreateColorCurve or function()
		local curve = { points = {} }
		function curve:SetType(curveType)
			curve.curveType = curveType
		end
		function curve:AddPoint(x, color)
			curve.points[#curve.points + 1] = { x = x, color = color }
		end
		return curve
	end
	_G.CreateColor = _G.CreateColor or function(r, g, b, a)
		return { r = r, g = g, b = b, a = a }
	end
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
				UpdateStackFontSize = function() end,
				UpdateFontSize = function() end,
			},
			WoWEx = {
				IsAuraStylingRestricted = function()
					return M.restricted
				end,
				HasPandemicRegions = function()
					return true
				end,
			},
		},
		Core = {},
		Framework = {
			GetSavedVars = function()
				return mockDb
			end,
			Notify = function(_, message, ...)
				M.notifications[#M.notifications + 1] = string.format(message, ...)
			end,
			NotifyWithPrefix = function(_, message, ...)
				M.notifications[#M.notifications + 1] = string.format(message, ...)
			end,
		},
	}

	for _, path in ipairs({
		"src/Core/Display/Pool.lua",
		"src/Core/Display/GrowAnchors.lua",
		-- Must precede AuraContainerDisplay: the glow catalog is read at its load.
		"src/Core/Display/GlowStyles.lua",
		"src/Core/Display/Outline.lua",
		-- Must precede AuraFilters: its spell-ID maps are built from these lists at load.
		"src/Core/Auras/AuraCategoryIds.lua",
		"src/Core/Auras/AuraFilters.lua",
		"src/Core/Kicks/KickSlot.lua",
		-- Must precede AuraContainerDisplay: bar buttons resolve their fill through the catalog.
		"src/Core/Display/BarTextures.lua",
		"src/Core/Auras/AuraContainerDisplay.lua",
	}) do
		assert(loadfile(path))("MiniAuras", addon)
	end

	return addon.Core.AuraContainerDisplay, addon, mockDb
end

return M
