-- Tests for the 12.1 AuraContainer display wrapper (Core/AuraContainerDisplay.lua) and the Core
-- modules it leans on, driven through the aura_container_mock environment. Focus areas are the
-- real bug classes from the 12.1 bring-up: style-signature skipping (and its staleness edge
-- cases), the restriction model (button children are forbidden while auras are secret) and the
-- deferred restyle that has to settle once the restriction lifts, pool pre-creation/reuse, the
-- kick chain anchoring math, and the kick expiry timer.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()
local acm = require("AuraContainerMock")
acm.setup()

local display, addon, mockDb = acm.loadDisplay()
local objectPool = addon.Core.Pool
local kickSlot = addon.Core.KickSlot
local auraFilters = addon.Core.AuraFilters

local BATCH = acm.batchSize

-- The default glow is static, so anything asserting animation has to opt into a moving style.
local ANIMATED_GLOW = "Rotation Assist (Anti-clockwise)"

local function newInstance(groups)
	return display:New(_G.UIParent, "target", groups or {
		{ Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 },
	}, 30, 2, "Test")
end

local function totalSetSizeCalls(instance)
	local total = 0
	for _, button in ipairs(instance.Buttons) do
		total = total + (button._calls.SetSize or 0)
	end
	return total
end

local function firstGlowWidgets(instance)
	for _, widgets in pairs(instance.ButtonWidgets) do
		if widgets.Glow then
			return widgets
		end
	end
end

local function anyGlowPlaying(instance)
	for _, widgets in pairs(instance.ButtonWidgets) do
		if widgets.Glow and widgets.Glow.Anim:IsPlaying() then
			return true
		end
	end
	return false
end

-- The wrapper creates ONE shared event frame, on the first display ever built. Capture it here,
-- before any acm.reset() empties the frame registry.
newInstance()
local displayEvents = assert(acm.lastFrameForEvent("PLAYER_REGEN_ENABLED"),
	"the display wrapper must listen for the end of combat")

fw.describe("AuraContainerDisplay - creation", function()
	fw.before_each(acm.reset)

	fw.it("creates one batch of styled buttons per group", function()
		local instance = newInstance({
			{ Key = "a", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 },
			{ Key = "b", FilterString = "HELPFUL|IMPORTANT", MaxIcons = 3 },
		})
		assert(#instance.Buttons == 2 * BATCH, "expected " .. 2 * BATCH .. " buttons, got " .. #instance.Buttons)
		assert(instance.Frame:HasAuraGroup("a") and instance.Frame:HasAuraGroup("b"), "groups registered")
		-- Every button was styled once at initializeFrame time.
		assert(totalSetSizeCalls(instance) == 2 * BATCH, "each button styled once at creation")
	end)

	fw.it("group layout carries both PTR spacing spellings and element sizes", function()
		local instance = newInstance()
		local group = instance.Frame._groups.cc
		assert(group.layout.elementSpacing == 2 and group.layout.lineSpacing == 2, "old spellings")
		assert(group.layout.elementSpacingX == 2 and group.layout.elementSpacingY == 2, "new spellings")
		assert(group.layout.elementWidth == 30 and group.layout.elementHeight == 30, "element sizes")
	end)

	fw.it("glow animations are NOT playing after creation", function()
		local instance = newInstance()
		assert(not anyGlowPlaying(instance), "no looping animations on freshly created buttons")
	end)
end)

fw.describe("AuraContainerDisplay - SetStyle signature", function()
	fw.before_each(function()
		acm.reset()
		mockDb.DisableSwipe = false
		mockDb.MillisecondsThreshold = 3
	end)

	fw.it("skips restyling when the style is unchanged", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = false, FontScale = 1 })
		local afterFirst = totalSetSizeCalls(instance)
		instance:SetStyle({ Glow = false, FontScale = 1 })
		assert(totalSetSizeCalls(instance) == afterFirst, "identical style must not restyle")
	end)

	fw.it("restyles when a style field changes", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local afterFirst = totalSetSizeCalls(instance)
		instance:SetStyle({ Glow = true })
		assert(totalSetSizeCalls(instance) > afterFirst, "changed style must restyle")
	end)

	fw.it("detects changes when the caller reuses one mutated style table", function()
		-- Callers pass a module-level scratch table, so the display must copy the fields out
		-- rather than hold the reference (holding it would make every comparison a self-compare
		-- and no style change would ever be seen again).
		local instance = newInstance()
		local scratch = { Glow = false, FontScale = 1 }

		instance:SetStyle(scratch)
		local afterFirst = totalSetSizeCalls(instance)

		instance:SetStyle(scratch)
		assert(totalSetSizeCalls(instance) == afterFirst, "unchanged scratch must not restyle")

		scratch.Glow = true
		instance:SetStyle(scratch)
		assert(totalSetSizeCalls(instance) > afterFirst, "mutated scratch must restyle")

		-- Mutating the caller's table afterwards must not corrupt what the display stored.
		local afterThird = totalSetSizeCalls(instance)
		scratch.Glow = false
		scratch.FontScale = 99
		assert(instance.Style.Glow == true and instance.Style.FontScale == 1,
			"the display must keep its own copy of the style")
		assert(totalSetSizeCalls(instance) == afterThird, "mutating the caller's table alone must not restyle")
	end)

	fw.it("restyles when a db-derived value changes (DisableSwipe)", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local afterFirst = totalSetSizeCalls(instance)
		mockDb.DisableSwipe = true
		instance:SetStyle({ Glow = false })
		assert(totalSetSizeCalls(instance) > afterFirst, "db change must restyle despite identical style table")
	end)

	fw.it("restyles when the global font face changes", function()
		-- The face lives outside the style table every caller builds, so without it folded into
		-- the comparison a font change left the text in the old face until something else moved.
		-- The healer warning is a label-only display that nothing else touches: it never moved.
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local afterFirst = totalSetSizeCalls(instance)

		acm.fontFace = "Interface/AddOns/SomeMediaPack/expressway.ttf"
		instance:SetStyle({ Glow = false })
		assert(totalSetSizeCalls(instance) > afterFirst, "a font change must restyle an untouched style")

		local afterFont = totalSetSizeCalls(instance)
		instance:SetStyle({ Glow = false })
		assert(totalSetSizeCalls(instance) == afterFont, "and only the once")
	end)

	fw.it("sweeps a font change onto a display whose owner never re-applies a style", function()
		-- The healer warning text is styled when the roster moves and at no other time, so a font
		-- change reached it only by luck. The sweep is what makes it land on every display.
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local afterFirst = totalSetSizeCalls(instance)

		acm.fontFace = "Interface/AddOns/SomeMediaPack/expressway.ttf"
		display:RefreshFontFace()
		assert(totalSetSizeCalls(instance) > afterFirst, "the sweep must restyle it")

		local afterSweep = totalSetSizeCalls(instance)
		display:RefreshFontFace()
		assert(totalSetSizeCalls(instance) == afterSweep, "and leave it alone once it is current")

		-- The style it now holds has to agree, or the next SetStyle would restyle all over again.
		instance:SetStyle({ Glow = false })
		assert(totalSetSizeCalls(instance) == afterSweep, "the swept face must be the stored one")
	end)

	fw.it("defers a swept font change while aura styling is restricted", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local styled = totalSetSizeCalls(instance)

		acm.restricted = true
		acm.fontFace = "Interface/AddOns/SomeMediaPack/other.ttf"
		display:RefreshFontFace()
		assert(totalSetSizeCalls(instance) == styled, "no button may be touched while restricted")

		acm.restricted = false
		acm.tickAll(1)
		assert(totalSetSizeCalls(instance) > styled, "the retry ticker settles it once it lifts")
	end)

	fw.it("SetIconSize restyles even with an unchanged style", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local afterFirst = totalSetSizeCalls(instance)
		instance:SetIconSize(40)
		assert(totalSetSizeCalls(instance) > afterFirst, "size change must restyle")
		instance:SetIconSize(40)
		local afterSecond = totalSetSizeCalls(instance)
		instance:SetIconSize(40)
		assert(totalSetSizeCalls(instance) == afterSecond, "unchanged size must not restyle")
	end)
end)

