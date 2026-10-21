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
UIManager.top = nil
function UIManager:show(w) say("  [show]" .. (w.modal and " (modal)" or ""), w.text or "?") self.top = w end
function UIManager:close(w) say("  [close]", w.text or "?") if self.top == w then self.top = nil end end
function UIManager:getTopmostVisibleWidget() return self.top end
function UIManager:forceRePaint() end
function UIManager:setDirty(w, t) say("  [refresh]", t) end
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
local Device = { screen_saver_mode = false, model = "Kobo_clarabw", suspend_calls = {},
    screen = { getWidth = function() return 1072 end, getHeight = function() return 1448 end, scaleBySize = function(_, v) return v * 2 end } }
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
    function kosync:updateProgress(ensure, interactive)
        if interactive then say("  [kosync] updateProgress interactive=true") end
        if push_fails then say("  [kosync] updateProgress FAILED -> queued") KOSyncQueue:push({ document = "digest1", device_id = "DEV" }) return end
        say("  [kosync] updateProgress route=" .. tostring(wifi.route))
        -- the server now holds our position, stamped with the push time
        server[self:getDocumentDigest()] = { device_id = self.device_id, device = "Kobo Clara BW",
            progress = self:getLastProgress(), percentage = self:getLastPercent(), timestamp = os.time() }
    end
    function kosync:getProgress() say("  [kosync] getProgress route=" .. tostring(wifi.route)) end
    function kosync:getDocumentDigest() return "digest1" end
    function kosync:getMetadata() return { title = "Vestigios" } end
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
    ["ffi/blitbuffer"] = { COLOR_WHITE = "white", COLOR_BLACK = "black" },
    ["ui/font"] = { getFace = function(_, name, size) return { name = name, size = size } end },
    ["ui/geometry"] = { new = function(_, o) return o end },
    ["ui/size"] = { border = { default = 2, thin = 1 }, padding = { default = 10, large = 20 } },
    ["ui/widget/textwidget"] = { new = function(_, o) o.getSize = function() return { w = 300, h = 40 } end return o end },
    ["ui/widget/container/framecontainer"] = { new = function(_, o) o.getSize = function() return { w = 300 + 2 * 20 + 4, h = 40 + 2 * 10 + 4 } end return o end },
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

-- MTK radio stack: by default the harness device is not an MTK Kobo, so the
-- stack check never runs. mtk(files, launcher) makes it one, with `files`
-- (path -> mode) as the only existing paths and the firmware daemon running or not.
local lfs_stub = stubs["libs/libkoreader-lfs"]
local real_isLauncherRunning = Link.isLauncherRunning
local function yes() return true end
local function resetRadio()
    Device.isKobo = nil Device.isMTK = nil
    lfs_stub.attributes = function() return nil end
    Link.isLauncherRunning = real_isLauncherRunning
    package.loaded["src/kobo_bluetooth"] = nil
    package.loaded["src/lib/bluetooth/wmt_power"] = nil
end
local function mtk(files, launcher)
    Device.isKobo = yes Device.isMTK = yes
    lfs_stub.attributes = function(path) return files and files[path] or nil end
    Link.isLauncherRunning = function() return launcher == true end
end

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
    resetRadio()
    fn()
end

