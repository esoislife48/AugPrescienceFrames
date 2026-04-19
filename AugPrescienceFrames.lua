local E, L, V, P, G = unpack(ElvUI)
local APF = E:NewModule("AugPrescienceFrames", "AceEvent-3.0")
local EP = LibStub("LibElvUIPlugin-1.0")

-- Expressway via SharedMedia (same as ElvUI defaults), with safe fallbacks.
local function GetExpresswayFont()
	local LSM = E.Libs and E.Libs.LSM
	if LSM and LSM.Fetch then
		local ok, path = pcall(function()
			return LSM:Fetch("font", "Expressway")
		end)
		if ok and path and path ~= "" then
			return path
		end
	end
	if E.media and E.media.normFont and E.media.normFont ~= "" then
		return E.media.normFont
	end
	return "Fonts\\FRIZQT__.TTF"
end

-- Bindings text
BINDING_HEADER_AUGPRESCIENCEFRAMES = "Aug Prescience Frames"
BINDING_NAME_AUGPRESCIENCEFRAMES_ADD_SLOT1 = "Add current unit to Slot 1"
BINDING_NAME_AUGPRESCIENCEFRAMES_ADD_SLOT2 = "Add current unit to Slot 2"
BINDING_NAME_AUGPRESCIENCEFRAMES_CLEAR_SLOTS = "Clear slots"

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function isAugEvoker()
	local _, class = UnitClass("player")
	if class ~= "EVOKER" then return false end
	local spec = GetSpecialization and GetSpecialization() or nil
	-- 3 = Augmentation (Retail)
	return spec == 3
end

local function spellKnown(spellID)
	return IsPlayerSpell and IsPlayerSpell(spellID) or false
end

-- Prescience spellID (Retail)
local PRESCIENCE_SPELL_ID = 409311
local PRESCIENCE_SPELL_NAME = (GetSpellInfo and GetSpellInfo(PRESCIENCE_SPELL_ID)) or "Prescience"
local PRESCIENCE_ICON = (C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(PRESCIENCE_SPELL_ID)) or (GetSpellTexture and GetSpellTexture(PRESCIENCE_SPELL_ID))
-- The aura on the target uses a different spellId than the cast spell.
-- (Matches what AugBuffTracker tracks.)
local PRESCIENCE_AURA_ID = 410089
-- Sense Power (Evoker). Retail spell is 361021; 361022 kept as fallback for aura/API quirks.
local SENSE_POWER_SPELL_IDS = { 361021, 361022 }

local function getSpellNameForMatch(spellID)
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spellID)
		if info and info.name then
			return info.name
		end
	end
	if GetSpellInfo then
		return GetSpellInfo(spellID)
	end
	return nil
end

-- spellId can be a "secret" number; direct == with a literal may error.
local function auraMatchesSpellId(aura, spellID)
	if not aura then
		return false
	end
	local ok, same = pcall(function()
		return aura.spellId == spellID
	end)
	if ok and same then
		return true
	end
	local wantName = getSpellNameForMatch(spellID)
	if wantName and aura.name then
		local okName, sameName = pcall(function()
			return aura.name == wantName
		end)
		if okName and sameName then
			return true
		end
	end
	return false
end

local function findAuraDataBySpellID(unit, spellID)
	if not unit or not UnitExists(unit) then return nil end

	local CUA = C_UnitAuras

	-- Player-only helper (often safest/fastest for self auras).
	if unit == "player" and CUA and CUA.GetPlayerAuraBySpellID then
		local ok, aura = pcall(function()
			return CUA.GetPlayerAuraBySpellID(spellID)
		end)
		if ok and aura then
			return aura
		end
	end

	-- 1) Direct by spell id (fast; Blizzard only permits this for whitelisted spells during
	-- encounters / M+ — others return nil, same as "not found".)
	if CUA and CUA.GetUnitAuraBySpellID then
		local ok, aura = pcall(function()
			return CUA.GetUnitAuraBySpellID(unit, spellID)
		end)
		if ok and aura then
			return aura
		end
	end

	-- 2) Lookup by spell name — often still works in dungeons when iterative scans cannot
	-- compare aura.spellId to literals ("secret" values) and GetUnitAuraBySpellID is blocked.
	if CUA and CUA.GetAuraDataBySpellName then
		local wantName = getSpellNameForMatch(spellID)
		if wantName and wantName ~= "" then
			local nameFilters = { "HELPFUL|PLAYER", "PLAYER|HELPFUL", "HELPFUL" }
			for i = 1, #nameFilters do
				local ok, aura = pcall(function()
					return CUA.GetAuraDataBySpellName(unit, wantName, nameFilters[i])
				end)
				if ok and aura then
					return aura
				end
			end
			local okAll, auraAll = pcall(function()
				return CUA.GetAuraDataBySpellName(unit, wantName)
			end)
			if okAll and auraAll then
				return auraAll
			end
		end
	end

	-- 3) Iterator (packed aura data)
	if AuraUtil and AuraUtil.ForEachAura then
		local found
		AuraUtil.ForEachAura(unit, "HELPFUL", nil, function(aura)
			if aura and auraMatchesSpellId(aura, spellID) then
				found = aura
				return true -- stop iteration
			end
			return false
		end, true)
		if found then return found end
	end

	-- 4) Index scan: try player buffs first (narrower list), then all helpful.
	if CUA and CUA.GetAuraDataByIndex then
		local indexFilters = { "HELPFUL|PLAYER", "HELPFUL" }
		for fi = 1, #indexFilters do
			local filt = indexFilters[fi]
			for i = 1, 80 do
				local ok, aura = pcall(function()
					return CUA.GetAuraDataByIndex(unit, i, filt)
				end)
				if not ok or not aura then
					break
				end
				if auraMatchesSpellId(aura, spellID) then
					return aura
				end
			end
		end
	end

	return nil