fw.describe("AuraContainerDisplay - restriction model", function()
	fw.before_each(function()
		acm.reset()
	end)

	fw.it("skips restyling while restricted, then retries on identical SetStyle", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local styled = totalSetSizeCalls(instance)

		acm.restricted = true
		instance:SetStyle({ Glow = true })
		assert(totalSetSizeCalls(instance) == styled, "restricted restyle must be skipped")

		acm.restricted = false
		instance:SetStyle({ Glow = true })
		assert(totalSetSizeCalls(instance) > styled, "pending restyle must run after restriction lifts")
	end)

	fw.it("a size change while restricted keeps the layout and the buttons in step", function()
		-- The engine only POSITIONS aura buttons: CustomAuraContainerFlowLayoutMixin's
		-- ApplyElementLayout discards the width/height it is handed, and spaces the row by
		-- group.elementWidth instead. The button's real size comes from the restyle, which is
		-- skipped while restricted. Publishing the layout early therefore spaces the row for a
		-- size the buttons have not taken - gaps when sizing up, overlap when sizing down.
		local instance = newInstance()
		local startSize = instance.Frame._groups.cc.layout.elementWidth

		acm.restricted = true
		instance:SetIconSize(startSize + 20)
		assert(instance.Frame._groups.cc.layout.elementWidth == startSize,
			"layout must not move ahead of the buttons while restricted")

		acm.restricted = false
		instance:RestyleButtons()
		assert(instance.Frame._groups.cc.layout.elementWidth == startSize + 20,
			"layout catches up once the restyle can run")
	end)

	fw.it("a spacing change while restricted does not publish a pending size either", function()
		-- BuildGroupLayout reads Size, so applying the layout for a spacing-only change would
		-- smuggle out a size the buttons have not taken yet.
		local instance = newInstance()
		local startSize = instance.Frame._groups.cc.layout.elementWidth

		acm.restricted = true
		instance:SetIconSize(startSize + 20)
		instance:SetSpacing(9)
		assert(instance.Frame._groups.cc.layout.elementWidth == startSize,
			"a spacing change must not publish the pending icon size")

		acm.restricted = false
		instance:RestyleButtons()
		assert(instance.Frame._groups.cc.layout.elementSpacing == 9, "spacing applied")
		assert(instance.Frame._groups.cc.layout.elementWidth == startSize + 20, "size applied")
	end)

	fw.it("parking a display leaves its glows running, so reuse under restriction still glows", function()
		-- Glow frames are children of AuraButtons, so re-showing one needs a restyle, and a
		-- restyle is blocked for as long as auras are secret (the whole of an arena). Nothing on
		-- the park path may stop them: a display parked in the world and reused inside an arena
		-- would come back with no glow for the entire match.
		mockDb.GlowType = ANIMATED_GLOW
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(anyGlowPlaying(instance), "glow animations playing while style.Glow")

		instance:SetEnabled(false)
		instance:Hide()
		acm.restricted = true
		instance:Show()
		instance:SetEnabled(true)

		assert(anyGlowPlaying(instance), "still glowing after a park and reuse under restriction")
	end)

	fw.it("touching a button child while restricted errors (mock sanity)", function()
		local instance = newInstance()
		acm.restricted = true
		local widgets = select(2, next(instance.ButtonWidgets))
		local ok = pcall(function()
			widgets.Glow:Hide()
		end)
		assert(not ok, "the mock must simulate the forbidden-object error")
	end)
end)

fw.describe("AuraContainerDisplay - dispel-type registrations", function()
	fw.before_each(acm.reset)

	local function countCalls(instance, methodName)
		local total = 0
		for _, button in ipairs(instance.Buttons) do
			total = total + (button._calls[methodName] or 0)
		end
		return total
	end

	fw.it("registers border only, or border + glow texture when the glow is enabled too", function()
		local instance = newInstance()
		local buttons = #instance.Buttons

		instance:SetStyle({ ColorByDispelType = true, Glow = false })
		assert(countCalls(instance, "AddDispelTypeTexture") == buttons, "border registered per button")

		instance:SetStyle({ ColorByDispelType = true, Glow = true })
		-- Re-registration clears and adds border + glow texture: 2 more adds per button.
		assert(countCalls(instance, "AddDispelTypeTexture") == 3 * buttons, "glow tint joins the border")
		assert(countCalls(instance, "ClearDispelTypeTextures") >= buttons, "cleared before re-registering")
	end)

	fw.it("unchanged registration needs are not re-registered on restyle", function()
		local instance = newInstance()
		instance:SetStyle({ ColorByDispelType = true, Glow = true })
		local adds = countCalls(instance, "AddDispelTypeTexture")
		instance:SetIconSize(44) -- restyles every button, but the dispel needs are unchanged
		assert(countCalls(instance, "AddDispelTypeTexture") == adds, "no registration churn")
	end)

	fw.it("a colour-only change still repaints the plain border", function()
		local instance = newInstance()
		instance:SetStyle({ Border = true, GlowColor = { 1, 0, 0 } })

		local widgets = select(2, next(instance.ButtonWidgets))
		local border = widgets.BorderTextures[1]

		instance:SetStyle({ Border = true, GlowColor = { 0, 0, 1 } })
		local color = border._lastArgs.SetVertexColor
		assert(color[1] == 0 and color[2] == 0 and color[3] == 1, "the new tint reached the border")
	end)

	fw.it("disabling dispel colours clears the registrations", function()
		local instance = newInstance()
		instance:SetStyle({ ColorByDispelType = true, Glow = true })
		local clears = countCalls(instance, "ClearDispelTypeTextures")
		instance:SetStyle({ ColorByDispelType = false, Glow = true })
		assert(countCalls(instance, "ClearDispelTypeTextures") > clears, "registrations cleared")
	end)
end)

fw.describe("AuraContainerDisplay - glow lifecycle", function()
	fw.before_each(acm.reset)

	fw.it("plays animations only while the glow style is enabled", function()
		mockDb.GlowType = ANIMATED_GLOW
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(anyGlowPlaying(instance), "enabled -> playing")
		instance:SetStyle({ Glow = false })
		assert(not anyGlowPlaying(instance), "disabled -> stopped")
	end)

end)

