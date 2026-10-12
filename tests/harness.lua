-- Mock harness for kosyncwifi.koplugin: fakes the KOReader modules the plugin
-- touches, drives a manual clock, and replays the event sequences.
--   luajit test/harness.lua kosyncwifi.koplugin/main.lua
local PLUGIN = arg[1]

local log = {}
local function say(...) local t = {} for i = 1, select("#", ...) do t[#t+1] = tostring(select(i, ...)) end log[#log+1] = table.concat(t, " ") end

-- ---- fake clock + UIManager ------------------------------------------------
local now = 0
local tasks = {}
local UIManager = {}
function UIManager:scheduleIn(s, fn, ...) local args = {...}; table.insert(tasks, { t = now + s, fn = fn, args = args }) end
function UIManager:nextTick(fn, ...) return self:scheduleIn(0, fn, ...) end
function UIManager:unschedule(fn) local n = 0 for i = #tasks, 1, -1 do if tasks[i].fn == fn then table.remove(tasks, i) n = n + 1 end end return n > 0 end
function UIManager:broadcastEvent(ev) say("  [event]", ev.name) end
function UIManager:show(w) say("  [show]", w.text or "?") end
function UIManager:getElapsedTimeSinceBoot() return now end
local function advance(to)
    while true do
        table.sort(tasks, function(a, b) return a.t < b.t end)
        local t = tasks[1]
        if not t or t.t > to then break end
        table.remove(tasks, 1)
        now = t.t
        t.fn(unpack(t.args))
    end
    now = to
end
os.time = function() return math.floor(now) + 1000000 end

-- ---- fake Wi-Fi world ----------------------------------------------------------
-- A "script" models restore-wifi-async.sh: modules load at start (+1 s),
-- association + link-local address at +5 s, DHCP (default route) and exit at +8 s.
local wifi
local function resetWifi()
    wifi = { modules = false, address = false, route = false, script = nil, never = false, pid_counter = 100 }
end
local function startScript(owner)
    wifi.pid_counter = wifi.pid_counter + 1
    wifi.script = { pid = wifi.pid_counter, started = now, owner = owner, never = wifi.never }
    say("  [script] started by", owner, "pid", wifi.script.pid)
end
local function tickWifi()
    local s = wifi.script
    if not s then return end
    local age = now - s.started
    if age >= 1 and not s.modules_loaded then s.modules_loaded = true wifi.modules = true end
    if not s.never then
        if age >= 5 and wifi.modules then wifi.address = true end
        if age >= 8 and wifi.modules then wifi.route = true wifi.script = nil say("  [script] finished") end
    elseif age >= 15 then
        wifi.script = nil wifi.modules = false wifi.address = false say("  [script] gave up, disabled Wi-Fi")
    end
end
local NetworkMgr = { wifi_was_on = true, pending_connection = false, pending_connectivity_check = false }
function NetworkMgr:isWifiOn() tickWifi() return wifi.modules end
function NetworkMgr:isConnected() tickWifi() return wifi.modules and wifi.address end
function NetworkMgr:hasDefaultRoute() tickWifi() return wifi.route end
function NetworkMgr:restoreWifiAsync() startScript("plugin") end
function NetworkMgr:disableWifi() say("  [net] disableWifi") wifi.modules = false wifi.address = false wifi.route = false self.pending_connection = false self:unscheduleConnectivityCheck() end
function NetworkMgr:turnOffWifi() say("  [net] turnOffWifi (foreign)") wifi.modules = false wifi.address = false wifi.route = false end
function NetworkMgr:unscheduleConnectivityCheck() UIManager:unschedule(self.connectivityCheck) self.pending_connectivity_check = false end
function NetworkMgr:scheduleConnectivityCheck(cb) self.pending_connectivity_check = true UIManager:scheduleIn(0.25, self.connectivityCheck, self, 1, cb) end
function NetworkMgr:connectivityCheck(iter, cb)
    if iter >= 180 then say("  [net] connectivity check gave up") self:disableWifi() return end
    if self:isWifiOn() and self:isConnected() then
        self.wifi_was_on = true; G_reader_settings:saveSetting("wifi_was_on", true)
        say("  [net] connectivity check: connected after", iter * 0.25, "s")
        UIManager:broadcastEvent({ name = "NetworkConnected" })
        if cb then cb() end
        self.pending_connectivity_check = false; self.pending_connection = false
    else
        UIManager:scheduleIn(0.25, self.connectivityCheck, self, iter + 1, cb)
    end
end
function NetworkMgr:enableWifi() error("standard method not expected in this harness") end

-- ---- fake Device -------------------------------------------------------------
local Device = { screen_saver_mode = false, model = "Kobo_clarabw", suspend_calls = {} }
function Device:hasWifiRestore() return true end
function Device:rescheduleSuspend(t) say("  [device] rescheduleSuspend", t) table.insert(self.suspend_calls, t) end

-- ---- settings ----------------------------------------------------------------
local gsettings = { wifi_was_on = true }
G_reader_settings = {
    readSetting = function(_, k) return gsettings[k] end,
    saveSetting = function(_, k, v) gsettings[k] = v end,
}

-- ---- fake KOSync, queue, client, server ------------------------------------------
local queue = {}
local server = {} -- document -> { timestamp, device_id, device }
local KOSyncQueue = {}
function KOSyncQueue:count() return #queue end
function KOSyncQueue:load() return queue end
function KOSyncQueue:push(item) item.queued_at = os.time() table.insert(queue, item) say("  [queue] push", item.document) end
function KOSyncQueue:drain(send)
    local n = 0
    for i, it in ipairs(queue) do
        if send(it) then n = n + 1 else
            local rest = {} for j = i, #queue do rest[#rest+1] = queue[j] end queue = rest return n
        end
    end
    queue = {} return n
end
local KOSyncClient = {}
function KOSyncClient:new(o) return setmetatable(o, { __index = KOSyncClient }) end
function KOSyncClient:update_progress(u, k, doc) say("  [client] update_progress (queue item)", doc) return true end
function KOSyncClient:get_progress(u, k, doc, cb)
    local s = server[doc]
    if s then cb(true, s) else cb(false, {}) end
end

local kosync
local push_fails = false
local function resetKOSync()
    kosync = {
        settings = { username = "u", userkey = "k", custom_server = "https://sync.example", kosync_hostname = "Clara", auto_sync = false },
        device_id = "DEV", push_timestamp = 0, pull_timestamp = 0, last_page_turn_timestamp = 0,
    }
    function kosync:updateProgress()
        if push_fails then say("  [kosync] updateProgress FAILED -> queued") KOSyncQueue:push({ document = "digest1", device_id = "DEV" }) return end
        say("  [kosync] updateProgress route=" .. tostring(wifi.route))
    end
    function kosync:getProgress() say("  [kosync] getProgress route=" .. tostring(wifi.route)) end
    function kosync:getDocumentDigest() return "digest1" end
    function kosync:getMetadata() return {} end
    function kosync:getLastProgress() return "/body/x" end
    function kosync:getLastPercent() return 0.5 end
    function kosync:onKOSyncToggleAutoSync(v) say("  [kosync] toggle auto sync", v) self.settings.auto_sync = false end
end

-- ---- module stubs ------------------------------------------------------------
local stubs = {
    ["datastorage"] = { getSettingsDir = function() return "/tmp" end },
    ["device"] = Device,
    ["dispatcher"] = { registerAction = function() end },
    ["ui/event"] = { new = function(_, name) return { name = name } end },
    ["ui/widget/infomessage"] = { new = function(_, o) return o end },
    ["luasettings"] = { open = function() return { readSetting = function() return kosync.settings end } end },
    ["ui/network/manager"] = NetworkMgr,
    ["ui/widget/notification"] = { notify = function(_, t) say("  [notify]", t) end },
    ["ui/uimanager"] = UIManager,
    ["ui/widget/container/widgetcontainer"] = { extend = function(_, o) o.new = function(cls, inst) inst = inst or {} setmetatable(inst, { __index = cls }) inst:init() return inst end return o end },
    ["libs/libkoreader-lfs"] = { dir = function() error("no /proc here") end },
    ["logger"] = { info = function(...) say("  [log]", ...) end, warn = function(...) say("  [warn]", ...) end, err = function(...) say("  [ERR]", ...) end, dbg = function() end },
    ["ffi/util"] = { template = function(s, ...) local a = {...} return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end },
    ["gettext"] = function(s) return s end,
    ["ui/widget/spinwidget"] = { new = function(_, o) return o end },
    ["KOSyncQueue"] = KOSyncQueue,
    ["KOSyncClient"] = KOSyncClient,
}
local real_require = require
package.searchpath = function() return "/plugins/kosync.koplugin/KOSyncClient.lua" end
require = function(name) if stubs[name] ~= nil then return stubs[name] end return real_require(name) end

local Plugin = dofile(PLUGIN)
local Link = Plugin._Link
Link.findScript = function() tickWifi() return wifi.script and wifi.script.pid end
Link.killScript = function(pid) say("  [kill] script pid", tostring(pid)) wifi.script = nil end
local menu = { registerToMainMenu = function() end }

local doc_settings_store = {}
local function newReader()
    local ui = { document = {}, kosync = kosync, menu = menu, current_page = 1 }
    ui.getCurrentPage = function(self) return self.current_page end
    ui.doc_settings = { readSetting = function(_, k) return doc_settings_store[k] end, saveSetting = function(_, k, v) doc_settings_store[k] = v end }
    return Plugin:new{ ui = ui }
end
local function newFM() return Plugin:new{ ui = { menu = menu } } end

local failures = 0
local function check(cond, msg) if cond then say("  OK:", msg) else failures = failures + 1 say("  FAIL:", msg) end end
local scenario_start = 0
local function lastLogHas(s) for i = #log, scenario_start + 1, -1 do if log[i]:find(s, 1, true) then return true end end return false end
local function scenario(name, fn)
    say("== " .. name)
    scenario_start = #log
    tasks = {} now = 0 resetWifi() queue = {} server = {} push_fails = false resetKOSync()
    NetworkMgr.wifi_was_on = true NetworkMgr.pending_connection = false NetworkMgr.pending_connectivity_check = false
    gsettings.wifi_was_on = true Device.screen_saver_mode = false Device.suspend_calls = {}
    Link.shutting_down = false Link.job = nil Link.last = nil doc_settings_store = {}
    fn()
end

scenario("open a book: pull only once DHCP is done, then Wi-Fi off", function()
    local p = newReader()
    p:onReaderReady()
    advance(30)
    check(lastLogHas("getProgress route=true"), "pull ran with a default route")
    check(not wifi.modules, "wifi is off at the end")
    check(not NetworkMgr.pending_connection, "no pending connection left")
    check(gsettings.wifi_was_on == true, "wifi_was_on restored to prior value")
    local items = {} p:addToMainMenu(items) check(items.kosyncwifi and #items.kosyncwifi.sub_item_table > 5, "menu builds")
    check(items.kosyncwifi.sub_item_table[1].text_func():find("open"), "status: " .. items.kosyncwifi.sub_item_table[1].text_func())
end)

scenario("sleep with a book: hold suspend, push after DHCP, release", function()
    local p = newReader()
    Device.screen_saver_mode = true
    p:onSuspend()
    advance(0.5)
    check(Device.suspend_calls[1] == 50, "suspend pushed out to 50 s")
    advance(60)
    check(lastLogHas("updateProgress route=true"), "push ran with a default route")
    check(Device.suspend_calls[#Device.suspend_calls] == 1, "suspend released right after the push")
    check(not wifi.modules, "wifi is off")
    check(#tasks == 0, "no stray scheduled tasks")
end)

scenario("sleep, but woken up before Wi-Fi came up", function()
    local p = newReader()
    Device.screen_saver_mode = true
    p:onSuspend()
    advance(3)
    Device.screen_saver_mode = false
    p:onResume()
    advance(60)
    check(#Device.suspend_calls == 1, "suspend not re-armed after wake")
    check(lastLogHas("getProgress route=true"), "converted job also pulled")
    check(not wifi.modules, "wifi off after the converted job")
end)

scenario("sleep, Wi-Fi never comes up", function()
    local p = newReader()
    Device.screen_saver_mode = true
    wifi.never = true
    p:onSuspend()
    advance(100)
    check(Device.suspend_calls[#Device.suspend_calls] == 1, "suspend released after the timeout")
    check(not NetworkMgr.pending_connection, "pending_connection cleared")
    check(wifi.script == nil, "no script left running")
    check(#tasks == 0, "no stray scheduled tasks")
end)

scenario("close a book offline: queue, then drain in background", function()
    local p = newReader()
    p:onPageUpdate(2)
    p:onCloseDocument()
    p = nil
    check(#queue == 1 and queue[1].last_page_turn ~= nil, "position queued with reading time")
    advance(30)
    check(#queue == 0, "queue drained")
    check(not wifi.modules, "wifi off")
end)

scenario("close a book while already online: direct push, Wi-Fi left alone", function()
    local p = newReader()
    wifi.modules = true wifi.address = true wifi.route = true
    p:onCloseDocument()
    advance(5)
    check(wifi.modules, "wifi left on")
    check(Link.last and Link.last.detail == "pushed", "reported as pushed")
end)

scenario("push failure is reported as queued", function()
    local p = newReader()
    push_fails = true
    Device.screen_saver_mode = true
    p:onSuspend()
    advance(60)
    check(Link.last and Link.last.detail:find("push failed, queued"), "status says queued: " .. tostring(Link.last and Link.last.detail))
    check(Link.last and Link.last.ok == false, "status marked as not ok")
end)

scenario("queued position is dropped when another device moved on since", function()
    queue = { { document = "d1", device_id = "DEV", last_page_turn = os.time() - 500, queued_at = os.time() },
              { document = "d2", device_id = "DEV", last_page_turn = os.time() - 500, queued_at = os.time() } }
    server.d1 = { timestamp = os.time() - 100, device_id = "X3", device = "Xteink" } -- newer than our reading
    server.d2 = { timestamp = os.time() - 900, device_id = "X3", device = "Xteink" } -- older
    local p = newFM()
    p:onResume()
    advance(30)
    check(#queue == 0, "queue empty")
    check(lastLogHas("dropping a queued position for d1"), "d1 dropped")
    check(lastLogHas("update_progress (queue item) d2"), "d2 sent")
    check(Link.last and Link.last.detail:find("1 queued sent, 1 queued dropped"), "summary: " .. tostring(Link.last and Link.last.detail))
end)

scenario("queue kept when the server cannot be asked", function()
    queue = { { document = "d1", device_id = "DEV", queued_at = os.time() } }
    KOSyncClient.get_progress = function() error("network unreachable") end
    local p = newFM()
    p:onResume()
    advance(30)
    check(#queue == 1, "item kept for later")
    KOSyncClient.get_progress = function(self, u, k, doc, cb) local s = server[doc] if s then cb(true, s) else cb(false, {}) end end
end)

scenario("wake: Bluetooth plugin has Wi-Fi borrowed, we wait for it", function()
    local p = newReader()
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = true }
    UIManager:scheduleIn(2.5, function() package.loaded["src/kobo_bluetooth"].wifi_borrowed = false end)
    local started_at
    local real_restore = NetworkMgr.restoreWifiAsync
    NetworkMgr.restoreWifiAsync = function(self) started_at = now real_restore(self) end
    p:onResume()
    advance(60)
    NetworkMgr.restoreWifiAsync = real_restore
    package.loaded["src/kobo_bluetooth"] = nil
    check(started_at and started_at >= 2.5, "our script started only after Bluetooth released Wi-Fi (at " .. tostring(started_at) .. " s)")
    check(lastLogHas("getProgress route=true"), "pulled")
    check(not wifi.modules, "wifi off at the end")
end)

scenario("wake: a foreign script that fails is waited out, then we connect", function()
    local p = newReader()
    wifi.never = true
    startScript("other")           -- doomed foreign script (gives up at 15 s)
    wifi.never = false
    p:onResume()
    advance(60)
    check(not lastLogHas("[kill]"), "nothing was killed")
    check(lastLogHas("getProgress route=true"), "our own connection then succeeded")
    check(not wifi.modules, "wifi off at the end")
end)

scenario("wake: another script finishes normally and leaves Wi-Fi on", function()
    local p = newReader()
    startScript("other")
    p:onResume()
    advance(30)
    check(lastLogHas("getProgress route=true"), "pulled over the foreign connection")
    check(wifi.modules, "foreign Wi-Fi left on")
end)

scenario("USB mass storage: Close aborts the job and stops the script", function()
    local p = newReader()
    p:onPageUpdate(2)
    p:onCloseDocument()
    advance(2)
    check(wifi.script ~= nil, "close job started a script")
    p:onClose()   -- 'Close' broadcast from MassStorage before quitting
    check(wifi.script == nil, "script stopped")
    check(Link.job == nil, "job aborted")
    check(#queue == 1, "position still queued for next time")
    advance(60)
    check(#tasks == 0, "no stray tasks")
end)

scenario("Close arrives before the close push: just queue", function()
    local p = newReader()
    p:onPageUpdate(2)
    p:onClose()
    p:onCloseDocument()
    advance(5)
    check(wifi.script == nil, "no script started")
    check(#queue == 1, "position queued")
end)

scenario("sleep while a close job is still connecting", function()
    local p = newReader()
    p:onPageUpdate(2)
    p:onCloseDocument()
    local fm = newFM()
    Device.screen_saver_mode = true
    fm:onSuspend()
    advance(0.5)
    check(Device.suspend_calls[1] == 50, "suspend held for the running job")
    advance(60)
    check(Device.suspend_calls[#Device.suspend_calls] == 1, "suspend released")
    check(#queue == 0, "queue drained")
end)


scenario("sleep push: a page was turned here, server older -> pushed", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    server.digest1 = { timestamp = os.time() - 100, device_id = "X3", device = "Xteink", progress = "/body/old", percentage = 0.4 }
    p:onPageUpdate(2)
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(Link.last and Link.last.detail == "pushed", "pushed: " .. tostring(Link.last and Link.last.detail))
    check(doc_settings_store.kosyncwifi_last_page_turn ~= nil, "page-turn time persisted per book")
    check(kosync.last_page_turn_timestamp == doc_settings_store.kosyncwifi_last_page_turn, "KOSync got the page-turn time too")
end)

scenario("sleep push: nothing read here and another device is ahead -> not pushed", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    server.digest1 = { timestamp = os.time() + 50, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(Link.last and Link.last.detail:find("not pushed: Xteink is ahead"), "skipped: " .. tostring(Link.last and Link.last.detail))
end)

scenario("sleep push: another device pushed AFTER our last page turn -> not pushed", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    advance(40)
    server.digest1 = { timestamp = os.time(), device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(Link.last and Link.last.detail:find("is ahead"), "skipped: " .. tostring(Link.last and Link.last.detail))
end)

scenario("sleep push: server already has our position -> in sync, not pushed", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    server.digest1 = { timestamp = os.time() - 100, device_id = "X3", device = "Xteink", progress = "/body/x", percentage = 0.5 }
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(Link.last and Link.last.detail:find("in sync"), "in sync: " .. tostring(Link.last and Link.last.detail))
end)

scenario("close offline with no page turned here -> nothing queued", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onCloseDocument()
    advance(30)
    check(#queue == 0, "nothing queued")
    check(wifi.script == nil, "no Wi-Fi started")
end)

scenario("close offline after reading -> queued with the reading time, then sent", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(3)
    local turn = os.time()
    advance(5)
    p:onCloseDocument()
    check(#queue == 1 and queue[1].last_page_turn == turn, "queued with reading time")
    advance(40)
    check(#queue == 0, "sent")
end)

scenario("legacy queue item with last_page_turn 0 is dropped as unread", function()
    queue = { { document = "d1", device_id = "DEV", last_page_turn = 0, queued_at = os.time(), progress = "/a", percentage = 0.6 } }
    server.d1 = { timestamp = os.time() - 5000, device_id = "X3", device = "Xteink", progress = "/b", percentage = 0.7 }
    local p = newFM()
    p:onResume() advance(30)
    check(#queue == 0 and lastLogHas("dropping a queued position for d1 - Xteink is ahead"), "dropped")
end)

scenario("page-turn time survives reopening the book", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(5)
    local turn = os.time()
    advance(100)
    resetKOSync()
    local p2 = newReader()
    p2:onReaderReady() advance(30)
    check(p2:getLastPageTurn() == turn, "restored from doc settings")
    check(kosync.last_page_turn_timestamp == turn, "handed to the new KOSync instance")
end)


print(table.concat(log, "\n"))
print(failures == 0 and "\nALL SCENARIOS PASSED" or ("\n" .. failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
