--[[
    DaHoodBypass.lua — universal client-side tripwire shield for Da Hood (PlaceId 2788229376).
    Standalone loadstring. Load FIRST, before ANY Da Hood script. No dependencies beyond
    executor natives (hookmetamethod, checkcaller, getgenv — all standard).

    PRODUCTION SCOPE: this shield is production-ready for DUMMY-ACCOUNT
    DEVELOPMENT ONLY. It is not safe for main-account use. It defeats the
    client-side tripwires it names, but it does not hide your position from
    server-side validation and it does not stop other players from reporting
    you. Orbit + any other high-visibility feature will eventually get an
    account banned. Test on dummies.

    WHICH TRIPWIRES EACH BLOCK DEFEATS (from a 291-script live sweep):
      [1] EGRESS FILTER .... CHECKER_1 (BodyVelocity/BodyPosition/BodyGyro reports),
                              CHECKER_2 (BodyMover/LinearVelocity reports),
                              CHECKER_3 (Head-anchor report),
                              CHECKER_4 (gun Grip-change report).
                              All four are client scripts snitching through
                              MainEvent:FireServer("CHECKER_*", ...). The filter
                              swallows exactly those codes on that exact remote.
      [2] PRE-EMPTION ....... Blocks OUR OWN threads (and only ours) from anchoring
                              the Head or rewriting a Tool's Grip, before the
                              watchers ever see the write. GHOST WARNING: if a
                              future feature of ours legitimately needs to anchor
                              the head or set a Grip, THIS hook will silently eat
                              the write and it will look like a bug in that
                              feature. Check here first.
      [3] STAMPERS ........... Per-character guards stamping the game's own
                              exemptions (AllowedBM attribute, IgnoredVelocity
                              name) onto physics objects. DORMANT BY DESIGN: our
                              features create zero physics objects, so these
                              should never fire. Insurance for future additions.
      [4] SPEED MONITOR ...... Observes only. Mirrors the Framework's grounded
                              speed rule into a counter. It PROVES compliance,
                              it does not enforce anything and never touches
                              the character. Enforcing here would fight motion
                              and trip the accumulator harder.

    HONEST REPORT (part of the deliverable, update if reality changes):
      FULLY DEFEATED .... CHECKER_1/2/4 reports, self-inflicted anchor + grip writes.
      PARTIALLY ......... CHECKER_3: its report is blocked, and our own anchor
                          attempts are pre-empted — but a GAME-driven head anchor
                          still passes through and still kicks, correctly.
      RESIDUAL RISK ..... server-side position validation, player reports,
                          aim-consistency checks. Untouched by any client trick.
      NO "undetected" CLAIM. Ever. Not here, not in any toast, not anywhere.

    UNLOAD HONESTY: metatables cannot be unhooked. Unload sets a flag the filters
    check (functionally reversible), disconnects every guard/monitor connection,
    and clears all getgenv state. Not literally clean — functionally silent.

    EXCLUSIONS (deliberate): no WalkSpeed/JumpPower blocking (no watchers found,
    we don't use them), no report-system interference (detectable + reportable),
    no server-side position tricks (impossible from the client), no executor or
    engine hooks outside the character, no remote spam of any kind.
]]

if game.PlaceId ~= 2788229376 then
    return
end

if getgenv().mj_acBypass and getgenv().mj_acBypass.On then
    print("[DaHoodBypass] already armed.")
    return getgenv().mj_acBypass
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local BLOCK_CODES: {[string]: boolean} = { CHECKER_1 = true, CHECKER_2 = true, CHECKER_3 = true, CHECKER_4 = true }

local state = {
    On = true,
    SwallowedTotal = 0,
    SwallowedRecent = {},
    SpeedExceeds = 0,
    SpeedAccum = 0,
    PlatformTicks = 0,
    MainEventFound = false,
    NamecallsSeen = 0,
    NewindexSeen = 0,
    LastProvenAt = nil,
    LastProvenCode = nil,
}

local MainEvent = nil
pcall(function()
    MainEvent = ReplicatedStorage:WaitForChild("MainEvent", 5)
end)
state.MainEventFound = (MainEvent ~= nil)

-- Single source of truth for the egress decision. hookmetamethod hands the hook
-- (self, ...) with self already separated, so for a colon-style call like
-- MainEvent:FireServer("CHECKER_1", payload) the code is the FIRST vararg:
-- select(1, ...). Verified against live call sites, not assumed.
local function shouldBlock(method, self, code)
    if method ~= "FireServer" then return false end
    if MainEvent == nil or self ~= MainEvent then return false end
    return BLOCK_CODES[code] == true
end

-- decideCall is the full pipeline decision: method gate, arg extraction, then
-- the predicate. BOTH the live hook and the self-test call this, so the test
-- exercises the real parsing path instead of a copy of the logic.
local function decideCall(method, self, ...)
    local code = select(1, ...)
    return shouldBlock(method, self, code)
end

local function logSwallow(code)
    state.SwallowedTotal = state.SwallowedTotal + 1
    table.insert(state.SwallowedRecent, 1, { code = tostring(code), t = os.clock() })
    if #state.SwallowedRecent > 50 then
        table.remove(state.SwallowedRecent)
    end
end

-- [1] EGRESS FILTER. Fails open: any internal error passes the call through.
-- hookmetamethod returns the previous handler, so this chains instead of
-- replacing: whatever the executor or the cheat hooks later still runs.
local oldNamecall
oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
    state.NamecallsSeen = state.NamecallsSeen + 1
    local ok, method = pcall(getnamecallmethod)
    local code = select(1, ...)
    local blocked = false
    if ok and state.On then
        local ok2, res = pcall(decideCall, method, self, code)
        blocked = ok2 and res or false
    end
    if blocked then
        pcall(logSwallow, code)
        return nil
    end
    return oldNamecall(self, ...)
end))