end

local function findSensePowerAura(unit)
	if not unit or not UnitExists(unit) then
		return nil
	end
	for i = 1, #SENSE_POWER_SPELL_IDS do
		local a = findAuraDataBySpellID(unit, SENSE_POWER_SPELL_IDS[i])
		if a then
			return a
		end
	end
	return nil
end

-- true = in range, false = out of range, nil = unknown / API unavailable
local function prescienceInRange(unit)
	if not unit or not UnitExists(unit) then
		return nil
	end
	if C_Spell and C_Spell.IsSpellInRange then
		local ok, r = pcall(function()
			return C_Spell.IsSpellInRange(PRESCIENCE_SPELL_ID, unit)
		end)
		if ok and r ~= nil then
			if r == true or r == 1 then return true end
			if r == false or r == 0 then return false end
		end
	end
	if IsSpellInRange then
		local ok, v = pcall(function()
			return IsSpellInRange(PRESCIENCE_SPELL_ID, "spell", unit)
		end)
		if ok and v ~= nil then
			if v == true then return true end
			if v == false then return false end
			if v == 1 then return true end
			if v == 0 then return false end
		end
		ok, v = pcall(function()
			return IsSpellInRange(PRESCIENCE_SPELL_NAME, unit)
		end)
		if ok and v ~= nil then
			if v == 1 then return true end
			if v == 0 then return false end
			if v == true then return true end
			if v == false then return false end
		end
	end
	return nil
end

P["AugPrescienceFrames"] = {
	enabled = true,
	width = 170,
	height = 28,
	spacing = 6,
	transparent = true,
	showRangeIndicator = true,
	showSensePowerGlow = true,
	slots = { nil, nil }, -- legacy (stored GUIDs); kept for migration
	slotUnits = { nil, nil }, -- stores unit tokens like "raid5"/"party2"
	-- Name readability (ElvUI options)
	nameFontSize = 14,
	nameStripAlpha = 0.72,
	nameShadow = 3, -- 0 = off
	nameOutline = "THICKOUTLINE", -- NONE | OUTLINE | THICKOUTLINE
	nameR = 1,
	nameG = 1,
	nameB = 1,
	nameA = 1,
}

function APF:DB()
	E.db.AugPrescienceFrames = E.db.AugPrescienceFrames or {}
	E.db.AugPrescienceFrames.slots = E.db.AugPrescienceFrames.slots or { nil, nil } -- legacy
	E.db.AugPrescienceFrames.slotUnits = E.db.AugPrescienceFrames.slotUnits or { nil, nil }
	return E.db.AugPrescienceFrames
end

local function resolveStableUnitToken(unit)
	if not unit or not UnitExists(unit) then return nil end

	-- If the player is in a group, prefer stable party/raid tokens.
	if IsInRaid and IsInRaid() then
		for i = 1, 40 do
			local u = "raid" .. i
			if UnitExists(u) and UnitIsUnit(u, unit) then
				return u
			end
		end
	elseif IsInGroup and IsInGroup() then
		for i = 1, 4 do
			local u = "party" .. i
			if UnitExists(u) and UnitIsUnit(u, unit) then
				return u
			end
		end
		if UnitIsUnit("player", unit) then
			return "player"
		end
	end

	-- Fallbacks (not stable, but better than nothing outside groups)
	if UnitIsUnit("player", unit) then return "player" end
	if UnitIsUnit("pet", unit) then return "pet" end
	if UnitIsUnit("focus", unit) then return "focus" end

	return unit -- target/mouseover are inherently not stable, but allow it if solo
end

local function unitDisplayName(unit)
	if not unit or not UnitExists(unit) then return "—" end
	local name = UnitName(unit)
	if not name then return "—" end
	return name
end

