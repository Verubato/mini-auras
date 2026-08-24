---@type string, Addon
local _, addon = ...

-- Numbers handed out by Commit. Shared by every stamp set, so one number stands for one set of
-- values on one key for the whole session.
local nextGeneration = 0

---@class ChangeStamp
local M = {}

addon.Utils.ChangeStamp = M

local Set = {}
Set.__index = Set

---A keyed "has any of this moved?" test, answered with a number.
---
---Compares the values against what the key last saw and returns a number that only changes when
---one of them did, cheaply enough for paths that run per nameplate and per roster event. Callers
---store the number on an entry and compare it to spot a stale one.
---
---One key is one thing being watched. Give a key the same values in the same order every time. A
---key fed two different looks reads as changing on every call.
---@return ChangeStampSet
function M:New()
	return setmetatable({ Entries = {} }, Set)
end

---Starts a comparison. Every Add after this belongs to the key, until Commit.
---@param key any
function Set:Begin(key)
	local entry = self.Entries[key]

	if not entry then
		entry = { Count = 0 }
		self.Entries[key] = entry
	end

	self.Entry = entry
	self.Index = 0
	self.Changed = false
end

---@param value any Compared with ~=, so pass a table's contents unless its identity is the point.
function Set:Add(value)
	local index = self.Index + 1
	local entry = self.Entry

	self.Index = index

	if entry[index] ~= value then
		entry[index] = value
		self.Changed = true
	end
end

---A colour as its components, so two equal colours still compare equal when the caller hands
---back a refilled scratch table.
---@param color number[]?
function Set:AddColor(color)
	self:Add(color ~= nil)

	if color == nil then
		return
	end

	self:Add(color[1])
	self:Add(color[2])
	self:Add(color[3])
	self:Add(color[4])
end

---A set of spell ids, sorted. Pairs order is not stable, and an order change would read as a
---settings change on every login.
---@param scratch number[] Caller owned, wiped and refilled.
---@param spellIds table<number, boolean>?
function Set:AddSet(scratch, spellIds)
	local count = 0

	if spellIds then
		for spellId, included in pairs(spellIds) do
			if included then
				count = count + 1
				scratch[count] = spellId
			end
		end
	end

	for index = #scratch, count + 1, -1 do
		scratch[index] = nil
	end

	table.sort(scratch)
	self:Add(count)

	for index = 1, count do
		self:Add(scratch[index])
	end
end

---The key's generation. The same number as last time when nothing moved, a fresh one otherwise.
---@return number
function Set:Commit()
	local entry = self.Entry
	local index = self.Index

	-- Fewer values this time, so the tail is stale. Left in place, it would match the next call.
	if index ~= entry.Count then
		for i = index + 1, entry.Count do
			entry[i] = nil
		end

		entry.Count = index
		self.Changed = true
	end

	if self.Changed or not entry.Generation then
		nextGeneration = nextGeneration + 1
		entry.Generation = nextGeneration
	end

	self.Entry = nil

	return entry.Generation
end

---Forgets a key that cannot come back, such as a deleted group. The next Begin starts fresh.
---@param key any
function Set:Forget(key)
	self.Entries[key] = nil
end

---@class ChangeStampSet
---@field Entries table<any, table> Per key: the values last seen, their Count, and the Generation
---they were stamped with.
---@field Entry table? The key being compared, between Begin and Commit.
---@field Index number How many values the comparison has taken.
---@field Changed boolean Whether any of them differed from what the key last saw.
