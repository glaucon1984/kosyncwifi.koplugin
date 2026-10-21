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
        now = math.max(now, t.t) -- a blocking step may already have moved the clock past it
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

-- MTK radio: by default the harness device is not an MTK Kobo, so none of the
-- radio code runs. mtk{...} makes it one, with a fake radio: loaded modules,
-- the firmware daemon, kobo.koplugin's ready marker, other processes, and
-- every start-up step recorded in radio.steps. Radio.run and Radio.sleep block
-- in the real plugin, so the fakes move the clock without running any
-- scheduled task: whatever is scheduled meanwhile runs only afterwards.
local lfs_stub = stubs["libs/libkoreader-lfs"]
local Radio = Plugin._Radio
local real = { isLauncherRunning = Link.isLauncherRunning, listProcesses = Link.listProcesses }
local radio
local function yes() return true end
local ALL_MODULES = { "wmt_drv", "wmt_chrdev_wifi", "wmt_cdev_bt", "wlan_drv_gen4m" }
local function resetRadio()
    -- hang[key]: that step runs into its time limit; fail[key]: it exits with 1
    -- (keys: a module name, "loader", "launcher", a handshake value)
    radio = { modules = {}, launcher = false, marker = false, procs = {}, steps = {}, hang = {}, fail = {} }
    Device.isKobo = nil Device.isMTK = nil
    lfs_stub.attributes = function(path)
        if path == "/dev/stpbt" then return radio.modules.wmt_cdev_bt and "char device" or nil end
        if path == "/tmp/kobo.koplugin-wmt-stack-ready" then return radio.marker and "file" or nil end
        return nil
    end
    Link.isLauncherRunning = function() return radio.launcher end
    Link.listProcesses = function() return radio.procs end
    Radio.loadedModules = function() local t = {} for k, v in pairs(radio.modules) do t[k] = v end return t end
    Radio.sleep = function(s) now = now + s end
    Radio.startLauncher = function()
        table.insert(radio.steps, "launcher")
        if not radio.fail.launcher then radio.launcher = true end
    end
    Radio.run = function(command, limit)
        table.insert(radio.steps, command)
        local module = command:match("insmod %S*/([%w_]+)%.ko")
        local key = module or (command:find("wmt_loader", 1, true) and "loader") or command:match("^echo '?([^'>]+)'? >")
        if radio.hang[key] then now = now + limit return false end
        now = now + 0.1
        if radio.fail[key] then return true, 1 end
        if module then radio.modules[module] = true end
        if key == "loader" then
            for i = 2, #ALL_MODULES do if not radio.fail[ALL_MODULES[i]] then radio.modules[ALL_MODULES[i]] = true end end
            return true, 255
        end
        return true, 0
    end
    package.loaded["src/kobo_bluetooth"] = nil
    package.loaded["src/lib/bluetooth/wmt_power"] = nil
end
local function mtk(state)
    Device.isKobo = yes Device.isMTK = yes
    for k, v in pairs(state or {}) do radio[k] = v end
end
-- What Nickel, kobo.koplugin or a finished start-up leaves behind.
local function radioUp()
    local modules = {} for _, m in ipairs(ALL_MODULES) do modules[m] = true end
    return { modules = modules, launcher = true }
end
local function stepIndex(s) for i, st in ipairs(radio.steps) do if st:find(s, 1, true) then return i end end end

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

-- MTK radio. A boot where Nickel never used the radio: KOReader's enable-wifi.sh
-- alone would panic the kernel, so the plugin starts the radio first, unless
-- something else is already working on it.
local function newerOnServer()
    server.digest1 = { timestamp = os.time() + 10, device_id = "X3", device = "Xteink", progress = "/body/new", percentage = 0.7 }
end
local function scriptStartTime()
    local started_at
    local real_restore = NetworkMgr.restoreWifiAsync
    NetworkMgr.restoreWifiAsync = function(self) started_at = started_at or now real_restore(self) end
    return function() NetworkMgr.restoreWifiAsync = real_restore return started_at end
end

