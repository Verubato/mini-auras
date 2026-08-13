---@type string, Addon
local _, addon = ...

-- The countdown a 12.1 aura button draws through a bound fontstring rather than the cooldown's
-- own numbers: the formatter that renders the remaining time, and the colour curves the engine
-- evaluates against it. Nothing here reads the clock - the remaining time is secret, and the
-- engine does the reading - so this is entirely a factory for objects the engine keeps.
--
-- Split out of AuraContainerDisplay because none of it touches a display: every value below is
-- built once and shared by every bound fontstring in the addon.

-- Colour-by-time stops for the countdown text: {seconds remaining, r, g, b}. OmniCC's classic
-- bands (red under 5s, yellow to the minute, white above) rather than a gradient: each
-- near-coincident stop pair fakes a hard edge on the linear curve, so the 0.05s blend windows
-- are never visible.
--
-- Must match ApplyCountdownColor's bands in Core/Display/IconSlotContainer, so the legacy icons
-- show exactly what the curve-bound ones do.
local COLOR_STOPS = {
	{ 0, 1, 0, 0 },
	{ 5, 1, 0, 0 },
	{ 5.05, 1, 0.8, 0 },
	{ 60, 1, 0.8, 0 },
	{ 60.05, 1, 1, 1 },
}

---@type table?
local colorCurve
-- The flat curve a countdown binds while the colouring is OFF. See Bind for why the off state is
-- a curve of its own rather than no colour binding at all. White matches the NumberFontNormal the
-- fontstring is created with.
---@type table?
local plainCurve
-- Formatters keyed by milliseconds threshold (0 = whole seconds only). The engine keeps each
-- reference, so variants are built once and shared across every bound fontstring.
---@type table<number, table>
local formatters = {}

---@class AuraCountdownText
local M = {}

addon.Core.AuraCountdownText = M

---Bare-number remaining time ("45" -> "2m" -> "1h"), matching the cooldown countdown the coloured
---text replaces. A rule formatter because the engine's default renders a unit suffix ("45s") and
---SecondsFormatter cannot drop it - its abbreviation enum spells the unit out or shortens it,
---never omits it. The promotion thresholds are the game's own (1 + 1.5x the unit), and the
---quotients round up to match Blizzard's frames (2m32s reads "3m"). A non-zero msThreshold adds a
---tenths band below it ("4.3"); that breakpoint deliberately carries no min/rounding fields - with
---them present the engine rendered no fractions at all.
---@param msThreshold number Seconds below which tenths show; 0 for whole seconds only.
---@return table
local function GetFormatter(msThreshold)
	local fmt = formatters[msThreshold]
	if not fmt then
		local down = Enum.NumericRuleFormatRounding.Down
		local up = Enum.NumericRuleFormatRounding.Up
		fmt = C_StringUtil.CreateNumericRuleFormatter()
		if msThreshold > 0 then
			fmt:AddBreakpoint({ threshold = 0, step = 0.1, format = "%.1f" })
			fmt:AddBreakpoint({ threshold = msThreshold, step = 1, rounding = down, min = 1, format = "%d" })
		else
			fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = down, min = 1, format = "%d" })
		end
		fmt:AddBreakpoint({ threshold = 91, step = 1, rounding = down, min = 1, format = "%dm",
			components = { { div = 60, rounding = up } } })
		fmt:AddBreakpoint({ threshold = 5401, step = 1, rounding = down, min = 1, format = "%dh",
			components = { { div = 3600, rounding = up } } })
		formatters[msThreshold] = fmt
	end

	return fmt
end

---True when the client supports colour curves and formatters on duration-text bindings. Probes
---the options processor rather than the curve API alone: builds that predate it accept the
---options table and silently drop the colour, which would leave the swap-in fontstring plain
---white.
---@return boolean
function M:IsSupported()
	return C_AuraContainerUtil ~= nil
		and C_AuraContainerUtil.ProcessCustomAuraButtonDurationTextOptions ~= nil
		and C_CurveUtil ~= nil
		and C_CurveUtil.CreateColorCurve ~= nil
		and C_StringUtil ~= nil
		and C_StringUtil.CreateNumericRuleFormatter ~= nil
		and Enum.DurationTextBindingProperty ~= nil
		and Enum.NumericRuleFormatRounding ~= nil
end

---The shared colour curve every countdown fontstring binds. Built once; the engine keeps the
---reference and curves are never mutated after creation.
---@return table
function M:GetColorCurve()
	if not colorCurve then
		local curve = C_CurveUtil.CreateColorCurve()
		curve:SetType(Enum.LuaCurveType.Linear)
		-- Highest threshold first: the curve API expects points added in descending x order.
		for i = #COLOR_STOPS, 1, -1 do
			local stop = COLOR_STOPS[i]
			curve:AddPoint(stop[1], CreateColor(stop[2], stop[3], stop[4]))
		end
		colorCurve = curve
	end

	return colorCurve
end

---The curve bound when colour-by-time is off: white the whole way down.
---@return table
function M:GetPlainCurve()
	if not plainCurve then
		local curve = C_CurveUtil.CreateColorCurve()
		curve:SetType(Enum.LuaCurveType.Linear)
		-- Descending, like the ramp above; two points so the value is flat rather than clamped
		-- off the end of a single one.
		curve:AddPoint(COLOR_STOPS[#COLOR_STOPS][1], CreateColor(1, 1, 1))
		curve:AddPoint(0, CreateColor(1, 1, 1))
		plainCurve = curve
	end

	return plainCurve
end

---Binds (or re-binds) a button's countdown fontstring. The engine retains the binding across
---calls, so this is how the formatter and colour curve are swapped at restyle time. Named fields,
---not positional: the options validator walks [textColor][curve] and [textColor][property], and a
---positional pair errors per button at AddAuraGroup time.
---
---While the fontstring is the countdown, a colour is bound either way round - the off state being
---a flat white curve, because leaving textColor out asks the engine to forget the binding it is
---holding and it does not: a bar's countdown IS this fontstring, so turning the setting off left
---it coloured until a reload.
---
---While it is NOT the countdown, no colour is bound at all. Binding one there has the engine draw
---the fontstring over the native numbers the cooldown is showing, which reads as two countdowns
---on one icon. The stale curve it keeps costs nothing: nothing is looking at it, and the next bind
---that does use it replaces it.
---@param button table
---@param durationText table
---@param msThreshold number Seconds below which tenths show; 0 for whole seconds only.
---@param curve table? The colour curve to bind, or nil while the fontstring is not in use.
function M:Bind(button, durationText, msThreshold, curve)
	button:SetDurationText(durationText, {
		textFormatter = GetFormatter(msThreshold),
		textColor = curve and {
			curve = curve,
			property = Enum.DurationTextBindingProperty.RemainingDuration,
		} or nil,
	})
end