local function unitColor(unit)
	if not unit or not UnitExists(unit) then
		return 0.35, 0.35, 0.35
	end
	if UnitIsDeadOrGhost(unit) or not UnitIsConnected(unit) then
		return 0.5, 0.5, 0.5
	end
	local _, class = UnitClass(unit)
	if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
		local c = RAID_CLASS_COLORS[class]
		return c.r, c.g, c.b
	end
	return 0.25, 0.85, 0.25
end

local function getHealthPct(unit)
	if not unit or not UnitExists(unit) then return 0 end
	local max = UnitHealthMax(unit) or 0
	if max == 0 then return 0 end

	local cur = UnitHealth(unit) or 0

	-- Dragonflight+ "secret values" can make arithmetic unsafe.
	-- If either value is secret, avoid math and just show empty.
	if E and E.IsSecretValue and (E:IsSecretValue(cur) or E:IsSecretValue(max)) then
		return 0
	end

	local ok, pct = pcall(function()
		return cur / max
	end)
	if not ok or not pct then return 0 end

	return clamp(pct, 0, 1)
end

APF.frames = {}

-- Keybinds can fire before ElvUI enables the module; ensure UI exists.
function APF:EnsureFrames()
	if not self.holder then
		self:CreateHolder()
	end
	if not self.frames[1] then
		self.frames[1] = self:CreateSlotFrame(1)
	end
	if not self.frames[2] then
		self.frames[2] = self:CreateSlotFrame(2)
	end
	self:Layout()
end

function APF:ApplyNameStyle(f)
	if not f or not f.nameText then return end
	local db = self:DB()
	local size = db.nameFontSize or 14
	local outline = db.nameOutline or "THICKOUTLINE"
	if outline == "NONE" or outline == "" then
		outline = ""
	end
	f.nameText:SetFont(GetExpresswayFont(), size, outline)

	local sh = db.nameShadow or 0
	if sh <= 0 then
		f.nameText:SetShadowOffset(0, 0)
		f.nameText:SetShadowColor(0, 0, 0, 0)
	else
		f.nameText:SetShadowOffset(sh, -sh)
		f.nameText:SetShadowColor(0, 0, 0, 1)
	end

	if f.nameBG then
		f.nameBG:SetColorTexture(0, 0, 0, db.nameStripAlpha or 0.72)
	end
end

-- Cyan/teal ADD border when Sense Power is up on the slotted unit.
function APF:CreateSensePowerGlow(f)
	local g = CreateFrame("Frame", nil, f)
	g:SetFrameStrata(f:GetFrameStrata())
	g:SetFrameLevel((f.overlay:GetFrameLevel() or 10) + 8)
	g:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
	g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
	g:Hide()

	local cr, cg, cb, baseA = 0.15, 0.92, 1.0, 0.75
	local thick = 3

	local top = g:CreateTexture(nil, "OVERLAY")
	top:SetBlendMode("ADD")
	top:SetColorTexture(cr, cg, cb, baseA)
	top:SetPoint("TOPLEFT", g, "TOPLEFT", 0, 0)
	top:SetPoint("TOPRIGHT", g, "TOPRIGHT", 0, 0)
	top:SetHeight(thick)

	local bot = g:CreateTexture(nil, "OVERLAY")
	bot:SetBlendMode("ADD")
	bot:SetColorTexture(cr, cg, cb, baseA)
	bot:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 0, 0)
	bot:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, 0)
	bot:SetHeight(thick)

	local left = g:CreateTexture(nil, "OVERLAY")
	left:SetBlendMode("ADD")
	left:SetColorTexture(cr, cg, cb, baseA)
	left:SetPoint("TOPLEFT", g, "TOPLEFT", 0, 0)
	left:SetPoint("BOTTOMLEFT", g, "BOTTOMLEFT", 0, 0)
	left:SetWidth(thick)

	local right = g:CreateTexture(nil, "OVERLAY")
	right:SetBlendMode("ADD")
	right:SetColorTexture(cr, cg, cb, baseA)
	right:SetPoint("TOPRIGHT", g, "TOPRIGHT", 0, 0)
	right:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, 0)
	right:SetWidth(thick)

	g._pulse = 0
	g:SetScript("OnUpdate", function(self, elapsed)
		if not self:IsShown() then
			return
		end
		self._pulse = (self._pulse or 0) + (elapsed or 0) * 2.8
		local m = 0.72 + 0.28 * math.sin(self._pulse)
		top:SetColorTexture(cr, cg, cb, baseA * m)
		bot:SetColorTexture(cr, cg, cb, baseA * m)
		left:SetColorTexture(cr, cg, cb, baseA * m)
		right:SetColorTexture(cr, cg, cb, baseA * m)
	end)

	f.senseGlowFrame = g
end