scenario("open a book: pull only once DHCP is done, then Wi-Fi off", function()
    local p = newReader()
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    p:onReaderReady()
    advance(30)
    check(lastLogHas("getProgress route=true"), "pull ran with a default route")
    check(not wifi.modules, "wifi is off at the end")
    check(not NetworkMgr.pending_connection, "no pending connection left")
    check(gsettings.wifi_was_on == true, "wifi_was_on restored to prior value")
    local items = {} p:addToMainMenu(items) local sub = items.kosyncwifi and items.kosyncwifi.sub_item_table_func() check(sub and #sub > 5, "menu builds (Tools fallback)")
    check(sub[1].text_func():find("open"), "status: " .. sub[1].text_func())
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
    check(lastLogHas("not pulling: latest progress is this device's own"), "converted job checked the server for a pull")
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
    check(Link.last and Link.last.detail:find("queued sent: d2, 1 queued dropped"), "summary: " .. tostring(Link.last and Link.last.detail))
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
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
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

-- A boot where Nickel never used the radio (MTK): enable-wifi.sh would panic the kernel.
scenario("cold MTK boot, nobody brings the radio up: open pull gives up at once, touches nothing", function()
    mtk({}, false)
    local p = newReader()
    p:onReaderReady()
    advance(1)
    check(not lastLogHas("[script] started"), "no restore script started")
    check(not lastLogHas("[net] disableWifi") and not lastLogHas("[kill]"), "no teardown for a job that started nothing")
    check(Link.job == nil and #tasks == 0, "job over, timeout unscheduled")
    check(Link.last and Link.last.detail == "radio not started", "status: " .. tostring(Link.last and Link.last.detail))
    check(not NetworkMgr.pending_connection, "no pending connection flagged (kobo.koplugin reads it)")
end)

scenario("cold MTK boot, kobo.koplugin bringing the stack up: wait, start on BluetoothWifiReleased", function()
    mtk({ ["/dev/stpbt"] = "char device" }, true) -- what the own check would see mid bring-up
    local stack_ready = false
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = true }
    package.loaded["src/lib/bluetooth/wmt_power"] = { bringing_up = true, isStackLoaded = function() return stack_ready end }
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    local started_at
    local real_restore = NetworkMgr.restoreWifiAsync
    NetworkMgr.restoreWifiAsync = function(self) started_at = now real_restore(self) end
    local p = newReader()
    p:onReaderReady()
    UIManager:scheduleIn(13.5, function()
        local wmt = package.loaded["src/lib/bluetooth/wmt_power"]
        wmt.bringing_up = false stack_ready = true
        package.loaded["src/kobo_bluetooth"].wifi_borrowed = false
        p:onBluetoothWifiReleased() -- the plugin's broadcast
    end)
    advance(60)
    NetworkMgr.restoreWifiAsync = real_restore
    check(started_at == 13.5, "script started on the event, not at the next poll (at " .. tostring(started_at) .. " s)")
    check(lastLogHas("getProgress route=true"), "pulled")
    check(not wifi.modules, "wifi off at the end")
end)

scenario("MTK, bring-up finished but failed (plugin says missing): Sync now explains", function()
    mtk({}, false)
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = false }
    package.loaded["src/lib/bluetooth/wmt_power"] = { bringing_up = false, isStackLoaded = function() return false end }
    local p = newReader()
    p:onKOSyncWiFiSyncNow() advance(5)
    check(lastLogHas("[show] Wi-Fi can't be turned on yet") and lastLogHas("Turn Bluetooth on"), "message says to turn Bluetooth on")
    check(not lastLogHas("[script] started"), "no restore script started")
end)

scenario("MTK, plugin's stack check says ready: sync runs even without the own evidence", function()
    mtk({}, false)
    package.loaded["src/lib/bluetooth/wmt_power"] = { isStackLoaded = function() return true end }
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    local p = newReader()
    p:onReaderReady() advance(30)
    check(lastLogHas("getProgress route=true"), "pulled")
end)

scenario("MTK without kobo.koplugin: device node plus firmware daemon counts as ready", function()
    mtk({ ["/dev/stpbt"] = "char device" }, true)
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    local p = newReader()
    p:onReaderReady() advance(30)
    check(lastLogHas("getProgress route=true"), "pulled")
end)

scenario("MTK without kobo.koplugin: the plugin's ready marker counts as ready", function()
    mtk({ ["/tmp/kobo.koplugin-wmt-stack-ready"] = "file" }, false)
    local p = newReader()
    p:onReaderReady() advance(30)
    check(lastLogHas("[script] started by plugin"), "script started")
end)

scenario("MTK without kobo.koplugin: device node but no firmware daemon is not ready", function()
    mtk({ ["/dev/stpbt"] = "char device" }, false)
    local p = newReader()
    p:onKOSyncWiFiSyncNow() advance(5)
    check(not lastLogHas("[script] started"), "no restore script started")
    check(lastLogHas("Turn Wi-Fi on in Kobo's own software"), "message for a device without the Bluetooth plugin")
end)

scenario("cold MTK boot, sleep with a book: suspend released at once, close position stays queued", function()
    mtk({}, false)
    local p = newReader()
    p:onPageUpdate(2)
    Device.screen_saver_mode = true
    p:onSuspend()
    advance(1)
    check(Device.suspend_calls[1] == 50 and Device.suspend_calls[2] == 1, "suspend held, then released right away")
    check(Link.last and Link.last.kind == "sleep" and Link.last.detail == "radio not started", "status: " .. tostring(Link.last and Link.last.detail))
    Device.screen_saver_mode = false
    p:onResume()
    p:onCloseDocument()
    check(#queue == 1, "close position queued for later")
    check(Link.last and Link.last.detail == "radio not started, queued", "status: " .. tostring(Link.last and Link.last.detail))
    advance(5)
    check(Link.last and Link.last.kind == "wake" and Link.last.detail == "radio not started", "wake sync gave up too")
    check(#queue == 1 and not lastLogHas("[script] started"), "still queued, nothing started")
end)

scenario("a job that only waited and timed out tears nothing down", function()
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = true } -- never released
    local p = newReader()
    p:onReaderReady()
    advance(36)
    check(Link.job == nil and Link.last and Link.last.detail == "no Wi-Fi", "job timed out")
    check(not lastLogHas("[net] disableWifi") and not lastLogHas("[kill]"), "no disable-wifi.sh, no kill")
end)

scenario("isLauncherRunning finds wmt_launcher by program name in /proc", function()
    local real_dir, real_open = lfs_stub.dir, io.open
    local cmdlines = { ["/proc/7/cmdline"] = "/bin/sh\0-c\0x\0", ["/proc/42/cmdline"] = "wmt_launcher\0-p\0/lib/firmware\0" }
    lfs_stub.dir = function() local names, i = { ".", "self", "7", "42" }, 0 return function() i = i + 1 return names[i] end end
    io.open = function(path) local s = cmdlines[path] if not s then return nil end return { read = function() return s end, close = function() end } end
    local found = real_isLauncherRunning()
    cmdlines["/proc/42/cmdline"] = "/usr/bin/wmt_loader\0"
    local not_found = real_isLauncherRunning()
    lfs_stub.dir, io.open = real_dir, real_open
    check(found == true, "found without a path")
    check(not_found == false, "wmt_loader is not the launcher")
end)

scenario("wake: a foreign script that fails is waited out, then we connect", function()
    local p = newReader()
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
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
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
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

scenario("USB mass storage while waiting for a foreign script: that script is stopped too", function()
    local p = newReader()
    startScript("other")
    p:onResume()
    advance(3)
    check(Link.job ~= nil and wifi.script and wifi.script.owner == "other", "waiting for the foreign script")
    p:onClose()
    check(wifi.script == nil, "foreign script stopped")
    check(not lastLogHas("[net] disableWifi"), "no Wi-Fi teardown for a job that started nothing")
    check(Link.job == nil, "job aborted")
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



scenario("pop-ups: open/wake pulls show nothing", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    check(not lastLogHas("[show]"), "no pop-up on open")
    p:onResume() advance(30)
    check(not lastLogHas("[show]"), "no pop-up on wake")
end)

scenario("pop-ups: sleep push draws a modal box on the sleep screen, wake removes it", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(lastLogHas("[show] (modal) Progress pushed at"), "modal box shown on the sleep screen")
    local d = p.sleep_box and p.sleep_box.dimen
    check(d and d.y == 1448 - 64 - 36 and d.x == math.floor((1072 - 344) / 2), "box sits centred near the bottom edge")
    check(p.sleep_box.frame.radius == 0 and p.sleep_box.frame[1].face.name == "NotoSerif-Regular.ttf", "square frame, serif face")
    Device.screen_saver_mode = false
    p:onResume()
    check(lastLogHas("[close] Progress pushed at"), "box closed on wake")
    check(lastLogHas("[refresh] full"), "full refresh after removing it")
    advance(30)
end)

scenario("pop-ups: sleep push with nothing new shows nothing", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    server.digest1 = { timestamp = os.time() - 100, device_id = "X3", device = "Xteink", progress = "/body/x", percentage = 0.5 }
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(not lastLogHas("[show]"), "no box for 'in sync'")
end)

scenario("pop-ups: online close push shows a pop-up above the file manager", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    wifi.modules = true wifi.address = true wifi.route = true
    p:onCloseDocument()
    check(not lastLogHas("[show] Progress pushed: Vestigios."), "not shown synchronously during close")
    advance(now + 2)
    check(lastLogHas("[show] Progress pushed: Vestigios."), "shown shortly after, naming the book")
end)

scenario("pop-ups: offline close, queue sent later, pop-up then", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    p:onCloseDocument()
    advance(40)
    check(lastLogHas("[show] Progress pushed: Vestigios (queued)."), "pop-up after the background send names the book")
end)

scenario("pop-ups: disabled setting shows nothing", function()
    local p = newReader()
    p.settings.notify = false
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(not lastLogHas("[show]"), "nothing shown")
    p.settings.notify = true
end)



scenario("Sync now: exactly one summary pop-up, KOSync called silently", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    local before = #log
    p:onKOSyncWiFiSyncNow() advance(now + 40)
    local shows = 0
    for i = before + 1, #log do if log[i]:find("[show]", 1, true) then shows = shows + 1 end end
    check(shows == 1, "one pop-up, got " .. shows)
    check(lastLogHas("[show] Progress sync: pushed"), "it is the summary")
    check(not lastLogHas("interactive=true"), "KOSync not called interactively")
end)

scenario("Sync now: no summary when KOSync's prompt is on screen", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    local real_get = kosync.getProgress
    local real_update = kosync.updateProgress
    kosync.updateProgress = function() say("  [kosync] updateProgress (server untouched)") end
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    kosync.getProgress = function(self, ensure, interactive)
        say("  [kosync] getProgress prompt")
        UIManager:show({ text = "Sync to latest location?" })
    end
    local before = #log
    p:onKOSyncWiFiSyncNow() advance(now + 40)
    kosync.getProgress = real_get
    kosync.updateProgress = real_update
    local shows = 0
    for i = before + 1, #log do if log[i]:find("[show]", 1, true) then shows = shows + 1 end end
    check(shows == 1, "only the prompt is on screen, got " .. shows)
    check(not lastLogHas("[show] Progress sync:"), "summary suppressed")
end)

scenario("Sync now: no Wi-Fi gives one message", function()
    local p = newReader()
    wifi.never = true
    local before = #log
    p:onKOSyncWiFiSyncNow() advance(now + 60)
    local shows = 0
    for i = before + 1, #log do if log[i]:find("[show]", 1, true) then shows = shows + 1 end end
    check(shows == 1 and lastLogHas("[show] Could not connect to Wi-Fi."), "single failure message")
end)



scenario("wake after our own sleep push: no pull, no prompt", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    Device.screen_saver_mode = true
    p:onSuspend() advance(60)
    check(Link.last and Link.last.detail == "pushed", "sleep push went out")
    local before = #log
    Device.screen_saver_mode = false
    p:onResume() advance(now + 40)
    local pulled = false
    for i = before + 1, #log do if log[i]:find("[kosync] getProgress", 1, true) then pulled = true end end
    check(not pulled, "KOSync's pull was not called for our own progress")
    check(lastLogHas("not pulling: latest progress is this device's own"), "reason logged")
    check(Link.last and Link.last.detail == "latest is ours", "status: " .. tostring(Link.last and Link.last.detail))
end)

scenario("wake when another device moved on: KOSync pull runs (prompt path)", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
    p:onResume() advance(now + 40)
    check(lastLogHas("[kosync] getProgress route=true"), "KOSync pull called")
end)

scenario("wake when the server already has the current position: in sync, no pull", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/x", percentage = 0.5 }
    local before = #log
    p:onResume() advance(now + 40)
    local pulled = false
    for i = before + 1, #log do if log[i]:find("[kosync] getProgress", 1, true) then pulled = true end end
    check(not pulled, "no pull")
    check(Link.last and Link.last.detail == "in sync", "status in sync")
end)



scenario("menu: entry goes inside Progress sync, both toggles grey each other out", function()
    local p = newReader()
    local auto = { text = "Automatically keep documents in sync", help_text = "KOSync help", checked_func = function() return kosync.settings.auto_sync end }
    local pages = { text_func = function() return "Sync every 10 pages" end, separator = true }
    local behaviour = { text = "Sync behavior" }
    local items = { progress_sync = { text = "Progress sync", sub_item_table = { { text = "Custom sync server" }, auto, pages, behaviour } } }
    p:addToMainMenu(items)
    local list = items.progress_sync.sub_item_table
    check(items.kosyncwifi == nil, "no Tools entry in the reader")
    check(list[4].text == "Wi-Fi on demand sync" and list[5] == behaviour, "inserted after the pages item, before Sync behavior")
    check(pages.separator == nil and list[4].separator == true, "separator moved to our entry")
    -- ours on -> KOSync's toggle greyed with a reason
    check(auto.enabled_func() == false, "KOSync toggle disabled while ours is on")
    check(auto.help_text_func():find("Wi%-Fi on demand sync"), "its help text says why")
    -- ours off -> KOSync's toggle back, original help
    p.settings.enabled = false
    check(auto.enabled_func() == true and auto.help_text_func() == "KOSync help", "KOSync toggle back with its own help")
    -- KOSync auto on -> our Enable greyed with a reason
    kosync.settings.auto_sync = true
    local before = #log
    local sub = list[4].sub_item_table_func()           -- as menu search / position restore would call it
    check(not lastLogHas("[show]"), "no pop-up when built outside a tap")
    local TouchMenu = {}
    function TouchMenu:onMenuSelect(item) return item.sub_item_table_func() end
    sub = TouchMenu:onMenuSelect(list[4])                -- as a tap does
    check(lastLogHas("[show] Wi-Fi on demand sync is off while"), "pop-up explains the greyed menu on tap")
    check(sub[1].text_func():find("Off: turn off"), "first line says why too")
    local enable = sub[2]
    check(enable.text == "Enable" and enable.enabled_func() == false, "our Enable disabled while KOSync auto is on")
    check(enable.help_text_func():find("Automatically keep documents in sync"), "its help text says why")
    kosync.settings.auto_sync = false
    before = #log
    TouchMenu:onMenuSelect(list[4])
    local shown = false
    for i = before + 1, #log do if log[i]:find("[show]", 1, true) then shown = true end end
    check(not shown and enable.enabled_func() == true, "no pop-up and Enable back once KOSync auto is off")
    p.settings.enabled = true
end)



scenario("launch(): same as Sync now, for other plugins' action pickers", function()
    local p = newReader()
    p:onReaderReady() advance(30)
    p:onPageUpdate(2)
    local before = #log
    p:launch() advance(now + 40)
    check(lastLogHas("sync requested: manual"), "launch runs the manual sync")
    check(lastLogHas("[show] Progress sync: pushed"), "with its summary")
end)


print(table.concat(log, "\n"))
print(failures == 0 and "\nALL SCENARIOS PASSED" or ("\n" .. failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