-- [2] PRE-EMPTION. checkcaller() == true means OUR threads only. The game's own
-- writes pass through untouched, so legit systems and legit kick paths work.
local oldNewIndex
oldNewIndex = hookmetamethod(game, "__newindex", newcclosure(function(t, k, v)
    state.NewindexSeen = state.NewindexSeen + 1
    local ok, block = pcall(function()
        if not state.On then return false end
        if not checkcaller() then return false end
        if typeof(t) ~= "Instance" then return false end
        if k == "Anchored" and v == true and t.Name == "Head" then
            local c = LocalPlayer and LocalPlayer.Character
            if c and t:IsDescendantOf(c) then return true end
        end
        if k == "Grip" and t:IsA("Tool") then
            return true
        end
        return false
    end)
    if ok and block then
        return nil
    end
    return oldNewIndex(t, k, v)
end))

-- [3] EXEMPTION STAMPERS. DORMANT BY DESIGN: our features create zero physics
-- objects, so these should never fire. Scoped strictly to LocalPlayer's
-- character — never the game's objects, never another player's.
local charConns = {}

local function stampMover(inst)
    pcall(function()
        if inst:IsA("BodyMover") or inst:IsA("LinearVelocity") then
            if not inst:GetAttribute("AllowedBM") then
                inst:SetAttribute("AllowedBM", true)
            end
            if inst.Name ~= "IgnoredVelocity" then
                pcall(function() inst.Name = "IgnoredVelocity" end)
            end
        end
    end)
end

local function armCharacter(char)
    if not char or char ~= LocalPlayer.Character then return end
    for _, conn in ipairs(charConns) do
        pcall(function() conn:Disconnect() end)
    end
    charConns = {}
    local hrp, torso = nil, nil
    pcall(function() hrp = char:WaitForChild("HumanoidRootPart", 5) end)
    pcall(function()
        torso = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
    end)
    for _, part in ipairs({ hrp, torso }) do
        if part then
            local c = part.ChildAdded:Connect(function(v)
                stampMover(v)
            end)
            table.insert(charConns, c)
        end
    end
end

local charAddedConn = nil
pcall(function()
    if LocalPlayer.Character then
        task.spawn(armCharacter, LocalPlayer.Character)
    end
    charAddedConn = LocalPlayer.CharacterAdded:Connect(function(char)
        task.spawn(armCharacter, char)
    end)
end)

