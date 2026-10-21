local _ = require("gettext")
return {
    fullname = _("Progress sync: Wi-Fi on demand"),
    version = "0.1.10",
    description = _([[Runs the Progress sync plugin automatically when a book is opened or closed and when the device wakes up or goes to sleep, turning Wi-Fi on for the sync and off again afterwards. Requires the Progress sync plugin (KOSync) to be set up.]]),
}