function APF:ApplyRangeVisualsToSlot(f, unit)
	if not f then
		return
	end
	local db = self:DB()
	local cr, cg, cb = f._classR or 0.35, f._classG or 0.75, f._classB or 0.35

	if db.showRangeIndicator == false or not unit or not UnitExists(unit) then
		if f.SetBackdropBorderColor then
			f:SetBackdropBorderColor(cr, cg, cb, 1)
		end
		if f.rangeText then
			f.rangeText:Hide()
		end
		if f.hp then
			f.hp:SetAlpha(1)
		end
		return
	end

	local inRange = prescienceInRange(unit)
	if inRange == false then
		if f.SetBackdropBorderColor then
			f:SetBackdropBorderColor(1, 0.18, 0.22, 1)
		end
		if f.rangeText then
			f.rangeText:SetText("OOR")
			f.rangeText:SetTextColor(1, 0.4, 0.4, 1)
			f.rangeText:Show()
		end
		if f.hp then
			f.hp:SetAlpha(0.5)
		end
	elseif inRange == true then
		if f.SetBackdropBorderColor then
			f:SetBackdropBorderColor(cr, cg, cb, 1)
		end
		if f.rangeText then
			f.rangeText:Hide()
		end
		if f.hp then
			f.hp:SetAlpha(1)
		end
	else
		if f.SetBackdropBorderColor then
			f:SetBackdropBorderColor(0.55, 0.55, 0.55, 1)
		end
		if f.rangeText then
			f.rangeText:SetText("?")
			f.rangeText:SetTextColor(0.85, 0.85, 0.85, 1)
			f.rangeText:Show()
		end
		if f.hp then
			f.hp:SetAlpha(0.88)
		end
	end
end

function APF:UpdateRangeVisualsOnly()
	if not self.initialized or not self.frames[1] then
		return
	end
	local db = self:DB()
	if db.showRangeIndicator == false then
		return
	end
	if not db.enabled or not isAugEvoker() or not spellKnown(PRESCIENCE_SPELL_ID) then
		return
	end
	for i = 1, 2 do
		local f = self.frames[i]
		if f and db.slotUnits[i] and UnitExists(db.slotUnits[i]) then
			self:ApplyRangeVisualsToSlot(f, db.slotUnits[i])
		end
	end
end

function APF:CreateHolder()
	if self.holder then return end

	local db = self:DB()
	local holder = CreateFrame("Frame", "AugPrescienceFramesHolder", E.UIParent)
	holder:SetFrameStrata("HIGH")
	holder:SetPoint("CENTER", E.UIParent, "CENTER", 0, -160)
	holder:SetSize(db.width, (db.height * 2) + db.spacing)
	holder:SetTemplate(db.transparent and "Transparent" or "Default")

	self.holder = holder
	E:CreateMover(holder, "AugPrescienceFramesMover", "Aug Prescience Frames", nil, nil, nil, nil, nil, "unitframe,augprescienceframes")
end

