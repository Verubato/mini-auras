---@type string, Addon
local _, addon = ...

-- The formatter and colour curves a 12.1 aura button's countdown fontstring binds. The remaining
-- time is secret, so nothing here reads the clock. These are objects the engine evaluates.

-- Colour-by-time bands for the countdown text, tinted by db.CountdownColors. Red under 5s, yellow
-- to the minute, white above by default.
--
-- Each near-coincident stop pair fakes a hard edge on the linear curve, so the 0.05s blend windows
-- are never visible.
--
-- Must match ApplyCountdownColor's bands in Core/Display/IconSlotContainer, so the legacy icons
-- show exactly what the curve-bound ones do.
local BAND_DEFAULTS = {
	Under5s = { R = 1, G = 0, B = 0 },
	Under60s = { R = 1, G = 0.8, B = 0 },
	Over60s = { R = 1, G = 1, B = 1 },
}
-- The highest stop on the ramp. The plain curve spans the same range so both clamp alike.
local TOP_STOP_SECONDS = 60.05

---@type table?
local cachedDb
---@type table?
local colorCurve
-- The generation the colour curve was built for. A mismatch rebuilds it.
---@type number?
local curveGeneration
-- The colours the current generation stands for, flattened for value compares. A profile switch
-- mutates the saved tables in place, so comparing references would miss the change.
local appliedColors = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
local colorGeneration = 0
-- The flat curves a countdown binds while the colouring is off, one per configured text colour.
-- Curves are never mutated after creation, since the engine keeps whatever reference is bound, so
-- each distinct colour is its own object.
---@type table<string, table>
local flatCurves = {}
local flatCurveCount = 0
-- Dragging the colour picker mints one curve per colour it passes through, so the cache is dropped
-- wholesale once it grows past this. Anything already bound goes on working, because the engine
-- holds its own reference.
local MAX_FLAT_CURVES = 32
-- Formatters keyed by milliseconds threshold (0 = whole seconds only). The engine keeps each
-- reference, so variants are built once and shared across every bound fontstring.
---@type table<number, table>
local formatters = {}

---@class AuraCountdownText
local M = {}

addon.Core.AuraCountdownText = M

local function GetDb()
	if not cachedDb then
		cachedDb = addon.Framework:GetSavedVars()
	end

	return cachedDb
end

---One band's saved colour, or its default while the saved table is missing. A profile snapshot
---from before the setting existed round-trips without it.
---@param key string
---@return table
local function BandColor(key)
	local db = GetDb()
	local colors = db and db.CountdownColors

	return (colors and colors[key]) or BAND_DEFAULTS[key]
end

---Bare-number remaining time ("45" -> "2m" -> "1h"), matching the cooldown countdown the coloured
---text replaces. A rule formatter, because the engine's default renders a unit suffix ("45s") and
---SecondsFormatter's abbreviation enum can shorten that unit but never omit it.
---The promotion thresholds are the game's own (1 + 1.5x the unit), and the quotients round up to
---match Blizzard's frames, so 2m32s reads "3m".
---The tenths breakpoint a non-zero msThreshold adds carries no min or rounding fields. With them
---present the engine rendered no fractions at all.
---Seconds round up like the cooldown's own numbers, so a six second root reads "6" the moment it
---lands and "1" through its last second.
---@param msThreshold number Seconds below which tenths show, or 0 for whole seconds only.
---@return table
local function GetFormatter(msThreshold)
	local fmt = formatters[msThreshold]
	if not fmt then
		local down = Enum.NumericRuleFormatRounding.Down
		local up = Enum.NumericRuleFormatRounding.Up
		fmt = C_StringUtil.CreateNumericRuleFormatter()
		if msThreshold > 0 then
			fmt:AddBreakpoint({ threshold = 0, step = 0.1, format = "%.1f" })
			fmt:AddBreakpoint({ threshold = msThreshold, step = 1, rounding = up, format = "%d" })
		else
			fmt:AddBreakpoint({ threshold = 0, step = 1, rounding = up, format = "%d" })
		end
		fmt:AddBreakpoint({ threshold = 91, step = 1, rounding = down, min = 1, format = "%dm",
			components = { { div = 60, rounding = up } } })
		fmt:AddBreakpoint({ threshold = 5401, step = 1, rounding = down, min = 1, format = "%dh",
			components = { { div = 3600, rounding = up } } })
		formatters[msThreshold] = fmt
	end

	return fmt
end

---True when the client supports colour curves and formatters on duration-text bindings. The options
---processor is the symbol to probe, because a build that predates it accepts the options table and
---silently drops the colour.
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

