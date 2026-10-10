-- Adds StrayCoop's buttons ("LOCAL CO-OP: ON/OFF", controller layout) to Stray's main menu, above Quit.
-- Layout (from the widget dump): Canvas > ... > ButtonVBox (VerticalBox) holding StartButton, OptionsButton,
-- CreditsButton, QuitButton, each a BP_HKButton_C with a TextBlock child.
local menu = {}

local log = print
local specs = {} -- { name, label(), click(), btn, text, state }

-- Run fn, logging (once per label) if it fails, so menu problems show up in UE4SS.log.
local reported = {}
local function try(label, fn)
    local ok, err = pcall(fn)
    if not ok and not reported[label] then
        reported[label] = true
        log("Menu: %s failed: %s", label, tostring(err))
    end
    return ok
end

local function toText(s)
    local ok, t = pcall(function() return FText(s) end)
    if ok and t then return t end
    -- Fallback for UE4SS builds without the FText constructor.
    return StaticFindObject("/Script/Engine.Default__KismetTextLibrary"):Conv_StringToText(s)
end

-- Selected by keyboard/controller focus (no hover box drawn): mark the label with > <.
local function refreshLabel(spec)
    if not (spec.text and spec.text:IsValid()) then return end
    local s = spec.label()
    if spec.state == "focus" then s = "> " .. s .. " <" end
    try("set label", function() spec.text:SetText(toText(s)) end)
end

