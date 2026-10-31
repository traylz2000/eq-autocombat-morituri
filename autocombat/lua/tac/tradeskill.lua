---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- ============================================================================
-- lua/tac/tradeskill.lua — MoriAC Tradeskills Plugin
-- ============================================================================
-- Makes a recipe over and over until you run out of materials (or a count).
--
-- It drives the game's own tradeskill window (TradeskillWnd), which opens
-- when you open a forge, oven, loom or tradeskill kit. That window lists
-- recipes (your favourites, or what you search for in it); picking one and
-- pressing Combine sends the server an auto-combine, and the server takes
-- every ingredient straight from your bags (zone/tradeskills.cpp
-- Object::HandleAutoCombine). So there's no slot-by-slot placement here:
-- select the row, click Combine, read the result line, put the result away,
-- repeat.
--
-- The loop stops on the server's own lines:
--   3456 Sorry, but you don't have everything you need for this recipe in
--        your general inventory.            -> out of materials (normal end)
--   3455 You are missing a %1.              -> which ones (logged)
--    334 You cannot combine these items in this container type!
--        "You are not skilled enough." / "You need to learn how to combine
--        these first." / class and race limits (alchemy, tinkering, poison)
--   6199 Combine would result in a LORE item (%1) you already possess.
-- and counts:
--    339 You have fashioned the items together to create something new!
--    336 You lacked the skills to fashion the items together.
--    338 You can no longer advance your skill from making this item.
--        "You have become better at %1! (%2)"
-- It also stops when combat starts, the window closes, the count is reached,
-- results can't be put away (bags full) or the server stops answering.
--
-- The window's controls are looked up by their XML names first and, failing
-- that, found by walking the window (the listbox, the button captioned
-- Combine), so a custom UI with renamed controls still works.
--
-- Runs on its own fiber (hasThread) so the loop can core.delay() between
-- clicks without holding up the combat loop.
-- ============================================================================

local plugin = {
    id                 = 'tradeskill',
    name               = 'Tradeskills',
    version            = '1.0.5',
    author             = 'MoriAC',
    description        = 'Pick a recipe in the game tradeskill window and make it until you run out of materials.',
    defaultEnabled     = true,
    tickInterval       = 0.01,  -- a turn every main-loop pass (the make loop waits on the game)
    runOutOfCombatOnly = false,
    hasThread          = true,
    window             = { label = 'Tradeskills', tooltip = 'Toggles the Tradeskills window (tradeskill plugin).', flag = 'show_tradeskill', key = 'tradeskill', desc = 'Make a recipe until you run out of materials', headerButton = false, order = 96 },
}

local core = nil  ---@type table
local ctrl, ImGui, mq = nil, nil, nil  ---@type table, table, table

local TS_WND = 'TradeskillWnd'
-- XML names tried first (stock RoF2 UI and common variants).
local CANDIDATES = {
    list    = { 'COMBW_RecipeList', 'TSW_RecipeList', 'RecipeList' },
    combine = { 'CombineButton', 'COMBW_CombineButton', 'TSW_CombineButton', 'Container_Combine' },
}
local WALK_MAX_NODES   = 400
local POLL_SEC         = 0.5
local SELECT_MS        = 600
local ENABLE_WAIT_MS   = 8000   -- Combine greys out ~2.5-3 s after each combine
local STABLE_MS        = 300    -- ...and must stay clickable this long before a click
local RESULT_MS        = 3000   -- no reply by then: the click didn't take
local AUTOINV_STEPS_MS = { 200, 300, 300 }  -- /autoinventory this long after Combine, then after each other
local GAP_MAX          = 6.0
local CURSOR_MS        = 3000   -- give up when one item won't go for this long
local CURSOR_STEP_MS   = 700    -- wait per /autoinventory
local CURSOR_SETTLE_MS = 200    -- cursor must stay empty this long (queued items)
local BETWEEN_MS       = 50
local MAX_TIMEOUTS     = 6
local MAX_COMBINES     = 2000
local MAX_LOG          = 60

-- Server result lines -> result kinds. Order matters only for readability;
-- each pattern is its own event.
local RESULT_EVENTS = {
    { 'TacTsSuccess',   'You have fashioned the items together to create something new!#*#', 'success' },
    { 'TacTsFail',      'You lacked the skills to fashion the items together.#*#', 'fail' },
    { 'TacTsMissing',   "Sorry, but you don't have everything you need for this recipe#*#", 'missing' },
    { 'TacTsNoCombine', 'You cannot combine these items in this container type!#*#', 'nocombine' },
    { 'TacTsLore',      'Combine would result in a LORE item#*#', 'lore' },
    { 'TacTsSkill',     'You are not skilled enough.#*#', 'skill' },
    { 'TacTsLearn',     'You need to learn how to combine these first.#*#', 'learn' },
    { 'TacTsOnlyBy',    'This tradeskill can only be performed by #*#', 'restricted' },
    { 'TacTsAlchemy',   'You cannot perform alchemy until #*#', 'restricted' },
    { 'TacTsGnome',     'Only gnomes can tinker.#*#', 'restricted' },
    { 'TacTsRogue',     'Only rogues can mix poisons.#*#', 'restricted' },
}

