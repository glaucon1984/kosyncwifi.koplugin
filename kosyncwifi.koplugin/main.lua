--[[--
Progress sync: Wi-Fi on demand.

Companion plugin for KOReader's built-in Progress sync plugin (kosync). It
drives KOSync's push / pull at the moments that matter (book open, book close,
device wake-up, device sleep) and brings Wi-Fi up only for the duration of the
sync, silently, through the same background script KOReader uses for
"Auto restore Wi-Fi". Afterwards Wi-Fi goes off again, unless it was already on
before the sync started.

On sleep the plugin pushes the actual suspend out by a configurable budget so
the push can complete, then lets the device sleep immediately. Kobo's own
suspend path kills Wi-Fi regardless, so a stuck connection can never block
sleep.

KOSync's own "Automatic sync" must stay off (this plugin switches it off when
it finds it on); KOSync still does the actual talking to the server, keeps the
account and the forward/backward prompt settings, and owns the offline queue.

@module koplugin.kosyncwifi
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")

local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local DEFAULTS = {
    enabled = true,
    on_open = true,
    on_close = true,
    on_resume = true,
    on_suspend = true,
    wifi_off_after = true,
    -- Seconds we give the Wi-Fi to come up (including DHCP) before giving up.
    -- NetworkMgr's own connectivity check aborts at 45s, so stay below that.
    connect_timeout = 35,
    -- "silent": restore-wifi-async.sh + connectivity check (no UI at all).
    -- "standard": NetworkMgr:enableWifi (non-interactive, shows KOReader's small
    -- "Scanning…" / "Connected to network" messages).
    method = "silent",
    -- Pop-up after a push went out (never for pulls, "in sync" or "ahead").
    notify = true,
    -- Also draw it on the sleep screen after the sleep push (cleared on wake).
    notify_on_sleep_screen = true,
    -- Where the sleep-screen box goes: "bottom", "bottom_left", "bottom_right".
    sleep_box_position = "bottom",
}

-- Extra seconds on top of connect_timeout that the suspend is pushed out by,
-- to leave room for the push itself and the Wi-Fi teardown.
local SUSPEND_MARGIN = 15

local RESTORE_SCRIPT = "restore-wifi-async.sh"

-- ---------------------------------------------------------------------------
-- KOSync access helpers
-- ---------------------------------------------------------------------------

-- Credentials and plugin path, readable without a live KOSync instance (file
-- manager, or after the reader closed). Returns nil when KOSync isn't set up.
local function loadKOSyncCreds()
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/kosync.lua")
    local s = settings:readSetting("settings") or {}
    if not s.username or not s.userkey then
        return nil
    end
    local client_file = package.searchpath("KOSyncClient", package.path)
    if not client_file then
        return nil
    end
    return {
        custom_server = s.custom_server,
        username = s.username,
        userkey = s.userkey,
        path = client_file:gsub("[/\\][^/\\]+$", ""),
    }
end

local function getQueue()
    local ok, KOSyncQueue = pcall(require, "KOSyncQueue")
    if ok then return KOSyncQueue end
end

local function queueCount()
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then return 0 end
    local ok, n = pcall(KOSyncQueue.count, KOSyncQueue)
    return ok and n or 0
end