function APF:CreateSlotFrame(slot)
	local db = self:DB()
	-- SecureUnitButtonTemplate makes the frame provide a real "mouseover" unit,
	-- so `/cast [@mouseover] Prescience` works when hovering the slot.
	local f = CreateFrame("Button", "AugPrescienceFramesSlot" .. slot, self.holder, "SecureUnitButtonTemplate,BackdropTemplate")
	f:SetFrameStrata("HIGH")
	f:SetSize(db.width, db.height)
	f:SetTemplate(db.transparent and "Transparent" or "Default")

	f.hp = CreateFrame("StatusBar", nil, f)
	f.hp:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
	f.hp:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
	f.hp:SetStatusBarTexture(E.media.normTex or "Interface\\TARGETINGFRAME\\UI-StatusBar")
	f.hp:SetMinMaxValues(0, 1)
	f.hp:SetValue(0)

	f.hpBG = f.hp:CreateTexture(nil, "BORDER")
	f.hpBG:SetAllPoints(f.hp)
	f.hpBG:SetColorTexture(0, 0, 0, 0.25)

	-- Overlay frame above the StatusBar (child frames can render above parent regions).
	f.overlay = CreateFrame("Frame", nil, f)
	f.overlay:SetAllPoints(f)
	f.overlay:SetFrameLevel((f.hp:GetFrameLevel() or 1) + 5)

	-- Dark strip behind the name for readability
	f.nameBG = f.overlay:CreateTexture(nil, "BORDER")
	f.nameBG:SetColorTexture(0, 0, 0, 0.45)
	f.nameBG:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
	f.nameBG:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 2, 2)
	f.nameBG:SetWidth(110) -- adjusted in Layout()

	-- Buff tracker (Prescience) on the right
	f.buff = CreateFrame("Frame", nil, f, "BackdropTemplate")
	f.buff:SetSize(db.height, db.height)
	f.buff:SetPoint("LEFT", f, "RIGHT", 6, 0)
	f.buff:SetTemplate(db.transparent and "Transparent" or "Default")

	f.buff.icon = f.buff:CreateTexture(nil, "ARTWORK")
	f.buff.icon:SetPoint("TOPLEFT", f.buff, "TOPLEFT", 2, -2)
	f.buff.icon:SetPoint("BOTTOMRIGHT", f.buff, "BOTTOMRIGHT", -2, 2)
	f.buff.icon:SetTexture(PRESCIENCE_ICON or 134400) -- fallback icon id
	f.buff.icon:SetTexCoord(unpack(E.TexCoords))

	f.buff.cd = CreateFrame("Cooldown", nil, f.buff, "CooldownFrameTemplate")
	f.buff.cd:SetAllPoints(f.buff.icon)
	f.buff.cd:SetDrawEdge(false)
	f.buff.cd:SetDrawBling(false)
	f.buff.cd:SetReverse(true)

	f.buff.timeText = f.buff:CreateFontString(nil, "OVERLAY")
	f.buff.timeText:SetFont(GetExpresswayFont(), 11, "OUTLINE")
	f.buff.timeText:SetPoint("CENTER", f.buff, "CENTER", 0, 0)
	f.buff.timeText:SetJustifyH("CENTER")
	f.buff.timeText:SetText("")

	f.nameText = f.overlay:CreateFontString(nil, "OVERLAY")
	f.nameText:SetPoint("LEFT", f, "LEFT", 8, 0)
	f.nameText:SetJustifyH("LEFT")
	f.nameText:SetWordWrap(false)
	f.nameText:SetNonSpaceWrap(false)
	f.nameText:SetMaxLines(1)
	self:ApplyNameStyle(f)
	f.nameText:SetText("—")

	f.slotText = f:CreateFontString(nil, "OVERLAY")
	f.slotText:SetFont(GetExpresswayFont(), 11, "OUTLINE")
	f.slotText:SetPoint("RIGHT", f, "RIGHT", -6, 0)
	f.slotText:SetJustifyH("RIGHT")
	f.slotText:SetText("S" .. slot)

	-- Out-of-range label (Prescience); updated by range ticker + UpdateVisuals
	f.rangeText = f.overlay:CreateFontString(nil, "OVERLAY")
	f.rangeText:SetFont(GetExpresswayFont(), 10, "OUTLINE")
	f.rangeText:SetPoint("BOTTOM", f, "BOTTOM", 0, 4)
	f.rangeText:SetJustifyH("CENTER")
	f.rangeText:SetTextColor(1, 0.35, 0.35, 1)
	f.rangeText:SetShadowColor(0, 0, 0, 1)
	f.rangeText:SetShadowOffset(1, -1)
	f.rangeText:Hide()

	-- Secure click-cast (left click defaults)
	f:SetAttribute("*type1", "spell")
	f:SetAttribute("*spell1", PRESCIENCE_SPELL_NAME)
	f:SetAttribute("checkselfcast", false)
	f:RegisterForClicks("AnyUp")

	self:CreateSensePowerGlow(f)

	return f
end

function APF:Layout()
	if not self.holder then return end
	-- Secure slot buttons cannot be resized/repositioned in combat.
	if InCombatLockdown() then
		pendingLayout = true
		return
	end
	local db = self:DB()

	self.holder:SetSize(db.width, (db.height * 2) + db.spacing)
	self.holder:SetTemplate(db.transparent and "Transparent" or "Default")

	for i = 1, 2 do
		local f = self.frames[i]
		if f then
			f:SetSize(db.width, db.height)
			f:SetTemplate(db.transparent and "Transparent" or "Default")

			if f.nameBG then
				-- Keep a readable strip that scales with the frame width.
				local stripW = math.max(90, db.width - (db.height + 6) - 40) -- leave room for slotText and buff
				f.nameBG:SetWidth(stripW)
			end

			if f.nameText then
				local textW = math.max(60, db.width - (db.height + 6) - 60)
				f.nameText:SetWidth(textW)
			end

			self:ApplyNameStyle(f)

			if f.buff then
				f.buff:SetSize(db.height, db.height)
				f.buff:SetTemplate(db.transparent and "Transparent" or "Default")
			end

			f:ClearAllPoints()
			if i == 1 then
				f:SetPoint("TOPLEFT", self.holder, "TOPLEFT", 0, 0)
			else
				f:SetPoint("TOPLEFT", self.frames[i - 1], "BOTTOMLEFT", 0, -db.spacing)
			end
		end
	end
end

local pendingSecureUpdate = false
local pendingVisibilityUpdate = false
local pendingLayout = false