-- Copy slot layout as plain Lua tables (UE4SS struct wrappers can't be passed straight back in).
-- Stray's buttons use Fill sizing; a slot left at the default Auto squeezes the others.
local function copyBoxSlot(from, to)
    if not (from and from:IsValid() and to and to:IsValid()) then return end
    try("slot padding", function()
        local p = from.Padding
        to:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
    end)
    try("slot size", function() to:SetSize({ SizeRule = from.Size.SizeRule, Value = from.Size.Value }) end)
    try("slot halign", function() to:SetHorizontalAlignment(from.HorizontalAlignment) end)
    try("slot valign", function() to:SetVerticalAlignment(from.VerticalAlignment) end)
end

-- TArray elements may come back wrapped (RemoteUnrealParam) or as the object itself.
local function first(arr)
    local v = arr[1]
    local ok, inner = pcall(function() return v:get() end)
    if ok and inner and inner.IsValid then return inner end
    return v
end

-- Build a copy of the Options button with its own label. Constructing with Options as the template gives
-- the exact look (white hover box, sounds), but the copy's slot still holds the Options label. Detach that
-- label from the copy, restore its link to Options' slot (RemoveChildAt clears it), check Options is intact,
-- then give the copy a fresh label. Returns button, label or nil.
local function cloneOptions(tree, options, optionsText, name)
    local okT, btn = pcall(StaticConstructObject, options:GetClass(), tree, FName(name), 0, 0, false, false, options)
    if not (okT and btn and btn:IsValid()) then return nil end
    local child = btn:GetChildAt(0)
    if child and child:IsValid() and child:GetAddress() ~= optionsText:GetAddress() then
        return btn, child -- the label was already copied
    end
    local tSlot, oSlot = first(btn.Slots), first(options.Slots)
    if not (tSlot:IsValid() and oSlot:IsValid()) or tSlot:GetAddress() == oSlot:GetAddress() then
        log("Menu: %s copy shares Options' slot; not using it.", name)
        return nil
    end
    local labelSlot = optionsText.Slot
    btn:RemoveChildAt(0)
    optionsText.Slot = labelSlot
    if options:GetChildAt(0):GetAddress() ~= optionsText:GetAddress()
        or optionsText:GetParent():GetAddress() ~= options:GetAddress() then
        log("Menu: Options label check failed after detach.")
        return nil
    end
    local text = StaticConstructObject(optionsText:GetClass(), tree, FName(name .. "Text"), 0, 0, false, false, optionsText)
    pcall(function() text.Slot = nil end)
    copyBoxSlot(labelSlot, btn:AddChild(text))
    return btn, text
end

-- Our buttons live in the menu's WidgetTree under fixed names. If this menu instance already has them
-- (e.g. it was hidden while Settings was open), pick them up again instead of adding duplicates.
local function adoptExisting(m)
    local treePath = m.WidgetTree:GetFullName():gsub("^%S+%s+", "") -- drop the class name prefix
    for _, spec in ipairs(specs) do
        local b = StaticFindObject(treePath .. "." .. spec.name)
        if not (b and b:IsValid()) then return false end
        spec.btn, spec.text, spec.state = b, b:GetChildAt(0), nil
    end
    return true
end

local function isPatched(m)
    local b = specs[1] and specs[1].btn
    if b and b:IsValid() and b:GetOuter():GetAddress() == m.WidgetTree:GetAddress() then return true end
    return adoptExisting(m)
end

local function patchMenu(m)
    local options, quit = m.OptionsButton, m.QuitButton
    if not (options:IsValid() and quit:IsValid()) then log("Menu: buttons not found.") return false end
    local vbox = options:GetParent()
    local optionsText = options:GetChildAt(0)
    if not (vbox and vbox:IsValid() and optionsText and optionsText:IsValid()) then
        log("Menu: button box not found.") return false
    end
    local made = {}
    for _, spec in ipairs(specs) do
        local btn, text = cloneOptions(m.WidgetTree, options, optionsText, spec.name)
        if not btn then return false end
        pcall(function() btn.Slot = nil end)
        made[spec] = { btn, text }
    end
    -- Insert above Quit: take Quit out, add ours, put Quit back; all get Options' slot layout.
    local optionsSlot = options.Slot
    vbox:RemoveChild(quit)
    for _, spec in ipairs(specs) do
        spec.btn, spec.text = made[spec][1], made[spec][2]
        spec.state = nil
        copyBoxSlot(optionsSlot, vbox:AddChild(spec.btn))
        refreshLabel(spec)
    end
    copyBoxSlot(optionsSlot, vbox:AddChild(quit))
    log("Menu: added %d buttons.", #specs)
    return true
end

-- Hover: the button takes keyboard focus (so Stray's highlight leaves its own buttons), and the content is
-- tinted black for dark text on the white hover box. UButton:SetColorAndOpacity takes a plain FLinearColor;
-- TextBlock colours (FSlateColor) can't be built from Lua and turned the text invisible.
local BLACK, WHITE = { R = 0, G = 0, B = 0, A = 1 }, { R = 1, G = 1, B = 1, A = 1 }

local function updateSelection(spec)
    local btn = spec.btn
    if not (btn and btn:IsValid()) then return end
    local hovered, focused = btn:IsHovered(), btn:HasKeyboardFocus()
    if hovered and not focused then
        btn:SetKeyboardFocus()
        focused = true
    end
    local state = hovered and "hover" or (focused and "focus" or "none")
    if state ~= spec.state then
        local wasHover = spec.state == "hover"
        spec.state = state
        if state == "hover" then
            try("tint", function() btn:SetColorAndOpacity(BLACK) end)
        elseif wasHover then
            try("tint", function() btn:SetColorAndOpacity(WHITE) end)
        end
        refreshLabel(spec)
    end
end

-- buttonSpecs: list of { name = unique widget name, label = function() -> string, click = function() }.
function menu.install(logFn, buttonSpecs)
    log = logFn
    specs = buttonSpecs

    LoopAsync(100, function()
        if specs[1].btn then
            ExecuteInGameThread(function()
                for _, spec in ipairs(specs) do
                    local ok, e = pcall(updateSelection, spec)
                    if not ok then try("selection", function() error(e) end) end
                end
            end)
        end
        return false
    end)

    -- Clicks: UHKButton routes OnClicked to its own _OnClicked; react when it is one of ours.
    local okHook, err = pcall(RegisterHook, "/Script/Hk_project.HKButton:_OnClicked", function(ctx)
        local addr = ctx:get():GetAddress()
        for _, spec in ipairs(specs) do
            if spec.btn and spec.btn:IsValid() and spec.btn:GetAddress() == addr then
                spec.click()
                refreshLabel(spec)
            end
        end
    end)
    if not okHook then log("Menu: click hook failed: %s", tostring(err)) end

    -- Forget our buttons as soon as the menu is gone: the widgets get destroyed after it closes, and
    -- touching them afterwards crashes UE4SS. (RegisterLoadMapPreHook would be the natural place too, but
    -- in UE4SS 3.0.1 with Stray it throws inside the engine's LoadMap and crashes the game at startup.)
    local function forgetButtons()
        for _, spec in ipairs(specs) do spec.btn, spec.text, spec.state = nil, nil, nil end
    end

    -- The menu widget is created whenever the title screen opens, so poll for new instances.
    local failures = 0
    LoopAsync(1000, function()
        ExecuteInGameThread(function()
            local m = FindFirstOf("UMG_MainMenu_C")
            if not (m and m:IsValid() and m:IsInViewport()) then
                forgetButtons()
                return
            end
            if isPatched(m) then
                for _, spec in ipairs(specs) do refreshLabel(spec) end
            elseif failures < 3 then
                local ok, e = pcall(patchMenu, m)
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
