-- Finds the most expensive uninterrupted runs of work in a Perfy trace, and per-function
-- worst-case cost per call. Perfy's own frame breakdown needs several instrumented addons to
-- bracket a frame, so a burst here is one top-level call instead, from an Enter on an empty
-- stack to the matching Leave, which is work the client cannot break across frames.

local analyzerDir, traceFile = arg[1], arg[2]
if not analyzerDir or not traceFile then
	print("Usage: Bursts.lua <perfy analyzer dir> <saved variables file> [top N]")
	return
end
local topN = tonumber(arg[3]) or 20

package.path = analyzerDir .. "/?.lua;" .. package.path
local parser = require "LuaParser"

local file = assert(io.open(traceFile, "rb"))
local contents = file:read("a")
file:close()
print(("Read %.1f MiB"):format(#contents / 1024 / 1024))

local env = parser:ParseLua(contents)
local export = env.Perfy_Export
local eventNames, functionNames = {}, {}
for k, v in pairs(export.EventNames) do eventNames[v] = k end
for k, v in pairs(export.FunctionNames) do functionNames[v] = k end
local trace = export.Trace
print(("%d trace entries covering %.1f seconds"):format(#trace, trace[#trace][1] - trace[1][1]))

-- Every trace call costs time and memory itself. Running totals let any span subtract the
-- overhead of the calls inside it. A span owns the overhead of its own Enter, which happens
-- after the timestamp was taken, but not that of its Leave.
local cumTime, cumMem = {}, {}
local timeSum, memSum = 0, 0
for i = 1, #trace do
	local e = trace[i]
	timeSum = timeSum + (e[4] or 0)
	memSum = memSum + (e[6] or 0)
	cumTime[i] = timeSum
	cumMem[i] = memSum
end

local function spanCost(fromIdx, toIdx)
	local from, to = trace[fromIdx], trace[toIdx]
	local time = to[1] - from[1] - (cumTime[toIdx - 1] - (cumTime[fromIdx - 1] or 0))
	local mem = (to[5] or 0) - (from[5] or 0) - (cumMem[toIdx - 1] - (cumMem[fromIdx - 1] or 0))
	return time > 0 and time or 0, mem > 0 and mem or 0
end

local stack = {}
local bursts = {}
local perFunc = {}
local burstIdx

for i = 1, #trace do
	local e = trace[i]
	local event = eventNames[e[2]]
	if event == "Enter" then
		if #stack == 0 then burstIdx = i end
		stack[#stack + 1] = { name = functionNames[e[3]], idx = i }
	elseif event == "Leave" then
		local name = functionNames[e[3]]
		-- Errors unwind without a Leave, so drop anything above the frame that is leaving.
		local depth
		for d = #stack, 1, -1 do
			if stack[d].name == name then depth = d break end
		end
		if depth then
			local frame = stack[depth]
			for d = #stack, depth, -1 do stack[d] = nil end
			local time, mem = spanCost(frame.idx, i)
			local stats = perFunc[name]
			if not stats then
				stats = { count = 0, total = 0, max = 0, mem = 0 }
				perFunc[name] = stats
			end
			stats.count = stats.count + 1
			stats.total = stats.total + time
			stats.mem = stats.mem + mem
			if time > stats.max then stats.max = time end
			if #stack == 0 then
				bursts[#bursts + 1] = { name = frame.name, time = time, mem = mem, entries = i - burstIdx + 1 }
			end
		end
	end
end

local function shorten(name)
	return (name:gsub("MiniAuras/", ""))
end

table.sort(bursts, function(a, b) return a.time > b.time end)
print()
print(("Top %d single bursts (one top-level call, cannot be split across frames):"):format(topN))
for i = 1, math.min(topN, #bursts) do
	local b = bursts[i]
	print(("%7.2f ms  %6.0f KiB  %6d entries  %s"):format(b.time * 1000, b.mem / 1024, b.entries, shorten(b.name)))
end

local byRoot = {}
for _, b in ipairs(bursts) do
	local stats = byRoot[b.name]
	if not stats then
		stats = { count = 0, total = 0, max = 0 }
		byRoot[b.name] = stats
	end
	stats.count = stats.count + 1
	stats.total = stats.total + b.time
	if b.time > stats.max then stats.max = b.time end
end

local function sorted(map, key)
	local list = {}
	for name, stats in pairs(map) do
		stats.name = name
		list[#list + 1] = stats
	end
	table.sort(list, function(a, b) return a[key] > b[key] end)
	return list
end

print()
print(("Entry points by total time (%d bursts total):"):format(#bursts))
for i, stats in ipairs(sorted(byRoot, "total")) do
	if i > topN then break end
	print(("%7.1f ms total  %6.2f ms worst  %6d calls  %6.3f ms avg  %s"):format(
		stats.total * 1000, stats.max * 1000, stats.count, stats.total / stats.count * 1000, shorten(stats.name)))
end

print()
print("Functions by worst single call:")
for i, stats in ipairs(sorted(perFunc, "max")) do
	if i > topN then break end
	print(("%7.2f ms worst  %7.1f ms total  %6d calls  %s"):format(
		stats.max * 1000, stats.total * 1000, stats.count, shorten(stats.name)))
end

print()
print("Functions by total inclusive time:")
for i, stats in ipairs(sorted(perFunc, "total")) do
	if i > topN then break end
	print(("%7.1f ms total  %6.2f ms worst  %6d calls  %6.3f ms avg  %s"):format(
		stats.total * 1000, stats.max * 1000, stats.count, stats.total / stats.count * 1000, shorten(stats.name)))
end
