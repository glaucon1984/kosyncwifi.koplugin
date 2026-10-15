# kosyncwifi.koplugin — Progress sync: Wi-Fi on demand

Companion plugin for KOReader's built-in **Progress sync** plugin (KOSync).
It runs the sync at the moments that matter and turns Wi-Fi on only for the
sync, then off again:

| Moment | What happens |
|---|---|
| Book opened | Wi-Fi up, queued positions sent, progress pulled, Wi-Fi down |
| Device wakes up (book open) | same as above |
| Device goes to sleep (book open) | sleep screen shows, the actual suspend is held for up to the time limit + 15 s, Wi-Fi up, progress pushed, Wi-Fi down, device sleeps |
| Book closed | push immediately if online; otherwise the position is queued and sent in the background once Wi-Fi is up |
| Wake-up / sleep in the file manager | only if the offline queue has something to send |

Wi-Fi is brought up silently with the same background script KOReader uses
for *Auto restore Wi-Fi* (`restore-wifi-async.sh`), so nothing is drawn on the
sleep screen and the reader never blocks. If Wi-Fi was already on before a
sync, it is left on.

KOSync keeps doing the actual work: account, server, document checksum, the
*forward* / *backward* prompts and the offline queue. This plugin only
schedules it and manages Wi-Fi. KOSync's own **Automatic sync** must stay off
(it needs KOReader to connect with prompts on every wake and leaves Wi-Fi on);
the plugin switches it off if it finds it on.

## Install

1. Set up Progress sync (server, login) as usual and leave its *Automatic sync*
   off.
2. Download `kosyncwifi.koplugin.zip` from the
   [latest release](https://github.com/glaucon1984/kosyncwifi.koplugin/releases/latest)
   and unzip it into `koreader/plugins/` on the device, so that
   `koreader/plugins/kosyncwifi.koplugin/main.lua` exists.
3. Restart KOReader. With a book open, the entry *Wi-Fi on demand sync* is
   inside Progress sync's own menu, right after its "Automatically keep
   documents in sync" item (in the file manager it is under Tools →
   *Progress sync: Wi-Fi on demand*).

The two automatic modes exclude each other, so each one's toggle is greyed
out while the other is on; tapping the greyed item shows why. Opening
*Wi-Fi on demand sync* while Progress sync's automatic sync is on shows a
pop-up explaining why everything in it is off, and its first line says so too.

A *Sync now* entry and a dispatcher action, "Sync now (Progress sync over
Wi-Fi)", for gestures, profiles and other plugins' action pickers (for
example SimpleUI's quick actions, under *System actions*; it also appears
under *Plugin* there through the plugin's `launch` method) are provided.
Sync now pushes and pulls and shows one summary line; when KOSync asks whether
to move to the newer location, the summary is skipped so nothing overlaps.

## Settings

- **Enable** and one toggle per moment (open, wake-up, sleep, close).
- **Turn Wi-Fi off afterwards** (default on; only for Wi-Fi the plugin turned on).
- **Wi-Fi connection time limit** (default 35 s). On sleep the device is held
  awake for at most this plus 15 s. KOReader's own connectivity check gives up
  at 45 s, so the limit stays below that.
- **Connect silently** (default on). Off = KOReader's normal non-interactive
  connection, which shows its small "Scanning…" / "Connected" messages; use it
  if the silent script never connects on your device.
- **Pop-up after a push** (default on). Shown only when progress actually
  went to the server: after closing a book, after the sleep push, or when the
  offline queue was sent. A queued position is often sent later, for example
  while the next book is being opened, so that pop-up names the book it
  belongs to: "Progress pushed: Vestigios (queued)." Nothing for pulls (KOReader asks before moving you
  anyway), "in sync" or when another device is ahead.
- **Also on the sleep screen** (default on). After the sleep push a small
  square box in a serif face, "Progress pushed at HH:MM", is drawn near the
  bottom edge of the sleep screen and stays there while the device sleeps; it
  is removed with a full refresh on wake-up. **Sleep screen box position**:
  bottom centred, bottom left or bottom right corner.