-- UNIT_AURA etc. fire for the whole raid; ignore unless the unit is one of our slots.
-- Unit tokens / DB values can be "secret" types: never use `if tok`, `not x`, or `==` on them
-- outside pcall — that throws "boolean test on a secret boolean/string".
function APF:ShouldHandleUnitEvent(event, unit)
	local ok, allow = pcall(function()
		local spammy = {
			UNIT_AURA = true,
			UNIT_HEALTH = true,
			UNIT_MAXHEALTH = true,
			UNIT_NAME_UPDATE = true,
			UNIT_CONNECTION = true,
		}
		if type(event) ~= "string" or not spammy[event] then
			return true
		end
		if type(unit) ~= "string" or unit == "" then
			return true
		end

		local db = self:DB()
		local su = db.slotUnits
		if type(su) ~= "table" then
			return false
		end

		for i = 1, 2 do
			local tok = su[i]
			if type(tok) == "string" and tok ~= "" and unit == tok then
				return true
			end
		end
		return false
	end)

	if not ok then
		-- Fail open: refresh occasionally wrong > spam errors / missed UI.
		return true
	end
	return allow
end

-- Coalesce burst events into one refresh (stops allocation/GC churn from aura spam).
function APF:ScheduleCoalescedRefresh()
	if self._eventCoalesceTimer then
		self._eventCoalesceTimer:Cancel()
		self._eventCoalesceTimer = nil
	end
	if not C_Timer or not C_Timer.NewTimer then
		self:RefreshEnabledState()
		self:UpdateSecureUnitAttributes()
		self:UpdateVisuals()
		return
	end
	self._eventCoalesceTimer = C_Timer.NewTimer(0.08, function()
		self._eventCoalesceTimer = nil
		self:RefreshEnabledState()
		self:UpdateSecureUnitAttributes()
		self:UpdateVisuals()
	end)
end

function APF:SetSlotUnit(slot, unitToken)
	local db = self:DB()
	db.slotUnits[slot] = unitToken
end

function APF:UpdateSecureUnitAttributes()
	if InCombatLockdown() then
		pendingSecureUpdate = true
		return
	end

	self:EnsureFrames()

	for slot = 1, 2 do
		local unit = self:DB().slotUnits[slot]
		local f = self.frames[slot]
		if f then
			if unit and UnitExists(unit) then
				f:SetAttribute("unit", unit)
				f:SetAttribute("*unit1", unit) -- left click (spell)
			else
				f:SetAttribute("unit", nil)
				f:SetAttribute("*unit1", nil)
			end
			-- Do not bind right-click actions (no target on right-click).
			f:SetAttribute("*type2", nil)
			f:SetAttribute("*unit2", nil)
		end
	end

	pendingSecureUpdate = false
end

function APF:UpdateVisuals()
	self:EnsureFrames()

	local db = self:DB()
	-- Self-toggle: Sense Power is usually a buff on the player while active; show glow on all
	-- filled slots without requiring you to target those units (boss targeting is common).
	local sensePowerOnPlayer = findSensePowerAura("player") ~= nil

	for slot = 1, 2 do
		local unit = db.slotUnits[slot]
		local f = self.frames[slot]
		if f then
			local name = unitDisplayName(unit)
			local r, g, b = unitColor(unit)

			f.nameText:SetText(name)
			f.nameText:SetTextColor(db.nameR or 1, db.nameG or 1, db.nameB or 1, db.nameA or 1)

			-- Solid class-color fill (not health-based)
			f.hp:SetValue(1)
			f.hp:SetStatusBarColor(r, g, b, 0.95)
			f._classR, f._classG, f._classB = r, g, b

			self:ApplyRangeVisualsToSlot(f, unit)

			-- Buff tracker: Prescience remaining
			if f.buff then
				f.buff.timeText:SetText("")
				f.buff.cd:Clear()
				f.buff:SetAlpha(0.25)

				if unit and UnitExists(unit) then
					local aura = findAuraDataBySpellID(unit, PRESCIENCE_AURA_ID)
					if aura and (not aura.sourceUnit or aura.sourceUnit == "player") then
						f.buff:SetAlpha(1)
						if aura.icon then f.buff.icon:SetTexture(aura.icon) end

						local duration = aura.duration
						local expirationTime = aura.expirationTime
						if duration and expirationTime and duration > 0 and expirationTime > 0 then
							local startTime = expirationTime - duration
							f.buff.cd:SetCooldown(startTime, duration)

							local remaining = expirationTime - GetTime()
							if remaining and remaining > 0 then
								if remaining >= 10 then
									f.buff.timeText:SetText(("%d"):format(remaining + 0.5))
								else
									f.buff.timeText:SetText(("%.1f"):format(remaining))
								end
							end
						end
					end
				end
			end

			-- Sense Power glow on slotted unit
			if f.senseGlowFrame then
				local unitHasSensePower = unit and UnitExists(unit) and findSensePowerAura(unit) ~= nil
				local showGlow = db.showSensePowerGlow ~= false
					and unit and UnitExists(unit)
					and (unitHasSensePower or sensePowerOnPlayer)
				if showGlow then
					f.senseGlowFrame:Show()
				else
					f.senseGlowFrame:Hide()
				end
			end
		end
	end
