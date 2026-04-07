local E, L, V, P, G = unpack(ElvUI)
local APF = E:NewModule("AugPrescienceFrames", "AceEvent-3.0")
local EP = LibStub("LibElvUIPlugin-1.0")

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

P["AugPrescienceFrames"] = {
	enabled = true,
	width = 170,
	height = 28,
	spacing = 6,
	transparent = true,
	slots = { nil, nil }, -- legacy (stored GUIDs); kept for migration
	slotUnits = { nil, nil }, -- stores unit tokens like "raid5"/"party2"
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

	f.nameText = f:CreateFontString(nil, "OVERLAY")
	f.nameText:SetFont(E.media.normFont, 12, "OUTLINE")
	f.nameText:SetPoint("LEFT", f, "LEFT", 8, 0)
	f.nameText:SetJustifyH("LEFT")
	f.nameText:SetText("—")

	f.slotText = f:CreateFontString(nil, "OVERLAY")
	f.slotText:SetFont(E.media.normFont, 11, "OUTLINE")
	f.slotText:SetPoint("RIGHT", f, "RIGHT", -6, 0)
	f.slotText:SetJustifyH("RIGHT")
	f.slotText:SetText("S" .. slot)

	-- Secure click-cast (left click defaults)
	f:SetAttribute("*type1", "spell")
	f:SetAttribute("*spell1", PRESCIENCE_SPELL_NAME)
	f:SetAttribute("checkselfcast", false)
	f:RegisterForClicks("AnyUp")

	-- QoL: right-click to target the stored unit (useful for verifying slots)
	f:SetAttribute("*type2", "target")

	-- Tooltip (debug/QoL): show what unit token this slot is pointing at.
	f:SetScript("OnEnter", function(self)
		if not GameTooltip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		local unit = self:GetAttribute("unit")
		if unit and UnitExists(unit) then
			GameTooltip:SetUnit(unit)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(("APF unit token: %s"):format(unit), 0.7, 0.7, 0.7)
		else
			GameTooltip:AddLine("Empty slot", 0.8, 0.8, 0.8)
		end
		GameTooltip:Show()
	end)
	f:SetScript("OnLeave", function()
		if GameTooltip then GameTooltip:Hide() end
	end)

	return f
end

function APF:Layout()
	if not self.holder then return end
	local db = self:DB()

	self.holder:SetSize(db.width, (db.height * 2) + db.spacing)
	self.holder:SetTemplate(db.transparent and "Transparent" or "Default")

	for i = 1, 2 do
		local f = self.frames[i]
		if f then
			f:SetSize(db.width, db.height)
			f:SetTemplate(db.transparent and "Transparent" or "Default")
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

function APF:SetSlotUnit(slot, unitToken)
	local db = self:DB()
	db.slotUnits[slot] = unitToken
end

function APF:UpdateSecureUnitAttributes()
	if InCombatLockdown() then
		pendingSecureUpdate = true
		return
	end

	for slot = 1, 2 do
		local unit = self:DB().slotUnits[slot]
		local f = self.frames[slot]
		if unit and UnitExists(unit) then
			f:SetAttribute("unit", unit)
			-- Ensure secure actions explicitly use this unit.
			f:SetAttribute("*unit1", unit) -- left click (spell)
			f:SetAttribute("*unit2", unit) -- right click (target)
		else
			f:SetAttribute("unit", nil)
			f:SetAttribute("*unit1", nil)
			f:SetAttribute("*unit2", nil)
		end
	end

	pendingSecureUpdate = false
end

function APF:UpdateVisuals()
	for slot = 1, 2 do
		local unit = self:DB().slotUnits[slot]
		local f = self.frames[slot]

		local name = unitDisplayName(unit)
		local pct = getHealthPct(unit)
		local r, g, b = unitColor(unit)

		f.nameText:SetText(name)
		f.hp:SetValue(pct)
		f.hp:SetStatusBarColor(r, g, b, 0.9)
	end
end

function APF:RefreshEnabledState()
	local db = self:DB()
	local shouldShow = db.enabled and isAugEvoker() and spellKnown(PRESCIENCE_SPELL_ID)

	-- Secure frames can't be shown/hidden safely in combat.
	-- Instead, we keep them shown and "soft disable" via alpha + mouse.
	if InCombatLockdown() then
		pendingVisibilityUpdate = true
		return
	end

	local anyVisible = false
	for i = 1, 2 do
		local f = self.frames[i]
		local unit = self:DB().slotUnits[i]
		local showThis = shouldShow and unit and UnitExists(unit)
		f:SetAlpha(showThis and 1 or 0)
		f:EnableMouse(showThis)
		anyVisible = anyVisible or showThis
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

function APF:AddSlot(slot)
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
			width = { order = 3, type = "range", name = "Width", min = 80, max = 400, step = 1 },
			height = { order = 4, type = "range", name = "Height", min = 16, max = 60, step = 1 },
			spacing = { order = 5, type = "range", name = "Spacing", min = 0, max = 40, step = 1 },
			clear = {
				order = 6,
				type = "execute",
				name = "Clear Slots",
				func = function() self:ClearSlots() end,
			},
			desc = {
				order = 7,
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
end

function APF:InitializeModule()
	if self.initialized then return end
	self.initialized = true

	self:CreateHolder()
	self.frames[1] = self:CreateSlotFrame(1)
	self.frames[2] = self:CreateSlotFrame(2)
	self:Layout()

	self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", "OnEventRefresh")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEventRefresh")
	self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnEventRefresh")
	self:RegisterEvent("UNIT_CONNECTION", "OnEventRefresh")
	self:RegisterEvent("UNIT_NAME_UPDATE", "OnEventRefresh")
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
	if pendingSecureUpdate then
		self:UpdateSecureUnitAttributes()
	end

	if pendingVisibilityUpdate then
		pendingVisibilityUpdate = false
		self:RefreshEnabledState()
	end

	self:UpdateVisuals()
end

function APF:OnEventRefresh()
	self:RefreshEnabledState()
	self:UpdateSecureUnitAttributes()
	self:UpdateVisuals()
end

E:RegisterModule(APF:GetName())
