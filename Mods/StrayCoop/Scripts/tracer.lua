-- Debug-only crash tracer (enable with DEBUG_TRACE in main.lua). While `tracer.active` is true it logs every
-- game-side function call and every actor/component/widget spawn, so the last UE4SS.log line before a crash
-- names the culprit. Hooks ~650 functions, so it costs performance and is off by default.
local tracer = { active = false }
local installed = false

local function hookClassChain(log, obj, label)
    if not (obj and obj:IsValid()) then return 0 end
    local count = 0
    local class = obj:GetClass()
    while class and class:IsValid() do
        local className = class:GetFullName()
        if className:find("/Script/Engine%.") or className:find("/Script/CoreUObject%.") then break end
        class:ForEachFunction(function(fn)
            local path = fn:GetFullName():gsub("^%S+%s+", "")
            if not path:find("Tick") then
                local ok = pcall(RegisterHook, path, function(ctx, ...)
                    if not tracer.active then return end
                    local okSelf, self = pcall(function() return ctx:get() end)
                    local who = (okSelf and self and self:IsValid()) and self:GetFName():ToString() or "?"
                    local args = {}
                    for _, a in ipairs({ ... }) do
                        local okA, v = pcall(function() return a:get() end)
                        if okA and type(v) == "userdata" and v.IsValid then
                            table.insert(args, v:IsValid() and v:GetFName():ToString() or "null")
                        elseif okA then
                            table.insert(args, tostring(v))
                        end
                    end
                    log("TRACE %s %s on %s (%s)", label, path, who, table.concat(args, ", "))
                end)
                if ok then count = count + 1 end
            end
        end)
        class = class:GetSuperStruct()
    end
    return count
end

function tracer.install(log, p1Controller)
    if installed then return end
    installed = true
    local n = 0
    n = n + hookClassChain(log, FindFirstOf("GameModeBase"), "GameMode")
    n = n + hookClassChain(log, FindFirstOf("GameStateBase"), "GameState")
    n = n + hookClassChain(log, p1Controller, "P1Controller")
    n = n + hookClassChain(log, p1Controller.MyHUD, "HUD")
    n = n + hookClassChain(log, FindFirstOf("LevelScriptActor"), "LevelScript")
    n = n + hookClassChain(log, FindFirstOf("GameInstance"), "GameInstance")
    n = n + hookClassChain(log, p1Controller.Pawn, "Cat")
    n = n + hookClassChain(log, FindFirstOf("BP_AudioManager_C"), "AudioManager")
    n = n + hookClassChain(log, FindFirstOf("BP_CameraThirdPerson_C"), "CatCamera")
    for _, path in ipairs({
        "/Script/Engine.PlayerController:ClientRestart",
        "/Script/Engine.PlayerController:ClientSetHUD",
        "/Script/Engine.PlayerController:ClientSetViewTarget",
    }) do
        local ok = pcall(RegisterHook, path, function(ctx)
            if tracer.active then
                local who = ctx and ctx.get and ctx:get()
                log("TRACE engine %s on %s", path, (who and who:IsValid()) and who:GetFullName() or "?")
            end
        end)
        if ok then n = n + 1 end
    end
    for _, base in ipairs({ "/Script/Engine.Actor", "/Script/Engine.ActorComponent", "/Script/UMG.UserWidget" }) do
        pcall(NotifyOnNewObject, base, function(obj)
            if tracer.active then log("SPAWN %s", obj:GetClass():GetFullName()) end
        end)
    end
    log("Tracer hooked %d functions.", n)
end

return tracer
