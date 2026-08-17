-- Deterministic C_Timer.NewTicker stand-in for suites that drive the background sweep by hand.
-- Tickers never fire on their own; a test pumps them with Tick. One shared copy, because the
-- sweep and pool suites need identical semantics and two private copies had already drifted.

local M = {}

local tickers = {}

---Installs the NewTicker override. Idempotent; call once per suite file. Must also work
---standalone, where no client mock has installed C_Timer at all.
function M.Install()
	_G.C_Timer = _G.C_Timer or {}
	_G.C_Timer.NewTicker = function(interval, fn)
		local ticker = { interval = interval, fn = fn, cancelled = false }

		function ticker:Cancel()
			self.cancelled = true
		end

		tickers[#tickers + 1] = ticker

		return ticker
	end
end

function M.Reset()
	for index = #tickers, 1, -1 do
		tickers[index] = nil
	end
end

function M.Tick(times)
	for _ = 1, times or 1 do
		-- Snapshot, because a tick may cancel its own ticker or start another.
		local snapshot = {}

		for index, ticker in ipairs(tickers) do
			snapshot[index] = ticker
		end

		for _, ticker in ipairs(snapshot) do
			if not ticker.cancelled then
				ticker.fn()
			end
		end
	end
end

function M.ActiveCount()
	local count = 0

	for _, ticker in ipairs(tickers) do
		if not ticker.cancelled then
			count = count + 1
		end
	end

	return count
end

return M
