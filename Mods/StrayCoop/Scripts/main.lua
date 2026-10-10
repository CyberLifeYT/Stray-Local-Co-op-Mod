-- StrayCoop: local split-screen co-op for Stray (UE 4.27) via UE4SS.
-- Player 1 = keyboard/mouse, Player 2 = first gamepad.
-- Keys:  F5 = toggle co-op on/off   F7 = bring Player 2 to Player 1   F8 = log diagnostics
local UEHelpers = require("UEHelpers")

------------------------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------------------------
local FOLLOW_DISTANCE = 3000   -- uu (~30 m). If P2 is further than this from P1, P2 is brought over.
local RESPAWN_DELAY = 3        -- seconds P2 may be without a cat before it is respawned.
local LOOP_MS = 1000           -- how often co-op state is checked.
local DEBUG_TRACE = false      -- true: log every game call while P2 is being created (slow, for crash hunting).
local STATE_FILE = "Mods/StrayCoop/coop_enabled.txt"

------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    print(string.format("[StrayCoop] " .. fmt .. "\n", ...))
end

local tracer = DEBUG_TRACE and require("tracer") or nil

local function loadEnabled()
    local f = io.open(STATE_FILE, "r")
    if not f then return false end
    local v = f:read("*l")
    f:close()
    return v == "1"
end

local function saveEnabled(v)
    local f = io.open(STATE_FILE, "w")
    if f then f:write(v and "1" or "0") f:close() end
end

local coopEnabled = loadEnabled()

-- Controllers by player index (1 = P1). Cached because the cutscene check runs 4x per second and
-- FindAllOf walks the whole object array; rescanned when a cached controller dies or every 2 s.
local cachedPcs, cachedAt = {}, -100

local function getControllers()
    local valid = next(cachedPcs) ~= nil
    for _, pc in pairs(cachedPcs) do
        if not (pc:IsValid() and pc.Player:IsValid()) then valid = false end
    end
    if valid and os.clock() - cachedAt < 2 then return cachedPcs end
    local list = {}
    for _, pc in pairs(FindAllOf("PlayerController") or {}) do
        if pc:IsValid() and pc.Player:IsValid() then
            list[pc.Player.ControllerId + 1] = pc
        end
    end
    cachedPcs, cachedAt = list, os.clock()
    return list
end

local function forgetControllers() cachedAt = -100 end

local inCutscene = false

local function isCat(pawn)
    return pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "BP_CatPawn_C"
end

local function enableSplitscreen()
    local settings = UEHelpers.GetGameMapsSettings()
    settings.bUseSplitscreen = true
    -- true: keyboard/mouse = P1, first gamepad = P2.
    settings.bOffsetPlayerGamepadIds = true
end

------------------------------------------------------------------------------------------------
-- Fix 1: Stray's CatPawn:_OnLargeInteractionColliderBeginOverlap assumes it never sees another player
-- pawn, so both cats' interaction colliders ignore the Pawn channel.
------------------------------------------------------------------------------------------------
local ECC_Pawn, ECR_Ignore = 2, 0
local patchedCats = {}