end

function APF:RefreshEnabledState()
	local db = self:DB()
	local shouldShow = db.enabled and isAugEvoker() and spellKnown(PRESCIENCE_SPELL_ID)

	-- Secure frames can't be shown/hidden or laid out in combat (SetSize/SetPoint taint).
	if InCombatLockdown() then
		pendingVisibilityUpdate = true
		pendingLayout = true
		return
	end

	self:EnsureFrames()

	local anyVisible = false
	for i = 1, 2 do
		local f = self.frames[i]
		if f then
			local unit = self:DB().slotUnits[i]
			local showThis = shouldShow and unit and UnitExists(unit)
			f:SetAlpha(showThis and 1 or 0)
			f:EnableMouse(showThis)
			anyVisible = anyVisible or showThis
		end
	end

	-- Hide the holder background if no slots are visible.
	if self.holder then
		self.holder:SetAlpha(anyVisible and 1 or 0)
	end

	if self.holder and self.holder.mover then
		if anyVisible then
			E:EnableMover(self.holder.mover.name)
		else
			E:DisableMover(self.holder.mover.name)
		end
	end

	-- If we disable the widget, also clear secure unit attributes out of combat.
	if not shouldShow then
		self:UpdateSecureUnitAttributes()
	end
end

-- Restored legacy helper (used in older versions / debugging)
local function guidFromBestUnit()
	-- Priority: target > mouseover > focus (so keybinds feel natural)
	local units = { "target", "mouseover", "focus" }
	for _, unit in ipairs(units) do
		if UnitExists(unit) and UnitIsPlayer(unit) and UnitIsFriend("player", unit) then
			return UnitGUID(unit)
		end
	end
	return nil
end

function APF:AddSlot(slot)
	self:EnsureFrames()

	slot = tonumber(slot)
	if slot ~= 1 and slot ~= 2 then return end

	local pick = nil
	for _, u in ipairs({ "target", "mouseover", "focus" }) do
		if UnitExists(u) and UnitIsPlayer(u) and UnitIsFriend("player", u) then
			pick = u
			break
		end
	end
	if not pick then return end

	local stable = resolveStableUnitToken(pick)
	if not stable then return end

	self:SetSlotUnit(slot, stable)
	self:UpdateSecureUnitAttributes()
	self:UpdateVisuals()
end

function APF:ClearSlots()
	self:EnsureFrames()

	local db = self:DB()
	db.slotUnits[1] = nil
	db.slotUnits[2] = nil
	self:UpdateSecureUnitAttributes()
	self:UpdateVisuals()
end

function AugPrescienceFrames_AddSlot(slot)
	if APF and APF.AddSlot then APF:AddSlot(slot) end
end

function AugPrescienceFrames_ClearSlots()
	if APF and APF.ClearSlots then APF:ClearSlots() end
end

SLASH_AUGPRESCIENCEFRAMES1 = "/apf"
SlashCmdList.AUGPRESCIENCEFRAMES = function(msg)
	msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

	if msg == "hide" then
		APF:DB().enabled = false
		APF:RefreshEnabledState()
		print("|cff66c0ffAug Prescience Frames|r: hidden.")
	elseif msg == "show" then
		APF:DB().enabled = true
		APF:RefreshEnabledState()
		print("|cff66c0ffAug Prescience Frames|r: shown.")
	elseif msg == "clear" then
		APF:ClearSlots()
		print("|cff66c0ffAug Prescience Frames|r: cleared.")
	elseif msg == "config" then
		E:ToggleOptions("AugPrescienceFrames")
	else
		print("|cff66c0ffAug Prescience Frames|r commands:")
		print("  /apf show | hide")
		print("  /apf clear")
		print("  /apf config")
	end
end

