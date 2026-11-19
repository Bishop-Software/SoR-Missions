-- Waxwork Abolishion: HP balance across the adds (MA), Rampage per wave (WAR/BER), and the
-- main tank's back-off once a wave is up.
local mq = require("mq")
local Core = require((...):match('^(.*)%.[^.]+$'))   -- the core: this module's parent

local W = {}
W.TASK  = "Waxwork Abolishion"
W.giver = 'Defense Unit CDL'

local def, flags, kill_order, State = Core.def, Core.flags, Core.kill_order, Core.state
local announce, announce_g, debug_local = Core.announce, Core.announce_g, Core.debug_local
local cwtn, ma_target = Core.cwtn, Core.ma_target

-- adds first (balanced while 2+ are up, see wax_balance_pick), Combuster in mission, Combustor in raid
kill_order[W.TASK] = {"Waxwork_Lancer","Waxwork_Igniter","Waxwork_Trapper","Waxwork_Combuster","Waxwork_Burster","Waxwork_Abolishion"}

-- Waxwork balance. The Abolishion despawns, its adds pop and go live after a delay, and
-- once the first add dies he reforms and the rest despawn soon after -- so the wave is
-- won by having them all low together, then finishing them fast. Two phases per wave:
--  * balance: until an add dies, keep their HP close by rotating over the healthiest:
--    polled from xtarget every pulse, the MA swaps off its current add onto the highest of
--    the rest (no engage() delays -- they drop quickly). Except when the highest leads the
--    next one down by SPREAD or more: then onto it and stay until the lead is under SPREAD.
--  * finish: once one has died, lowest HP first, to kill as many as possible before the
--    rest despawn.
-- The wave ends when no add is left on xtarget; a later wave starts in balance again.
-- The adds are the kill order's names other than the Abolishion itself.
-- With balance off, or under two adds before any has died, the normal kill order applies.
-- Tuned on a live run (2026-10-27): the adds drop 10-50 %/s, so a 500 ms poll with a 3%
-- margin left the group well behind.
local wax_st = {}
wax_st.SPREAD = 8     -- target spread, shown in the UI
wax_st.SWITCH_GAP = 800      -- ms between balance target switches, plus...
wax_st.SWITCH_JITTER = 350   -- ...a random 0..this ms
wax_st.spread = nil   -- current HP spread across the adds, for the UI (nil: not balancing)
wax_st.wave_max = 0   -- most adds seen live at once this wave
wax_st.finishing = false
W.st = wax_st

-- XTarget(i).Name() is the CLEAN name ('Waxwork Lancer'), the kill order uses the spawn
-- name ('Waxwork_Lancer'): compare with underscores turned into spaces on both sides.
local function is_wax_add(name)
    name = (name or ''):lower():gsub('_', ' ')
    if name:find('abolishion', 1, true) then return false end
    for _, n in ipairs(kill_order[W.TASK]) do
        if name:find((n:lower():gsub('_', ' ')), 1, true) then return true end
    end
    return false
end