local function patchCatColliders(cat, label)
    if not (cat and cat:IsValid()) then return end
    local addr = cat:GetAddress()
    if patchedCats[addr] then return end
    local patched = {}
    local function visit(c)
        if c and c.IsValid and c:IsValid() and c:GetFName():ToString():find("Interaction") then
            c:SetCollisionResponseToChannel(ECC_Pawn, ECR_Ignore)
            table.insert(patched, c:GetFName():ToString())
        end
    end
    local okArr, comps = pcall(function()
        return cat:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.PrimitiveComponent"))
    end)
    if okArr and comps then
        -- UE4SS may hand back either a TArray wrapper or a plain Lua table.
        if type(comps) == "table" then
            for _, c in pairs(comps) do visit(c) end
        elseif comps.ForEach then
            comps:ForEach(function(_, elem) visit(elem:get()) end)
        end
    end
    if #patched == 0 then
        for _, c in pairs(FindAllOf("ShapeComponent") or {}) do
            local outer = c:IsValid() and c:GetOuter()
            if outer and outer:IsValid() and outer:GetAddress() == addr then visit(c) end
        end
    end
    patchedCats[addr] = true
    log("%s: interaction colliders ignore pawns (%s)", label, #patched > 0 and table.concat(patched, ", ") or "none found")
end

------------------------------------------------------------------------------------------------
-- Fix 2: AHKPlayerCameraManager::BeginPlay pushes a view target, and APlayerCameraManager::SetViewTarget
-- then reads PCOwner->Pawn. P1's camera manager is spawned before the world begins play, so its BeginPlay
-- waits until InitializeFor() has set PCOwner. P2's is spawned mid-game, so BeginPlay runs inside SpawnActor
-- while PCOwner is still null (crash: read 0x258 = Controller.Pawn). Set PCOwner as soon as it is constructed.
------------------------------------------------------------------------------------------------
local spawningP2 = false
local p2Controller = nil
local hooksInstalled = false

local function installHooks()
    if hooksInstalled then return end
    hooksInstalled = true
    pcall(NotifyOnNewObject, "/Game/Technical/BP_HKPlayerController.BP_HKPlayerController_C", function(pc)
        if spawningP2 then p2Controller = pc end
    end)
    pcall(NotifyOnNewObject, "/Game/Technical/BP_HKPlayerCameraManager.BP_HKPlayerCameraManager_C", function(cam)
        if spawningP2 and p2Controller and p2Controller:IsValid() then
            cam.PCOwner = p2Controller
        end
    end)
    pcall(RegisterHook, "/Game/Character/Cat/BP_CatPawn.BP_CatPawn_C:ReceiveBeginPlay", function(ctx)
        local cat = ctx:get()
        local p1 = getControllers()[1]
        if p1 and cat:IsValid() and cat:GetAddress() ~= p1.Pawn:GetAddress() then
            patchCatColliders(cat, "P2 cat")
        end
    end)
end

------------------------------------------------------------------------------------------------
-- Player 2 management (all functions below must run on the game thread)
------------------------------------------------------------------------------------------------
local function createP2(pcs)
    installHooks()
    enableSplitscreen()
    patchCatColliders(pcs[1].Pawn, "P1 cat")
    if tracer then tracer.install(log, pcs[1]) end
    log("Adding Player 2...")
    p2Controller = nil
    spawningP2 = true
    if tracer then tracer.active = true end
    local ok, newPc = pcall(function()
        return UEHelpers.GetGameplayStatics():CreatePlayer(pcs[1], 1, true)
    end)
    if tracer then tracer.active = false end
    spawningP2 = false
    if ok and newPc and newPc:IsValid() then
        log("Player 2 joined (%s).", isCat(newPc.Pawn) and "cat spawned" or "no cat yet")
    else
        log("Adding Player 2 failed: %s", tostring(newPc))
    end
end

local function removeP2()
    local pc2 = getControllers()[2]
    if pc2 then
        UEHelpers.GetGameplayStatics():RemovePlayer(pc2, true)
        forgetControllers()
        log("Player 2 removed.")
    end
end

local function bringP2ToP1(p1, p2)
    local loc = p1:K2_GetActorLocation()
    local fwd = p1:GetActorForwardVector()
    -- Drop P2 slightly behind and above P1 so the cats don't spawn inside each other.
    local target = { X = loc.X - fwd.X * 80, Y = loc.Y - fwd.Y * 80, Z = loc.Z + 40 }
    p2:K2_SetActorLocation(target, false, {}, true)
end

local function distance(a, b)
    local la, lb = a:K2_GetActorLocation(), b:K2_GetActorLocation()
    local dx, dy, dz = la.X - lb.X, la.Y - lb.Y, la.Z - lb.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local p2NoCatSince = nil

-- Called every LOOP_MS while co-op is enabled: join P2 once P1 is in gameplay, respawn P2's cat if it is
-- gone, and keep P2 near P1 (Stray teleports P1 during scripted moments and chapter changes).
local function tick()
    local pcs = getControllers()
    local p1 = pcs[1]
    if not (p1 and isCat(p1.Pawn)) then return end -- main menu, loading or cinematic
    patchCatColliders(p1.Pawn, "P1 cat")

    local p2 = pcs[2]
    if not p2 then
        createP2(pcs)
        forgetControllers()
        return
    end
    if inCutscene then return end

    if not isCat(p2.Pawn) then
        p2NoCatSince = p2NoCatSince or os.clock()
        if os.clock() - p2NoCatSince >= RESPAWN_DELAY then
            local gm = FindFirstOf("GameModeBase")
            if gm and gm:IsValid() then
                log("Player 2 has no cat; respawning.")
                gm:RestartPlayer(p2)
                if isCat(p2.Pawn) then bringP2ToP1(p1.Pawn, p2.Pawn) end
            end
            p2NoCatSince = nil
        end
        return
    end
    p2NoCatSince = nil

    if distance(p1.Pawn, p2.Pawn) > FOLLOW_DISTANCE then
        bringP2ToP1(p1.Pawn, p2.Pawn)
        log("Player 2 was too far away; brought to Player 1.")
    end
end

------------------------------------------------------------------------------------------------
-- Cutscenes: while P1's camera looks through a cinematic camera, show only P1's view (full screen),
-- hide P2's cat, and pause follow/respawn. Afterwards restore the split and bring P2 to P1.
------------------------------------------------------------------------------------------------
local lastViewTargetClass = nil

local function isCinematicView(p1)
    local ok, vt = pcall(function() return p1:GetViewTarget() end)
    if not (ok and vt and vt:IsValid()) then return false end
    local cls = vt:GetClass():GetFName():ToString()
    if cls ~= lastViewTargetClass then
        lastViewTargetClass = cls
        log("P1 camera now views through: %s", cls) -- helps refine the cutscene rule below
    end
    return cls:find("Cine") ~= nil or cls == "CameraActor" or not isCat(p1.Pawn)
end

-- Stray often places P1's cat a moment after the camera returns from a cutscene, so after a cutscene
-- P2 keeps being moved next to P1 for REGROUP_SECONDS.
local REGROUP_SECONDS = 3
local regroupUntil = 0
local regroupLogged = true

local function setCutscene(on, p1, p2)
    inCutscene = on
    UEHelpers.GetGameplayStatics():SetForceDisableSplitscreen(p1, on)
    if p2 and isCat(p2.Pawn) then
        p2.Pawn:SetActorHiddenInGame(on)
    end
    if not on then
        regroupUntil = os.clock() + REGROUP_SECONDS
        regroupLogged = false
    end
    log("Cutscene %s: split screen %s.", on and "started" or "ended", on and "off" or "on")
end

local function cutsceneTick()
    local pcs = getControllers()
    local p1, p2 = pcs[1], pcs[2]
    if not (p1 and p2) then
        if inCutscene and p1 then setCutscene(false, p1, nil) end
        return
    end
    local cine = isCinematicView(p1)
    if cine ~= inCutscene then setCutscene(cine, p1, p2) end
    if not inCutscene and os.clock() < regroupUntil and isCat(p1.Pawn) and isCat(p2.Pawn) then
        bringP2ToP1(p1.Pawn, p2.Pawn)
        if not regroupLogged then
            regroupLogged = true
            log("After cutscene: moving Player 2 to Player 1 for %d s.", REGROUP_SECONDS)
        end
    end
end

local cutsceneBusy = false
LoopAsync(250, function()
    if coopEnabled and not cutsceneBusy then
        cutsceneBusy = true
        ExecuteInGameThread(function()
            local ok, err = pcall(cutsceneTick)
            if not ok then log("cutscene check error: %s", tostring(err)) end
            cutsceneBusy = false
        end)
    end
    return false
end)

local busy = false
LoopAsync(LOOP_MS, function()
    if coopEnabled and not busy then
        busy = true
        ExecuteInGameThread(function()
            local ok, err = pcall(tick)
            if not ok then log("tick error: %s", tostring(err)) end
            busy = false
        end)
    end
    return false
end)

------------------------------------------------------------------------------------------------
-- Keys
------------------------------------------------------------------------------------------------
local function toggleCoop()
    coopEnabled = not coopEnabled
    saveEnabled(coopEnabled)
    log("Co-op %s.", coopEnabled and "ON (Player 2 joins on the controller)" or "OFF")
    if not coopEnabled then ExecuteInGameThread(removeP2) end
    return coopEnabled
end

RegisterKeyBind(Key.F5, toggleCoop)

require("menu").install(log, function() return coopEnabled end, toggleCoop)

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local pcs = getControllers()
        local p1, p2 = pcs[1] and pcs[1].Pawn, pcs[2] and pcs[2].Pawn
        if isCat(p1) and isCat(p2) then
            bringP2ToP1(p1, p2)
            log("Brought Player 2 to Player 1.")
        end
    end)
end)

RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function()
        log("Co-op enabled: %s", tostring(coopEnabled))
        for i, pc in pairs(getControllers()) do
            local pawn = pc.Pawn
            log("P%d controller=%s pawn=%s", i, pc:GetFName():ToString(),
                (pawn and pawn:IsValid()) and pawn:GetFName():ToString() or "none")
        end
    end)
end)

log("Loaded. Co-op is %s. F5 toggle co-op, F7 bring P2 to P1, F8 diagnostics.", coopEnabled and "ON" or "OFF")
