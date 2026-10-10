-- Makes Stray's enemies react to Player 2's cat, not only Player 1's.
--   Zurks:     each swarm leader (AZurgPawnLeader) caches one player cat in m_cachedPlayerCatPawn, and the
--              AZurgManager keeps one in m_catPawn. Point both at whichever cat is closest to the swarm.
--   Sentinels: ASentinel exposes SetLockOnTarget(actor). A Sentinel that is already locked on a cat switches
--              to the closer cat when it has line of sight to it; a patrolling one locks onto Player 2 when
--              Player 2 is close, in front of it and in line of sight.
-- Enemies are looked up fresh every call (never cached): Stray destroys them on level loads and reloads.
local ai = {}

local SENTINEL_NOTICE_RANGE = 1000   -- uu (~10 m): patrolling Sentinels notice P2 within this range...
local SENTINEL_NOTICE_COS = 0.5      -- ...and within ~60 degrees of where they face
local SENTINEL_SIGHT_RANGE = 3000    -- uu: max distance for switching a chasing Sentinel's target
local ECC_Visibility = 3

local log = print

local function dist2(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return dx * dx + dy * dy + dz * dz
end

local function loc(actor)
    local l = actor:K2_GetActorLocation()
    return { X = l.X, Y = l.Y, Z = l.Z }
end

local function closerCat(pos, cat1, cat2)
    return dist2(pos, loc(cat1)) <= dist2(pos, loc(cat2)) and cat1 or cat2
end

-- Line of sight from a Sentinel to a cat, using the Sentinel's own vision check (traces past obstacles).
local function canSee(sentinel, cat, maxDist)
    local s, c = loc(sentinel), loc(cat)
    local dir = { X = c.X - s.X, Y = c.Y - s.Y, Z = c.Z - s.Z }
    local ok, seen = pcall(function()
        return sentinel:IsActorInVision(cat, dir, 45, maxDist, ECC_Visibility, false)
    end)
    return ok and seen
end

local retargeted = {} -- leader/sentinel name -> last cat name we pointed it at, for change-only logging

local function note(who, cat)
    local w, c = who:GetFName():ToString(), cat:GetFName():ToString()
    if retargeted[w] ~= c then
        retargeted[w] = c
        log("AI: %s now targets %s", w, c)
    end
end

-- Only the swarm leaders' cached cat is retargeted. AZurgManager.m_catPawn is deliberately left on Player 1:
-- it's the game-wide "player cat" that other systems (chase cameras, pursuit state) read, and pointing it at
-- Player 2 crashed the game in the camera code after the first Zurk chase.
local function updateZurks(cat1, cat2)
    local leaders = FindAllOf("ZurgPawnLeader")
    if not leaders then return end
    for _, leader in pairs(leaders) do
        if leader:IsValid() and leader.m_cachedPlayerCatPawn:IsValid() then
            local target = closerCat(loc(leader), cat1, cat2)
            if leader.m_cachedPlayerCatPawn:GetAddress() ~= target:GetAddress() then
                leader.m_cachedPlayerCatPawn = target
                note(leader, target)
            end
        end
    end
end

-- Put every swarm back on Player 1 (used when enemy targeting is switched off).
function ai.reset(cat1)
    pcall(function()
        for _, leader in pairs(FindAllOf("ZurgPawnLeader") or {}) do
            if leader:IsValid() and leader.m_cachedPlayerCatPawn:IsValid()
                and leader.m_cachedPlayerCatPawn:GetAddress() ~= cat1:GetAddress() then
                leader.m_cachedPlayerCatPawn = cat1
            end
        end
    end)
end

local function updateSentinels(cat1, cat2)
    local sentinels = FindAllOf("Sentinel")
    if not sentinels then return end
    local addr1, addr2 = cat1:GetAddress(), cat2:GetAddress()
    for _, s in pairs(sentinels) do
        if s:IsValid() then
            local locked = s:GetLockedTargetActor()
            local lockedAddr = locked and locked:IsValid() and locked:GetAddress() or nil
            local sp = loc(s)
            if lockedAddr == addr1 or lockedAddr == addr2 then
                -- Chasing a cat: switch to the closer one if it can see it.
                local target = closerCat(sp, cat1, cat2)
                if target:GetAddress() ~= lockedAddr and canSee(s, target, SENTINEL_SIGHT_RANGE) then
                    s:SetLockOnTarget(target)
                    note(s, target)
                end
            elseif not lockedAddr then
                -- Patrolling: notice P2 if it's close, in front and visible. (P1 is handled by the game.)
                local cp = loc(cat2)
                local d2 = dist2(sp, cp)
                if d2 < SENTINEL_NOTICE_RANGE * SENTINEL_NOTICE_RANGE and d2 > 1 then
                    local f = s:GetActorForwardVector()
                    local d = math.sqrt(d2)
                    local cos = (f.X * (cp.X - sp.X) + f.Y * (cp.Y - sp.Y) + f.Z * (cp.Z - sp.Z)) / d
                    if cos > SENTINEL_NOTICE_COS and canSee(s, cat2, SENTINEL_NOTICE_RANGE) then
                        s:SetLockOnTarget(cat2)
                        note(s, cat2)
                    end
                end
            end
        end
    end
end

function ai.setLogger(fn) log = fn end

local reportedErrors = {}
local function run(label, fn, cat1, cat2)
    local ok, err = pcall(fn, cat1, cat2)
    if not ok and not reportedErrors[label] then
        reportedErrors[label] = true
        log("AI: %s error (reported once): %s", label, tostring(err))
    end
end

-- Call on the game thread with both players' cats (valid BP_CatPawn_C pawns).
function ai.update(cat1, cat2)
    run("zurk", updateZurks, cat1, cat2)
    run("sentinel", updateSentinels, cat1, cat2)
end

return ai
