-- Tests for the 12.1 AuraContainer display wrapper (Core/AuraContainerDisplay.lua), driven
-- through the aura_container_mock environment. Focus areas are the real bug classes from the
-- 12.1 bring-up: style-signature skipping (and its staleness edge cases), the restriction
-- model (button children are forbidden while auras are secret), pool pre-creation/reuse, the
-- kick chain anchoring math, and the kick expiry timer.

local fw = require("framework")
local wow = require("wow_api")
wow.setup()
local acm = require("aura_container_mock")
acm.setup()

local display, _, mockDb = acm.loadDisplay()

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

local function anyGlowPlaying(instance)
	for _, widgets in pairs(instance.ButtonWidgets) do
		if widgets.Glow and widgets.Glow.Anim:IsPlaying() then
			return true
		end
	end
	return false
end

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

	fw.it("StopGlowAnimations under restriction does not touch forbidden children", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(anyGlowPlaying(instance), "glow animations playing while style.Glow")

		acm.restricted = true
		local ok, err = pcall(function()
			instance:StopGlowAnimations()
		end)
		assert(ok, "StopGlowAnimations must not error while restricted: " .. tostring(err))
		assert(anyGlowPlaying(instance), "animations untouched while restricted")
		assert(instance.RestylePending, "pending flag set for the eventual restyle")
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

fw.describe("AuraContainerDisplay - glow lifecycle", function()
	fw.before_each(acm.reset)

	fw.it("plays animations only while the glow style is enabled", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		assert(anyGlowPlaying(instance), "enabled -> playing")
		instance:SetStyle({ Glow = false })
		assert(not anyGlowPlaying(instance), "disabled -> stopped")
	end)

	fw.it("StopGlowAnimations stops everything and glows resume on next identical SetStyle", function()
		local instance = newInstance()
		instance:SetStyle({ Glow = true })
		instance:StopGlowAnimations()
		assert(not anyGlowPlaying(instance), "parked -> stopped")
		instance:SetStyle({ Glow = true })
		assert(anyGlowPlaying(instance), "reuse with identical style must resume animations")
	end)
end)

fw.describe("AuraContainerDisplay - NewPool", function()
	fw.before_each(acm.reset)

	local function newCountingPool(prealloc)
		local created, resets = 0, 0
		local pool = display:NewPool(function()
			created = created + 1
			return { id = created }
		end, function()
			resets = resets + 1
		end, prealloc)
		return pool, function() return created end, function() return resets end
	end

	fw.it("pre-creates staggered until the target, then stops the ticker", function()
		local pool, created = newCountingPool(5)
		assert(created() == 0, "nothing created before ticks")
		acm.tickAll(2) -- 2 per tick
		assert(created() == 4, "2 items per tick")
		acm.tickAll(10)
		assert(created() == 5, "stops at the preallocation target, got " .. created())
	end)

	fw.it("Acquire drains the pool then falls back to on-demand creation", function()
		local pool, created = newCountingPool(2)
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

fw.describe("AuraContainerDisplay - RenderKickSlot", function()
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

		local timer = display:RenderKickSlot(container, kickEntry, { Texture = "tex" }, nil, function()
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
		local first = display:RenderKickSlot(container, { StartTime = 100, Duration = 5 }, {}, nil, function() end)
		local second = display:RenderKickSlot(container, { StartTime = 101, Duration = 5 }, {}, first, function() end)
		assert(first.cancelled, "previous timer cancelled")
		assert(second and not second.cancelled, "new timer active")
	end)

	fw.it("clears the slot and returns no timer when the kick is gone", function()
		local container = newSlotRecorder()
		local timer = display:RenderKickSlot(container, nil, nil, nil, function() end)
		assert(timer == nil, "no timer without a kick")
		assert(#container.unusedCalls == 1 and container.unusedCalls[1] == 1, "slot 1 cleared")
	end)

	fw.it("an already-expired kick renders but schedules nothing", function()
		wow.setTime(200)
		local container = newSlotRecorder()
		local timer = display:RenderKickSlot(container, { StartTime = 100, Duration = 5 }, {}, nil, function() end)
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
end)
