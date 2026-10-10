-- StrayCoop: local split-screen co-op for Stray (UE 4.27) via UE4SS.
-- Default: Player 1 = keyboard/mouse, Player 2 = controller 1 (see INPUT_MODES for the other layouts).
-- Keys:  F5 co-op on/off   F6 controller layout   F7 bring P2 to P1   F8 diagnostics   F9 enemies target P2 on/off
local UEHelpers = require("UEHelpers")

------------------------------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------------------------------
local FOLLOW_DISTANCE = 3000   -- uu (~30 m). If P2 is further than this from P1, P2 is brought over.
local RESPAWN_DELAY = 3        -- seconds P2 may be without a cat before it is respawned.
local LOOP_MS = 1000           -- how often co-op state is checked.
local DEBUG_TRACE = false      -- true: log every game call while P2 is being created (slow, for crash hunting).
local AI_TARGETS_P2 = true     -- Zurks and Sentinels go after whichever cat is closer (see ai.lua). F9 toggles.
local AI_FILE = "Mods/StrayCoop/ai_enabled.txt"
local STATE_FILE = "Mods/StrayCoop/coop_enabled.txt"
local INPUT_FILE = "Mods/StrayCoop/input_mode.txt"

-- Controller layouts. Unreal routes gamepad N to the local player whose ControllerId is N, or N+1 when
-- bOffsetPlayerGamepadIds is set. Keyboard/mouse always arrive as ControllerId 0.
local INPUT_MODES = {
    { label = "P1 KEYBOARD - P2 PAD 1", offset = true,  p1 = 0, p2 = 1 },
    { label = "P1 KEYBOARD - P2 PAD 2", offset = true,  p1 = 0, p2 = 2 },
    { label = "P1 PAD 1 - P2 PAD 2",    offset = false, p1 = 0, p2 = 1 }, -- keyboard also drives P1
    { label = "P1 PAD 2 - P2 PAD 1",    offset = false, p1 = 1, p2 = 0 }, -- keyboard also drives P2
}

------------------------------------------------------------------------------------------------
local function log(fmt, ...)
    print(string.format("[StrayCoop] " .. fmt .. "\n", ...))
end

local tracer = DEBUG_TRACE and require("tracer") or nil
local ai = AI_TARGETS_P2 and require("ai") or nil
if ai then ai.setLogger(function(fmt, ...) print(string.format("[StrayCoop] " .. fmt .. "\n", ...)) end) end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local v = f:read("*l")
    f:close()
    return v
end

local function writeFile(path, v)
    local f = io.open(path, "w")
    if f then f:write(v) f:close() end
end

local coopEnabled = readFile(STATE_FILE) == "1"
local aiEnabled = readFile(AI_FILE) ~= "0" -- on unless switched off with F9
local inputMode = tonumber(readFile(INPUT_FILE) or "") or 1
if not INPUT_MODES[inputMode] then inputMode = 1 end

-- Controllers by local player order (1 = P1), not by ControllerId: the controller layouts reassign IDs.
-- Never keep references to controllers, pawns or widgets between calls: Stray reloads the level when a cat
-- dies, and touching an object that was destroyed since crashes UE4SS. Only the GameInstance is kept; it
-- lives for the whole session. Controllers are read fresh from its LocalPlayers each time (cheap: no scan).
local gameInstance = nil

local function getControllers()
    if not (gameInstance and gameInstance:IsValid()) then gameInstance = FindFirstOf("GameInstance") end
    local list = {}
    if gameInstance and gameInstance:IsValid() then
        gameInstance.LocalPlayers:ForEach(function(i, elem)
            local lp = elem:get()
            local pc = lp:IsValid() and lp.PlayerController
            if pc and pc:IsValid() then list[i] = pc end
        end)
    end
    return list
end

local function forgetControllers() end -- nothing is cached any more

local inCutscene = false

local function isCat(pawn)
    return pawn and pawn:IsValid() and pawn:GetClass():GetFName():ToString() == "BP_CatPawn_C"
end

local function enableSplitscreen()
    local settings = UEHelpers.GetGameMapsSettings()
    settings.bUseSplitscreen = true
    settings.bOffsetPlayerGamepadIds = INPUT_MODES[inputMode].offset
end

-- Point P1 and P2 at the controllers of the current layout. SetPlayerControllerID swaps IDs when another
-- local player already has the requested one, so the order of the two calls doesn't matter.
local function applyInputMode()
    local mode = INPUT_MODES[inputMode]
    local pcs = getControllers()
    if not pcs[2] then return end -- solo play keeps normal input; the layout applies once P2 joins
    enableSplitscreen()
    local gs = UEHelpers.GetGameplayStatics()
    if pcs[1] then gs:SetPlayerControllerID(pcs[1], mode.p1) end
    if pcs[2] then gs:SetPlayerControllerID(pcs[2], mode.p2) end