-- Why a run ended, for the summary line.
local STOP_TEXT = {
    missing    = 'out of materials',
    nocombine  = 'this recipe needs a different container',
    lore       = 'you already have the LORE result',
    skill      = 'your skill is too low for this recipe',
    learn      = 'you have to learn this recipe first',
    restricted = 'your class or race cannot do this tradeskill',
}

local state = {
    windowOpen   = false,
    controls     = {},       -- kind -> child name in TradeskillWnd (nil = not found)
    controlsHow  = {},       -- kind -> 'name' | 'walk'
    recipes      = {},       -- { row, name }
    lastPollAt   = 0,
    selected     = nil,      -- recipe name picked in our window
    filter       = '',
    -- run
    running      = false,
    stopRequested = false,
    job          = nil,      -- { name, count }
    progress     = '',
    lastResult   = nil,
    missing      = {},       -- item names from "You are missing a X."
    trivialSeen  = false,
    succeeded    = 0,
    failed       = 0,
    skillUps     = 0,
    lastSkill    = nil,      -- { name, value }
    lastRunSummary = '',
    log          = {},
    registeredEvents = {},
    debug        = false,
}

local settings = {
    count        = 0,        -- successful combines to make; 0 = until out of materials
    combineGap   = 0,        -- seconds from one Combine click to the next (the slider)
    stopAtTrivial = false,   -- stop once the server says the recipe is trivial
    chatSummary  = true,
    lastRecipe   = '',
}

local function refresh()
    if not core then return end
    ctrl = core.ctrl
    ImGui = core.ImGui
    mq = core.mq
end

local function say(fmt, ...)
    print(string.format('\ag[MoriAC Tradeskills]\ax ' .. fmt, ...))
end

local function addLog(text, kind)
    table.insert(state.log, 1, { time = os.date('%H:%M:%S'), text = text, kind = kind or 'info' })
    while #state.log > MAX_LOG do table.remove(state.log) end
end

-- ---------------------------------------------------------------------------
-- Pure helpers (exposed for tests)
-- ---------------------------------------------------------------------------
local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

-- "a Bolt of Cloth" / "an Ore" -> "Bolt of Cloth" (TRADESKILL_MISSING_ITEM
-- puts the article in front of the item name).
local function stripArticle(s)
    s = trim(s):gsub('%.$', '')
    return (s:gsub('^[Aa]n? ', ''))
end

-- Row of `name` in a recipe list (case-insensitive, exact), or nil.
local function findRecipeRow(recipes, name)
    local want = trim(name):lower()
    if want == '' then return nil end
    for _, r in ipairs(recipes or {}) do
        if trim(r.name):lower() == want then return r.row end
    end
    return nil
end