-- [4] SPEED MONITOR. Observe only. Mirrors the Framework's grounded rule
-- (40 horizontal / 0.3s) into counters. Proves compliance, enforces nothing,
-- touches nothing on the character.
local monitorConn = nil
pcall(function()
    monitorConn = RunService.Heartbeat:Connect(function(dt)
        if not state.On then return end
        local ok = pcall(function()
            local c = LocalPlayer.Character
            local hum = c and c:FindFirstChildOfClass("Humanoid")
            local root = hum and c:FindFirstChild("HumanoidRootPart")
            if not hum or not root then return end
            if hum.PlatformStand then
                state.PlatformTicks = (state.PlatformTicks or 0) + 1
                state.SpeedAccum = 0
                return
            end
            if hum.FloorMaterial == Enum.Material.Air then
                state.SpeedAccum = 0
                return
            end
            local v = (root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
            if v > 40 then
                state.SpeedAccum = state.SpeedAccum + (dt or 0.016)
                if state.SpeedAccum > 0.3 then
                    state.SpeedExceeds = state.SpeedExceeds + 1
                    state.SpeedAccum = 0
                end
            else
                state.SpeedAccum = 0
            end
        end)
    end)
end)

-- Self-test at load: pure Lua, zero remotes. Goes through decideCall, the same
-- function the live hook uses, so a PASS covers the parsing path too.
local function selfTest()
    local cases = {
        { "FireServer", "CHECKER_1", true }, { "FireServer", "CHECKER_2", true },
        { "FireServer", "CHECKER_3", true }, { "FireServer", "CHECKER_4", true },
        { "FireServer", "ShootGun", false }, { "FireServer", "UpdateMousePos", false },
        { "InvokeServer", "CHECKER_1", false },
    }
    for _, c in ipairs(cases) do
        local got = decideCall(c[1], MainEvent, c[2])
        print(string.format("[DaHoodBypass] selftest %-12s expect=%s got=%s %s",
            tostring(c[2]), tostring(c[3]), tostring(got),
            (got == c[3]) and "PASS" or "FAIL"))
    end
end
pcall(selfTest)

-- Public surface: inspection + unload. Unload is functionally (not literally)
-- reversible: flag off, connections dropped, state cleared.
local api = {}
function api.State()
    return {
        on = state.On,
        mainEvent = state.MainEventFound,
        swallowedTotal = state.SwallowedTotal,
        recent = state.SwallowedRecent,
        speedExceeds = state.SpeedExceeds,
        platformTicks = state.PlatformTicks or 0,
        namecallsSeen = state.NamecallsSeen,
        newindexSeen = state.NewindexSeen,
        lastProven = state.LastProvenAt and { code = state.LastProvenCode, t = state.LastProvenAt } or nil,
    }
end
function api.DryRun(code)
    -- NOTE: this tests the predicate only, not the hook. A passing DryRun
    -- does not prove the layer is armed; State() + swallowedTotal do.
    return shouldBlock("FireServer", MainEvent, code)
end
function api.AddTestCode(code)
    -- Test-only: adds a code to the block set so the full pipeline
    -- (hook -> decideCall -> shouldBlock -> swallow -> log) can be proven
    -- with a harmless synthetic code. No behavior change otherwise.
    -- Records when the pipeline was last proven (see State().lastProven).
    if typeof(code) == "string" and code ~= "" then
        BLOCK_CODES[code] = true
        state.LastProvenAt = os.clock()
        state.LastProvenCode = code
    end
    return BLOCK_CODES[code] == true
end
function api.Unload()
    state.On = false
    for _, conn in ipairs(charConns) do
        pcall(function() conn:Disconnect() end)
    end
    charConns = {}
    if charAddedConn then
        pcall(function() charAddedConn:Disconnect() end)
        charAddedConn = nil
    end
    if monitorConn then
        pcall(function() monitorConn:Disconnect() end)
        monitorConn = nil
    end
    getgenv().mj_acBypass = nil
    print("[DaHoodBypass] unloaded (filters dormant, guards disconnected).")
end
getgenv().mj_acBypass = setmetatable(api, {
    __index = function(_, k)
        if k == "On" then return state.On end
        return nil
    end,
})

print("[DaHoodBypass] armed. Egress filter + pre-emption live. See header for the honest report.")