fw.describe("AuraContainerDisplay - glow styles", function()
	fw.before_each(function()
		acm.reset()
		mockDb.GlowType = nil
	end)

	fw.it("defaults to the static slot glow", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(firstGlowWidgets(instance).GlowStyle == "Slot Glow", "default is the slot glow")
		assert(not anyGlowPlaying(instance), "and it does not animate")
	end)

	fw.it("draws the plain border only when the style asks for one", function()
		-- Dispel colouring hands the border to the engine; without it the border is ours to
		-- show or hide, and it stays hidden unless a module opts in.
		local instance = newInstance()
		instance:SetStyle({ Glow = false })
		local widgets = select(2, next(instance.ButtonWidgets))
		local border = widgets.BorderTextures[1]
		assert(border._shown == false, "no border by default")

		instance:SetStyle({ Border = true, GlowColor = { 1, 0, 0 } })
		assert(border._shown, "shown once asked for")
		local color = border._lastArgs.SetVertexColor
		assert(color[1] == 1 and color[2] == 0 and color[3] == 0, "tinted with the style colour")

		instance:SetStyle({ Border = false })
		assert(border._shown == false, "and hidden again")
	end)

	fw.it("tints each group's glow with its own category colour", function()
		-- One container renders importants and defensives as separate aura groups, so a
		-- per-group tint is the only way to colour them differently - the button can only be
		-- styled in initializeFrame, which runs per group.
		local instance = display:New(_G.UIParent, "target", {
			{ Key = "imp", FilterString = "HELPFUL", MaxIcons = 3, GlowColor = { 1, 0.2, 0.2 } },
			{ Key = "def", FilterString = "HELPFUL", MaxIcons = 3, GlowColor = { 0.2, 1, 0.2 } },
			{ Key = "plain", FilterString = "HELPFUL", MaxIcons = 3 },
		}, 30, 2, "Test", { Style = { Glow = true } })

		local function colorOf(groupKey)
			local button = instance.Frame:GetAuraGroupFrame(groupKey, 1)
			return instance.ButtonWidgets[button].Glow.Texture._lastArgs.SetVertexColor
		end

		local imp, def, plain = colorOf("imp"), colorOf("def"), colorOf("plain")
		assert(imp[1] == 1 and imp[2] == 0.2 and imp[3] == 0.2, "importants glow red")
		assert(def[1] == 0.2 and def[2] == 1 and def[3] == 0.2, "defensives glow green")
		assert(plain[1] == 1 and plain[2] == 1 and plain[3] == 1, "a group with no colour stays white")
	end)

	fw.it("a tinted group keeps its colour instead of the dispel palette", function()
		-- The engine's palette has nothing to say about a buff, so the categories the user picked
		-- a colour for opt out of dispel colouring and draw their own border and glow.
		local instance = display:New(_G.UIParent, "target", {
			{ Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 3 },
			{ Key = "def", FilterString = "HELPFUL", MaxIcons = 3, GlowColor = { 0.2, 1, 0.2 } },
		}, 30, 2, "Test", { Style = { Glow = true, ColorByDispelType = true } })

		local function widgetsOf(groupKey)
			return instance.ButtonWidgets[instance.Frame:GetAuraGroupFrame(groupKey, 1)]
		end

		local cc, def = widgetsOf("cc"), widgetsOf("def")
		local ccButton = instance.Frame:GetAuraGroupFrame("cc", 1)
		local defButton = instance.Frame:GetAuraGroupFrame("def", 1)

		assert((ccButton._calls.AddDispelTypeTexture or 0) > 0, "the cc group is handed to the engine")
		assert((defButton._calls.AddDispelTypeTexture or 0) == 0, "the tinted group is not")

		local border = def.BorderTextures[1]
		assert(border._shown, "a tinted group still draws its border")
		local color = border._lastArgs.SetVertexColor
		assert(color[1] == 0.2 and color[2] == 1 and color[3] == 0.2, "in the group's colour")
		assert(cc.BorderTextures[1]._lastArgs.SetVertexColor == nil,
			"while the engine owns the cc border's colour")
	end)

	fw.it("SetGroupGlowColors recolours a display that already exists", function()
		-- Buttons can only be built once, and rebuilding one is impossible while auras are secret,
		-- so a colour change has to reach the buttons that are already there.
		local instance = display:New(_G.UIParent, "target", {
			{ Key = "def", FilterString = "HELPFUL", MaxIcons = 3, GlowColor = { 0.2, 1, 0.2 } },
		}, 30, 2, "Test", { Style = { Glow = true } })

		local function glowColor()
			local button = instance.Frame:GetAuraGroupFrame("def", 1)
			return instance.ButtonWidgets[button].Glow.Texture._lastArgs.SetVertexColor
		end

		local keys = { "def" }
		local created = instance.GroupsByKey.def.GlowColor

		instance:SetGroupGlowColors(keys, { def = { 1, 0, 0 } })
		assert(created[1] == 0.2 and created[2] == 1 and created[3] == 0.2,
			"the table the caller built the group with is never written to")

		local color = glowColor()
		assert(color[1] == 1 and color[2] == 0 and color[3] == 0, "the new colour reached the buttons")

		-- A group with no entry in the map is what "back to the plain glow" looks like.
		instance:SetGroupGlowColors(keys, {})
		color = glowColor()
		assert(color[1] == 1 and color[2] == 1 and color[3] == 1, "and clearing it goes back to white")

		acm.notifications = {}
		instance:SetGroupGlowColors({ "nosuchgroup" }, { nosuchgroup = { 1, 0, 0 } })
		assert(#acm.notifications == 1, "an unknown group key is reported rather than ignored")
	end)

	fw.it("the style signature covers the global glow type", function()
		-- Displays are cached by this signature, and the glow style is a global db value the
		-- caller never passes in; leaving it out meant changing it in the options never reached
		-- the already-built buttons.
		local style = display:GetStyleScratch()
		style.Glow = true

		local before = display:GetStyleSignature(style, 30, 2)
		mockDb.GlowType = ANIMATED_GLOW
		local after = display:GetStyleSignature(style, 30, 2)

		assert(before ~= after, "changing the glow type must invalidate cached displays")
	end)

	fw.it("Slot Glow applies its static asset and runs no animation", function()
		mockDb.GlowType = "Slot Glow"
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local widgets = firstGlowWidgets(instance)
		assert(widgets.GlowStyle == "Slot Glow", "slot glow selected")
		assert(not anyGlowPlaying(instance), "a static glow must not animate")

		local asset = widgets.Glow.Texture._lastArgs.SetTexture[1]
		assert(asset:find("SlotGlow"), "slot glow asset applied, got " .. tostring(asset))
	end)

	fw.it("an atlas-backed glow style uses SetAtlas rather than SetTexture", function()
		-- Ants ships with the client as an atlas, so it has no file of its own to point at.
		mockDb.GlowType = "Ants (Anti-Clockwise)"
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local widgets = firstGlowWidgets(instance)
		assert(widgets.GlowStyle == "Ants (Anti-Clockwise)", "ants selected")
		assert(widgets.Glow.Texture._lastArgs.SetAtlas, "applied through SetAtlas")
		assert(anyGlowPlaying(instance), "and it animates")
	end)

	fw.it("an LCG-only glow type falls back to the default", function()
		mockDb.GlowType = "Proc Glow"
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(firstGlowWidgets(instance).GlowStyle == "Slot Glow", "unsupported type falls back")
	end)

	fw.it("changing the glow type restyles despite an identical style table", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		local afterFirst = totalSetSizeCalls(instance)

		mockDb.GlowType = ANIMATED_GLOW
		instance:SetStyle({ Glow = true })
		assert(totalSetSizeCalls(instance) > afterFirst, "glow type must be part of the style signature")
	end)

	fw.it("re-applying the same glow type does not re-set the asset", function()
		mockDb.GlowType = "Slot Glow"
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local texture = firstGlowWidgets(instance).Glow.Texture
		local applied = texture._calls.SetTexture
		assert(applied == 1, "asset applied once, got " .. tostring(applied))

		instance:SetIconSize(40)
		assert(texture._calls.SetTexture == applied, "restyle without a type change must not re-skin")
	end)

	fw.it("a restyle that leaves the padding alone does not re-anchor the glow", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local glow = firstGlowWidgets(instance).Glow
		local points = #glow._points

		instance:SetStyle({ Glow = true, Border = true })
		assert(#glow._points == points, "same size and style must not re-anchor")

		instance:SetIconSize(50)
		assert(#glow._points > points, "a size change moves the glow with the button")
	end)

	fw.it("switching away from the flipbook resets its tex coords", function()
		mockDb.GlowType = ANIMATED_GLOW
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local texture = firstGlowWidgets(instance).Glow.Texture
		local before = texture._calls.SetTexCoord or 0

		mockDb.GlowType = "Slot Glow"
		instance:SetStyle({ Glow = true })
		assert((texture._calls.SetTexCoord or 0) > before, "static asset must clear the flipbook's cell coords")
	end)
end)

fw.describe("AuraContainerDisplay - CarriesConfig", function()
	fw.before_each(function()
		acm.reset()
		mockDb.GlowType = nil
	end)

	fw.it("answers from what the buttons were built with", function()
		local instance = newInstance()
		assert(instance:CarriesConfig(30, 2, {}), "the creation config is carried")
		assert(not instance:CarriesConfig(44, 2, {}), "a different size is not")
		assert(not instance:CarriesConfig(30, 5, {}), "a different spacing is not")
		assert(not instance:CarriesConfig(30, 2, { Glow = true }), "a different style is not")
	end)

	fw.it("a style stored under restriction is not carried until its restyle lands", function()
		local instance = newInstance()

		acm.restricted = true
		instance:SetStyle({ Glow = true })
		assert(not instance:CarriesConfig(30, 2, { Glow = true }),
			"stored but not yet on the buttons must not read as carried")

		acm.restricted = false
		instance:RestyleButtons()
		assert(instance:CarriesConfig(30, 2, { Glow = true }), "carried once the restyle lands")
	end)
end)

fw.describe("Pool", function()
	fw.before_each(acm.reset)

	local function newCountingPool(prealloc)
		local created, resets = 0, 0
		local pool = objectPool:New(function()
			created = created + 1
			return { id = created }
		end, function()
			resets = resets + 1
		end, prealloc)
		return pool, function() return created end, function() return resets end
	end

	-- The one moment a caller can influence how an item is built, which matters for anything
	-- baked in at creation and refused afterwards: an aura button's whole look, for instance.
	fw.it("hands Acquire's arguments to the create function", function()
		local seen
		local pool = objectPool:New(function(...)
			seen = { ... }
			return {}
		end, function() end, 0)

		pool:Acquire("style", 7)

		assert(seen and seen[1] == "style" and seen[2] == 7,
			"the create function was given what Acquire was given")
	end)

	fw.it("does not pass them to an item that came off the free list", function()
		-- A pooled item was built before the caller existed, so there is nothing to pass on:
		-- a caller that needs its own settings has to apply them after acquiring.
		local calls = 0
		local pool = objectPool:New(function()
			calls = calls + 1
			return {}
		end, function() end, 0)

		pool:Release(pool:Acquire("first"))
		pool:Acquire("second")

		assert(calls == 1, "the second acquire reused rather than built, got " .. calls)
	end)

	-- Created counts what the pool has ever built, not what is free. A burst that outran the
	-- pool otherwise leaves Prewarm still owing the whole target, and it builds a second set of
	-- the expensive objects the pool exists to ration.
	fw.it("counts an on-demand build against the pre-creation target", function()
		local pool, created = newCountingPool(3)

		for _ = 1, 3 do
			pool:Acquire()
		end

		assert(created() == 3, "three acquires on an empty pool built three, got " .. created())

		pool:Prewarm()
		acm.tickAll(10)

		assert(created() == 3, "the target is already met, so nothing more is built, got " .. created())
	end)

	fw.it("does not pre-create until Prewarm is called", function()
		local _, created = newCountingPool(5)
		acm.tickAll(10)
		assert(created() == 0, "an un-prewarmed pool must stay empty, got " .. created())
	end)

	fw.it("pre-creates staggered until the target, then stops the ticker", function()
		local pool, created = newCountingPool(5)
		pool:Prewarm()
		assert(created() == 0, "nothing created before ticks")
		acm.tickAll(2) -- 2 per tick
		assert(created() == 4, "2 items per tick")
		acm.tickAll(10)
		assert(created() == 5, "stops at the preallocation target, got " .. created())
	end)

	fw.it("Prewarm is idempotent and can raise (never lower) the target", function()
		local pool, created = newCountingPool(2)
		pool:Prewarm()
		pool:Prewarm() -- must not start a second ticker
		acm.tickAll(10)
		assert(created() == 2, "repeat Prewarm must not over-create, got " .. created())

		pool:Prewarm(4)
		acm.tickAll(10)
		assert(created() == 4, "a raised target resumes pre-creation, got " .. created())

		pool:Prewarm(1)
		acm.tickAll(10)
		assert(created() == 4, "a lower target must not create or discard anything")
	end)

	fw.it("Acquire drains the pool then falls back to on-demand creation", function()
		local pool, created = newCountingPool(2)
		pool:Prewarm()
		acm.tickAll(5)
		assert(created() == 2)
		local a = pool:Acquire()
		local b = pool:Acquire()
		assert(a and b and a ~= b, "distinct pooled items")
		local c = pool:Acquire()
		assert(c and created() == 3, "empty pool must create on demand")
	end)

	fw.it("Release resets the item and hands it back on the next Acquire", function()
		local pool, created, resets = newCountingPool(0)
		local item = pool:Acquire()
		assert(created() == 1)
		pool:Release(item)
		assert(resets() == 1, "release must reset")
		assert(pool:Acquire() == item, "released item is reused")
		assert(created() == 1, "no extra creation on reuse")
	end)

	-- AcquireMatching exists for the restricted moments where a reused item cannot be corrected
	-- after the fact: only a free item the matcher accepts may come back.
	fw.it("AcquireMatching reuses only a free item the matcher accepts", function()
		local pool, created = newCountingPool(0)
		local a = pool:Acquire()
		local b = pool:Acquire()
		pool:Release(a)
		pool:Release(b)

		local hit = pool:AcquireMatching(function(item, wanted)
			return item.id == wanted
		end, a.id)

		assert(hit == a, "the matching free item is handed back")
		assert(created() == 2, "no build while a free item matches")
	end)

	fw.it("AcquireMatching builds fresh from its arguments when nothing free matches", function()
		local seen
		local pool = objectPool:New(function(...)
			seen = { ... }
			return {}
		end, function() end, 0)

		pool:Release(pool:Acquire())

		local item = pool:AcquireMatching(function()
			return false
		end, "style", 7)

		assert(item and seen and seen[1] == "style" and seen[2] == 7,
			"a mismatch builds on demand even though free items remain")
	end)

	-- Prewarm used to build with no arguments at all, which for aura displays meant buttons
	-- baked with an empty style that no restricted acquire could ever match.
	fw.it("Prewarm asks argsFn for each pre-created item's creation arguments", function()
		local seen = {}
		local pool = objectPool:New(function(arg)
			seen[#seen + 1] = arg
			return {}
		end, function() end, 3)

		local calls = 0
		pool:Prewarm(nil, function(ctx)
			calls = calls + 1
			return ctx .. calls
		end, "ctx")
		acm.tickAll(10)

		assert(#seen == 3, "three pre-created, got " .. #seen)
		assert(seen[1] == "ctx1" and seen[3] == "ctx3",
			"arguments produced fresh per item from the given context")
	end)
end)

fw.describe("AuraContainerDisplay - AnchorAfterKick", function()
	fw.before_each(acm.reset)

	local kickFrame, anchor

	local function anchorWith(grow, kickActive)
		kickFrame = acm.NewFrame("Frame", "Kick")
		anchor = acm.NewFrame("Frame", "Anchor")
		local instance = newInstance()
		instance:AnchorAfterKick(kickFrame, anchor, grow, 4, 10, -10, kickActive)
		return select(1, instance.Frame:GetPoint(1)), select(2, instance.Frame:GetPoint(1)),
			select(3, instance.Frame:GetPoint(1)), select(4, instance.Frame:GetPoint(1)),
			select(5, instance.Frame:GetPoint(1))
	end

	fw.it("anchors to the configured point when no kick is active", function()
		local point, relativeTo, relativePoint, x, y = anchorWith("RIGHT", false)
		assert(point == "LEFT" and relativePoint == "RIGHT", "grow RIGHT maps LEFT->RIGHT")
		assert(relativeTo == anchor, "anchored to the anchor frame")
		assert(x == 10 and y == -10, "configured offsets used")
	end)

	fw.it("chains after the kick frame while a kick is active", function()
		local point, relativeTo, relativePoint, x, y = anchorWith("RIGHT", true)
		assert(point == "LEFT" and relativePoint == "RIGHT", "chain edge for grow RIGHT")
		assert(relativeTo == kickFrame, "anchored to the kick frame")
		assert(x == 4 and y == 0, "spacing along the grow axis")
	end)

	fw.it("grow LEFT chains with negative spacing", function()
		local point, relativeTo, relativePoint, x = anchorWith("LEFT", true)
		assert(point == "RIGHT" and relativePoint == "LEFT" and relativeTo == kickFrame)
		assert(x == -4, "spacing points left")
	end)

	fw.it("grow UP chains vertically", function()
		local point, _, relativePoint, x, y = anchorWith("UP", true)
		assert(point == "BOTTOM" and relativePoint == "TOP")
		assert(x == 0 and y == 4, "spacing points up")
	end)

	fw.it("CENTER without a kick anchors center-to-center", function()
		local point, relativeTo, relativePoint = anchorWith("CENTER", false)
		assert(point == "CENTER" and relativePoint == "CENTER" and relativeTo == anchor)
	end)
end)

fw.describe("KickSlot", function()
	fw.before_each(acm.reset)

	local function newSlotRecorder()
		local recorder = { setCalls = {}, unusedCalls = {} }
		function recorder:SetSlot(index, options)
			recorder.setCalls[#recorder.setCalls + 1] = { index = index, options = options }
		end
		function recorder:SetSlotUnused(index)
			recorder.unusedCalls[#recorder.unusedCalls + 1] = index
		end
		return recorder
	end

	fw.it("renders the kick and schedules expiry", function()
		wow.setTime(100)
		local container = newSlotRecorder()
		local expired = false
		local kickEntry = { StartTime = 100, Duration = 5, Texture = "tex" }

		local timer = kickSlot:Render(container, kickEntry, { Texture = "tex" }, nil, function()
			expired = true
		end)

		assert(#container.setCalls == 1 and container.setCalls[1].index == 1, "kick rendered into slot 1")
		assert(timer and math.abs(timer.delay - 5.05) < 0.001, "expiry timer ~duration+0.05, got " .. tostring(timer and timer.delay))
		acm.runTimers()
		assert(expired, "onExpired fires when the timer runs")
	end)

	fw.it("cancels the previous timer on re-render", function()
		wow.setTime(100)
		local container = newSlotRecorder()
		local first = kickSlot:Render(container, { StartTime = 100, Duration = 5 }, {}, nil, function() end)
		local second = kickSlot:Render(container, { StartTime = 101, Duration = 5 }, {}, first, function() end)
		assert(first.cancelled, "previous timer cancelled")
		assert(second and not second.cancelled, "new timer active")
	end)

	fw.it("clears the slot and returns no timer when the kick is gone", function()
		local container = newSlotRecorder()
		local timer = kickSlot:Render(container, nil, nil, nil, function() end)
		assert(timer == nil, "no timer without a kick")
		assert(#container.unusedCalls == 1 and container.unusedCalls[1] == 1, "slot 1 cleared")
	end)

	fw.it("an already-expired kick renders but schedules nothing", function()
		wow.setTime(200)
		local container = newSlotRecorder()
		local timer = kickSlot:Render(container, { StartTime = 100, Duration = 5 }, {}, nil, function() end)
		assert(timer == nil, "no timer for an expired kick")
		assert(#container.setCalls == 1, "icon still rendered (cooldown shows it expired)")
	end)
end)

fw.describe("AuraContainerDisplay - group budgets", function()
	fw.before_each(acm.reset)

	fw.it("SetMaxIcons targets only the named group and skips unchanged values", function()
		local instance = newInstance({
			{ Key = "a", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 },
			{ Key = "b", FilterString = "HELPFUL|IMPORTANT", MaxIcons = 3 },
		})
		instance:SetMaxIcons("a", 0)
		assert(instance.Frame._groups.a.maxFrameCount == 0, "group a zeroed")
		assert(instance.Frame._groups.b.maxFrameCount == 3, "group b untouched")

		local sets = instance.Frame._groups.a.maxFrameCountSets or 0
		instance:SetMaxIcons("a", 0)
		assert((instance.Frame._groups.a.maxFrameCountSets or 0) == sets, "unchanged budget skips the API call")
	end)

	fw.it("an unknown group key is reported, not silently ignored", function()
		-- A budget of 0 is how a whole category is switched off, so a mistyped key would
		-- silently disable one with no symptom anywhere.
		local instance = newInstance({
			{ Key = "a", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 },
		})
		acm.notifications = {}

		instance:SetMaxIcons("nope", 0)

		assert(#acm.notifications == 1, "expected one warning, got " .. #acm.notifications)
		assert(acm.notifications[1]:find("nope", 1, true), "the warning names the bad key")
		assert(instance.Frame._groups.a.maxFrameCount == 5, "the real group is untouched")
	end)
end)

fw.describe("AuraContainerDisplay - deferred restyle", function()
	fw.before_each(acm.reset)

	---Puts an instance into the "styled, then a change was skipped while restricted" state.
	local function newPendingInstance()
		local instance = newInstance()
		instance:SetStyle({ Glow = false })

		acm.restricted = true
		instance:SetStyle({ Glow = true })
		acm.restricted = false

		assert(instance.RestylePending, "precondition: restyle is pending")
		return instance, totalSetSizeCalls(instance)
	end

	fw.it("settles a pending restyle when combat ends", function()
		-- Without this the buttons keep the old style for the rest of the fight: nothing else
		-- calls SetStyle again, and the container-level layout has ALREADY taken the new size.
		local instance, styled = newPendingInstance()

		displayEvents:TriggerEvent("PLAYER_REGEN_ENABLED")

		assert(not instance.RestylePending, "pending flag cleared")
		assert(totalSetSizeCalls(instance) > styled, "buttons restyled once the restriction lifted")
	end)

	fw.it("does not restyle while the restriction is still in force", function()
		local instance, styled = newPendingInstance()
		acm.restricted = true

		displayEvents:TriggerEvent("PLAYER_REGEN_ENABLED")

		assert(instance.RestylePending, "still pending")
		assert(totalSetSizeCalls(instance) == styled, "no forbidden button calls attempted")
	end)

	fw.it("skips parked (hidden) displays, whose buttons are off screen anyway", function()
		local instance, styled = newPendingInstance()
		instance:Hide()

		displayEvents:TriggerEvent("PLAYER_REGEN_ENABLED")

		assert(instance.RestylePending, "a parked display stays pending")
		assert(totalSetSizeCalls(instance) == styled, "parked display not restyled")
	end)

	fw.it("settles a pending restyle when the display is shown again", function()
		local instance, styled = newPendingInstance()
		instance:Hide()
		displayEvents:TriggerEvent("PLAYER_REGEN_ENABLED")
		assert(totalSetSizeCalls(instance) == styled, "still parked")

		instance:Show()

		assert(not instance.RestylePending, "showing settles the pending restyle")
		assert(totalSetSizeCalls(instance) > styled, "buttons restyled on show")
	end)
end)

fw.describe("AuraContainerDisplay - per-display button options", function()
	fw.before_each(acm.reset)

	local function newOptionInstance(options)
		return display:New(_G.UIParent, "target", {
			{ Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 1 },
		}, 30, 0, "Test", options)
	end

	fw.it("Minimal skips the dispel border and the glow frame", function()
		-- Portrait icons take neither, and creating them anyway would cost two frames per button
		-- across every portrait container.
		local instance = newOptionInstance({ Minimal = true })
		local widgets = select(2, next(instance.ButtonWidgets))

		assert(widgets.BorderTextures == nil and widgets.Glow == nil, "no border/glow widgets created")
		-- Styling must not assume they exist.
		local ok, err = pcall(function()
			instance:SetStyle({ ColorByDispelType = true, Glow = true })
		end)
		assert(ok, "styling a minimal display must not error: " .. tostring(err))
	end)

	fw.it("applies the icon crop and mask to every button icon", function()
		local mask = { _mask = true }
		local instance = newOptionInstance({ IconTexCoord = { 0.1, 0.9, 0.1, 0.9 }, IconMask = mask })
		local button = instance.Buttons[1]
		local icon = button._createdTextures and button._createdTextures[1]

		assert(icon, "the button created an icon texture")
		assert(icon._lastArgs.SetTexCoord and icon._lastArgs.SetTexCoord[1] == 0.1, "crop applied")
		assert(icon._lastArgs.AddMaskTexture and icon._lastArgs.AddMaskTexture[1] == mask, "mask applied")
	end)

	-- The overlays and the border ring both have rounded inner corners, so a square icon under
	-- either leaves its own corners poking out past the art.
	fw.it("trims the icon corners under a ring, whichever draws it", function()
		local instance = newOptionInstance()
		local widgets = select(2, next(instance.ButtonWidgets))

		instance:SetStyle({ Glow = false, Border = false, ColorByDispelType = false })
		assert(widgets.CornersRounded == false, "a bare icon keeps its corners")

		instance:SetStyle({ Glow = true })
		assert(widgets.CornersRounded == true, "the glow trims them")

		instance:SetStyle({ Glow = false, Border = true })
		assert(widgets.CornersRounded == true, "and so does a plain border")

		instance:SetStyle({ Glow = false, Border = false, ColorByDispelType = true })
		assert(widgets.CornersRounded == true, "and the engine's dispel ring")
	end)

	fw.it("a plain display still builds the border and glow", function()
		local instance = newOptionInstance()
		local widgets = select(2, next(instance.ButtonWidgets))
		assert(widgets.BorderTextures and widgets.Glow, "default displays keep the full chrome")
	end)

	fw.it("Pandemic registers a refresh-window region on every button", function()
		local instance = newOptionInstance({ Pandemic = true })
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		assert(button._calls.AddPandemicRegion == 1, "one region registered per button")
		assert(widgets.Pandemic and widgets.Pandemic.Textures[1], "the holder carries the ring texture")
		local ring = widgets.Pandemic.Textures[1]
		-- Off by default: the engine decides when the HOLDER shows, but the ring only draws for a
		-- group that turned the reveal on. Hidden, not just transparent - alpha alone left an amber
		-- ring on every icon of every group that had the reveal switched off.
		assert(ring._shown == false, "ring starts hidden")
		assert(ring._lastArgs.SetAlpha[1] == 0, "and transparent with it")

		instance:SetStyle({ Pandemic = true })
		assert(ring._shown, "the style toggle reveals the ring")
		assert(ring._lastArgs.SetAlpha[1] == 1, "at full alpha")

		instance:SetStyle({ Pandemic = false })
		assert(ring._shown == false, "and puts it away again")

		local tint = ring._lastArgs.SetVertexColor
		assert(tint[1] == 1 and tint[2] == 0.1 and tint[3] == 0.1, "unset colour keeps the built-in red")

		instance:SetStyle({ Pandemic = true, PandemicColor = { 0.2, 0.4, 0.8 } })
		tint = ring._lastArgs.SetVertexColor
		assert(tint[1] == 0.2 and tint[2] == 0.4 and tint[3] == 0.8, "the style colour tints the ring")
	end)

	fw.it("a display without the Pandemic option registers no regions", function()
		local instance = newOptionInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		assert((button._calls.AddPandemicRegion or 0) == 0, "no region registered")
		assert(widgets.Pandemic == nil, "no holder created")
	end)
end)

fw.describe("AuraContainerDisplay - countdown colour by time", function()
	fw.before_each(function()
		acm.reset()
		mockDb.ColorCountdownByTime = nil
	end)

	fw.it("binds the curve-coloured fontstring once per button", function()
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		assert(button._calls.SetDurationText == 1, "duration text bound at creation")
		assert(widgets.DurationText, "the fontstring is kept on the widgets")
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 0, "hidden while the setting is off")
	end)

	fw.it("the global setting swaps the countdown to the coloured text", function()
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]
		local hideCalls = widgets.Cooldown._calls.SetHideCountdownNumbers or 0

		mockDb.ColorCountdownByTime = true
		instance:SetStyle({})

		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 1, "coloured text revealed")
		assert((widgets.Cooldown._calls.SetHideCountdownNumbers or 0) > hideCalls,
			"the cooldown's own numbers were re-driven")

		mockDb.ColorCountdownByTime = nil
		instance:SetStyle({})
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 0, "and hides again when turned off")
	end)

	fw.it("the milliseconds toggle re-binds the text with a fractions formatter", function()
		-- Fractions can only render through the duration-text binding: the cooldown's own
		-- SetCountdownFormatter and SetCountdownMillisecondsThreshold both no-op for 12.1
		-- duration objects.
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]
		assert(button._calls.SetDurationText == 1, "bound once at creation")

		instance:SetStyle({ ShowMilliseconds = true })
		assert(button._calls.SetDurationText == 2, "the toggle re-binds")
		local breakpoints = button._durationTextOptions.textFormatter.breakpoints
		assert(breakpoints[1].format == "%.1f" and breakpoints[1].threshold == 0, "tenths below the threshold")
		assert(breakpoints[2].format == "%d" and breakpoints[2].threshold == 3,
			"whole seconds from the db threshold up")
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 1,
			"the bound text shows even without colour-by-time; nothing else can draw fractions")

		instance:SetStyle({ ShowMilliseconds = true })
		assert(button._calls.SetDurationText == 2, "an unchanged style does not re-bind")

		instance:SetStyle({})
		assert(button._calls.SetDurationText == 3, "turning it off re-binds the plain formatter")
		assert(button._durationTextOptions.textFormatter.breakpoints[1].format == "%d", "back to whole seconds")
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 0, "and the text hides again")
	end)

	fw.it("milliseconds and colour-by-time combine in one binding", function()
		local instance = newInstance()
		local button = instance.Buttons[1]

		mockDb.ColorCountdownByTime = true
		instance:SetStyle({ ShowMilliseconds = true })
		local options = button._durationTextOptions
		assert(options.textFormatter.breakpoints[1].format == "%.1f", "fractions formatter carried")
		assert(options.textColor ~= nil, "colour curve carried alongside it")

		local ramp = options.textColor.curve

		mockDb.ColorCountdownByTime = nil
		instance:SetStyle({ ShowMilliseconds = true })

		local plain = button._durationTextOptions.textColor

		-- A colour is bound either way round. Leaving it out asks the engine to forget the
		-- binding it is holding, which it does not do, and a bar's countdown stayed coloured
		-- after the setting was turned off.
		assert(plain ~= nil, "the off state binds a colour of its own")
		assert(plain.curve ~= ramp, "and it is not the by-time ramp")
	end)

	fw.it("a deferred restyle applies a milliseconds change once the restriction lifts", function()
		local instance = newInstance()
		local button = instance.Buttons[1]

		acm.restricted = true
		instance:SetStyle({ ShowMilliseconds = true })
		assert(button._calls.SetDurationText == 1, "no re-bind while buttons are forbidden")

		acm.restricted = false
		displayEvents:TriggerEvent("PLAYER_REGEN_ENABLED")
		assert(button._calls.SetDurationText == 2, "re-bound when the deferred restyle runs")
	end)

	fw.it("the coloured text copies the cooldown countdown's font face", function()
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		widgets.Cooldown.MiniAurasFontString = widgets.Cooldown:CreateFontString()
		mockDb.ColorCountdownByTime = true
		instance:SetStyle({})

		local args = widgets.DurationText._lastArgs.SetFont
		assert(args and args[1] == "MockFont" and args[2] == 10 and args[3] == "",
			"face, size and flags taken from the countdown fontstring")
	end)
end)

fw.describe("AuraContainerDisplay - Edit Mode preview suppression", function()
	-- Blizzard force-feeds every AuraContainer placeholder auras while Edit Mode is open, with no
	-- opt-out; hiding the container is the only escape. That makes visibility a two-input state
	-- machine (what the module asked for x whether the preview is running), and getting it wrong
	-- paints fake auras over portraits and nameplates.

	local function setPreview(active)
		displayEvents:TriggerEvent("AURA_DATA_PROVIDER_SWITCH", not active)
	end

	fw.before_each(function()
		acm.reset()
		setPreview(false)
	end)

	fw.it("the preview hides live containers without changing what the module asked for", function()
		local instance = newInstance()
		assert(instance.Frame:IsShown(), "precondition: shown")

		setPreview(true)
		assert(not instance.Frame:IsShown(), "the real frame hides while the preview runs")
		assert(instance:IsShown(), "the module's requested visibility is unchanged")

		setPreview(false)
		assert(instance.Frame:IsShown(), "and comes back when the preview ends")
	end)

	fw.it("a display created during the preview starts hidden", function()
		-- Modules build containers on roster/plate events, which keep firing while Edit Mode is
		-- open; one created then must not miss the suppression.
		setPreview(true)
		local instance = newInstance()
		assert(not instance.Frame:IsShown(), "created hidden while the preview runs")

		setPreview(false)
		assert(instance.Frame:IsShown(), "revealed when the preview ends")
	end)

	fw.it("SetShown during the preview cannot reveal placeholder auras", function()
		local instance = newInstance()
		setPreview(true)

		instance:Hide()
		instance:Show()

		assert(not instance.Frame:IsShown(), "the module's Show must not defeat the suppression")
		assert(instance:IsShown(), "but it is still recorded as the desired state")
	end)

	fw.it("the preview ending restores each display's own visibility", function()
		local shown = newInstance()
		local hidden = newInstance()
		hidden:Hide()

		setPreview(true)
		setPreview(false)

		assert(shown.Frame:IsShown(), "a display the module wanted shown comes back")
		assert(not hidden.Frame:IsShown(), "a display the module had hidden stays hidden")
	end)
end)

fw.describe("AuraFilters - category partitioning", function()
	-- The four category filters must partition the aura space: an aura flagged both BIG_DEFENSIVE
	-- and IMPORTANT is a normal thing, and without the `!` negations it would be drawn once per
	-- matching group on the same display.

	---Evaluates one of our filter strings against a synthetic aura, the way the engine does:
	---tokens combine with AND, `!` negates.
	local function matches(filterString, aura)
		for token in filterString:gmatch("[^|]+") do
			local negated = token:sub(1, 1) == "!"
			local flag = negated and token:sub(2) or token
			local present
			if flag == "HELPFUL" then
				present = aura.Helpful == true
			elseif flag == "HARMFUL" then
				present = aura.Helpful ~= true
			else
				present = aura[flag] == true
			end
			if present == negated then
				return false
			end
		end
		return true
	end

	local CATEGORIES = { "CrowdControl", "BigDefensive", "ExternalDefensive", "Important" }

	local function matchingCategories(aura)
		local hits = {}
		for _, name in ipairs(CATEGORIES) do
			if matches(auraFilters.Filter[name], aura) then
				hits[#hits + 1] = name
			end
		end
		return hits
	end

	local function assertOnly(aura, expected, label)
		local hits = matchingCategories(aura)
		assert(#hits == 1 and hits[1] == expected,
			("[%s] expected only %s, got {%s}"):format(label, expected, table.concat(hits, ", ")))
	end

	fw.it("an aura lands in exactly one category, by priority", function()
		assertOnly({ Helpful = false, CROWD_CONTROL = true }, "CrowdControl", "plain cc")
		assertOnly({ Helpful = true, BIG_DEFENSIVE = true }, "BigDefensive", "plain big defensive")
		assertOnly({ Helpful = true, EXTERNAL_DEFENSIVE = true }, "ExternalDefensive", "plain external")
		assertOnly({ Helpful = true, IMPORTANT = true }, "Important", "plain important")

		-- The overlaps that actually occur in game.
		assertOnly({ Helpful = true, BIG_DEFENSIVE = true, IMPORTANT = true },
			"BigDefensive", "important big defensive")
		assertOnly({ Helpful = true, EXTERNAL_DEFENSIVE = true, IMPORTANT = true },
			"ExternalDefensive", "important external")
		assertOnly({ Helpful = true, BIG_DEFENSIVE = true, EXTERNAL_DEFENSIVE = true, IMPORTANT = true },
			"BigDefensive", "all three flags")
	end)

	fw.it("harmful and helpful never cross over", function()
		assert(#matchingCategories({ Helpful = false, IMPORTANT = true }) == 0,
			"a harmful important is not a helpful category")
		assertOnly({ Helpful = false, CROWD_CONTROL = true, IMPORTANT = true }, "CrowdControl", "cc + important")
		assert(#matchingCategories({ Helpful = true, CROWD_CONTROL = true }) == 0,
			"the cc filter is harmful-only")
	end)

	fw.it("disarm partitions against CC by negation, against the rest by its spell-ID map", function()
		-- Not in the matrix above: the disarm string deliberately matches any non-CC debuff and
		-- relies on its includeSpellIDs map, which a string-level matrix cannot model.
		assert(not matches(auraFilters.Filter.Disarm, { Helpful = false, CROWD_CONTROL = true }),
			"a disarm the game starts flagging as CC must not draw in both groups")
		assert(matches(auraFilters.Filter.Disarm, { Helpful = false }),
			"a plain debuff passes the string; the spell-ID map does the narrowing")
	end)

	fw.it("BuildCategoryGroups hands out a fresh spec list per display", function()
		-- SetMaxIcons mutates group.MaxIcons in place, so a shared list would make one display's
		-- category toggle silently re-budget every other display's.
		local first = auraFilters:BuildCategoryGroups(5)
		local second = auraFilters:BuildCategoryGroups(5)

		assert(first ~= second, "distinct lists")
		assert(first[1] ~= second[1], "distinct group specs")

		first[1].MaxIcons = 0
		assert(second[1].MaxIcons == 5, "mutating one list must not touch the other")
	end)

	fw.it("the built groups are exactly the keys ApplyCategoryBudgets drives", function()
		-- The two halves are written in different files; a key renamed in one and not the other
		-- would silently disable a whole category (SetMaxIcons only warns).
		local instance = display:New(_G.UIParent, "target", auraFilters:BuildCategoryGroups(5), 30, 2, "Test")
		acm.notifications = {}

		auraFilters:ApplyCategoryBudgets(instance, 4, false, true, false, true)

		assert(#acm.notifications == 0, "every budgeted key exists: " .. table.concat(acm.notifications, "; "))
		local groups = instance.Frame._groups
		assert(groups[auraFilters.GroupKey.CrowdControl].maxFrameCount == 0, "cc off")
		assert(groups[auraFilters.GroupKey.Disarm].maxFrameCount == 4,
			"disarm has its own switch (callers gate it on assistability, not on ShowCC alone)")
		assert(groups[auraFilters.GroupKey.BigDefensive].maxFrameCount == 4, "big defensive on")
		assert(groups[auraFilters.GroupKey.ExternalDefensive].maxFrameCount == 4,
			"the defensives toggle covers BOTH defensive groups")
		assert(groups[auraFilters.GroupKey.Important].maxFrameCount == 0, "important off")
	end)
end)

fw.describe("AuraFilters - canonical filter strings", function()
	fw.before_each(acm.reset)

	fw.it("collapses reordered spellings onto one", function()
		assert(auraFilters:Canonical("HELPFUL|PLAYER") == auraFilters:Canonical("PLAYER|HELPFUL"),
			"token order must not matter")
		assert(auraFilters:Canonical("PLAYER|HELPFUL") == "HELPFUL|PLAYER", "sorted spelling wins")
	end)

	fw.it("sorts a negation by the token it negates and drops duplicates", function()
		assert(auraFilters:Canonical("HELPFUL|IMPORTANT|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE")
			== "!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE|HELPFUL|IMPORTANT", "negations sort by bare name")
		assert(auraFilters:Canonical("HELPFUL|HELPFUL|PLAYER") == "HELPFUL|PLAYER", "duplicates drop out")
	end)

	fw.it("groups are created with the canonical spelling", function()
		local instance = newInstance()

		assert(instance.Frame._groups.cc.filterString == "CROWD_CONTROL|HARMFUL",
			"the engine sees the sorted spelling, whatever the caller wrote")

		instance:SetFilterString("cc", "HARMFUL|CROWD_CONTROL")
		assert(instance.Frame._groups.cc.filterString == "CROWD_CONTROL|HARMFUL",
			"the live setter canonicalises too")
	end)
end)

fw.describe("AuraContainerDisplay - bar buttons", function()
	fw.before_each(acm.reset)

	local function newBarInstance(style)
		style = style or {}
		style.BarWidth = style.BarWidth or 180

		return display:New(_G.UIParent, "target", {
			{ Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 1 },
		}, 24, 2, "Test", { Bar = true, Pandemic = true, Style = style })
	end

	fw.it("registers the fill and the name with the engine instead of a cooldown", function()
		-- The whole point of the shape: the bar drains and the name is written by the engine, so
		-- nothing on a bar button needs an aura read any more than an icon does.
		local instance = newBarInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		assert(button._calls.SetDurationBar == 1, "the fill is registered once")
		-- The engine's value grows towards expiry, so the registered fill is the SPENT part,
		-- eating into the coloured strip from the right. Without that the bar would fill up.
		assert(widgets.Bar._reverseFill, "the spent block grows in from the far end")
		assert(button._calls.SetSpellName == 1, "the name is registered once")
		assert((button._calls.SetDurationCooldown or 0) == 0, "no cooldown widget on a bar")
		assert(widgets.Bar and widgets.Name and widgets.Icon, "the widgets are kept for restyling")
	end)

	fw.it("sizes buttons and the group layout to the bar, not to a square", function()
		local instance = newBarInstance({ BarWidth = 180 })
		local button = instance.Buttons[1]

		assert(button:GetWidth() == 180 and button:GetHeight() == 24, "button takes width x height")
		assert(instance.Frame._groups.cc.layout.elementWidth == 180, "the row is spaced for the width")
		assert(instance.Frame._groups.cc.layout.elementHeight == 24, "and for the height")

		instance:ApplyConfig(30, 2, { BarWidth = 260 })

		assert(button:GetWidth() == 260 and button:GetHeight() == 30, "a restyle resizes both")
		assert(instance.Frame._groups.cc.layout.elementWidth == 260, "and republishes the layout")
	end)

	fw.it("never lets a bar be narrower than it is tall", function()
		-- The icon leads the fill and is squared to the height, so a nonsense width would leave
		-- the fill with negative room rather than just a short bar.
		local instance = newBarInstance({ BarWidth = 4 })

		assert(instance.Buttons[1]:GetWidth() == 24, "clamped up to the height")
	end)

	fw.it("colours the remaining strip with the style colour and tints the border to match", function()
		local instance = newBarInstance({ Border = true, GlowColor = { 1, 0, 0 } })
		local widgets = select(2, next(instance.ButtonWidgets))
		local color = widgets.Strip._lastArgs.SetVertexColor

		assert(color[1] == 1 and color[2] == 0 and color[3] == 0, "the strip takes the group colour")

		local edge = widgets.BorderTextures[1]
		assert(edge._shown, "the border shows when asked for")
		local edgeColor = edge._lastArgs.SetVertexColor
		assert(edgeColor[1] == 1 and edgeColor[2] == 0, "and takes the same colour")
	end)

	fw.it("hands every border edge to the engine for dispel colouring", function()
		-- A bar's border is four flat edges rather than one ring asset, and all four have to be
		-- registered or the outline would be coloured on some sides only.
		local instance = newBarInstance({ ColorByDispelType = true })
		local button = instance.Buttons[1]

		assert(button._calls.AddDispelTypeTexture == 4, "all four edges registered")
	end)

	fw.it("shows the countdown text, which is the only clock a bar has", function()
		local instance = newBarInstance()
		local widgets = select(2, next(instance.ButtonWidgets))

		assert(widgets.DurationText, "the bound duration text exists")
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 1,
			"and is visible without the millisecond or colour options being on")
	end)

	fw.it("builds no glow frame, whatever the style asks for", function()
		-- Every glow in the catalog is art drawn for a square; stretched around a row three times
		-- as wide as it is tall it reads as a mistake. The editor hides the option to match, so a
		-- group carrying Glow from its icon days must not resurrect one here.
		local instance = newBarInstance({ Glow = true })
		local widgets = select(2, next(instance.ButtonWidgets))

		assert(widgets.Glow == nil, "no glow frame on a bar button")

		local ok, err = pcall(function()
			instance:SetStyle({ BarWidth = 180, Glow = true, ColorByDispelType = true })
		end)

		assert(ok, "styling must not assume a glow exists: " .. tostring(err))
	end)

	fw.it("leaves the pandemic outline hidden until the group asks for it", function()
		-- Same rule as the icon ring: created hidden, because a bar's reveal is four edges around
		-- the whole row and is impossible to miss when it should not be there at all.
		local instance = newBarInstance()
		local widgets = select(2, next(instance.ButtonWidgets))
		local edges = widgets.Pandemic.Textures

		assert(#edges == 4, "the reveal is built from four edges")

		for _, edge in ipairs(edges) do
			assert(edge._shown == false, "every edge starts hidden")
		end

		instance:SetStyle({ BarWidth = 180, Pandemic = true })

		for _, edge in ipairs(edges) do
			assert(edge._shown, "and every edge shows once the reveal is on")
		end
	end)

	fw.it("falls back to icons on a client with no SetDurationBar", function()
		acm.missingButtonMethods.SetDurationBar = true

		local instance = newBarInstance()

		assert(instance.Bar == false, "the display drops back to the icon shape")
		assert(instance.Buttons[1]._calls.SetDurationCooldown == 1, "icon buttons are built instead")

		-- Republished on the next restyle, which is when the cleared flag first reaches it.
		instance:ApplyConfig(26, 2, { BarWidth = 180 })
		assert(instance.Frame._groups.cc.layout.elementWidth == 26, "and the row is spaced square")
	end)
end)

fw.describe("AuraContainerDisplay - refreshing a token whose occupant changed", function()
	fw.it("re-points the container so the engine sees a unit change", function()
		local instance = newInstance()
		local frame = instance.Frame

		assert(frame:GetUnit() == "target", "tracking the token it was built with")

		local shows = frame._calls.Show or 0

		instance:RequestRefresh()

		-- The token string never changes across a target swap, so the container has nothing to
		-- react to unless it is pointed away and back.
		assert(frame:GetUnit() == "target", "and still tracking it afterwards")
		assert((frame._calls.Show or 0) > shows, "the dirty flags were armed by a bounce")
	end)

	fw.it("bounces in combat, which is when targets actually get swapped", function()
		local instance = newInstance()
		local frame = instance.Frame
		local shows = frame._calls.Show or 0

		_G.InCombatLockdown = function() return true end
		instance:RequestRefresh()
		_G.InCombatLockdown = function() return false end

		assert((frame._calls.Show or 0) > shows,
			"an occupant swap has nothing else coming that would settle it")
	end)

	-- The other half of the combat rule. A setter-driven change settles on the unit's next aura
	-- event, which combat has plenty of, so bouncing the frame for one is churn during the busiest
	-- moment there is. Only changes with nothing else coming (an occupant swap, a gate that zeroed
	-- a budget) are marked urgent and go through.
	fw.it("parks a non-urgent bounce in combat until combat ends", function()
		local instance = newInstance()
		local frame = instance.Frame
		local shows = frame._calls.Show or 0

		_G.InCombatLockdown = function()
			return true
		end
		instance:SetMaxIcons("cc", 3)
		_G.InCombatLockdown = function()
			return false
		end

		assert((frame._calls.Show or 0) == shows, "a non-urgent bounce must not flush in combat")

		-- Still pending, so the next flush out of combat takes it.
		instance:SetMaxIcons("cc", 4)

		assert((frame._calls.Show or 0) > shows, "and it settles once combat is over")
	end)

	fw.it("leaves an untracked display alone", function()
		local instance = newInstance()

		instance:SetUnit("none")
		instance:RequestRefresh()

		assert(instance.Frame:GetUnit() == "none", "nothing to re-point at")
	end)
end)

fw.describe("AuraContainerDisplay - which countdown is on screen", function()
	fw.it("binds no colour while the native countdown is the one showing", function()
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		mockDb.ColorCountdownByTime = true
		instance:SetStyle({})
		assert(button._durationTextOptions.textColor ~= nil, "coloured while it is the countdown")

		mockDb.ColorCountdownByTime = nil
		instance:SetStyle({})

		-- The cooldown's own numbers take over here, and a colour bound to this fontstring has
		-- the engine draw it over them: two countdowns on one icon.
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 0, "the bound text is hidden")
		assert(button._durationTextOptions.textColor == nil, "so nothing is bound to colour it")
	end)

	fw.it("HideNumbers drops both countdowns but keeps the swipe", function()
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		mockDb.ColorCountdownByTime = true
		instance:SetStyle({ HideNumbers = true })

		assert(widgets.Cooldown._lastArgs.SetHideCountdownNumbers[1] == true, "no native numbers")
		assert(widgets.DurationText._lastArgs.SetAlpha[1] == 0, "and no coloured stand-in either")
		assert(widgets.Cooldown._lastArgs.SetDrawSwipe[1] == true, "the swipe is a separate switch")

		mockDb.ColorCountdownByTime = nil
	end)

	fw.it("HideSwipe drops the swipe and leaves the numbers alone", function()
		local instance = newInstance()
		local button = instance.Buttons[1]
		local widgets = instance.ButtonWidgets[button]

		instance:SetStyle({ HideSwipe = true })

		assert(widgets.Cooldown._lastArgs.SetDrawSwipe[1] == false, "no swipe")
		assert(widgets.Cooldown._lastArgs.SetHideCountdownNumbers[1] == false, "the numbers stay")

		instance:SetStyle({})
		assert(widgets.Cooldown._lastArgs.SetDrawSwipe[1] == true, "and it comes back when turned off")
	end)
end)

fw.describe("AuraContainerDisplay - when a container first parses", function()
	fw.it("is not visible until its groups exist", function()
		local shownWhenGroupAdded

		acm.onAddAuraGroup = function(container)
			shownWhenGroupAdded = container:IsShown()
		end

		local instance = newInstance()

		acm.onAddAuraGroup = nil

		-- A container parses as soon as it is visible, and a parse made before the groups carry
		-- their real filters is what stays on screen.
		assert(shownWhenGroupAdded == false, "the container is hidden while its groups are built")
		assert(instance.Frame:IsShown(), "and shown once they exist")
	end)
end)

fw.describe("AuraContainerDisplay - while a vehicle has the player", function()
	fw.it("takes player displays off screen and puts them back afterwards", function()
		local onPlayer = display:New(_G.UIParent, "player", {
			{ Key = "cc", FilterString = "HELPFUL", MaxIcons = 5 },
		}, 30, 2, "Test")
		local onTarget = newInstance()

		assert(onPlayer.Frame:IsShown() and onTarget.Frame:IsShown(), "both start on screen")

		-- While the vehicle lasts the engine stops honouring this container's spell-id filters
		-- and it fills with auras nobody asked for. Nothing subtler than hiding it works.
		wow.setInVehicle(true)
		displayEvents:TriggerEvent("UNIT_ENTERED_VEHICLE", "player")

		assert(not onPlayer.Frame:IsShown(), "the player's display is suppressed")
		assert(onTarget.Frame:IsShown(), "and nothing else is")

		wow.setInVehicle(false)
		displayEvents:TriggerEvent("UNIT_EXITED_VEHICLE", "player")
		acm.runTimers()

		assert(onPlayer.Frame:IsShown(), "it comes back once the vehicle is gone")
	end)

	fw.it("leaves a display its module wanted hidden alone", function()
		local onPlayer = display:New(_G.UIParent, "player", {
			{ Key = "cc", FilterString = "HELPFUL", MaxIcons = 5 },
		}, 30, 2, "Test")

		onPlayer:SetShown(false)

		wow.setInVehicle(true)
		displayEvents:TriggerEvent("UNIT_ENTERED_VEHICLE", "player")
		wow.setInVehicle(false)
		displayEvents:TriggerEvent("UNIT_EXITED_VEHICLE", "player")
		acm.runTimers()

		assert(not onPlayer.Frame:IsShown(), "the module's own answer still decides")
	end)
end)

fw.describe("AuraContainerDisplay - vehicles the client will not admit to", function()
	fw.it("suppresses on the event alone when every question answers false", function()
		local onPlayer = display:New(_G.UIParent, "player", {
			{ Key = "cc", FilterString = "HELPFUL", MaxIcons = 5 },
		}, 30, 2, "Test")

		-- Some seats have no vehicle UI and answer false to everything; the event is the only
		-- thing that knows, so it is taken at its word.
		wow.setInVehicle(false)
		displayEvents:TriggerEvent("UNIT_ENTERED_VEHICLE", "player")

		assert(not onPlayer.Frame:IsShown(), "suppressed on the event, not on the answer")

		displayEvents:TriggerEvent("UNIT_EXITED_VEHICLE", "player")
		acm.runTimers()

		assert(onPlayer.Frame:IsShown(), "and restored once it ends")
	end)

	fw.it("stays suppressed while a question still says yes", function()
		local onPlayer = display:New(_G.UIParent, "player", {
			{ Key = "cc", FilterString = "HELPFUL", MaxIcons = 5 },
		}, 30, 2, "Test")

		wow.setInVehicle(true)
		displayEvents:TriggerEvent("UNIT_ENTERED_VEHICLE", "player")

		-- An exit event for one seat while another still holds: the answer is re-asked rather
		-- than assumed.
		displayEvents:TriggerEvent("UNIT_EXITED_VEHICLE", "player")
		acm.runTimers()

		assert(not onPlayer.Frame:IsShown(), "still off screen while the client says vehicle")

		wow.setInVehicle(false)
		displayEvents:TriggerEvent("UNIT_EXITED_VEHICLE", "player")
		acm.runTimers()

		assert(onPlayer.Frame:IsShown(), "and back once it stops saying so")
	end)
end)

fw.describe("AuraContainerDisplay - after a teleport inside one map", function()
	fw.before_each(acm.reset)

	local SPELL_MAP = { includeSpellIDs = { [12345] = true } }

	---A display whose group filters on spell ids, which is the only kind a transfer can spoil.
	local function newFilteredInstance()
		return display:New(_G.UIParent, "player", {
			{ Key = "cc", FilterString = "HELPFUL", MaxIcons = 5, CandidateFilters = SPELL_MAP },
		}, 30, 2, "Test")
	end

	fw.it("takes the displays that filter on spell ids off screen for a moment", function()
		local instance = newFilteredInstance()

		-- The auras the engine cannot filter properly mid-transfer never reach a group at all
		-- this way, which is the only remedy while it is answering wrongly rather than late.
		displayEvents:TriggerEvent("ZONE_CHANGED")
		assert(not instance.Frame:IsShown(), "off screen as the transfer starts")

		acm.runTimers()
		assert(instance.Frame:IsShown(), "and back a moment later")
		assert(instance.Frame:GetUnit() == "player", "still on the token it was built with")
	end)

	fw.it("leaves a display with no spell-id map on screen throughout", function()
		-- A transfer only spoils a filter the engine has to decide whether it may apply, and it
		-- decides that from the unit's identity. A plain filter string is read the same either
		-- way, so hiding a plate or a portrait for a third of a second would buy nothing.
		newFilteredInstance()

		local plain = newInstance()

		displayEvents:TriggerEvent("ZONE_CHANGED")
		assert(plain.Frame:IsShown(), "nothing to protect it from")

		acm.runTimers()
		assert(plain.Frame:IsShown(), "and nothing to put back")
	end)

	fw.it("listens for every event a transfer can arrive on", function()
		-- Which of the three the client picks depends on where the pad puts you, so a missing
		-- registration would leave the leak in place for that kind of teleport only.
		for _, event in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA" }) do
			local instance = newFilteredInstance()

			displayEvents:TriggerEvent(event)
			assert(not instance.Frame:IsShown(), event .. " suppresses")

			acm.runTimers()
			assert(instance.Frame:IsShown(), event .. " comes back")
		end
	end)

	fw.it("re-reads the unit from scratch rather than waiting for an aura event", function()
		local instance = newFilteredInstance()
		local frame = instance.Frame
		local before = frame._calls.SetUnit or 0

		displayEvents:TriggerEvent("ZONE_CHANGED_INDOORS")
		acm.runTimers()

		-- Which group an aura belongs to is settled once per aura instance, and an ordinary aura
		-- event only re-parses what changed, so an aura that was up during the transfer keeps the
		-- answer it got there. Pointing the container at nobody and back is the full re-parse.
		assert((frame._calls.SetUnit or 0) >= before + 2, "pointed at nobody and back")
		assert(frame:GetUnit() == "player", "and left on its own unit")
	end)

	fw.it("spends no re-read on a display with no spell-id map", function()
		newFilteredInstance()

		local plain = newInstance()
		local before = plain.Frame._calls.SetUnit or 0

		displayEvents:TriggerEvent("ZONE_CHANGED_INDOORS")
		acm.runTimers()

		assert((plain.Frame._calls.SetUnit or 0) == before, "nothing to recover, nothing done")
	end)

	fw.it("keeps trying for a while, since nothing tells it the transfer is over", function()
		local instance = newFilteredInstance()
		local frame = instance.Frame
		local before = frame._calls.SetUnit or 0

		displayEvents:TriggerEvent("ZONE_CHANGED_INDOORS")
		acm.runTimers()

		-- The events that look like a "done" tell are not dispatched on every teleport, so one
		-- pass timed against nothing would miss any transfer slower than it.
		assert((frame._calls.SetUnit or 0) > before + 2, "more than the pass the blackout ends with")
	end)

	fw.it("leaves a display its module wanted hidden alone", function()
		local instance = newFilteredInstance()

		instance:SetShown(false)

		displayEvents:TriggerEvent("ZONE_CHANGED_INDOORS")
		acm.runTimers()

		assert(not instance.Frame:IsShown(), "the module's own answer still decides")
	end)
end)

-- The icon zoom option (Misc panel). The crop is read when a display is configured and baked
-- into each button as it is built, so what this guards is the reading, not the redraw: the
-- panel asks for a reload because pooled buttons keep the crop they were made with.
fw.describe("AuraContainerDisplay - the icon zoom option", function()
	fw.it("crops Blizzard's baked border off by default", function()
		local instance = newInstance()

		assert(instance.IconTexCoord[1] == 0.08, "left edge trimmed")
		assert(instance.IconTexCoord[2] == 0.92, "right edge trimmed")
	end)

	fw.it("hands back the whole icon when the option is off", function()
		mockDb.IconZoom = false

		local instance = newInstance()

		assert(instance.IconTexCoord[1] == 0, "no crop at all")
		assert(instance.IconTexCoord[2] == 1, "the border comes back")

		mockDb.IconZoom = nil
	end)

	fw.it("leaves a display with its own crop alone", function()
		mockDb.IconZoom = false

		local instance = display:New(_G.UIParent, "target", {
			{ Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 },
		}, 30, 2, "Test", { IconTexCoord = { 0.2, 0.8, 0.2, 0.8 } })

		assert(instance.IconTexCoord[1] == 0.2, "the portrait's own inset is geometry, not trim")

		mockDb.IconZoom = nil
	end)
end)