local function filterRecipes(recipes, text)
    local f = trim(text):lower()
    if f == '' then return recipes end
    local out = {}
    for _, r in ipairs(recipes or {}) do
        if r.name:lower():find(f, 1, true) then out[#out + 1] = r end
    end
    return out
end

-- Summary of a finished run.
local function summaryLine(name, succeeded, failed, skillUps, reason)
    local s = string.format('Made %d %s', succeeded, name or 'item')
    local extra = {}
    if failed > 0 then extra[#extra + 1] = string.format('%d failed', failed) end
    if skillUps > 0 then extra[#extra + 1] = string.format('%d skill-up%s', skillUps, skillUps == 1 and '' or 's') end
    if #extra > 0 then s = s .. ' (' .. table.concat(extra, ', ') .. ')' end
    if reason and reason ~= '' then s = s .. ' - ' .. reason end
    return s
end

-- ---------------------------------------------------------------------------
-- Window access
-- ---------------------------------------------------------------------------
local function wndPath(name) return TS_WND .. '/' .. name end

local function exists(path)
    local ok = false
    pcall(function()
        local w = mq.TLO.Window(path)
        ok = (w ~= nil and w() ~= nil)
    end)
    return ok
end

local function tsWindowOpen()
    local open = false
    pcall(function()
        local w = mq.TLO.Window(TS_WND)
        open = (w and w.Open()) == true
    end)
    return open
end

local function childName(w)
    local n = ''
    pcall(function() n = tostring(w.Name() or '') end)
    if n == '' or n == 'NULL' then pcall(function() n = tostring(w.ScreenID() or '') end) end
    if n == 'NULL' then n = '' end
    return n
end

-- Walk TradeskillWnd for a control: the first listbox (one named for
-- recipes wins), and the button captioned "Combine".
local function walkFor(kind)
    local found, fallback = nil, nil
    local seen = 0
    local function visit(w, depth)
        if found or not w or seen >= WALK_MAX_NODES or depth > 8 then return end
        local okW, isW = pcall(function() return w() ~= nil end)
        if not okW or not isW then return end
        seen = seen + 1
        local typ, txt = '', ''
        pcall(function() typ = tostring(w.Type() or ''):lower() end)
        pcall(function() txt = trim(w.Text() or ''):lower() end)
        local nm = childName(w)
        if kind == 'list' and typ:find('listbox', 1, true) and nm ~= '' then
            if nm:lower():find('recipe', 1, true) then found = nm; return end
            fallback = fallback or nm
        elseif kind == 'combine' and typ:find('button', 1, true) and txt == 'combine' and nm ~= '' then
            found = nm; return
        end
        local child = nil
        pcall(function() child = w.FirstChild end)
        while child and not found and seen < WALK_MAX_NODES do
            visit(child, depth + 1)
            local nxt = nil
            pcall(function() nxt = child.Next end)
            child = nxt
        end
    end
    pcall(function() visit(mq.TLO.Window(TS_WND), 0) end)
    return found or fallback
end

local function resolveControls()
    for kind, names in pairs(CANDIDATES) do
        if not state.controls[kind] or not exists(wndPath(state.controls[kind])) then
            state.controls[kind], state.controlsHow[kind] = nil, nil
            for _, n in ipairs(names) do
                if exists(wndPath(n)) then
                    state.controls[kind], state.controlsHow[kind] = n, 'name'
                    break
                end
            end
            if not state.controls[kind] then
                local n = walkFor(kind)
                if n then state.controls[kind], state.controlsHow[kind] = n, 'walk' end
            end
        end
    end
    return state.controls
end

local function listPath() return state.controls.list and wndPath(state.controls.list) end
local function combinePath() return state.controls.combine and wndPath(state.controls.combine) end

local function listInt(member)
    local v = 0
    local p = listPath()
    if not p then return 0 end
    pcall(function()
        local w = mq.TLO.Window(p)
        if w and w[member] then v = tonumber(w[member]()) or 0 end
    end)
    return v
end

local function listCell(row, col)
    local s = ''
    local p = listPath()
    if not p then return '' end
    pcall(function()
        local v = mq.TLO.Window(p).List(row, col)()
        if v ~= nil then s = tostring(v) end
    end)
    return trim(s)
end

local function readRecipes()
    local out = {}
    local n = listInt('Items')
    for r = 1, n do
        local name = listCell(r, 1)
        if name == '' or tonumber(name) then name = listCell(r, 2) end
        if name ~= '' then out[#out + 1] = { row = r, name = name } end
    end
    return out
end

local function combineEnabled()
    local p = combinePath()
    if not p then return false end
    local en = true
    pcall(function()
        local w = mq.TLO.Window(p)
        if w and w.Enabled then
            local v = w.Enabled()
            if v == false then en = false end
        end
    end)
    return en
end

-- Combine is clickable and stays so for STABLE_MS (it can grey out a
-- moment after the last result went away). False after ENABLE_WAIT_MS.
local waitCombineReady
local function cursorHasItem()
    local has = false
    pcall(function() has = mq.TLO.Cursor() ~= nil end)
    return has
end

-- Puts whatever is on the cursor away. False when it won't go (bags full).
-- Every wait in a run goes through here. MoriAC's main loop sleeps 150 ms
-- a pass and a wait is only re-checked once a pass, so each check renews a
-- short-pass window (core.fastLoop); it lapses a second after the run ends.
local function fastLoop()
    if core.fastLoop then pcall(core.fastLoop, 1) end
end

local function wait(ms, cond)
    fastLoop()
    return core.delay(ms, function()
        fastLoop()
        if cond then return cond() == true end
        return false
    end)
end

local function cursorName()
    local n = ''
    pcall(function() n = tostring(mq.TLO.Cursor.Name() or '') end)
    return n
end

-- Puts everything on the cursor away. The server can queue several items
-- (product plus salvage, multi-yield recipes, a result that came in while
-- something was still held); the next one shows up a moment after the one
-- before goes into the bags. So it's only done once the cursor has stayed
-- empty for CURSOR_SETTLE_MS. False when an item won't go (bags full).
local function clearCursor()
    -- nothing held: nothing can be queued behind it either, go straight on
    if not cursorHasItem() then return true end
    local deadline = os.clock() + CURSOR_MS / 1000
    while os.clock() < deadline do
        if cursorHasItem() then
            local before = cursorName()
            pcall(mq.cmd, '/autoinventory')
            wait(CURSOR_STEP_MS, function() return not cursorHasItem() or cursorName() ~= before end)
            -- each item that went away buys time for the next in the queue
            if not cursorHasItem() or cursorName() ~= before then
                deadline = math.max(deadline, os.clock() + CURSOR_MS / 1000)
            end
        elseif not wait(CURSOR_SETTLE_MS, cursorHasItem) then
            return true
        end
    end
    return not cursorHasItem()
end

waitCombineReady = function()
    local deadline = os.clock() + ENABLE_WAIT_MS / 1000
    while os.clock() < deadline do
        local left = math.max(1, (deadline - os.clock()) * 1000)
        if not wait(left, combineEnabled) then return false end
        if not wait(STABLE_MS, function() return not combineEnabled() end) then return true end
    end
    return false
end

local function inCombatNow()
    local rt = core and core.runtime
    if rt and rt.isCombat then
        local ok, v = pcall(rt.isCombat)
        if ok and v == true then return true end
    end
    local haters = 0
    pcall(function() haters = tonumber(mq.TLO.Me.XTHaterCount()) or 0 end)
    return haters > 0
end

local function poll(force)
    local now = os.clock()
    if not force and (now - state.lastPollAt) < POLL_SEC then return end
    state.lastPollAt = now
    local open = tsWindowOpen()
    if not open then
        state.windowOpen = false
        state.controls, state.controlsHow = {}, {}
        state.recipes = {}
        return
    end
    state.windowOpen = true
    resolveControls()
    state.recipes = state.controls.list and readRecipes() or {}
end

-- ---------------------------------------------------------------------------
-- Chat events (pumped by the core's mq.doevents on the main loop)
-- ---------------------------------------------------------------------------
local function onResult(kind)
    if not state.running then return end
    -- A success or fail is the combine's own answer; a later line on the
    -- same combine (e.g. trivial) never overwrites it.
    if state.lastResult == nil then state.lastResult = kind end
end

local function onMissingItem(_, item)
    if not state.running then return end
    local n = stripArticle(item)
    if n ~= '' then state.missing[#state.missing + 1] = n end
end

local function onTrivial()
    if state.running then state.trivialSeen = true end
end

local function onSkillUp(_, skill, value)
    if not state.running then return end
    state.skillUps = state.skillUps + 1
    state.lastSkill = { name = trim(skill), value = tonumber(value) }
end

local function registerEvents()
    if not (mq and mq.event) then return end
    local function reg(name, pattern, handler)
        if mq.unevent then pcall(mq.unevent, name) end
        mq.event(name, pattern, handler)
        table.insert(state.registeredEvents, name)
    end
    for _, e in ipairs(RESULT_EVENTS) do
        local kind = e[3]
        reg(e[1], e[2], function() onResult(kind) end)
    end
    reg('TacTsMissingItem', 'You are missing #1#', onMissingItem)
    reg('TacTsTrivial', 'You can no longer advance your skill from making this item.#*#', onTrivial)
    reg('TacTsSkillUp', 'You have become better at #1#! (#2#)', onSkillUp)
end

local function unregisterEvents()
    if mq and mq.unevent then
        for _, name in ipairs(state.registeredEvents) do pcall(mq.unevent, name) end
    end
    state.registeredEvents = {}
end

-- ---------------------------------------------------------------------------
-- The make loop (runs inside onTick on the plugin fiber; core.delay yields)
-- ---------------------------------------------------------------------------
local function finishRun(reason, kind)
    local job = state.job or {}
    -- the last product of the run goes into the bags too
    if cursorHasItem() and not clearCursor() then
        reason = (reason and reason ~= '' and (reason .. '; ') or '') .. 'the last result is still on your cursor (bags full?)'
        kind = 'warn'
    end
    state.running = false
    state.progress = ''
    local summary = summaryLine(job.name, state.succeeded, state.failed, state.skillUps, reason)
    if state.lastSkill and state.lastSkill.value then
        summary = summary .. string.format(' [%s %d]', state.lastSkill.name, state.lastSkill.value)
    end
    state.lastRunSummary = summary
    addLog(summary, kind or 'info')
    if #state.missing > 0 then addLog('Missing: ' .. table.concat(state.missing, ', '), 'warn') end
    if settings.chatSummary then
        say('%s', summary)
        if #state.missing > 0 then say('Missing: %s', table.concat(state.missing, ', ')) end
    end
    if core.log and core.log.info then core.log.info('tradeskill', '%s', summary) end
    poll(true)
end

local function runMake()
    local job = state.job
    state.succeeded, state.failed, state.skillUps = 0, 0, 0
    state.lastSkill, state.trivialSeen = nil, false
    state.missing = {}
    state.stopRequested = false
    local timeouts = 0
    local selectFails = 0
    local lastClickAt = nil

    for _ = 1, MAX_COMBINES do
        if state.stopRequested then return finishRun('stopped', 'warn') end
        if not tsWindowOpen() then return finishRun('the tradeskill window closed', 'warn') end
        if inCombatNow() then return finishRun('combat started', 'warn') end
        if job.count > 0 and state.succeeded >= job.count then return finishRun('done') end
        if settings.stopAtTrivial and state.trivialSeen then return finishRun('the recipe is trivial for you now') end
        if not clearCursor() then return finishRun('could not put the result away (bags full?)', 'warn') end

        resolveControls()
        if not state.controls.list then return finishRun('could not find the recipe list in the tradeskill window', 'warn') end
        if not state.controls.combine then return finishRun('could not find the Combine button in the tradeskill window', 'warn') end

        state.recipes = readRecipes()
        local row = findRecipeRow(state.recipes, job.name)
        if not row then
            return finishRun('the recipe is no longer in the list (search for it in the game window)', 'warn')
        end

        state.progress = string.format('Making %s: %d made%s', job.name, state.succeeded,
            job.count > 0 and string.format(' of %d', job.count) or '')

        if listInt('GetCurSel') ~= row then
            pcall(function() mq.TLO.Window(listPath()).Select(row) end)
        end
        local selected = wait(SELECT_MS, function() return listInt('GetCurSel') == row end)
        if not selected then
            selectFails = selectFails + 1
            if selectFails >= 5 then return finishRun('could not select the recipe in the list', 'warn') end
            wait(100)
        else
            selectFails = 0
            -- Selecting asks the server for the recipe's details, and every
            -- combine refreshes them: Combine is greyed out until they come.
            local t0 = os.clock()
            if not waitCombineReady() then
                return finishRun('the Combine button stayed greyed out (out of materials?)', 'warn')
            end
            -- a client that never reports the grey state: keep the learned gap
            local gap = tonumber(settings.combineGap) or 0
            if lastClickAt and gap > 0 then
                local left = gap - (os.clock() - lastClickAt)
                if left > 0 then wait(left * 1000) end
            end

            -- Never combine while holding something: a finished or failed
            -- product (or salvage) still on the cursor goes into the bags first.
            if not clearCursor() then return finishRun('could not put the result away (bags full?)', 'warn') end
            local readyIn = os.clock() - t0
            state.lastResult = nil
            lastClickAt = os.clock()
            -- The player's working social, plus one more /autoinventory:
            --   /notify TradeskillWnd CombineButton leftmouseup
            --   /pause .2  /autoinventory  /pause .3  /autoinventory  (/pause .3  /autoinventory)
            -- (the Window TLO's LeftMouseUp() did not press this button)
            pcall(mq.cmd, string.format('/notify %s %s leftmouseup', TS_WND, state.controls.combine))
            for _, ms in ipairs(AUTOINV_STEPS_MS) do
                wait(ms)
                pcall(mq.cmd, '/autoinventory')
            end
            -- the result line usually arrived during those; give it the rest of RESULT_MS
            local left = RESULT_MS - (os.clock() - lastClickAt) * 1000
            if state.lastResult == nil and left > 0 then wait(left, function() return state.lastResult ~= nil end) end
            local answerIn = os.clock() - lastClickAt
            local result = state.lastResult
            if state.debug then
                addLog(string.format('ready %.2f s, answer %.2f s, %s', readyIn, answerIn, tostring(result or 'none')), 'info')
            end

            if result == 'success' then
                state.succeeded = state.succeeded + 1
                timeouts = 0
            elseif result == 'fail' then
                state.failed = state.failed + 1
                timeouts = 0
            elseif result and STOP_TEXT[result] then
                return finishRun(STOP_TEXT[result], result == 'missing' and 'info' or 'warn')
            else
                -- The click didn't take: try again once the button is ready.
                timeouts = timeouts + 1
                addLog('Combine did not take - trying again (raise Wait between combines if this keeps happening)', 'warn')
                if timeouts >= MAX_TIMEOUTS then return finishRun('the server stopped answering', 'warn') end
            end
            -- anything still arriving (multi-yield, salvage) goes away too
            if not clearCursor() then return finishRun('could not put the result away (bags full?)', 'warn') end
            wait(BETWEEN_MS)
        end
    end
    return finishRun('hit the per-run combine cap')
end

-- ---------------------------------------------------------------------------
-- Public API (/ac ts, buttons)
-- ---------------------------------------------------------------------------
function plugin.isRunning() return state.running == true end

-- name: recipe as listed in the game window; count: successful combines
-- (0 or nil = until out of materials).
function plugin.start(name, count)
    refresh()
    if state.running then return false end
    name = trim(name)
    if name == '' then say('Pick a recipe first.'); return false end
    poll(true)
    if not state.windowOpen then
        say('Open a tradeskill container first (forge, oven, loom, kit...), so the game tradeskill window is showing.')
        return false
    end
    if not findRecipeRow(state.recipes, name) then
        say('"%s" is not in the tradeskill window list. Search for it in the game window first.', name)
        return false
    end
    count = math.max(0, math.floor(tonumber(count) or 0))
    state.job = { name = name, count = count }
    state.selected = name
    settings.lastRecipe = name
    state.running = true
    state.progress = 'Starting...'
    addLog(string.format('Making %s %s', name, count > 0 and ('x' .. count) or 'until out of materials'), 'info')
    if core.saveLoadout then core.saveLoadout(true) end
    return true
end

function plugin.stop()
    if not state.running then return false end
    state.stopRequested = true
    return true
end

function plugin.openWindow(val)
    refresh()
    if not ctrl then return end
    if val == nil then val = not ctrl.show_tradeskill end
    ctrl.show_tradeskill = (val == true)
    core.saveLoadout(true)
end

-- ---------------------------------------------------------------------------
-- Plugin hooks
-- ---------------------------------------------------------------------------
function plugin.onInit(coreApi)
    core = coreApi
    refresh()
    if ctrl and ctrl.show_tradeskill == nil then ctrl.show_tradeskill = false end
    registerEvents()
end

function plugin.onDestroy()
    unregisterEvents()
    state.running = false
    state.stopRequested = false
    state.progress = ''
end

function plugin.onSaveSettings()
    return {
        count         = settings.count,
        combineGap    = settings.combineGap,
        stopAtTrivial = settings.stopAtTrivial == true,
        chatSummary   = settings.chatSummary ~= false,
        lastRecipe    = settings.lastRecipe or '',
    }
end

function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    settings.count = math.max(0, math.min(9999, math.floor(tonumber(s.count) or 0)))
    settings.stopAtTrivial = s.stopAtTrivial == true
    settings.combineGap = math.max(0, math.min(GAP_MAX, tonumber(s.combineGap) or 0))
    settings.chatSummary = s.chatSummary ~= false
    settings.lastRecipe = type(s.lastRecipe) == 'string' and s.lastRecipe or ''
    if settings.lastRecipe ~= '' then state.selected = settings.lastRecipe end
end

function plugin.onZoned()
    if state.running then state.stopRequested = true end
    state.controls, state.controlsHow = {}, {}
end

function plugin.onTick()
    refresh()
    if not mq then return end
    if state.running then
        local ok, err = xpcall(runMake, debug.traceback)
        if not ok then
            state.running = false
            state.progress = ''
            addLog('Stopped by an error: ' .. tostring(err):match('^[^\n]*'), 'warn')
            if core.log and core.log.error then core.log.error('tradeskill', 'make loop failed:\n%s', tostring(err)) end
        end
    elseif ctrl and ctrl.show_tradeskill then
        poll(false)
    end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------
local function colorsTable()
    local c = core.colors or {}
    return {
        GOOD  = c.GOOD or { 0.40, 0.85, 0.50, 1.0 },
        WARN  = c.WARN or { 0.95, 0.75, 0.30, 1.0 },
        MUTED = c.MUTED or { 0.55, 0.60, 0.65, 1.0 },
        ARC   = c.ARC or { 0.30, 0.80, 1.00, 1.0 },
        GOLD  = c.GOLD or { 1.0, 0.70, 0.54, 1.0 },
    }
end

local function colored(col, text)
    ImGui.TextColored(col[1], col[2], col[3], col[4], text)
end

local function drawSettingsBody()
    core.formLabel('How many', core.px(110))
    local n, changed = ImGui.InputInt('##tsCount', settings.count or 0)
    if changed then
        settings.count = math.max(0, math.min(9999, math.floor(tonumber(n) or 0)))
        core.saveLoadout(true)
    end
    if ImGui.IsItemHovered() then core.setTooltip('Successful combines to make. 0 = keep going until you run out of materials.') end

    core.formLabel('Wait between combines', core.px(110))
    local curGap = tonumber(settings.combineGap) or 0
    local g = ImGui.SliderFloat('##tsGap', curGap, 0, GAP_MAX, '%.1f s')
    g = math.max(0, math.min(GAP_MAX, math.floor((tonumber(g) or curGap) * 10 + 0.5) / 10))
    if g ~= curGap then
        settings.combineGap = g
        core.saveLoadout(true)
    end
    if ImGui.IsItemHovered() then core.setTooltip('Least time from one Combine click to the next. 0 = as soon as the button is clickable again.\nRaise it if combines get skipped.') end

    local v = ImGui.Checkbox('Stop once the recipe is trivial##tsTrivial', settings.stopAtTrivial == true)
    if v ~= (settings.stopAtTrivial == true) then settings.stopAtTrivial = v; core.saveLoadout(true) end
    if ImGui.IsItemHovered() then core.setTooltip('Stops when the server says "You can no longer advance your skill from making this item."\nUseful when you are only making it for skill-ups.') end

    v = ImGui.Checkbox('Chat summary when a run ends##tsChat', settings.chatSummary ~= false)
    if v ~= (settings.chatSummary ~= false) then settings.chatSummary = v; core.saveLoadout(true) end
end

local function drawRecipeList(C)
    local s = ImGui.InputTextWithHint('##tsFilter', 'Filter the list...', state.filter or '')
    if s ~= state.filter then state.filter = s end
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('%d recipe%s', #state.recipes, #state.recipes == 1 and '' or 's'))
    local rows = filterRecipes(state.recipes, state.filter)
    if ImGui.BeginChild('##tsRecipes', 0, core.px(200), true) then
        if #state.recipes == 0 then
            colored(C.MUTED, 'The game window lists no recipes. Search for one there (or mark favourites).')
        elseif #rows == 0 then
            colored(C.MUTED, 'Nothing matches the filter.')
        else
            for _, r in ipairs(rows) do
                local isSel = state.selected ~= nil and state.selected:lower() == r.name:lower()
                local _, pressed = ImGui.Selectable(r.name .. '##tsRow' .. r.row, isSel)
                if pressed and not state.running then state.selected = r.name end
            end
        end
    end
    ImGui.EndChild()
end

local function drawRunControls(C)
    local btnW, btnH = core.px(150), core.px(26)
    if state.running then
        if ImGui.Button('Stop##tsStop', btnW, btnH) then plugin.stop() end
        ImGui.SameLine()
        colored(C.GOLD, state.progress ~= '' and state.progress or 'Working...')
        ImGui.TextDisabled(string.format('Succeeded %d, failed %d, skill-ups %d', state.succeeded, state.failed, state.skillUps))
        return
    end
    local name = state.selected
    local inList = name and findRecipeRow(state.recipes, name) ~= nil
    ImGui.TextDisabled('Recipe:')
    ImGui.SameLine()
    if name and name ~= '' then
        colored(inList and C.ARC or C.MUTED, name .. (inList and '' or ' (not in the game list right now)'))
    else
        colored(C.MUTED, 'pick one above')
    end
    drawSettingsBody()
    local label = (settings.count or 0) > 0 and string.format('Make %d##tsStart', settings.count) or 'Make until out##tsStart'
    if ImGui.Button(label, btnW, btnH) and inList then
        plugin.start(name, settings.count)
    end
    if ImGui.IsItemHovered() then
        core.setTooltip(inList and 'Selects the recipe in the game window and presses Combine until you run out of materials\n(or reach the count). Results are put in your bags.'
            or 'Pick a recipe that is in the game window list first.')
    end
    if state.lastRunSummary ~= '' then
        ImGui.SameLine()
        ImGui.TextDisabled(state.lastRunSummary)
    end
end

local function drawLog(C)
    ImGui.TextDisabled('SESSION LOG')
    if ImGui.BeginChild('##tsLog', 0, core.px(90), true) then
        if #state.log == 0 then
            colored(C.MUTED, '(nothing yet)')
        else
            for _, e in ipairs(state.log) do
                ImGui.TextDisabled(e.time)
                ImGui.SameLine()
                if e.kind == 'good' then colored(C.GOOD, e.text)
                elseif e.kind == 'warn' then colored(C.WARN, e.text)
                else ImGui.Text(e.text) end
            end
        end
    end
    ImGui.EndChild()
end

local function drawWindow()
    if not ctrl or not ctrl.show_tradeskill then return end
    local C = colorsTable()
    core.pushTheme()
    ImGui.SetNextWindowSize(core.px(460), core.px(520), ImGuiCond.FirstUseEver)
    core.preBeginWindow('tradeskill')
    local flags = core.windowFlags and core.windowFlags('tradeskill', 0) or 0
    local open, draw = ImGui.Begin('MoriAC Tradeskills###TriuneTradeskills', ctrl.show_tradeskill, flags)
    if not open then
        ctrl.show_tradeskill = false
        if core.preEndWindow then core.preEndWindow('tradeskill', false) end
        ImGui.End()
        core.popTheme()
        core.saveLoadout(true)
        return
    end
    if not draw then
        if core.preEndWindow then core.preEndWindow('tradeskill', false) end
        ImGui.End()
        core.popTheme()
        return
    end
    core.postBeginWindow('tradeskill')

    if ImGui.BeginPopupContextWindow('##tsContextMenu') then
        if core.applyWindowScale then core.applyWindowScale('tradeskill') end
        if core.drawWindowMenuItems then
            core.drawWindowMenuItems('tradeskill', { header = false, close = false })
            ImGui.Separator()
        end
        local dbg = ImGui.Checkbox('Debug info##tsDbg', state.debug == true)
        if dbg ~= (state.debug == true) then state.debug = dbg end
        ImGui.EndPopup()
    end

    colored(C.ARC, 'TRADESKILLS')
    ImGui.SameLine()
    ImGui.TextDisabled('| Make a recipe until you run out')
    ImGui.Separator()

    if not state.windowOpen and not state.running then
        colored(C.MUTED, 'Open a tradeskill container (forge, oven, loom, kit...) so the game tradeskill window shows,')
        colored(C.MUTED, 'then pick a recipe here.')
    else
        if ctrl.running then
            colored(C.WARN, 'MoriAC is running and may move or pull while you craft. Pause it first.')
        end
        if state.windowOpen and not state.controls.list then
            colored(C.WARN, 'Cannot find the recipe list. Switch the game window out of Experiment mode.')
        end
        if state.debug then
            ImGui.TextDisabled(string.format('list: %s (%s)  combine: %s (%s)',
                tostring(state.controls.list or '-'), tostring(state.controlsHow.list or '-'),
                tostring(state.controls.combine or '-'), tostring(state.controlsHow.combine or '-')))
        end
        drawRecipeList(C)
        ImGui.Dummy(0, core.px(4))
        drawRunControls(C)
    end
    ImGui.Dummy(0, core.px(4))
    drawLog(C)

    if core.preEndWindow then core.preEndWindow('tradeskill', true) end
    ImGui.End()
    core.popTheme()
end

function plugin.onDrawUI()
    if not core then return end
    refresh()
    drawWindow()
end

function plugin.onDrawSettings()
    if not core then return end
    refresh()
    if core.section('tradeskill_make', 'Making recipes', true) then
        drawSettingsBody()
    end
end

-- /ac ts                    toggle the window
-- /ac ts make <recipe> [n]  make a recipe from the game window list (n = count, default until out)
-- /ac ts stop               stop a run
function plugin.onCommand(cmd, args)
    if cmd ~= 'ts' and cmd ~= 'tradeskill' and cmd ~= 'tradeskills' then return false end
    refresh()
    local sub = (args and args[2]) and string.lower(args[2]) or ''
    if sub == 'make' or sub == 'start' then
        local parts = {}
        for i = 3, #args do parts[#parts + 1] = args[i] end
        local count = 0
        if #parts > 1 and tonumber(parts[#parts]) then count = tonumber(parts[#parts]); parts[#parts] = nil end
        local name = table.concat(parts, ' ')
        if name == '' then name = state.selected or settings.lastRecipe or '' end
        plugin.start(name, count)
    elseif sub == 'stop' then
        if plugin.stop() then say('Stopping.') else say('Nothing is being made.') end
    else
        plugin.openWindow()
        say('Tradeskills window %s.', ctrl.show_tradeskill and 'OPENED' or 'CLOSED')
    end
    return true
end

plugin.help = {
    '  \ag/ac ts\ax - Toggle the Tradeskills window',
    '  \ag/ac ts make <recipe> [count]\ax - Make a recipe from the game tradeskill window until out of materials (or count)',
    '  \ag/ac ts stop\ax - Stop making',
}

-- Exposed for tests
plugin.state = state
plugin.settings = settings
plugin._findRecipeRow = findRecipeRow
plugin._filterRecipes = filterRecipes
plugin._stripArticle = stripArticle
plugin._summaryLine = summaryLine
plugin._onResult = onResult
plugin._onMissingItem = onMissingItem
plugin._onSkillUp = onSkillUp
plugin._onTrivial = onTrivial

return plugin