-- The wave's live adds on our xtarget: {id, hp, name}.
local function wax_live_adds()
    local set = {}
    for i = 1, 20 do
        local xt = mq.TLO.Me.XTarget(i)
        local id = xt.ID() or 0
        -- Type NPC: a corpse sits on xtarget for a beat at its last HP (seen live 2026-11-06,
        -- "Balance: -> Waxwork Igniter's corpse 9%")
        if id ~= 0 and xt.TargetType() == 'Auto Hater' and xt.Type() == 'NPC' and is_wax_add(xt.Name())
                and Core.xt_sane(id) then
            local hp = xt.PctHPs()
            if hp and hp > 0 then set[#set + 1] = { id = id, hp = hp, name = xt.CleanName() } end
        end
    end
    return set
end

-- Warriors and berserkers: Rampage once per wave, as soon as the first add dies.
-- Every toon tracks its own wave (the balance state above is the MA's only); retried each
-- pulse until it fires or the wave ends, in case it was not ready yet.
-- By name, not ID.
local WAX_AA = "Rampage"
local wax_aa = { max = 0, fired = false }
local function check_wax_aa()
    if State.current_task ~= W.TASK then return end
    if def.class ~= 'WAR' and def.class ~= 'BER' then return end
    local n = #wax_live_adds()
    if n == 0 then wax_aa.max, wax_aa.fired = 0, false return end
    if n > wax_aa.max then wax_aa.max = n end
    if wax_aa.fired or n >= wax_aa.max then return end
    if mq.TLO.Me.AltAbilityReady(WAX_AA)() then
        wax_aa.fired = true
        mq.cmdf("/alt act %d", mq.TLO.Me.AltAbility(WAX_AA).ID() or 0)
        announce('Waxwork: an add died -- %s', WAX_AA)
    end
end

local wax_balance_decide   -- below: the pick itself

local function wax_balance_pick()
    -- At most once per Main cycle, whoever calls it (Main's pick, or the back-off hold
    -- that blocks Main): one shared clock, so the hold's last pick and Main's pick just
    -- after it cannot land back to back. Main's cycle is never shorter than def.pulse;
    -- the 50 ms keeps a normal cycle from being skipped. Between picks, stay put and give
    -- Main the last pick's answer, or it would run its own kill-order pick instead.
    local now = mq.gettime()
    if now < (wax_st.next_pick or 0) then return wax_st.last_result end
    wax_st.next_pick = now + def.pulse - 50
    wax_st.last_result = wax_balance_decide()
    return wax_st.last_result
end

wax_balance_decide = function()
    local set = wax_live_adds()
    if #set == 0 then   -- wave over (or not live yet): next wave starts in balance
        if wax_st.finishing then announce('Balance: wave over') end
        wax_st.wave_max, wax_st.finishing, wax_st.spread = 0, false, nil
        return false
    end
    if #set > wax_st.wave_max then wax_st.wave_max = #set end
    if not wax_st.finishing and #set < wax_st.wave_max then
        wax_st.finishing = true
        announce('Balance: an add died -- finishing the rest, lowest HP first')
    end
    local tid = mq.TLO.Target.ID()
    local function switch_to(s, why)
        if not ma_target(s.id) then return end   -- not targetable: no attack onto the old one
        State.assigned_target, State.current_target_priority = s.id, 0
        -- auto attack carries over to the new target: only send it when it is off
        if not mq.TLO.Me.Combat() then mq.cmd("/attack on") end
        -- balance switches every pulse: log at most once a second
        local now = mq.gettime()
        if why == 'finishing' or now >= (wax_st.log_at or 0) then
            wax_st.log_at = now + 1000
            debug_local('Balance: -> %s %d%% (%s)', tostring(s.name), s.hp, why)
        end
    end

    if wax_st.finishing then
        wax_st.spread = nil
        for _, s in ipairs(set) do
            if s.id == tid then return true end   -- stay on it until it dies
        end
        table.sort(set, function(a, b) return a.hp < b.hp end)
        switch_to(set[1], 'finishing')
        return true
    end

    if #set < 2 then wax_st.spread = nil return false end
    local lo, hi = 100, 0
    for _, s in ipairs(set) do lo, hi = math.min(lo, s.hp), math.max(hi, s.hp) end
    wax_st.spread = hi - lo
    -- Never stay put: every pulse, off whatever we are on and onto the highest of the rest.
    -- The nukers' damage lands a cast time after the switch, so the add we are on still
    -- reads high and staying on "the highest" overshot it -- the spread swung 15-48% (seen
    -- live 2026-11-06). Rotating through the top of the pack spreads that lag across them.
    -- Gap between switches: SWITCH_GAP + random(0, SWITCH_JITTER) ms. Checked once a
    -- pulse, so the real gap rounds up to the next pulse. A 1s minimum gap once let the
    -- spread reach 42% (2026-11-06), but at 700+250 the spread held 7-8% over two runs
    -- (2026-11-11, measured gaps ~1.0-1.4s median).
    -- Exception: the highest add leads the next one down by SPREAD or more -- an outlier
    -- (a late add going live, or one the rotation missed). Go to it and stay on it until
    -- the lead drops under SPREAD, then rotate again.
    local now = mq.gettime()
    table.sort(set, function(a, b) return a.hp > b.hp end)
    local top = set[1]
    if top.hp - set[2].hp >= wax_st.SPREAD then
        if top.id == tid then return true end   -- on the outlier: stay
        if now < (wax_st.next_switch or 0) then return true end
        switch_to(top, string.format('outlier, +%d%% over next', top.hp - set[2].hp))
        wax_st.next_switch = now + wax_st.SWITCH_GAP + math.random(0, wax_st.SWITCH_JITTER)
        return true
    end
    if now < (wax_st.next_switch or 0) then return true end
    for _, s in ipairs(set) do
        if s.id ~= tid then
            switch_to(s, string.format('spread %d%%', wax_st.spread))
            wax_st.next_switch = now + wax_st.SWITCH_GAP + math.random(0, wax_st.SWITCH_JITTER)
            break
        end
    end
    return true
end

-- Waxwork: the adds pop all around the MT, who then gets summoned by whichever one is
-- behind it every time the balance moves it to the next add (seen live 2026-11-06). Once a
-- wave, as soon as two or more adds have spawned -- in the gap before they go live -- the
-- MT steps out of the pack, facing them, so they all come at it from the front. Live adds
-- on xtarget trigger it too, in case the spawns are missed.
-- Done by hand it is a flutter backwards: short steps (WAX.STEP), each aimed straight away
-- from the pack's middle, until every add is in front of us -- within WAX.FRONT degrees of
-- the line to that middle. One long move from the middle of a wide ring of adds left the
-- tank still inside it (seen live 2026-11-09). Once they are live their summons (and
-- SicTank) pull the tank back in, so the steps go on through the hold below: in Manual,
-- another step whenever an add is behind us again.
-- Once a wave. A second back-off (after WAX.BACKOFF_GAP, re-aimed from where they now are)
-- was tried live 2026-11-06: the extra seconds without rotating opened a 54-65% spread
-- before balancing began, against 2-17% with one, and the summons did not drop.
-- The rest of the group goes WAX.BEHIND past the tank's spot on the same line, re-sent each
-- step, so the adds come at them through the tank. After the back-off the tank stays in
-- Manual until the adds are live (WAX.LIVE_MAX at most), then until every one is in front
-- of it and has closed to its melee reach (Waxflame Snare slows it, and the adds take
-- their time) -- WAX.HOLD at least, WAX.HOLD_MAX at most -- then SicTank.
local WAX = { BACKOFF_TIMES = 1, BACKOFF_GAP = 1500,
    OUT_STEP = 15, STEPS_MAX = 8,   -- before they go live: units per step, most steps
    STEP = 6,                       -- once live: units per step, taken only with them all in reach
    FRONT = 70,                 -- degrees either side of the pack's middle that count as in front
    BEHIND = 15,
    SPAWN_RADIUS = 200,   -- adds this close count as this wave's
    LIVE_MAX = 15000,     -- ms to wait for them to go live after the back-off
    HOLD = 2000, HOLD_MAX = 10000 }   -- ms in Manual after that, before SicTank
local wax_back = { done = false }

-- The wave's adds as spawns, live or not yet: {id, name}
local function wax_spawned_adds()
    local out = {}
    for _, s in ipairs(mq.getFilteredSpawns(function(sp)
        local n = sp.CleanName() or ''
        return sp.Type() == 'NPC' and not sp.Dead() and not n:find('corpse', 1, true)
            and is_wax_add(n) and (sp.Distance() or 999) < WAX.SPAWN_RADIUS
    end)) do out[#out + 1] = { id = s.ID(), name = s.CleanName() } end
    return out
end

-- The adds to back off from: the spawned ones, or the live ones if more show there
local function wax_wave_adds()
    local spawned, live = wax_spawned_adds(), wax_live_adds()
    return #live > #spawned and live or spawned
end

-- Every live add within its melee reach of us (+5)
local function wax_adds_closed()
    for _, a in ipairs(wax_live_adds()) do
        local s = mq.TLO.Spawn(a.id)
        if s() and (s.Distance() or 0) > (s.MaxRange() or 15) + 5 then return false end
    end
    return true
end

-- Where the adds are from us: true if every one is in front, i.e. within WAX.FRONT degrees
-- of the line from us to the pack's middle; and the unit vector pointing away from that
-- middle (the way to step). An add on top of us counts as in front.
local function wax_in_front(set)
    local my, mx = mq.TLO.Me.Y(), mq.TLO.Me.X()
    if not (my and mx) then return true end
    local pts = {}
    for _, a in ipairs(set) do
        local s = mq.TLO.Spawn(a.id)
        local y, x = s.Y(), s.X()
        if y and x then pts[#pts + 1] = { y - my, x - mx } end
    end
    if #pts == 0 then return true end
    local cy, cx = 0, 0
    for _, p in ipairs(pts) do cy, cx = cy + p[1], cx + p[2] end
    cy, cx = cy / #pts, cx / #pts
    local c = math.sqrt(cy * cy + cx * cx)
    -- in the dead middle of them: none is in front, and any way out will do
    if c < 1 then return false, 1, 0 end
    local min_cos = math.cos(math.rad(WAX.FRONT))
    local front = true
    for _, p in ipairs(pts) do
        local a = math.sqrt(p[1] * p[1] + p[2] * p[2])
        if a >= 5 and (p[1] * cy + p[2] * cx) / (a * c) < min_cos then front = false break end
    end
    return front, -cy / c, -cx / c
end

-- One step of `dist` away from the pack's middle, walked backward so we keep facing them,
-- the group sent along behind. Nav ignores moves under ~5, so WAX.STEP stays above that.
-- False if there was no path or we did not move at all (a wall behind us).
local function wax_step(uy, ux, dist)
    local my, mx, mz = mq.TLO.Me.Y(), mq.TLO.Me.X(), mq.TLO.Me.Z()
    if not (my and mx and mz) then return false end
    if not Core.nav_to_loc(my + uy * dist, mx + ux * dist, mz, 'facing=backward log=off') then
        announce_g('Waxwork: no nav path to step out of the adds')
        return false
    end
    Core.bcge("/nav locyxz %.1f %.1f %.1f log=off",
        my + uy * (dist + WAX.BEHIND), mx + ux * (dist + WAX.BEHIND), mz)
    Core.wait_nav()
    local y, x = mq.TLO.Me.Y(), mq.TLO.Me.X()
    return (y and x and Core.dist_yx(y, x, my, mx) or 0) >= 1
end

-- The group in Manual for the step-out and hold, or Chase pulls them straight back to the
-- MA; back to Chase when we go to SicTank. Manual, not pause: a paused healer left the
-- group without heals for the whole hold (seen live 2026-11-09), where Manual still heals
-- and casts, it just does not move.
local function wax_group_manual(on)
    if not on and not wax_back.group_manual then return end
    wax_back.group_manual = on
    local reach = Core.reachable_names()   -- our boxes only: not mercs or outside players
    for i = 1, (mq.TLO.Group.Members() or 0) do
        local m = mq.TLO.Group.Member(i)
        local name, cls = m.Name(), m.Class.ShortName()
        if name and cls and not m.Mercenary() and reach[name:lower()] then
            Core.bct_mode(name, cls, on and 'mode 0' or 'mode 2', on and 'manual' or 'chase')
        end
    end
end

local function do_wax_backoff(set)
    wax_group_manual(true)
    mq.delay(300)
    local steps, front = 0, false
    for _ = 1, WAX.STEPS_MAX do
        local uy, ux
        front, uy, ux = wax_in_front(set)
        if front or not wax_step(uy, ux, WAX.OUT_STEP) then break end
        steps = steps + 1
        set = wax_wave_adds()
    end
    front = wax_in_front(set)
    announce('Waxwork: %d adds up, %d step(s) out -- %s', #set, steps,
        front and 'all in front' or 'some still behind')
    wax_back.steps = steps
end

local function check_wax_backoff()
    if State.current_task ~= W.TASK or mq.TLO.Group.MainTank() ~= def.name then return end
    local set = wax_wave_adds()
    if #set == 0 then wax_back.done = false return end
    if wax_back.done or #set < 2 then return end
    wax_back.done = true
    -- Manual, not pause(): CWTN would walk us straight back in to the target, and resume()
    -- handed it control the moment the nav ended -- too soon for the adds to close up.
    -- Manual holds us there until they are live and have closed (see WAX), then SicTank.
    cwtn('mode 0')
    local ok, err = pcall(function()
        for i = 1, WAX.BACKOFF_TIMES do
            if i > 1 then
                mq.delay(WAX.BACKOFF_GAP)
                set = wax_wave_adds()
                if #set == 0 then return end
            end
            do_wax_backoff(set)
        end
    end)
    if not ok then
        announce_g('wax backoff error: %s', tostring(err))
        if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
    end
    -- The waits below block Main, so the MA keeps balancing from in here: targets only,
    -- Manual does not move us. At Main's own pace -- one pick per def.pulse + jitter, as
    -- if Main were running -- not every 250 ms wait; the switch gap applies on top.
    local function hold_wait(ms)
        if flags.MA_MODE and flags.WAX_BALANCE then wax_balance_pick() end   -- self-paced
        mq.delay(ms)
    end
    local tl = mq.gettime()
    while mq.gettime() - tl < WAX.LIVE_MAX and #wax_live_adds() < #wax_spawned_adds() do
        hold_wait(250)
    end
    -- Live: the summons start. Flutter back out whenever one has pulled us into the pack,
    -- until they are all in front and in reach. Only short steps, and only with every add
    -- in reach: an add we step out of melee range of summons us straight back.
    local t0, flutters = mq.gettime(), 0
    local ok2, err2 = pcall(function()
        while mq.gettime() - t0 < WAX.HOLD_MAX do
            local live = wax_live_adds()
            if #live == 0 then return end
            local front, uy, ux = wax_in_front(live)
            local closed = wax_adds_closed()
            if not front and closed then
                if wax_step(uy, ux, WAX.STEP) then flutters = flutters + 1 else hold_wait(250) end
            elseif front and closed and mq.gettime() - t0 >= WAX.HOLD then
                return
            else
                hold_wait(250)
            end
        end
    end)
    if not ok2 then
        announce_g('wax flutter error: %s', tostring(err2))
        if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
    end
    debug_local('Waxwork: %.1fs for the adds to go live, then held %.1fs in Manual (%d step(s) back after summons), adds %s',
        (t0 - tl) / 1000, (mq.gettime() - t0) / 1000, flutters,
        wax_adds_closed() and 'in reach' or 'still not all in reach')
    cwtn('mode 7')
    wax_group_manual(false)
end

-- Summons. Each add summons the tank onto itself ('You will not evade me, <name>!' then
-- 'You have been summoned!'), which drops us in the middle of the pack with adds behind
-- -- all wave long, not just in the back-off's hold (seen live 2026-11-19: summons after
-- the hold, the tank back in SicTank and surrounded). So on every summon while a wave is
-- up: Manual, one short step back out of the pack's middle, then the mode we were in.
-- Only with every add in reach -- one we step out of range of summons us right back -- so
-- a summon is retried for up to WAX.SUMMON_RETRY ms while they close up. During the
-- back-off's hold this never runs (it blocks Main); the hold's flutter covers it there.
-- In practice this rarely steps: the adds settle 2-12 off on all sides of the tank, in
-- reach, and the summons stop. That partial surround is accepted (2026-11-19) -- do not
-- try to step out of it, any step leaves one out of reach and starts a summon loop.
local wax_summon = { at = nil }
WAX.SUMMON_RETRY = 3000

-- True if, from the spot a step of `dist` along (uy, ux) would leave us, every live add
-- is still within its MaxRange of us -- no slack.
local function wax_step_safe(uy, ux, dist)
    local my, mx = mq.TLO.Me.Y(), mq.TLO.Me.X()
    if not (my and mx) then return false end
    local ty, tx = my + uy * dist, mx + ux * dist
    for _, a in ipairs(wax_live_adds()) do
        local s = mq.TLO.Spawn(a.id)
        local y, x = s.Y(), s.X()
        if not (y and x) then return false end
        if Core.dist_yx(y, x, ty, tx) > (s.MaxRange() or 15) then return false end
    end
    return true
end

local function wax_summoned()
    if State.current_task ~= W.TASK or mq.TLO.Group.MainTank() ~= def.name then return end
    wax_summon.at = mq.gettime()
end

local function check_wax_summon()
    if not wax_summon.at then return end
    if State.current_task ~= W.TASK or mq.gettime() - wax_summon.at > WAX.SUMMON_RETRY then
        wax_summon.at = nil
        return
    end
    local live = wax_live_adds()
    if #live < 2 then wax_summon.at = nil return end
    local front, uy, ux = wax_in_front(live)
    if front then wax_summon.at = nil return end
    -- Only a step that leaves EVERY add within its own melee reach: an add we step out of
    -- reach of summons us straight back, and the step turns into a summon loop (seen live
    -- 2026-11-19: adds spread 2-26 off, step -> summon -> step five times in a row).
    if not wax_step_safe(uy, ux, WAX.STEP) then return end   -- retry next pulse
    wax_summon.at = nil
    local m = Core.get_cwtn_mode()
    local manual = (m == 'Manual')
    if not manual then cwtn('mode 0') end
    local ok, err = pcall(wax_step, uy, ux, WAX.STEP)
    if not ok then
        announce_g('wax summon step error: %s', tostring(err))
        if mq.TLO.Navigation.Active() then mq.cmd("/nav stop") end
    end
    announce('Waxwork: summoned into the pack -- stepped back out (%d adds)', #live)
    if not manual then Core.set_mode(m) end
end

-- ============================================================
-- Mission hooks (see init.lua)
-- ============================================================

function W.events()
    mq.event('wax_summoned', '#*#You have been summoned!#*#', wax_summoned)
end

function W.pre_pulse()
    check_wax_aa()
    check_wax_backoff()
    check_wax_summon()
end

function W.pick()
    return flags.WAX_BALANCE and wax_balance_pick()
end

-- A pair of mobs on the way in usually aggro as we pass. Rather than drag them onto the
-- Abolishion, the walk stops and kills anything on the hate list that is not him.
function W.start()
    Core.start_nav_clearing('abolishion')
    if not Core.start_gather() then return end
    local abo = mq.TLO.Spawn("npc Abolishion")
    if not (abo() and Core.safe_target(abo.ID())) then
        announce_g('Start: the Abolishion is not in reach -- start it by hand')
        return
    end
    mq.delay(500)
    mq.cmd("/say destroy")
    announce('Start: Waxwork Abolishion started')
    mq.delay(500)
    mq.cmd("/attack on")
end

W.commands = {
    wax = function(value)
        if value == 'balance' then flags.WAX_BALANCE = true
        elseif value == 'kill' then flags.WAX_BALANCE = false
        else flags.WAX_BALANCE = not flags.WAX_BALANCE end
        printf('Waxwork adds: %s', flags.WAX_BALANCE and 'balance HP' or 'kill in order')
    end,
}

function W.usage(c)
    print('  Waxwork Abolishion:')
    printf('  %s wax [balance|kill]       --> MA balances the adds\' HP within %d%%, or kills in order', c, wax_st.SPREAD)
end

function W.ui()
    local COLOR = Core.COLOR
    ImGui.Text('Adds (MA):')
    ImGui.SameLine()
    if ImGui.RadioButton('Balance##wax', flags.WAX_BALANCE) then flags.WAX_BALANCE = true end
    ImGui.SameLine()
    if ImGui.RadioButton('Kill in order##wax', not flags.WAX_BALANCE) then flags.WAX_BALANCE = false end
    if flags.WAX_BALANCE then
        if wax_st.finishing then
            ImGui.TextColored(COLOR.AMBER, 'Finishing: lowest HP first')
        elseif wax_st.spread then
            ImGui.Text('HP spread:')
            ImGui.SameLine()
            ImGui.TextColored(wax_st.spread > wax_st.SPREAD and COLOR.AMBER or COLOR.GREEN,
                '%d%% (target %d%%)', wax_st.spread, wax_st.SPREAD)
        else
            ImGui.TextDisabled('HP spread: None')
        end
    end
end

return W
