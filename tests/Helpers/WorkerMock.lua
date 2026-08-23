-- Deterministic stand-in for the frame the background sweep rides, for suites that drive it by
-- hand. Nothing runs on its own; a test pumps frames with Frame. One shared copy, because the
-- sweep and pool suites need identical semantics and two private copies had already drifted.

local M = {}

-- Every frame handed out, so a pump can find the one the sweep put a script on.
local frames = {}
-- Stand-in for the client's millisecond clock, which the sweep reads to bound a frame. Nothing
-- advances on its own; a test that wants to spend the slice calls Advance.
local clockMs = 0
local loadingScreen = false

---Installs CreateFrame and a controllable debugprofilestop. Call once per suite file. Must also
---work standalone, where no client mock has installed either.
function M.Install()
	-- Each suite file loads its own copy of the sweep, and so gets its own worker. Forgetting the
	-- previous file's keeps one file's leftovers out of the next one's frames.
	for index = #frames, 1, -1 do
		frames[index] = nil
	end

	_G.debugprofilestop = function()
		return clockMs
	end

	_G.CreateFrame = function()
		local frame = { shown = true, scripts = {} }

		function frame:SetScript(script, fn)
			self.scripts[script] = fn
		end

		function frame:Show()
			self.shown = true
		end

		function frame:Hide()
			self.shown = false
		end

		function frame:IsShown()
			return self.shown
		end

		frames[#frames + 1] = frame

		return frame
	end
end

function M.Reset()
	clockMs = 0
	loadingScreen = false
end

---An addon table shaped the way the sweep reads it, for suites that load one file rather than the
---whole addon.
---@return table
function M.Addon()
	return {
		Core = {},
		IsLoadingScreenUp = function()
			return loadingScreen
		end,
	}
end

---Spends `ms` of the clock the sweep bounds its frames against.
---@param ms number
function M.Advance(ms)
	clockMs = clockMs + ms
end

---@param up boolean
function M.SetLoadingScreen(up)
	loadingScreen = up
end

---Runs one client frame through every worker still on the clock.
---@param elapsed number? Seconds since the last frame; a whole one by default, which is more than
---enough to refill the sweep's background credit to its cap.
function M.Frame(elapsed)
	-- Snapshot, because a frame may hide its worker or create another.
	local snapshot = {}

	for index, frame in ipairs(frames) do
		snapshot[index] = frame
	end

	for _, frame in ipairs(snapshot) do
		if frame.shown and frame.scripts.OnUpdate then
			frame.scripts.OnUpdate(frame, elapsed or 1)
		end
	end
end

---@param times number
---@param elapsed number?
function M.Frames(times, elapsed)
	for _ = 1, times do
		M.Frame(elapsed)
	end
end

---How many workers are still on the clock; 0 once the sweep has hidden its own.
---@return number
function M.ActiveCount()
	local count = 0

	for _, frame in ipairs(frames) do
		if frame.shown then
			count = count + 1
		end
	end

	return count
end

return M