end

------------------------------------------------------------------------------------------------
-- Fix 1: Stray's CatPawn:_OnLargeInteractionColliderBeginOverlap assumes it never sees another player
-- pawn, so both cats' interaction colliders ignore the Pawn channel.
------------------------------------------------------------------------------------------------
local ECC_Pawn, ECR_Ignore = 2, 0
local patchedCats = {}

local function patchCatColliders(cat, label)
    if not (cat and cat:IsValid()) then return end
    -- Key on address + object name: after a level reload a new cat can reuse an old cat's address.
    local addr = cat:GetAddress()
    local key = tostring(addr) .. ":" .. cat:GetFName():ToString()
    if patchedCats[key] then return end
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
    patchedCats[key] = true
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
        -- -1 = next free controller ID; applyInputMode() then sets the IDs the chosen layout wants.
        return UEHelpers.GetGameplayStatics():CreatePlayer(pcs[1], -1, true)
    end)
    if tracer then tracer.active = false end
    spawningP2 = false
    if ok and newPc and newPc:IsValid() then
        forgetControllers()
        applyInputMode()
        log("Player 2 joined (%s), controllers: %s.", isCat(newPc.Pawn) and "cat spawned" or "no cat yet",
            INPUT_MODES[inputMode].label)
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
    -- Back to normal single-player input: keyboard and the first controller both drive P1.
    UEHelpers.GetGameMapsSettings().bOffsetPlayerGamepadIds = false
    local p1 = getControllers()[1]
    if p1 then UEHelpers.GetGameplayStatics():SetPlayerControllerID(p1, 0) end
end

-- K2_TeleportTo (unlike K2_SetActorLocation) goes through ACharacter::TeleportSucceeded, which tells the
-- cat's movement component it was teleported; otherwise Stray's CatMovementComponent snaps the cat back.
-- It also nudges the cat out of walls. Returns true if the teleport succeeded.
local function bringP2ToP1(p1, p2)
    local loc = p1:K2_GetActorLocation()
    local fwd = p1:GetActorForwardVector()
    local r = p1:K2_GetActorRotation()
    local rot = { Pitch = 0, Yaw = r.Yaw, Roll = 0 } -- plain table: UE4SS struct wrappers can't be passed back in
    -- Drop P2 slightly behind and above P1 so the cats don't land inside each other.
    local target = { X = loc.X - fwd.X * 80, Y = loc.Y - fwd.Y * 80, Z = loc.Z + 40 }
    if p2:K2_TeleportTo(target, rot) then return true end
    -- Spot behind P1 blocked: try right on top of P1.
    if p2:K2_TeleportTo({ X = loc.X, Y = loc.Y, Z = loc.Z + 60 }, rot) then return true end
    log("Teleport failed (no free spot near Player 1).")
    return false
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

    if distance(p1.Pawn, p2.Pawn) > FOLLOW_DISTANCE and bringP2ToP1(p1.Pawn, p2.Pawn) then
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

-- After a cutscene Stray often keeps moving P1's cat for a while (blend-out animations, placement), so
-- wait until P1 has stood still for REGROUP_STILL_TICKS checks (250 ms each), then bring P2 over, and
-- keep checking until P2 is actually next to P1. Gives up after REGROUP_TIMEOUT seconds.
local REGROUP_TIMEOUT = 15
local REGROUP_STILL_TICKS = 3
local REGROUP_NEAR = 400 -- uu: close enough to count as regrouped
local regroupUntil = 0
local regroupLastLoc = nil
local regroupStill = 0

local function setCutscene(on, p1, p2)
    inCutscene = on
    UEHelpers.GetGameplayStatics():SetForceDisableSplitscreen(p1, on)
    if p2 and isCat(p2.Pawn) then
        p2.Pawn:SetActorHiddenInGame(on)
    end
    if not on then
        regroupUntil = os.clock() + REGROUP_TIMEOUT
        regroupLastLoc, regroupStill = nil, 0
    end
    log("Cutscene %s: split screen %s.", on and "started" or "ended", on and "off" or "on")
end

local aiTick = 0

