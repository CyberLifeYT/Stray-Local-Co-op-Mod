-- Adds a "LOCAL CO-OP: ON/OFF" button to Stray's main menu (UMG_MainMenu_C), above Quit.
-- Layout (from the widget dump): Canvas > ... > ButtonVBox (VerticalBox) holding StartButton, OptionsButton,
-- CreditsButton, QuitButton, each a BP_HKButton_C with a TextBlock child.
local menu = {}

local coopButton = nil
local coopLabel = nil

-- Run fn, logging (once per label) if it fails, so menu styling problems show up in UE4SS.log.
local reported = {}
local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok and not reported[label] then
        reported[label] = true
        print(string.format("[StrayCoop] Menu: %s failed: %s\n", label, tostring(err)))
    end
    return ok
end

local function toText(s)
    local ok, t = pcall(function() return FText(s) end)
    if ok and t then return t end
    -- Fallback for UE4SS builds without the FText constructor.
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return lib:Conv_StringToText(s)
end

local labelMarked = false        -- true while selected by keyboard/controller
local currentEnabled = function() return false end

local function setLabel(enabled)
    if coopLabel and coopLabel:IsValid() then
        local s = enabled and "LOCAL CO-OP: ON" or "LOCAL CO-OP: OFF"
        if labelMarked then s = "> " .. s .. " <" end
        local ok, err = pcall(function()
            coopLabel:SetText(toText(s))
        end)
        if not ok then print("[StrayCoop] Menu: could not set label: " .. tostring(err) .. "\n") end
    end
end

-- Selection: Stray links its menu buttons with explicit up/down navigation and highlights the focused one.
-- Splice our button into that chain (Credits -> Co-op -> Quit), make it take focus when hovered, and swap
-- its label to Stray's selected text colour while it is hovered or focused.
local EUINavigation_Up, EUINavigation_Down = 2, 3
local normalTextColor, selectedTextColor = nil, nil
local wasSelected = nil

local function linkNavigation(m, btn)
    local credits, quit = m.CreditsButton, m.QuitButton
    try("nav credits->coop", function() credits:SetNavigationRuleExplicit(EUINavigation_Down, btn) end)
    try("nav coop->credits", function() btn:SetNavigationRuleExplicit(EUINavigation_Up, credits) end)
    try("nav coop->quit", function() btn:SetNavigationRuleExplicit(EUINavigation_Down, quit) end)
    try("nav quit->coop", function() quit:SetNavigationRuleExplicit(EUINavigation_Up, btn) end)
end

-- TextBlock:SetColorAndOpacity takes an FSlateColor, which UE4SS can't build from a Lua table (the text
-- turned invisible). Instead tint the button's content via UButton:SetColorAndOpacity, which takes a plain
-- FLinearColor and multiplies the label: white text x black = black text on the white hover box.
local function captureColors(options)
    normalTextColor = { R = 1, G = 1, B = 1, A = 1 }
    selectedTextColor = { R = 0, G = 0, B = 0, A = 1 }
end

local function updateSelection()
    if not (coopButton and coopButton:IsValid() and coopLabel and coopLabel:IsValid()) then return end
    local hovered, focused = coopButton:IsHovered(), coopButton:HasKeyboardFocus()
    if hovered and not focused then
        coopButton:SetKeyboardFocus()
        focused = true
    end
    -- "hover": white box drawn (mouse) -> dark text. "focus": selected by keyboard/controller, where the
    -- hover box isn't drawn -> keep white text and mark it with > <. "none": normal.
    local state = hovered and "hover" or (focused and "focus" or "none")
    if state ~= wasSelected then
        local wasHover = wasSelected == "hover"
        wasSelected = state
        -- Only recolour when entering or leaving hover; never on the first check.
        local c = (state == "hover" and selectedTextColor) or (wasHover and normalTextColor) or nil
        if c then
            try("content tint", function() coopButton:SetColorAndOpacity(c) end)
        end
        labelMarked = state == "focus"
        setLabel(currentEnabled())
    end
end

local function isPatched(m)
    return coopButton and coopButton:IsValid() and coopButton:GetOuter():GetAddress() == m.WidgetTree:GetAddress()
end