The status line at the top of the menu shows the last sync: when, which
event, and what happened ("pushed", "pulled", "not pushed: in sync",
"not pushed: CrossInk X3 is ahead", "push failed, queued", "no Wi-Fi").

## Details worth knowing

- **"Connected" means a route.** KOReader's own check reports the interface as
  connected as soon as it has any address, which includes the IPv6 link-local
  one that exists before DHCP. The plugin waits until the restore script has
  finished and a default route exists before it pushes or pulls.
- **Other Wi-Fi start-ups.** The plugin does not start its own connection
  while KOReader's *Auto restore Wi-Fi* script is still running, or while the
  Bluetooth part of [kobo.koplugin](https://github.com/OGKevin/kobo.koplugin)
  (my fork's 0.4.1-touch.6 or later) has the Wi-Fi function borrowed for its
  chip start-up (`wifi_borrowed`, about 2 s after wake). Older kobo.koplugin
  builds ran the full restore script at wake-up and then killed Wi-Fi
  underneath everyone; update if you use it.
- **A push never undoes reading done elsewhere.** The plugin records when a
  page was last turned in each book (per-book setting, survives reopening) and
  hands that time to KOSync as well, which fixes KOSync's own forward/backward
  decision on pull (KOSync only records page turns while its own automatic
  sync is on). Before every push, on sleep, on close or from the queue, the
  server is asked for its position first. Nothing is pushed when the server
  already has this position, when no page was turned here, or when another
  device pushed after the last page turn here.
- **A pull never offers you your own push.** KOSync's "latest progress is
  coming from this device" check compares the device *name* on the server
  with KOReader's internal model name, which fails as soon as you give the
  device a custom name in Progress sync's settings; KOSync then offers to
  "sync forward" to the position this device sent a minute ago. The plugin
  asks the server before every pull and skips KOSync's pull when the latest
  progress is this device's own (by device id) or already the current
  position.
- **USB storage, power off, reboot, exit.** The "Close" / "Exit" broadcasts
  abort any running Wi-Fi job and stop the background script, which runs from
  the onboard partition and would otherwise block the USB export.

## How the sleep hold works

On Kobo the Suspend event is delivered *after* KOReader has already turned
Wi-Fi off and *before* it schedules the real suspend 15 s later. The plugin
defers one tick, calls `Device:rescheduleSuspend()` with its budget, connects,
pushes, tears Wi-Fi down and reschedules the suspend for one second later.
Kobo's suspend path kills Wi-Fi regardless, so a stuck connection cannot keep
the device awake past the budget. Waking the device during the window simply
cancels the suspend; the pending sync then runs as a wake sync (push + pull).

Measured on a Kobo Clara BW: Wi-Fi up in 6 to 8 s, device asleep about 9 s
after the power press; wake pull done 7 to 11 s after waking.

## Requirements

- KOReader 2026.07 or later (needs `KOSyncQueue`, the offline queue that came
  with KOSync's 2026 rework). Tested on a Kobo Clara BW with v2026.07.1.
- A Kobo or other device with `restore-wifi-async.sh` for the silent mode
  (anything with *Auto restore Wi-Fi* in the Network menu). Other devices can
  use the "standard" connection mode (untested).

## Tests

`tests/harness.lua` fakes the KOReader pieces the plugin touches (clock,
UIManager tasks, NetworkMgr, Device, KOSync, the sync server) and replays the
event sequences: open, sleep, wake during sleep, Wi-Fi timeout, offline close,
USB mass storage, foreign Wi-Fi scripts, the push guard and the queue rules.

```bash
luajit tests/harness.lua kosyncwifi.koplugin/main.lua
```

CI runs it on every push and checks that the tag matches the version in
`_meta.lua` on releases.

## Uninstall

Delete the folder or disable it in Plugin management. Nothing in
`kosync.koplugin` is modified.

## License

AGPL-3.0-or-later, like KOReader.