local function cutsceneTick()
    local pcs = getControllers()
    local p1, p2 = pcs[1], pcs[2]
    if not (p1 and p2) then
        if inCutscene and p1 then setCutscene(false, p1, nil) end
        return
    end
    local cine = isCinematicView(p1)
    if cine ~= inCutscene then setCutscene(cine, p1, p2) end

    -- Enemies: every other check (2x per second), outside cutscenes, when both cats exist.
    aiTick = aiTick + 1
    if ai and aiEnabled and not inCutscene and aiTick % 2 == 0 and isCat(p1.Pawn) and isCat(p2.Pawn) then
        ai.update(p1.Pawn, p2.Pawn)
    end
    if not inCutscene and os.clock() < regroupUntil and isCat(p1.Pawn) and isCat(p2.Pawn) then
        local loc = p1.Pawn:K2_GetActorLocation()
        local here = { X = loc.X, Y = loc.Y, Z = loc.Z }
        if regroupLastLoc then
            local dx, dy, dz = here.X - regroupLastLoc.X, here.Y - regroupLastLoc.Y, here.Z - regroupLastLoc.Z
            regroupStill = (dx * dx + dy * dy + dz * dz < 25) and regroupStill + 1 or 0
        end
        regroupLastLoc = here
        if regroupStill >= REGROUP_STILL_TICKS then
            if distance(p1.Pawn, p2.Pawn) <= REGROUP_NEAR then
                log("After cutscene: Player 2 is with Player 1.")
                regroupUntil = 0
            else
                bringP2ToP1(p1.Pawn, p2.Pawn)
            end
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
    writeFile(STATE_FILE, coopEnabled and "1" or "0")
    log("Co-op %s.", coopEnabled and "ON (Player 2 joins on the controller)" or "OFF")
    if not coopEnabled then ExecuteInGameThread(removeP2) end
end

local function nextInputMode()
    inputMode = inputMode % #INPUT_MODES + 1
    writeFile(INPUT_FILE, tostring(inputMode))
    log("Controllers: %s", INPUT_MODES[inputMode].label)
    ExecuteInGameThread(function()
        local ok, err = pcall(applyInputMode)
        if not ok then log("Could not apply controller layout: %s", tostring(err)) end
    end)
end

local function toggleAi()
    aiEnabled = not aiEnabled
    writeFile(AI_FILE, aiEnabled and "1" or "0")
    log("Enemies targeting Player 2: %s", aiEnabled and "ON" or "OFF")
    if not aiEnabled and ai then
        ExecuteInGameThread(function()
            local p1 = getControllers()[1]
            if p1 and isCat(p1.Pawn) then ai.reset(p1.Pawn) end
        end)
    end
end

RegisterKeyBind(Key.F5, toggleCoop)
RegisterKeyBind(Key.F6, nextInputMode)
RegisterKeyBind(Key.F9, toggleAi)

require("menu").install(log, {
    { name = "CoopButton",
      label = function() return coopEnabled and "LOCAL CO-OP: ON" or "LOCAL CO-OP: OFF" end,
      click = toggleCoop },
    { name = "ControllersButton",
      label = function() return INPUT_MODES[inputMode].label end,
      click = nextInputMode },
})

RegisterKeyBind(Key.F7, function()
    ExecuteInGameThread(function()
        local pcs = getControllers()
        local p1, p2 = pcs[1] and pcs[1].Pawn, pcs[2] and pcs[2].Pawn
        if not pcs[2] then
            log("F7: Player 2 isn't in the game.")
        elseif not (isCat(p1) and isCat(p2)) then
            log("F7: both players need a cat (P1: %s, P2: %s).",
                (p1 and p1:IsValid()) and p1:GetClass():GetFName():ToString() or "none",
                (p2 and p2:IsValid()) and p2:GetClass():GetFName():ToString() or "none")
        elseif bringP2ToP1(p1, p2) then
            log("Brought Player 2 to Player 1.")
        end
    end)
end)

RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function()
        log("Co-op enabled: %s, controllers: %s", tostring(coopEnabled), INPUT_MODES[inputMode].label)
        for i, pc in pairs(getControllers()) do
            local pawn = pc.Pawn
            log("P%d controller=%s controllerId=%d pawn=%s", i, pc:GetFName():ToString(), pc.Player.ControllerId,
                (pawn and pawn:IsValid()) and pawn:GetFName():ToString() or "none")
        end
    end)
end)

log("Loaded. Co-op is %s, controllers: %s, enemies target P2: %s. F5 co-op, F6 controllers, F7 bring P2 to P1, F8 diagnostics, F9 enemy targeting.",
    coopEnabled and "ON" or "OFF", INPUT_MODES[inputMode].label, aiEnabled and "ON" or "OFF")