---A generation stamp for the configured band colours, bumped whenever any component moves. Styles
---store the stamp and the style generation folds it in, so one number stands in for nine compares
---at every call site.
---The compare happens here by value, because a profile switch mutates the saved tables in place.
---Missing components count as 1, matching what the curve would draw.
---@return number
function M:GetColorGeneration()
	local under5, under60, over60 = BandColor("Under5s"), BandColor("Under60s"), BandColor("Over60s")
	local r1, g1, b1 = under5.R or 1, under5.G or 1, under5.B or 1
	local r2, g2, b2 = under60.R or 1, under60.G or 1, under60.B or 1
	local r3, g3, b3 = over60.R or 1, over60.G or 1, over60.B or 1
	local a = appliedColors

	if a[1] ~= r1 or a[2] ~= g1 or a[3] ~= b1
		or a[4] ~= r2 or a[5] ~= g2 or a[6] ~= b2
		or a[7] ~= r3 or a[8] ~= g3 or a[9] ~= b3 then
		a[1], a[2], a[3] = r1, g1, b1
		a[4], a[5], a[6] = r2, g2, b2
		a[7], a[8], a[9] = r3, g3, b3
		colorGeneration = colorGeneration + 1
	end

	return colorGeneration
end

---The colour curve every countdown fontstring binds, rebuilt when the configured colours change.
---Curves are never mutated after creation, since the engine keeps whatever reference is bound. A
---change means a new object, and that reference change is what makes StyleCountdown re-bind.
---@return table
function M:GetColorCurve()
	local generation = M:GetColorGeneration()

	if not colorCurve or curveGeneration ~= generation then
		curveGeneration = generation

		-- appliedColors is current, refreshed by the generation call above.
		local a = appliedColors
		local curve = C_CurveUtil.CreateColorCurve()
		curve:SetType(Enum.LuaCurveType.Linear)
		-- Highest threshold first: the curve API expects points added in descending x order.
		curve:AddPoint(TOP_STOP_SECONDS, CreateColor(a[7], a[8], a[9]))
		curve:AddPoint(60, CreateColor(a[4], a[5], a[6]))
		curve:AddPoint(5.05, CreateColor(a[4], a[5], a[6]))
		curve:AddPoint(5, CreateColor(a[1], a[2], a[3]))
		curve:AddPoint(0, CreateColor(a[1], a[2], a[3]))
		colorCurve = curve
	end

	return colorCurve
end

---The curve bound when colour-by-time is off: one flat colour the whole way down, white unless
---a style asks for its own text colour.
---@param r number?
---@param g number?
---@param b number?
---@return table
function M:GetFlatCurve(r, g, b)
	-- Quantised so a colour picker drag cannot mint a cached curve per pixel of movement.
	r = math.floor((r or 1) * 100 + 0.5) / 100
	g = math.floor((g or 1) * 100 + 0.5) / 100
	b = math.floor((b or 1) * 100 + 0.5) / 100

	local key = r .. ":" .. g .. ":" .. b
	local curve = flatCurves[key]

	if not curve then
		if flatCurveCount >= MAX_FLAT_CURVES then
			wipe(flatCurves)
			flatCurveCount = 0
		end

		curve = C_CurveUtil.CreateColorCurve()
		curve:SetType(Enum.LuaCurveType.Linear)
		-- Descending, like the ramp above. Two points, because a single one clamps off its end.
		curve:AddPoint(TOP_STOP_SECONDS, CreateColor(r, g, b))
		curve:AddPoint(0, CreateColor(r, g, b))
		flatCurves[key] = curve
		flatCurveCount = flatCurveCount + 1
	end

	return curve
end

---Binds (or re-binds) a button's countdown fontstring. The engine retains the binding across calls,
---so this is how the formatter and colour curve are swapped at restyle time.
---The fields are named, because the options validator walks [textColor][curve] and
---[textColor][property], and a positional pair errors per button at AddAuraGroup time.
---
---While the fontstring is the countdown a colour is always bound, the off state being a flat white
---curve. Leaving textColor out asks the engine to forget the binding it is holding and it does not,
---so turning the setting off left a bar's countdown coloured until a reload.
---
---While it is not the countdown no colour is bound at all. Binding one there has the engine draw
---the fontstring over the native numbers the cooldown is showing, which reads as two countdowns on
---one icon.
---@param button table
---@param durationText table
---@param msThreshold number Seconds below which tenths show, or 0 for whole seconds only.
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
