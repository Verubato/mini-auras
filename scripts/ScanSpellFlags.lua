-- Dev tool (NOT shipped with the addon): scans every spell ID and collects the ones flagged
-- CrowdControl / Important, for regenerating src/Core/AuraCategoryIds.lua.
--
-- Usage:
--   1. Temporarily add to src/MiniCC.toc:  ScanSpellFlags.lua  (copy this file into src/)
--      and extend the saved variables line: ## SavedVariables: MiniCCDB, MiniCCSpellScan
--   2. In game: /miniccscan, then /reload to flush the results to disk.
--   3. Run scripts/GenerateAuraCategoryIds.lua on the resulting
--      WTF\Account\<ACCOUNT>\SavedVariables\MiniCC.lua (see that file's header).
--   4. Revert the TOC changes.
--
-- Run OUT of combat in the open world - the flags can be secret in combat/instanced content,
-- and secret results can't be collected. The scan takes ~30-60 seconds; progress prints to
-- chat. Results are written to the MiniCCSpellScan saved variable (the copy window only shows
-- a summary - the full lists are too big for an edit box).
--
-- If the "secret" counts are non-zero, Blizzard has made the flags unreadable in this client
-- version/context and the lists will be incomplete - try a different zone, or this approach
-- is dead on that client.

local MAX_ID = 1400000 -- above the highest live spell ID as of 12.0; bump if needed
local BATCH = 20000 -- spell IDs scanned per frame; lower this if the client stutters

local scanner = CreateFrame("Frame")
local scanning = false

local function ShowCopyWindow(text)
	local win = CreateFrame("Frame", "MiniCCSpellScanWindow", UIParent, "BasicFrameTemplateWithInset")
	win:SetSize(700, 500)
	win:SetPoint("CENTER")
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:SetFrameStrata("DIALOG")
	if win.TitleText then
		win.TitleText:SetText("MiniCC spell scan")
	end

	local scroll = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -28)
	scroll:SetPoint("BOTTOMRIGHT", -28, 8)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(650)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	edit:SetText(text)
	edit:HighlightText()
	edit:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	scroll:SetScrollChild(edit)
end

local function AppendList(out, label, list, secretCount)
	out[#out + 1] = ("-- %s: %d found, %d secret (secret > 0 means the list is incomplete)"):format(label, #list, secretCount)
	out[#out + 1] = ("local %s = {"):format(label)
	for _, entry in ipairs(list) do
		out[#out + 1] = ("\t[%d] = true, -- %s"):format(entry.id, entry.name or "?")
	end
	out[#out + 1] = "}"
	out[#out + 1] = ""
end

local function StartScan()
	if scanning then
		print("MiniCC spell scan already running.")
		return
	end
	scanning = true

	local cc, imp = {}, {}
	local ccSecret, impSecret = 0, 0
	local currentId = 0
	local lastProgress = 0

	local function Finish()
		scanner:SetScript("OnUpdate", nil)
		scanning = false
		print(("MiniCC scan complete: %d CC spells (%d secret), %d Important spells (%d secret)"):format(#cc, ccSecret, #imp, impSecret))

		-- Full results go to the saved variable (they're far too large for chat or an edit box);
		-- /reload to flush them to WTF\...\SavedVariables\MiniCC.lua.
		MiniCCSpellScan = {
			BuildVersion = select(4, GetBuildInfo()),
			CC = {},
			Important = {},
			CCSecretCount = ccSecret,
			ImportantSecretCount = impSecret,
		}
		for _, entry in ipairs(cc) do
			MiniCCSpellScan.CC[entry.id] = entry.name or true
		end
		for _, entry in ipairs(imp) do
			MiniCCSpellScan.Important[entry.id] = entry.name or true
		end
		print("MiniCC scan: results stored in the MiniCCSpellScan saved variable - /reload to write them to disk.")

		-- The important list is usually small enough to eyeball; show it plus a summary.
		local out = {
			("-- Scan of build %s: %d CC (%d secret), %d Important (%d secret)."):format(tostring(select(4, GetBuildInfo())), #cc, ccSecret, #imp, impSecret),
			"-- Full lists saved to the MiniCCSpellScan saved variable; /reload to flush to disk.",
			"",
		}
		AppendList(out, "importantSpellIds", imp, impSecret)
		ShowCopyWindow(table.concat(out, "\n"))
	end

	scanner:SetScript("OnUpdate", function()
		local stop = math.min(currentId + BATCH, MAX_ID)

		while currentId < stop do
			currentId = currentId + 1
			if C_Spell.DoesSpellExist(currentId) then
				local isCC = C_Spell.IsSpellCrowdControl(currentId)
				if issecretvalue and issecretvalue(isCC) then
					ccSecret = ccSecret + 1
				elseif isCC then
					cc[#cc + 1] = { id = currentId, name = C_Spell.GetSpellName(currentId) }
				end

				local isImp = C_Spell.IsSpellImportant(currentId)
				if issecretvalue and issecretvalue(isImp) then
					impSecret = impSecret + 1
				elseif isImp then
					imp[#imp + 1] = { id = currentId, name = C_Spell.GetSpellName(currentId) }
				end
			end
		end

		if currentId - lastProgress >= 100000 then
			lastProgress = currentId
			print(("MiniCC scan: %dk/%dk (CC %d, Important %d)"):format(currentId / 1000, MAX_ID / 1000, #cc, #imp))
		end

		if currentId >= MAX_ID then
			Finish()
		end
	end)

	print("MiniCC spell scan started...")
end

SLASH_MINICCSCAN1 = "/miniccscan"
SlashCmdList.MINICCSCAN = StartScan