-- Copy layout between slots as plain Lua tables (passing UE4SS struct wrappers straight through doesn't work).
-- Stray's buttons use Fill sizing; a slot left at the default Auto squeezes the Fill ones.
local function copyBoxSlot(from, to)
    if not (from and from:IsValid() and to and to:IsValid()) then return end
    try("slot padding", function()
        local p = from.Padding
        to:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
    end)
    try("slot size", function()
        local s = from.Size
        to:SetSize({ SizeRule = s.SizeRule, Value = s.Value })
    end)
    try("slot halign", function() to:SetHorizontalAlignment(from.HorizontalAlignment) end)
    try("slot valign", function() to:SetVerticalAlignment(from.VerticalAlignment) end)
end

-- Copy the button's look (brushes for normal/hovered/pressed etc.) from Options.
local function copyButtonStyle(from, to)
    if try("SetStyle", function() to:SetStyle(from.WidgetStyle) end) then return end
    if try("WidgetStyle assign", function() to.WidgetStyle = from.WidgetStyle end) then return end
    for _, field in ipairs({ "Normal", "Hovered", "Pressed", "Disabled", "NormalPadding", "PressedPadding" }) do
        try("WidgetStyle." .. field, function() to.WidgetStyle[field] = from.WidgetStyle[field] end)
    end
end

local function patchMenu(m, log, isEnabled)
    local options, quit = m.OptionsButton, m.QuitButton
    if not (options:IsValid() and quit:IsValid()) then log("Menu: buttons not found.") return false end
    local vbox = options:GetParent()
    if not (vbox and vbox:IsValid()) then log("Menu: button box not found.") return false end
    local optionsText = options:GetChildAt(0)
    local tree = m.WidgetTree

    -- Preferred: construct the button with Options as its template. Panel slots and their content are
    -- instanced subobjects, so this should deep-copy the button *and* its label with the exact look.
    -- Verify the label really is a new object: if it were shared with Options, using it would rip the
    -- label out of the Options button.
    local okT, tbtn = pcall(StaticConstructObject, options:GetClass(), tree, FName("CoopButton"), 0, 0, false, false, options)
    if okT and tbtn and tbtn:IsValid() then
        local child = tbtn:GetChildAt(0)
        local ownLabel = child and child:IsValid() and optionsText and optionsText:IsValid()
            and child:GetAddress() ~= optionsText:GetAddress()
            and child:GetParent():GetAddress() == tbtn:GetAddress()
        if ownLabel then
            pcall(function() tbtn.Slot = nil end)
            coopLabel = child
            local optionsSlot = options.Slot
            vbox:RemoveChild(quit)
            copyBoxSlot(optionsSlot, vbox:AddChild(tbtn))
            copyBoxSlot(optionsSlot, vbox:AddChild(quit))
            coopButton = tbtn
            setLabel(isEnabled())
            log("Menu: added Local Co-op button (copied from Options).")
            return true
        end
        -- The copy got Options' exact look (style, highlight) but its slot still points at the Options label.
        -- If the slot object itself is the copy's own, detach the shared label from it, restore the label's
        -- link to Options' slot (RemoveChildAt clears it), and give the copy a fresh label instead.
        local okFix, fixed = pcall(function()
            -- TArray elements may come back wrapped (RemoteUnrealParam) or as the object itself.
            local function first(arr)
                local v = arr[1]
                local ok, inner = pcall(function() return v:get() end)
                if ok and inner and inner.IsValid then return inner end
                return v
            end
            local tSlot, oSlot = first(tbtn.Slots), first(options.Slots)
            if not (tSlot:IsValid() and oSlot:IsValid()) or tSlot:GetAddress() == oSlot:GetAddress() then
                return false
            end
            local labelSlot = optionsText.Slot
            tbtn:RemoveChildAt(0)
            optionsText.Slot = labelSlot
            if options:GetChildAt(0):GetAddress() ~= optionsText:GetAddress()
                or optionsText:GetParent():GetAddress() ~= options:GetAddress() then
                log("Menu: Options label check failed after detach.")
                return false
            end
            local text = StaticConstructObject(optionsText:GetClass(), tree, FName("CoopButtonText"), 0, 0, false, false, optionsText)
            pcall(function() text.Slot = nil end)
            copyBoxSlot(labelSlot, tbtn:AddChild(text))
            coopLabel = text
            return true
        end)
        if okFix and fixed then
            pcall(function() tbtn.Slot = nil end)
            local optionsSlot = options.Slot
            vbox:RemoveChild(quit)
            copyBoxSlot(optionsSlot, vbox:AddChild(tbtn))
            copyBoxSlot(optionsSlot, vbox:AddChild(quit))
            coopButton = tbtn
            setLabel(isEnabled())
            linkNavigation(m, tbtn)
            captureColors(options)
            wasSelected = nil
            log("Menu: added Local Co-op button (copied from Options, new label).")
            return true
        end
        log("Menu: template copy shares the Options label (%s); using the manual method.", okFix and "shared slot" or tostring(fixed))
    else
        log("Menu: template copy failed (%s); using the manual method.", tostring(tbtn))
    end

    -- Fallback: plain new button with Options' properties copied over.
    local btn = StaticConstructObject(options:GetClass(), tree, FName("CoopButtonManual"), 0, 0, false, false, nil)
    if not (btn and btn:IsValid()) then log("Menu: could not create button.") return false end
    copyButtonStyle(options, btn)
    for _, prop in ipairs({ "m_onSelectedSound", "m_onPressedSound", "m_onHoveredAlpha",
                            "m_changeAlphaOnHovered", "m_changeTextColorOnSelected", "IsFocusable" }) do
        try("copy " .. prop, function() btn[prop] = options[prop] end)
    end
    -- Colour structs as plain tables.
    for _, prop in ipairs({ "SelectedTextColor", "ColorAndOpacity" }) do
        try("copy " .. prop, function()
            local c = options[prop]
            btn[prop] = { R = c.R, G = c.G, B = c.B, A = c.A }
        end)
    end
    -- The style copy doesn't work in this UE4SS build, leaving the engine's grey default brush;
    -- make the button background fully transparent so only the label shows.
    try("SetBackgroundColor", function() btn:SetBackgroundColor({ R = 1, G = 1, B = 1, A = 0 }) end)

    -- Label, copied from the Options label (font, colour, justification). Clear the copied Slot pointer
    -- first, otherwise AddChild would detach the Options label from its own button.
    if optionsText and optionsText:IsValid() then
        local text = StaticConstructObject(optionsText:GetClass(), tree, FName("CoopButtonText"), 0, 0, false, false, optionsText)
        if text and text:IsValid() then
            pcall(function() text.Slot = nil end)
            local slot = btn:AddChild(text)
            copyBoxSlot(optionsText.Slot, slot)
            coopLabel = text
        end
    end

    -- Insert above Quit: take Quit out, add ours, put Quit back; both get Options' slot layout.
    local optionsSlot = options.Slot
    vbox:RemoveChild(quit)
    copyBoxSlot(optionsSlot, vbox:AddChild(btn))
    copyBoxSlot(optionsSlot, vbox:AddChild(quit))

    coopButton = btn
    setLabel(isEnabled())
    linkNavigation(m, btn)
    captureColors(options)
    wasSelected = nil
    log("Menu: added Local Co-op button (manual).")
    return true
end

-- isEnabled(): current co-op state. toggle(): flips it and returns the new state.
function menu.install(log, isEnabled, toggle)
    currentEnabled = isEnabled

    -- Hover/focus visuals, 10x per second (no object scans; only touches our own button).
    LoopAsync(100, function()
        if coopButton then
            ExecuteInGameThread(function()
                local ok, e = pcall(updateSelection)
                if not ok then log("Menu: selection update error: %s", tostring(e)) end
            end)
        end
        return false
    end)

    -- Clicks: UHKButton routes OnClicked to its own _OnClicked; react when it is our button.
    local okHook, err = pcall(RegisterHook, "/Script/Hk_project.HKButton:_OnClicked", function(ctx)
        local b = ctx:get()
        if coopButton and coopButton:IsValid() and b:GetAddress() == coopButton:GetAddress() then
            setLabel(toggle())
        end
    end)
    if not okHook then log("Menu: click hook failed: %s", tostring(err)) end

    -- The menu widget is created whenever the title screen opens, so poll for new instances.
    local failures = 0
    LoopAsync(1000, function()
        ExecuteInGameThread(function()
            local m = FindFirstOf("UMG_MainMenu_C")
            if not (m and m:IsValid() and m:IsInViewport()) then return end
            if isPatched(m) then
                setLabel(isEnabled())
            elseif failures < 3 then
                local ok, e = pcall(patchMenu, m, log, isEnabled)
                if not ok or not e then
                    failures = failures + 1
                    log("Menu: patch attempt %d failed: %s", failures, tostring(e))
                end
            end
        end)
        return false
    end)
end

return menu