scenario("MTK, radio started by Nickel: sync as usual, no start-up of our own", function()
    mtk(radioUp())
    newerOnServer()
    local p = newReader()
    p:onReaderReady() advance(30)
    check(#radio.steps == 0, "no radio start-up steps")
    check(lastLogHas("getProgress route=true"), "pulled")
end)

scenario("cold MTK boot, nothing else around: start the radio Nickel's way, then sync", function()
    mtk()
    newerOnServer()
    local stop = scriptStartTime()
    local p = newReader()
    p:onReaderReady()
    advance(40)
    local started_at = stop()
    local i_drv, i_loader, i_launcher = stepIndex("insmod"), stepIndex("wmt_loader"), stepIndex("launcher")
    local i_unlock, i_on, i_wifi = stepIndex("0xDB9DB9"), stepIndex("7 9 1"), stepIndex("echo 1 >/dev/wmtWifi")
    check(i_drv == 1 and i_drv < i_loader and i_loader < i_launcher and i_launcher < i_unlock and i_unlock < i_on and i_on < i_wifi,
        "order: wmt_drv, loader, firmware daemon, handshake, Wi-Fi function on")
    check(radio.steps[1]:find("/mt66xx/wmt_drv.ko", 1, true) ~= nil, "module from the platform's mt66xx folder: " .. tostring(radio.steps[1]))
    check(stepIndex("wmt_cdev_bt.ko") == nil and #radio.steps == 8, "loader inserted the rest, nothing inserted twice (" .. #radio.steps .. " steps)")
    check(lastLogHas("[show] (modal) Starting the radio for progress sync") and lastLogHas("[close] Starting the radio"), "box shown, then closed")
    check(started_at and started_at >= 4.25, "Wi-Fi script only after the start-up (at " .. tostring(started_at) .. " s)")
    check(lastLogHas("radio started in about"), "logged")
    check(lastLogHas("getProgress route=true"), "pulled")
    check(not wifi.modules, "wifi off at the end")
end)

scenario("cold MTK boot, kobo.koplugin starting the radio (Enable on startup): wait, start nothing ourselves", function()
    mtk()
    local stack_ready = false
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = true }
    package.loaded["src/lib/bluetooth/wmt_power"] = { bringing_up = true, isStackLoaded = function() return stack_ready end }
    newerOnServer()
    local stop = scriptStartTime()
    local p = newReader()
    p:onReaderReady()
    UIManager:scheduleIn(13.5, function()
        mtk(radioUp())
        local wmt = package.loaded["src/lib/bluetooth/wmt_power"]
        wmt.bringing_up = false stack_ready = true
        package.loaded["src/kobo_bluetooth"].wifi_borrowed = false
        p:onBluetoothWifiReleased() -- the plugin's broadcast
    end)
    advance(60)
    local started_at = stop()
    check(#radio.steps == 0, "no start-up of our own")
    check(lastLogHas("waiting for kobo.koplugin to finish with the radio"), "waiting logged")
    check(started_at == 13.5, "Wi-Fi script started on the event (at " .. tostring(started_at) .. " s)")
    check(lastLogHas("getProgress route=true"), "pulled")
end)

scenario("kobo.koplugin installed, Bluetooth not on at startup: start the radio ourselves, its flags untouched", function()
    mtk()
    local kb = { wifi_borrowed = false }
    local wmt = { bringing_up = false, isStackLoaded = function() return radio.launcher and radio.modules.wmt_cdev_bt == true end }
    package.loaded["src/kobo_bluetooth"] = kb
    package.loaded["src/lib/bluetooth/wmt_power"] = wmt
    newerOnServer()
    local p = newReader()
    p:onReaderReady() advance(40)
    check(stepIndex("echo 1 >/dev/wmtWifi") ~= nil, "radio started")
    check(kb.wifi_borrowed == false and wmt.bringing_up == false, "kobo.koplugin's flags not touched")
    check(lastLogHas("getProgress route=true"), "pulled")
end)

scenario("a Bluetooth tap during the start-up is only handled once the radio is up", function()
    mtk()
    local seen
    local p = newReader()
    p:onReaderReady()
    -- what kobo.koplugin would look at when the tap is handled
    UIManager:scheduleIn(1, function() seen = { launcher = radio.launcher, wifi_on = stepIndex("echo 1 >/dev/wmtWifi") ~= nil, at = now } end)
    advance(40)
    check(seen and seen.launcher and seen.wifi_on, "the tap saw a radio that is up, handshake done")
    check(seen and seen.at >= 4.25, "and only after the start-up (at " .. tostring(seen and seen.at) .. " s)")
end)

scenario("another program working on the radio (wmt_loader): wait, then use what it left", function()
    mtk()
    radio.procs = { { pid = 5, cmdline = "/usr/bin/wmt_loader\0" } }
    UIManager:scheduleIn(3, function() radio.procs = {} mtk(radioUp()) end)
    local stop = scriptStartTime()
    local p = newReader()
    p:onReaderReady() advance(40)
    local started_at = stop()
    check(lastLogHas("waiting for wmt_loader to finish with the radio"), "waited for the loader")
    check(#radio.steps == 0, "no start-up of our own")
    check(started_at and started_at >= 3, "Wi-Fi script after it finished (at " .. tostring(started_at) .. " s)")
end)

scenario("KOReader's own enable-wifi.sh running, radio already up: wait for it", function()
    mtk(radioUp())
    radio.procs = { { pid = 6, cmdline = "/bin/sh\0./enable-wifi.sh\0" } }
    UIManager:scheduleIn(2, function() radio.procs = {} end)
    local stop = scriptStartTime()
    local p = newReader()
    p:onReaderReady() advance(40)
    local started_at = stop()
    check(lastLogHas("waiting for enable-wifi.sh"), "waited")
    check(started_at and started_at >= 2, "started after it (at " .. tostring(started_at) .. " s)")
end)

scenario("Kobo's Bluetooth daemon running while the radio is down: give it 10 s, then start the radio", function()
    mtk()
    radio.procs = { { pid = 7, cmdline = "/usr/bin/mtkbtd\0" } }
    local p = newReader()
    p:onReaderReady() advance(9)
    check(#radio.steps == 0 and lastLogHas("waiting for mtkbtd"), "waiting for it at first")
    advance(40)
    check(stepIndex("echo 1 >/dev/wmtWifi") ~= nil, "then started the radio")
    check(lastLogHas("open sync done"), "and synced")
end)

scenario("Kobo's Bluetooth daemon with the radio up is not radio work", function()
    mtk(radioUp())
    radio.procs = { { pid = 7, cmdline = "/usr/bin/mtkbtd\0" }, { pid = 8, cmdline = "/usr/bin/wmt_launcher\0-p\0/lib/firmware\0" } }
    local p = newReader()
    p:onReaderReady() advance(30)
    check(not lastLogHas("waiting for"), "no wait")
    check(lastLogHas("[script] started by plugin"), "connected at once")
end)

scenario("start-up step hangs (chip loader): stopped at its limit, no handshake, no Wi-Fi script", function()
    mtk()
    radio.hang.loader = true
    local p = newReader()
    p:onReaderReady() advance(40)
    check(stepIndex("0xDB9DB9") == nil, "no handshake")
    check(lastLogHas("the chip loader still running after 10 s"), "time-out logged")
    check(not lastLogHas("[script] started"), "no Wi-Fi script")
    check(not lastLogHas("[net] disableWifi"), "no teardown")
    check(lastLogHas("[close] Starting the radio"), "box closed")
    check(Link.last and Link.last.detail == "radio did not start", "status: " .. tostring(Link.last and Link.last.detail))
end)

scenario("a module missing after the loader: stop before the handshake", function()
    mtk()
    radio.fail.wlan_drv_gen4m = true
    local p = newReader()
    p:onReaderReady() advance(40)
    check(stepIndex("wlan_drv_gen4m.ko") ~= nil, "tried to insert it")
    check(stepIndex("0xDB9DB9") == nil and lastLogHas("module wlan_drv_gen4m is not loaded"), "stopped before the handshake")
    check(not lastLogHas("[script] started"), "no Wi-Fi script")
end)

scenario("the firmware daemon does not start: stop before the handshake", function()
    mtk()
    radio.fail.launcher = true
    local p = newReader()
    p:onReaderReady() advance(40)
    check(stepIndex("0xDB9DB9") == nil and lastLogHas("the firmware daemon did not start"), "stopped before the handshake")
end)

scenario("a handshake write fails: stop, no Wi-Fi script", function()
    mtk()
    radio.fail["7 9 1"] = true
    local p = newReader()
    p:onReaderReady() advance(40)
    check(stepIndex("echo 1 >/dev/wmtWifi") == nil, "Wi-Fi function not switched on")
    check(not lastLogHas("[script] started"), "no Wi-Fi script")
end)

scenario("several slow steps: the whole start-up stops at 20 s", function()
    mtk()
    Radio.run = (function(run) return function(command, limit) now = now + 6 return run(command, limit) end end)(Radio.run)
    local p = newReader()
    p:onReaderReady() advance(60)
    check(lastLogHas("over 20 s, not running"), "stopped by the overall limit")
    check(not lastLogHas("[script] started"), "no Wi-Fi script")
end)

scenario("Sync now after a failed start-up says what else starts the radio", function()
    mtk()
    radio.hang.loader = true
    local p = newReader()
    p:onKOSyncWiFiSyncNow() advance(30)
    check(lastLogHas("[show] Could not start the radio for Wi-Fi. Turn Wi-Fi on in Kobo's own software"), "without kobo.koplugin")
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = false }
    p:onKOSyncWiFiSyncNow() advance(60)
    check(lastLogHas("[show] Could not start the radio for Wi-Fi. Turn Bluetooth on"), "with kobo.koplugin")
end)

scenario("sleep on a cold boot: radio started without a box, push goes out, suspend released", function()
    mtk()
    local p = newReader()
    p:onPageUpdate(2)
    Device.screen_saver_mode = true
    p:onSuspend()
    advance(60)
    check(stepIndex("echo 1 >/dev/wmtWifi") ~= nil, "radio started")
    check(not lastLogHas("Starting the radio for progress sync"), "no box on the sleep screen")
    check(lastLogHas("updateProgress route=true"), "pushed")
    check(Device.suspend_calls[#Device.suspend_calls] == 1, "suspend released")
end)

scenario("close offline on a cold boot when the start-up fails: position stays queued", function()
    mtk()
    radio.hang.loader = true
    local p = newReader()
    p:onPageUpdate(2)
    p:onCloseDocument()
    advance(30)
    check(#queue == 1, "still queued")
    check(Link.last and Link.last.detail == "radio did not start, queued", "status: " .. tostring(Link.last and Link.last.detail))
end)

scenario("second sync of the boot: radio already up from our start-up, no second start-up", function()
    mtk()
    local p = newReader()
    p:onReaderReady() advance(40)
    local steps = #radio.steps
    p:onResume() advance(now + 40)
    check(steps > 0 and #radio.steps == steps, "start-up ran once")
end)

scenario("a job that only waited and timed out tears nothing down", function()
    package.loaded["src/kobo_bluetooth"] = { wifi_borrowed = true } -- never released
    local p = newReader()
    p:onReaderReady()
    advance(36)
    check(Link.job == nil and Link.last and Link.last.detail == "no Wi-Fi", "job timed out")
    check(not lastLogHas("[net] disableWifi") and not lastLogHas("[kill]"), "no disable-wifi.sh, no kill")
end)

scenario("radio work found in /proc: scripts, loader, insmod; the Bluetooth daemon only while the radio is down", function()
    local job = {}
    local function work(procs, down) radio.procs = procs return Link.radioWork(job, down) end
    check(work({ { pid = 1, cmdline = "/bin/sh\0./disable-wifi.sh\0" } }, false) == "disable-wifi.sh", "disable-wifi.sh")
    check(work({ { pid = 1, cmdline = "/bin/sh\0./obtain-ip.sh\0" } }, false) == "obtain-ip.sh", "obtain-ip.sh")
    check(work({ { pid = 1, cmdline = "insmod\0/drivers/x/mt66xx/wmt_drv.ko\0" } }, false) == "insmod", "insmod")
    check(work({ { pid = 1, cmdline = "/usr/bin/mtkbtd\0" } }, false) == nil, "mtkbtd ignored while the radio is up")
    check(work({ { pid = 1, cmdline = "/usr/bin/mtkbtd\0" }, { pid = 2, cmdline = "/usr/bin/wmt_loader\0" } }, true) == "wmt_loader", "the loader wins over mtkbtd")
    check(work({ { pid = 1, cmdline = "/usr/bin/wmt_launcher\0-p\0/lib/firmware\0" }, { pid = 2, cmdline = "./luajit\0./reader.lua\0" } }, true) == nil, "the running firmware daemon is not work")
    check(work({ { pid = 1, cmdline = "sh\0-c\0for p in /proc; do case $c in *enable-wifi.sh*) ;; esac; done\0" } }, false) == nil, "a command line that only mentions a script is not work")
    check(work({ { pid = 1, cmdline = "./restore-wifi-async.sh\0" } }, false) == "restore-wifi-async.sh", "a script run directly")
    check(work({ { pid = 1, cmdline = "/usr/bin/btservice\0" } }, true) == "btservice", "btservice counts while the radio is down")
end)

scenario("isLauncherRunning finds wmt_launcher by program name in /proc", function()
    local real_dir, real_open = lfs_stub.dir, io.open
    local cmdlines = { ["/proc/7/cmdline"] = "/bin/sh\0-c\0x\0", ["/proc/42/cmdline"] = "wmt_launcher\0-p\0/lib/firmware\0" }
    lfs_stub.dir = function() local names, i = { ".", "self", "7", "42" }, 0 return function() i = i + 1 return names[i] end end
    io.open = function(path) local s = cmdlines[path] if not s then return nil end return { read = function() return s end, close = function() end } end
    local found = real.isLauncherRunning()
    cmdlines["/proc/42/cmdline"] = "/usr/bin/wmt_loader\0"
    local not_found = real.isLauncherRunning()
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


-- Stopping the restore script: everything it started goes too (it would keep
-- the onboard partition busy and block USB mass storage), except that a
-- running enable-wifi.sh finishes its steps. A fake process table: each entry
-- { pid, ppid, cmdline, ends_at = finishes on its own, ignores_term }.
local Proc = Plugin._Proc
local real_killScript = Plugin._killScript
local function fakeProcesses(list)
    local by_pid, signals = {}, {}
    for _, p in ipairs(list) do p.alive = true by_pid[p.pid] = p end
    local saved = { list = Proc.list, isAlive = Proc.isAlive, signal = Proc.signal, sleep = Proc.sleep, findScript = Proc.findScript }
    Proc.list = function() local t = {} for _, p in ipairs(list) do if p.alive then table.insert(t, p) end end return t end
    Proc.isAlive = function(pid)
        local p = by_pid[pid]
        if p and p.alive and p.ends_at and now >= p.ends_at then p.alive = false end
        return p ~= nil and p.alive
    end
    Proc.signal = function(pid, name)
        table.insert(signals, name .. " " .. pid)
        local p = by_pid[pid]
        if p and (name == "KILL" or not p.ignores_term) then p.alive = false end
    end
    Proc.sleep = function(s) now = now + s end
    Proc.findScript = function()
        for _, p in ipairs(list) do if p.alive and p.cmdline:find("restore-wifi-async.sh", 1, true) then return p.pid end end
    end
    local function restore() for k, v in pairs(saved) do Proc[k] = v end end
    return by_pid, signals, restore
end
local function sent(signals, s) for _, x in ipairs(signals) do if x == s then return true end end return false end

scenario("stopping the restore script: its steps are stopped, a running enable-wifi.sh finishes", function()
    local procs, signals, restore = fakeProcesses({
        { pid = 100, ppid = 1, cmdline = "/bin/sh\0./restore-wifi-async.sh\0" },
        { pid = 101, ppid = 100, cmdline = "/bin/sh\0./enable-wifi.sh\0", ends_at = 3 },
        { pid = 102, ppid = 101, cmdline = "insmod\0/drivers/x/mt66xx/wlan_drv_gen4m.ko\0", ends_at = 3 },
        { pid = 103, ppid = 100, cmdline = "usleep\0" .. "250000\0" },
        { pid = 200, ppid = 1, cmdline = "./luajit\0./reader.lua\0" },
        { pid = 201, ppid = 1, cmdline = "wpa_supplicant\0-B\0" },
    })
    real_killScript(100)
    restore()
    check(sent(signals, "TERM 100") and sent(signals, "TERM 103"), "script and its usleep TERMed")
    check(not sent(signals, "TERM 101") and not sent(signals, "KILL 101"), "enable-wifi.sh not signalled")
    check(not sent(signals, "TERM 102"), "enable-wifi.sh's own steps left to it")
    check(not sent(signals, "TERM 200") and not sent(signals, "TERM 201"), "nothing outside the tree touched")
    check(not procs[101].alive and now >= 3 and now < 3.5, "waited for enable-wifi.sh to finish (" .. now .. " s)")
    check(lastLogHas("and what it started: enable-wifi.sh, usleep"), "logged what it stopped")
end)

scenario("stopping the restore script during DHCP: obtain-ip.sh and the DHCP client stopped, KILL after 1 s if needed", function()
    local procs, signals, restore = fakeProcesses({
        { pid = 300, ppid = 1, cmdline = "/bin/sh\0./restore-wifi-async.sh\0" },
        { pid = 301, ppid = 300, cmdline = "/bin/sh\0./obtain-ip.sh\0" },
        { pid = 302, ppid = 301, cmdline = "dhcpcd\0-d\0-t\0" .. "30\0-w\0wlan0\0", ignores_term = true },
    })
    real_killScript(300)
    restore()
    check(sent(signals, "TERM 301") and sent(signals, "TERM 302"), "obtain-ip.sh and dhcpcd TERMed")
    check(sent(signals, "KILL 302") and not procs[302].alive, "dhcpcd ignored TERM and got KILL")
    check(now >= 1 and now < 1.5, "after the 1 s grace (" .. now .. " s)")
end)

scenario("stopping the restore script: an enable-wifi.sh that never ends is killed after 8 s", function()
    local procs, signals, restore = fakeProcesses({
        { pid = 400, ppid = 1, cmdline = "/bin/sh\0./restore-wifi-async.sh\0" },
        { pid = 401, ppid = 400, cmdline = "/bin/sh\0./enable-wifi.sh\0" },
    })
    real_killScript(400)
    restore()
    check(sent(signals, "KILL 401") and not procs[401].alive, "killed")
    check(now >= 8 and now < 8.5, "after 8 s (" .. now .. " s)")
    check(lastLogHas("killed what was still running after 8 s"), "logged")
end)

scenario("killScript without a pid stops every restore script running, then stops looking", function()
    local procs, signals, restore = fakeProcesses({
        { pid = 500, ppid = 1, cmdline = "/bin/sh\0./restore-wifi-async.sh\0" },
        { pid = 501, ppid = 1, cmdline = "/bin/sh\0./restore-wifi-async.sh\0" },
    })
    real_killScript()
    restore()
    check(sent(signals, "TERM 500") and sent(signals, "TERM 501"), "both stopped")
    check(not procs[500].alive and not procs[501].alive, "both gone")
end)

scenario("USB mass storage during our Wi-Fi start: the real stop runs before KOReader quits", function()
    local procs, signals, restore = fakeProcesses({
        { pid = 600, ppid = 1, cmdline = "/bin/sh\0./restore-wifi-async.sh\0" },
        { pid = 601, ppid = 600, cmdline = "/bin/sh\0./obtain-ip.sh\0" },
    })
    local stub = Link.killScript
    Link.killScript = real_killScript
    local p = newReader()
    p:onPageUpdate(2)
    p:onCloseDocument()
    advance(2)
    p:onClose()
    Link.killScript = stub
    restore()
    check(sent(signals, "TERM 600") and sent(signals, "TERM 601"), "restore script and obtain-ip.sh stopped")
    check(lastLogHas("[net] disableWifi"), "then Wi-Fi turned off")
    check(Link.job == nil and #queue == 1, "job aborted, position still queued")
end)

print(table.concat(log, "\n"))
print(failures == 0 and "\nALL SCENARIOS PASSED" or ("\n" .. failures .. " CHECK(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