-- Snapshot used to tell whether a push ended up in the queue instead.
local function queueSignature()
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then return { count = 0 } end
    local ok, q = pcall(KOSyncQueue.load, KOSyncQueue)
    if not ok or type(q) ~= "table" then return { count = 0 } end
    local last = q[#q]
    return { count = #q, last = last and last.queued_at }
end

local function newClient(creds)
    local KOSyncClient = require("KOSyncClient")
    return KOSyncClient:new{
        custom_url = creds.custom_server,
        service_spec = creds.path .. "/api.json",
    }
end

-- Ask the server for a document's progress. Returns "ok", body on success,
-- "none" when the server has nothing (or refused), nil when it couldn't be
-- reached at all.
local function fetchServerProgress(client, creds, document)
    local server_ok, server
    local called = pcall(client.get_progress, client, creds.username, creds.userkey, document,
        function(ok, body) server_ok = ok; server = body end)
    if not called or server_ok == nil then
        return nil
    end
    if server_ok and type(server) == "table" then
        return "ok", server
    end
    return "none"
end

local function samePosition(a_progress, a_percentage, b_progress, b_percentage)
    if a_progress and b_progress and a_progress == b_progress then
        return true
    end
    if a_percentage and b_percentage and math.abs(a_percentage - b_percentage) < 0.00005 then
        return true
    end
    return false
end

-- Decide whether a position read here at `read_at` (0 = nothing was read
-- here) should be pushed over what the server holds. Returns true to push,
-- or false plus a reason.
local function shouldPush(server, our_device_id, progress, percentage, read_at)
    if samePosition(progress, percentage, server.progress, server.percentage) then
        return false, _("in sync")
    end
    if server.device_id ~= our_device_id and server.timestamp then
        if not read_at or read_at == 0 or server.timestamp > read_at then
            return false, T(_("%1 is ahead"), server.device or _("another device"))
        end
    end
    return true
end

-- Send everything in KOSync's offline queue. Self-contained so it can run from
-- a scheduled task after the reader (and its KOSync instance) is gone.
-- A queued position is dropped, not sent, when the server already has it, or
-- when another device has pushed a newer one since this one was read here:
-- the queue must never undo reading done elsewhere in the meantime.
-- Returns sent, dropped; or nil if the queue module is unavailable.
local function drainQueue(creds)
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then return nil end
    if KOSyncQueue:count() == 0 then return 0, 0 end
    creds = creds or loadKOSyncCreds()
    if not creds then return 0, 0 end
    local client = newClient(creds)
    local dropped = 0
    local sent = KOSyncQueue:drain(function(item)
        -- Items queued by KOSync itself carry no reading time; they come from
        -- a push we had already vetted, so their queue time stands in for it.
        local read_at = item.last_page_turn
        if read_at == nil then read_at = item.queued_at end
        local state, server = fetchServerProgress(client, creds, item.document)
        if state == nil then
            -- Couldn't ask the server: keep the item for later.
            return false
        end
        if state == "ok" then
            local push, reason = shouldPush(server, item.device_id, item.progress, item.percentage, read_at)
            if not push then
                logger.info("KOSyncWiFi: dropping a queued position for", item.document, "-", reason)
                dropped = dropped + 1
                return true
            end
        end
        -- Same success criterion as KOSync:drainQueue (the call went through).
        local ok = pcall(client.update_progress,
            client,
            creds.username,
            creds.userkey,
            item.document,
            item.metadata,
            item.progress,
            item.percentage,
            item.device,
            item.device_id,
            function() end)
        return ok
    end)
    return sent - dropped, dropped
end

-- ---------------------------------------------------------------------------
-- Process helpers (the restore script runs from the onboard partition and
-- other plugins use it too, so we need to see it and, if orphaned, stop it).
-- ---------------------------------------------------------------------------

-- pid of a running restore-wifi-async.sh, or nil.
local function findScript()
    local ok, res = pcall(function()
        for pid in lfs.dir("/proc") do
            if pid:match("^%d+$") then
                local f = io.open("/proc/" .. pid .. "/cmdline", "rb")
                if f then
                    local cmdline = f:read("*a") or ""
                    f:close()
                    if cmdline:find(RESTORE_SCRIPT, 1, true) then
                        return tonumber(pid)
                    end
                end
            end
        end
    end)
    if ok then return res end
end

local function killScript(pid)
    pid = pid or findScript()
    if pid then
        logger.warn("KOSyncWiFi: stopping " .. RESTORE_SCRIPT .. " (pid " .. pid .. ")")
        os.execute("kill -TERM " .. pid .. " 2>/dev/null")
    end
end

-- ---------------------------------------------------------------------------
-- Link: one shared "bring Wi-Fi up, run work, bring it down" job.
-- Module-level on purpose: the reader and the file manager each get their own
-- plugin instance, and a close-time job must outlive the reader instance.
-- ---------------------------------------------------------------------------

local Link = {
    job = nil,
    last = nil, -- { kind, ok, when, detail }
    shutting_down = false,
    findScript = findScript, -- replaceable for tests
    killScript = killScript,
}

function Link.isUp()
    return NetworkMgr:isWifiOn() and NetworkMgr:isConnected()
end

function Link.setLast(kind, ok, detail)
    Link.last = { kind = kind, ok = ok, when = os.time(), detail = detail }
end

local function restoreWifiWasOn(job)
    NetworkMgr.wifi_was_on = job.prior_wifi_was_on
    G_reader_settings:saveSetting("wifi_was_on", job.prior_wifi_was_on)
end

-- Runs every registered on_connected(ok) then every on_finished(ok).
function Link._complete(job, ok)
    if Link.job == job then
        Link.job = nil
    end
    if job.timeout_task then
        UIManager:unschedule(job.timeout_task)
    end
    UIManager:unschedule(Link._launch)
    UIManager:unschedule(Link._waitReady)

    local keep = false
    if ok then
        for _, entry in ipairs(job.entries) do
            if entry.on_connected then
                local call_ok, res = pcall(entry.on_connected, true)
                if not call_ok then
                    logger.err("KOSyncWiFi: on_connected failed:", res)
                elseif res == true then
                    keep = true
                end
            end
        end
    end

    -- Tear Wi-Fi down if we were the ones who brought it up.
    if job.we_turned_it_on then
        if not ok then
            -- Failed attempt: make sure nothing is left half-up or half-running.
            logger.info("KOSyncWiFi: cleaning up the failed Wi-Fi attempt")
            NetworkMgr:unscheduleConnectivityCheck()
            Link.killScript()
            NetworkMgr:disableWifi()
            restoreWifiWasOn(job)
        elseif not keep and job.settings.wifi_off_after then
            logger.info("KOSyncWiFi: turning Wi-Fi off")
            NetworkMgr:disableWifi()
            -- The connectivity check flags wifi_was_on; keep the user's prior
            -- state so "Auto restore Wi-Fi" / startup restore aren't affected.
            restoreWifiWasOn(job)
        end
    end

    if not ok then
        for _, entry in ipairs(job.entries) do
            if entry.on_connected then
                local call_ok, err = pcall(entry.on_connected, false)
                if not call_ok then
                    logger.err("KOSyncWiFi: on_connected failed:", err)
                end
            end
        end
    end
    for _, entry in ipairs(job.entries) do
        if entry.on_finished then
            local call_ok, err = pcall(entry.on_finished, ok)
            if not call_ok then
                logger.err("KOSyncWiFi: on_finished failed:", err)
            end
        end
    end
end

function Link._onTimeout()
    local job = Link.job
    if not job then return end
    logger.warn("KOSyncWiFi: Wi-Fi did not come up within", job.settings.connect_timeout, "s")
    Link._complete(job, false)
end

-- NetworkMgr says "connected" as soon as the interface has *an* address, which
-- includes the IPv6 link-local one that appears before DHCP. Wait until the
-- restore script is done and there is a default route before doing any work.
function Link._waitReady(job)
    if Link.job ~= job then return end
    if Link.findScript() then
        UIManager:scheduleIn(0.5, Link._waitReady, job)
        return
    end
    if not NetworkMgr:isWifiOn() then
        logger.warn("KOSyncWiFi: Wi-Fi went down while connecting")
        Link._complete(job, false)
        return
    end
    if not NetworkMgr:hasDefaultRoute() then
        UIManager:scheduleIn(0.5, Link._waitReady, job)
        return
    end
    logger.info("KOSyncWiFi: Wi-Fi is up after", os.time() - job.started, "s")
    Link._complete(job, true)
end

function Link._onConnected()
    local job = Link.job
    if not job then return end -- stale connectivity callback
    Link._waitReady(job)
end

-- True while the Bluetooth plugin (kobo.koplugin >= 0.4.1-touch.6) has the
-- Wi-Fi function powered for its own chip start-up; it broadcasts
-- BluetoothWifiReleased when it lets go. Only consulted if that module is
-- already loaded, so a disabled plugin is never pulled in.
local function bluetoothHasWifi()
    local kb = package.loaded["src/kobo_bluetooth"]
    return type(kb) == "table" and kb.wifi_borrowed == true
end

-- Starts the connection, once nothing else is in the middle of a Wi-Fi
-- start-up: KOReader's own "Auto restore Wi-Fi" script at wake, or the
-- Bluetooth plugin borrowing the Wi-Fi function for a couple of seconds.
function Link._launch(job)
    if Link.job ~= job then return end

    if Link.isUp() then
        -- Someone else got us connected in the meantime.
        job.we_turned_it_on = false
        Link._waitReady(job)
        return
    end

    if Link.findScript() or bluetoothHasWifi() then
        logger.dbg("KOSyncWiFi: waiting for another Wi-Fi start-up to finish")
        UIManager:scheduleIn(1, Link._launch, job)
        return
    end

    local method = job.settings.method
    if method == "silent" and not (Device:hasWifiRestore() and NetworkMgr.restoreWifiAsync) then
        method = "standard"
    end
    logger.info("KOSyncWiFi: bringing Wi-Fi up (" .. method .. ")")

    if method == "silent" then
        if NetworkMgr.pending_connection then
            -- Somebody else is already connecting; just wait for it.
            job.we_turned_it_on = false
        else
            NetworkMgr.pending_connection = true
            UIManager:broadcastEvent(Event:new("NetworkConnecting"))
            NetworkMgr:restoreWifiAsync()
        end
        if NetworkMgr.pending_connectivity_check then
            NetworkMgr:unscheduleConnectivityCheck()
        end
        NetworkMgr:scheduleConnectivityCheck(Link._onConnected)
    else
        local status = NetworkMgr:enableWifi(Link._onConnected, false)
        if status == false then
            Link._complete(job, false)
            return
        elseif status == nil then
            -- EBUSY: a connection attempt by someone else is in flight and our
            -- callback was dropped; poll for it ourselves.
            job.we_turned_it_on = false
            if NetworkMgr.pending_connectivity_check then
                NetworkMgr:unscheduleConnectivityCheck()
            end
            NetworkMgr:scheduleConnectivityCheck(Link._onConnected)
        end
    end
end

-- Request network for some work.
-- on_connected(ok): runs once Wi-Fi is connected (ok=true) or when the attempt
--   failed (ok=false); return true to leave Wi-Fi on afterwards.
-- on_finished(ok): runs after the teardown.
-- Requests made while a job is pending are attached to it.
function Link.request(settings, on_connected, on_finished)
    local entry = { on_connected = on_connected, on_finished = on_finished }

    if Link.job then
        logger.dbg("KOSyncWiFi: attaching to the pending Wi-Fi job")
        table.insert(Link.job.entries, entry)
        return
    end

    local job = {
        entries = { entry },
        we_turned_it_on = true,
        settings = settings,
        started = os.time(),
        prior_wifi_was_on = NetworkMgr.wifi_was_on,
    }

    if Link.isUp() and not Link.findScript() then
        -- Already connected, and not by us: just run the work, leave Wi-Fi alone.
        job.we_turned_it_on = false
        Link._complete(job, true)
        return
    end

    if Link.shutting_down then
        logger.info("KOSyncWiFi: not starting Wi-Fi, KOReader is closing")
        job.we_turned_it_on = false
        Link._complete(job, false)
        return
    end

    Link.job = job
    job.timeout_task = function() Link._onTimeout() end
    UIManager:scheduleIn(settings.connect_timeout, job.timeout_task)
    Link._launch(job)
end

-- KOReader is about to quit (USB storage, power off, reboot, exit, restart):
-- never leave a Wi-Fi script running from the onboard partition.
function Link.shutdown()
    Link.shutting_down = true
    local job = Link.job
    if job then
        logger.info("KOSyncWiFi: aborting the Wi-Fi job, KOReader is closing")
        Link._complete(job, false)
    end
end

-- ---------------------------------------------------------------------------
-- The plugin
-- ---------------------------------------------------------------------------

local KOSyncWiFi = WidgetContainer:extend{
    name = "kosyncwifi",
    is_doc_only = false,
}
KOSyncWiFi._Link = Link -- for tests

function KOSyncWiFi:init()
    local s = G_reader_settings:readSetting("kosyncwifi") or {}
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    self.settings = s
    G_reader_settings:saveSetting("kosyncwifi", s)

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function KOSyncWiFi:saveSettings()
    G_reader_settings:saveSetting("kosyncwifi", self.settings)
end

function KOSyncWiFi:onDispatcherRegisterActions()
    Dispatcher:registerAction("kosyncwifi_sync_now", {
        category = "none",
        event = "KOSyncWiFiSyncNow",
        title = _("Progress sync over Wi-Fi now"),
        general = true,
    })
end

function KOSyncWiFi:inReader()
    return self.ui and self.ui.document ~= nil
end

-- Live KOSync instance (reader only), when it is set up.
function KOSyncWiFi:getKOSync()
    local kosync = self.ui and self.ui.kosync
    if kosync and kosync.settings and kosync.settings.username and kosync.settings.userkey then
        return kosync
    end
end

-- Pop-up after a push went out. Independent of any plugin instance so it can
-- be scheduled from a closing reader.
local function showPushed(settings, text)
    if not settings.notify then return end
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

local function pushedText(summary)
    return T(_("Progress pushed (%1)."), summary)
end

-- ---- reading-time tracking --------------------------------------------------
-- KOSync only records page turns while its own automatic sync is on, so we
-- keep our own "last page turned in this book" time, persisted per book, and
-- feed it to KOSync too (its pull logic compares the server's timestamp
-- against it).

local LAST_TURN_KEY = "kosyncwifi_last_page_turn"

function KOSyncWiFi:getLastPageTurn()
    return self.last_page_turn or 0
end

function KOSyncWiFi:onPageUpdate(page)
    if page == nil or not self:inReader() then return end
    if self.last_page == page then return end
    self.last_page = page
    local now = os.time()
    self.last_page_turn = now
    local kosync = self:getKOSync()
    if kosync then
        kosync.last_page_turn_timestamp = now
    end
    if self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(LAST_TURN_KEY, now)
    end
end

-- Push through KOSync, unless the server already has this position or
-- another device has read further since we last turned a page here.
-- Returns ok, summary part.
function KOSyncWiFi:pushNow(interactive)
    local kosync = self:getKOSync()
    if not kosync then return true, nil end
    local digest = kosync:getDocumentDigest()
    local progress, percentage = kosync:getLastProgress(), kosync:getLastPercent()
    local creds = loadKOSyncCreds()
    if digest and creds then
        local state, server = fetchServerProgress(newClient(creds), creds, digest)
        if state == "ok" then
            local push, reason = shouldPush(server, kosync.device_id, progress, percentage, self:getLastPageTurn())
            if not push then
                logger.info("KOSyncWiFi: not pushing:", reason)
                return true, T(_("not pushed: %1"), reason)
            end
        end
    end
    local before = queueSignature()
    -- Our events are the only pushes, so don't let KOSync's 25 s debounce
    -- swallow one.
    kosync.push_timestamp = 0
    kosync:updateProgress(false, interactive)
    local after = queueSignature()
    if after.count > before.count or (after.last and after.last ~= before.last) then
        return false, _("push failed, queued")
    end
    return true, _("pushed")
end

-- The sync work itself, run while Wi-Fi is up. Returns a one-line summary,
-- whether everything went through, and whether anything was actually pushed.
function KOSyncWiFi:doSync(opts)
    local parts = {}
    local all_ok = true
    local pushed = false
    local prompt_shown = false
    local sent, dropped = drainQueue()
    if sent and sent > 0 then
        table.insert(parts, T(_("%1 queued sent"), sent))
        pushed = true
    end
    if dropped and dropped > 0 then
        table.insert(parts, T(_("%1 queued dropped"), dropped))
    end
    if queueCount() > 0 then
        all_ok = false
    end
    local kosync = self:getKOSync()
    if kosync and self:inReader() then
        if opts.push then
            -- Always KOSync's silent mode: its interactive mode shows its own
            -- "Progress has been pushed." under ours.
            local ok, part = self:pushNow(false)
            if part then table.insert(parts, part) end
            if not ok then all_ok = false end
            if ok and part == _("pushed") then pushed = true end
        end
        if opts.pull then
            kosync.pull_timestamp = 0
            -- Silent mode keeps the forward/backward prompt instead of jumping
            -- blindly. If it put a prompt on screen, the caller must not cover it.
            local top = UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget()
            kosync:getProgress(false, false)
            if UIManager.getTopmostVisibleWidget and UIManager:getTopmostVisibleWidget() ~= top then
                prompt_shown = true
            end
            table.insert(parts, _("pulled"))
        end
    end
    if #parts == 0 then
        return _("nothing to do"), true, false, prompt_shown
    end
    return table.concat(parts, ", "), all_ok, pushed, prompt_shown
end

-- Bring Wi-Fi up, sync, bring it down.
function KOSyncWiFi:runSync(kind, opts, on_finished)
    logger.info("KOSyncWiFi: sync requested:", kind)
    Link.request(self.settings, function(ok)
        if not ok then
            Link.setLast(kind, false, _("no Wi-Fi"))
            if opts.manual then
                UIManager:show(InfoMessage:new{ text = _("Could not connect to Wi-Fi."), timeout = 3 })
            end
            return
        end
        local summary, all_ok, pushed, prompt_shown = self:doSync(opts)
        Link.setLast(kind, all_ok, summary)
        logger.info("KOSyncWiFi:", kind, "sync done:", summary)
        if opts.manual then
            -- One summary, and none at all when KOSync's "move to the new
            -- location?" prompt is already on screen.
            if not prompt_shown then
                UIManager:show(InfoMessage:new{ text = T(_("Progress sync: %1"), summary), timeout = 3 })
            end
        elseif pushed then
            showPushed(self.settings, pushedText(summary))
        end
    end, on_finished)
end

-- ---- events ---------------------------------------------------------------

function KOSyncWiFi:onReaderReady()
    if not self.settings.enabled then return end
    local kosync = self:getKOSync()
    if not kosync then return end

    if kosync.settings.auto_sync then
        -- Both of us hooking Suspend/Resume would fight; KOSync's own version
        -- also brings the "Connecting to Wi-Fi…" prompts with it.
        kosync:onKOSyncToggleAutoSync(false)
        UIManager:show(InfoMessage:new{
            text = _("Progress sync's own automatic sync has been switched off. Wi-Fi on demand sync handles it from now on."),
        })
    end

    -- Reading-time tracking for this book.
    self.last_page = self.ui.getCurrentPage and self.ui:getCurrentPage()
    local saved = self.ui.doc_settings and self.ui.doc_settings:readSetting(LAST_TURN_KEY)
    self.last_page_turn = tonumber(saved) or 0
    if (kosync.last_page_turn_timestamp or 0) == 0 then
        kosync.last_page_turn_timestamp = self.last_page_turn
    end

    if self.settings.on_open then
        UIManager:nextTick(function()
            self:runSync("open", { pull = true })
        end)
    end
end

function KOSyncWiFi:onCloseDocument()
    self.suspend_token = nil
    if not self.settings.enabled or not self.settings.on_close then return end
    local kosync = self:getKOSync()
    if not kosync then return end

    if Link.isUp() and not Link.findScript() then
        logger.info("KOSyncWiFi: sync requested: close (online)")
        local ok, part = self:pushNow(false)
        Link.setLast("close", ok, part or _("nothing to do"))
        if ok and part == _("pushed") then
            -- The file manager is about to be shown; put the pop-up above it.
            local settings = self.settings
            UIManager:scheduleIn(0.5, function() showPushed(settings, _("Progress pushed.")) end)
        end
        return
    end

    if self:getLastPageTurn() == 0 then
        logger.info("KOSyncWiFi: close: no page was turned in this book here, nothing to push")
        return
    end

    -- Offline: queue the position (KOSync's own format, plus the time the
    -- book was last read here), then send the queue in the background once
    -- Wi-Fi is up. Nothing below may touch `self`, the reader is going away.
    local digest = kosync:getDocumentDigest()
    if not digest then return end
    local KOSyncQueue = getQueue()
    if not KOSyncQueue then
        logger.warn("KOSyncWiFi: no KOSyncQueue module, cannot defer the close push")
        return
    end
    KOSyncQueue:push({
        document = digest,
        metadata = kosync:getMetadata(),
        progress = kosync:getLastProgress(),
        percentage = kosync:getLastPercent(),
        device = kosync.settings.kosync_hostname or Device.model,
        device_id = kosync.device_id,
        last_page_turn = self:getLastPageTurn(),
    })
    if Link.shutting_down then
        logger.info("KOSyncWiFi: position queued, KOReader is closing")
        return
    end
    logger.info("KOSyncWiFi: sync requested: close (offline, queued)")

    local creds = loadKOSyncCreds()
    local settings = self.settings
    Link.request(settings, function(up)
        if not up then
            Link.setLast("close", false, _("no Wi-Fi, queued"))
            return
        end
        local sent, dropped = drainQueue(creds)
        sent, dropped = sent or 0, dropped or 0
        local summary = T(_("%1 queued sent"), sent)
        if dropped > 0 then
            summary = summary .. ", " .. T(_("%1 queued dropped"), dropped)
        end
        Link.setLast("close", queueCount() == 0, summary)
        logger.info("KOSyncWiFi: close sync done:", summary)
        if sent > 0 then
            showPushed(settings, _("Progress pushed."))
        end
    end)
end

-- Suspend: we run inside Device:_beforeSuspend(), i.e. after onPowerEvent has
-- already killed Wi-Fi and *before* it schedules the real suspend (15 s).
-- Defer one tick so our rescheduleSuspend wins, then do the work.
function KOSyncWiFi:onSuspend()
    if not self.settings.enabled or not self.settings.on_suspend then return end
    if not Device.rescheduleSuspend then return end
    local has_book = self:inReader() and self:getKOSync() ~= nil
    if not has_book and queueCount() == 0 then return end

    local token = {}
    self.suspend_token = token
    UIManager:nextTick(function()
        if self.suspend_token ~= token or not Device.screen_saver_mode then
            return -- woke up in between
        end
        local budget = self.settings.connect_timeout + SUSPEND_MARGIN
        logger.info("KOSyncWiFi: holding suspend for up to", budget, "s for the sleep sync")
        Device:rescheduleSuspend(budget)

        Link.request(self.settings, function(ok)
            if not ok then
                Link.setLast("sleep", false, _("no Wi-Fi"))
                return
            end
            -- If we were woken up meanwhile, also pull (acts as the wake sync).
            local awake = self.suspend_token ~= token
            local summary, all_ok, pushed = self:doSync({ push = true, pull = awake })
            Link.setLast("sleep", all_ok, summary)
            logger.info("KOSyncWiFi: sleep sync done:", summary)
            if pushed then
                if awake or not Device.screen_saver_mode then
                    showPushed(self.settings, pushedText(summary))
                else
                    self:showOnSleepScreen(T(_("Progress pushed at %1."), os.date("%H:%M")))
                end
            end
        end, function()
            if self.suspend_token == token then
                self.suspend_token = nil
                if Device.screen_saver_mode then
                    logger.info("KOSyncWiFi: releasing suspend")
                    Device:rescheduleSuspend(1)
                end
            end
        end)
    end)
end

-- The box drawn over the sleep screen: a plain square frame, serif text,
-- near the bottom edge. Deliberately not an InfoMessage (no rounded window,
-- no icon, not centred). It has to be modal: UIManager slips non-modal
-- widgets *below* the (modal) screensaver widget.
local SleepBox = WidgetContainer:extend{
    modal = true,
    text = "",
    position = "bottom", -- "bottom" (centred), "bottom_left", "bottom_right"
}

function SleepBox:init()
    local Screen = Device.screen
    local edge = Screen:scaleBySize(18)
    local face = Font:getFace("NotoSerif-Regular.ttf", 15) or Font:getFace("infofont")
    local text_widget = TextWidget:new{
        text = self.text,
        face = face,
        max_width = Screen:getWidth() - 2 * edge - 2 * Size.padding.large,
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        bordersize = Size.border.default,
        radius = 0,
        margin = 0,
        padding = Size.padding.default,
        padding_left = Size.padding.large,
        padding_right = Size.padding.large,
        text_widget,
    }
    local size = self.frame:getSize()
    local x
    if self.position == "bottom_left" then
        x = edge
    elseif self.position == "bottom_right" then
        x = Screen:getWidth() - size.w - edge
    else
        x = math.floor((Screen:getWidth() - size.w) / 2)
    end
    local y = Screen:getHeight() - size.h - edge
    self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
    self[1] = self.frame
end

function SleepBox:getSize()
    return self.dimen
end

function SleepBox:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function SleepBox:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.dimen end)
end

function KOSyncWiFi:showOnSleepScreen(text)
    if not self.settings.notify or not self.settings.notify_on_sleep_screen then return end
    self:clearSleepScreenBox(false)
    self.sleep_box = SleepBox:new{ text = text, position = self.settings.sleep_box_position }
    UIManager:show(self.sleep_box)
    UIManager:forceRePaint()
end

function KOSyncWiFi:clearSleepScreenBox(refresh)
    if not self.sleep_box then return end
    UIManager:close(self.sleep_box)
    self.sleep_box = nil
    if refresh then
        -- Full flash: the box sat on the e-ink panel for a long time.
        UIManager:setDirty(nil, "full")
    end
end

function KOSyncWiFi:onResume()
    self:clearSleepScreenBox(true)
    local suspend_job_pending = self.suspend_token ~= nil and Link.job ~= nil
    self.suspend_token = nil
    if not self.settings.enabled or not self.settings.on_resume then return end
    if suspend_job_pending then
        -- The sleep job is still connecting; its callback will push and pull.
        return
    end
    if self:inReader() then
        if not self:getKOSync() then return end
        UIManager:scheduleIn(1, function()
            self:runSync("wake", { pull = true })
        end)
    elseif queueCount() > 0 then
        UIManager:scheduleIn(1, function()
            self:runSync("wake", {})
        end)
    end
end

function KOSyncWiFi:onKOSyncWiFiSyncNow()
    if not self:getKOSync() and not self:inReader() then
        if queueCount() == 0 then
            UIManager:show(InfoMessage:new{ text = _("Nothing queued; open a book to sync its progress."), timeout = 3 })
            return true
        end
    end
    self:runSync("manual", { push = true, pull = true, manual = true })
    return true
end

-- Broadcast before KOReader quits: Exit / Restart from the menu, power off,
-- reboot, and "Close" right before entering USB mass storage. Returning
-- nothing lets the event continue to the reader itself.
local function markShutdown()
    Link.shutdown()
end
KOSyncWiFi.onExit = markShutdown
KOSyncWiFi.onRestart = markShutdown
KOSyncWiFi.onPowerOff = markShutdown
KOSyncWiFi.onReboot = markShutdown
KOSyncWiFi.onClose = markShutdown

-- ---- menu -----------------------------------------------------------------

local function statusText()
    local last = Link.last
    if not last then
        return _("Last sync: none yet")
    end
    local kinds = {
        open = _("open"), close = _("close"), wake = _("wake"), sleep = _("sleep"), manual = _("manual"),
    }
    return T(_("Last sync: %1 at %2, %3"),
        kinds[last.kind] or last.kind,
        os.date("%H:%M", last.when),
        last.ok and last.detail or (_("failed") .. ": " .. last.detail))
end

function KOSyncWiFi:toggleEntry(key, text, help)
    return {
        text = text,
        help_text = help,
        checked_func = function() return self.settings[key] end,
        enabled_func = function() return key == "enabled" or self.settings.enabled end,
        callback = function()
            self.settings[key] = not self.settings[key]
            self:saveSettings()
        end,
    }
end

function KOSyncWiFi:positionEntry(value, text)
    return {
        text = text,
        radio = true,
        checked_func = function() return self.settings.sleep_box_position == value end,
        callback = function()
            self.settings.sleep_box_position = value
            self:saveSettings()
        end,
    }
end

function KOSyncWiFi:addToMainMenu(menu_items)
    menu_items.kosyncwifi = {
        text = _("Progress sync: Wi-Fi on demand"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text_func = statusText,
                enabled = false,
                separator = true,
            },
            self:toggleEntry("enabled", _("Enable"),
                _("Run Progress sync automatically and turn Wi-Fi on only for the sync. Progress sync's own 'Automatic sync' must stay off.")),
            {
                text = _("Sync now"),
                enabled_func = function() return self.settings.enabled end,
                callback = function() self:onKOSyncWiFiSyncNow() end,
                separator = true,
            },
            self:toggleEntry("on_open", _("Pull when opening a book")),
            self:toggleEntry("on_resume", _("Pull on wake-up")),
            self:toggleEntry("on_suspend", _("Push on sleep"),
                _("Keeps the device awake (sleep screen already showing) until the push is done or the time limit is reached.")),
            self:toggleEntry("on_close", _("Push when closing a book")),
            {
                text = _("Turn Wi-Fi off afterwards"),
                help_text = _("Only when the plugin turned it on. Wi-Fi that was already on is left alone."),
                enabled_func = function() return self.settings.enabled end,
                checked_func = function() return self.settings.wifi_off_after end,
                callback = function()
                    self.settings.wifi_off_after = not self.settings.wifi_off_after
                    self:saveSettings()
                end,
                separator = true,
            },
            {
                text_func = function()
                    return T(_("Wi-Fi connection time limit: %1 s"), self.settings.connect_timeout)
                end,
                enabled_func = function() return self.settings.enabled end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        value = self.settings.connect_timeout,
                        value_min = 10,
                        value_max = 40,
                        value_step = 5,
                        default_value = DEFAULTS.connect_timeout,
                        title_text = _("Wi-Fi connection time limit"),
                        info_text = _("How long to wait for Wi-Fi before giving up. On sleep, the device is held awake for this plus 15 seconds at most."),
                        callback = function(spin)
                            self.settings.connect_timeout = spin.value
                            self:saveSettings()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
            },
            {
                text = _("Connect silently (background script)"),
                help_text = _("Uses the same background reconnect as 'Auto restore Wi-Fi': no messages on screen. Turn off to use KOReader's normal connection, which shows its usual messages."),
                enabled_func = function() return self.settings.enabled end,
                checked_func = function() return self.settings.method == "silent" end,
                callback = function()
                    self.settings.method = self.settings.method == "silent" and "standard" or "silent"
                    self:saveSettings()
                end,
            },
            self:toggleEntry("notify", _("Pop-up after a push"),
                _("Shown when progress actually went to the server: on close, on sleep, or from the queue. Nothing for pulls, 'in sync' or when another device is ahead.")),
            {
                text = _("Also on the sleep screen"),
                help_text = _("After the sleep push, a small box with the time is drawn over the sleep screen and removed on wake-up."),
                enabled_func = function() return self.settings.enabled and self.settings.notify end,
                checked_func = function() return self.settings.notify_on_sleep_screen end,
                callback = function()
                    self.settings.notify_on_sleep_screen = not self.settings.notify_on_sleep_screen
                    self:saveSettings()
                end,
            },
            {
                text = _("Sleep screen box position"),
                enabled_func = function() return self.settings.enabled and self.settings.notify and self.settings.notify_on_sleep_screen end,
                sub_item_table = {
                    self:positionEntry("bottom", _("Bottom, centred")),
                    self:positionEntry("bottom_left", _("Bottom left corner")),
                    self:positionEntry("bottom_right", _("Bottom right corner")),
                },
            },
        },
    }
end

return KOSyncWiFi