function APF:InsertOptions()
	E.Options.args.AugPrescienceFrames = {
		order = 100,
		type = "group",
		name = "Aug Prescience Frames",
		get = function(info) return self:DB()[info[#info]] end,
		set = function(info, value)
			self:DB()[info[#info]] = value
			self:Layout()
			self:RefreshEnabledState()
			self:UpdateSecureUnitAttributes()
			self:UpdateVisuals()
		end,
		args = {
			enabled = { order = 1, type = "toggle", name = "Enable" },
			transparent = { order = 2, type = "toggle", name = "Transparent" },
			showRangeIndicator = {
				order = 2.5,
				type = "toggle",
				name = "Range (Prescience)",
				desc = "Show when the slotted player is out of range to cast Prescience (red border + OOR).",
			},
			showSensePowerGlow = {
				order = 2.6,
				type = "toggle",
				name = "Sense Power glow",
				desc = "Pulse glow on the slot when Sense Power is active on that player.",
			},
			width = { order = 3, type = "range", name = "Width", min = 80, max = 400, step = 1 },
			height = { order = 4, type = "range", name = "Height", min = 16, max = 60, step = 1 },
			spacing = { order = 5, type = "range", name = "Spacing", min = 0, max = 40, step = 1 },
			clear = {
				order = 6,
				type = "execute",
				name = "Clear Slots",
				func = function() self:ClearSlots() end,
			},
			nameHeader = { order = 7, type = "header", name = "Name" },
			nameFontSize = { order = 8, type = "range", name = "Font size", min = 8, max = 24, step = 1 },
			nameStripAlpha = {
				order = 9,
				type = "range",
				name = "Name strip opacity",
				desc = "Dark bar behind the player name (0 = invisible, 1 = solid).",
				min = 0,
				max = 1,
				step = 0.05,
			},
			nameShadow = {
				order = 10,
				type = "range",
				name = "Text shadow",
				desc = "0 disables the drop shadow.",
				min = 0,
				max = 5,
				step = 1,
			},
			nameOutline = {
				order = 11,
				type = "select",
				name = "Outline",
				values = {
					NONE = "None",
					OUTLINE = "Outline",
					THICKOUTLINE = "Thick outline",
				},
			},
			nameColor = {
				order = 12,
				type = "color",
				name = "Text color",
				hasAlpha = true,
				get = function()
					local d = self:DB()
					return d.nameR or 1, d.nameG or 1, d.nameB or 1, d.nameA or 1
				end,
				set = function(_, r, g, b, a)
					local d = self:DB()
					d.nameR, d.nameG, d.nameB, d.nameA = r, g, b, a
					self:Layout()
					self:UpdateVisuals()
				end,
			},
			desc = {
				order = 13,
				type = "description",
				name = "Use keybinds to assign Slot 1/2 from target/mouseover/focus. Click a slot to cast Prescience on it.\nMover: Aug Prescience Frames.",
			},
		},
	}
end

function APF:OnInitialize()
	EP:RegisterPlugin("AugPrescienceFrames", function() self:InsertOptions() end)
end

function APF:OnEnable()
	self:InitializeModule()
	self:EnsureRangeTicker()
end

function APF:OnDisable()
	if self._rangeTicker then
		self._rangeTicker:Cancel()
		self._rangeTicker = nil
	end
	if self._eventCoalesceTimer then
		self._eventCoalesceTimer:Cancel()
		self._eventCoalesceTimer = nil
	end
end

function APF:EnsureRangeTicker()
	if not C_Timer or not C_Timer.NewTicker then
		return
	end
	if self._rangeTicker then
		return
	end
	self._rangeTicker = C_Timer.NewTicker(0.35, function()
		self:UpdateRangeVisualsOnly()
	end)
end

function APF:InitializeModule()
	if self.initialized then return end

	self:EnsureFrames()
	self.initialized = true

	self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "OnEventRefresh")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEventRefresh")
	self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnEventRefresh")
	self:RegisterEvent("UNIT_CONNECTION", "OnEventRefresh")
	self:RegisterEvent("UNIT_NAME_UPDATE", "OnEventRefresh")
	self:RegisterEvent("UNIT_AURA", "OnEventRefresh")
	self:RegisterEvent("UNIT_HEALTH", "OnEventRefresh")
	self:RegisterEvent("UNIT_MAXHEALTH", "OnEventRefresh")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnRegenEnabled")

	-- One-time migration from legacy GUID storage to unit tokens (best-effort, out of combat).
	if not InCombatLockdown() then
		local db = self:DB()
		if db.slots and (db.slots[1] or db.slots[2]) and db.slotUnits then
			-- We can't safely compare GUIDs anymore (secret values), so only migrate if the unit
			-- is currently target/mouseover/focus and matches by UnitIsUnit via those tokens.
			-- Otherwise user can just re-add slots with keybinds.
			db.slots[1], db.slots[2] = nil, nil
		end
	end

	self:UpdateSecureUnitAttributes()
	self:UpdateVisuals()
	self:RefreshEnabledState()
end

function APF:OnRegenEnabled()
	if pendingLayout then
		pendingLayout = false
		self:Layout()
	end

	if pendingSecureUpdate then
		self:UpdateSecureUnitAttributes()
	end

	if pendingVisibilityUpdate then
		pendingVisibilityUpdate = false
		self:RefreshEnabledState()
	end

	self:UpdateVisuals()
end

function APF:OnEventRefresh(event, unit)
	if not self:ShouldHandleUnitEvent(event, unit) then
		return
	end
	self:ScheduleCoalescedRefresh()
end

E:RegisterModule(APF:GetName())
