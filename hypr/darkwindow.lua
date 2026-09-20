-- Hypr-DarkWindow rules (hyprpm add https://github.com/micha4w/Hypr-DarkWindow).
-- Kept out of monitors.lua so it travels between machines: the nil guard makes
-- the file a no-op wherever the plugin isn't installed.
if hl.plugin.darkwindow == nil then
	return
end

hl.window_rule({
	match = { class = "chromium", title = "New Tab - Chromium" },
	["darkwindow:shade"] = "chromakey bkg=[0.02 0.02 0.02] similarity=1 amount=1.5 targetOpacity=0.1",
})
