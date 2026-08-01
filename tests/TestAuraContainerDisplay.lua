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

	fw.it("defaults to the animated flipbook glow", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(firstGlowWidgets(instance).GlowStyle == "Rotation Assist", "default is the flipbook")
		assert(anyGlowPlaying(instance), "the flipbook animates")
	end)

	fw.it("the style signature covers the global glow type", function()
		-- Displays are cached by this signature, and the glow style is a global db value the
		-- caller never passes in; leaving it out meant changing it in the options never reached
		-- the already-built buttons.
		local style = display:GetStyleScratch()
		style.Glow = true

		local before = display:GetStyleSignature(style, 30, 2)
		mockDb.GlowType = "Slot Glow"
		local after = display:GetStyleSignature(style, 30, 2)

		assert(before ~= after, "changing the glow type must invalidate cached displays")
	end)

	fw.it("Slot Glow applies the static atlas and runs no animation", function()
		mockDb.GlowType = "Slot Glow"
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local widgets = firstGlowWidgets(instance)
		assert(widgets.GlowStyle == "Slot Glow", "slot glow selected")
		assert(not anyGlowPlaying(instance), "a static glow must not animate")

		local asset = widgets.Glow.Texture._lastArgs.SetTexture[1]
		assert(asset:find("newplayertutorial%-drag%-slotgreen"), "slot atlas applied, got " .. tostring(asset))
	end)

	fw.it("an LCG-only glow type falls back to the flipbook", function()
		mockDb.GlowType = "Proc Glow"
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(firstGlowWidgets(instance).GlowStyle == "Rotation Assist", "unsupported type falls back")
	end)

	fw.it("changing the glow type restyles despite an identical style table", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		local afterFirst = totalSetSizeCalls(instance)

		mockDb.GlowType = "Slot Glow"
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

	fw.it("switching away from the flipbook resets its tex coords", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })

		local texture = firstGlowWidgets(instance).Glow.Texture
		local before = texture._calls.SetTexCoord or 0

		mockDb.GlowType = "Slot Glow"
		instance:SetStyle({ Glow = true })
		assert((texture._calls.SetTexCoord or 0) > before, "static asset must clear the flipbook's cell coords")
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

	fw.it("does not pre-create until Prewarm is called", function()
		local pool, created = newCountingPool(5)
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

		assert(widgets.Border == nil and widgets.Glow == nil, "no border/glow widgets created")
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

	fw.it("a plain display still builds the border and glow", function()
		local instance = newOptionInstance()
		local widgets = select(2, next(instance.ButtonWidgets))
		assert(widgets.Border and widgets.Glow, "default displays keep the full chrome")
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

	fw.it("ImportantOnly is deliberately unpartitioned", function()
		-- Precognition shows importants and nothing else, so it must NOT carry the defensive
		-- negations - a precog buff that also flagged defensive would vanish.
		assert(matches(auraFilters.Filter.ImportantOnly, { Helpful = true, BIG_DEFENSIVE = true, IMPORTANT = true }),
			"ImportantOnly matches an important that is also a defensive")
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

		auraFilters:ApplyCategoryBudgets(instance, 4, false, true, false)

		assert(#acm.notifications == 0, "every budgeted key exists: " .. table.concat(acm.notifications, "; "))
		local groups = instance.Frame._groups
		assert(groups[auraFilters.GroupKey.CrowdControl].maxFrameCount == 0, "cc off")
		assert(groups[auraFilters.GroupKey.BigDefensive].maxFrameCount == 4, "big defensive on")
		assert(groups[auraFilters.GroupKey.ExternalDefensive].maxFrameCount == 4,
			"the defensives toggle covers BOTH defensive groups")
		assert(groups[auraFilters.GroupKey.Important].maxFrameCount == 0, "important off")
	end)
end)
