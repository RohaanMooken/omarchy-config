-- Extra autostart processes.
-- o.launch_on_start("my-service")

-- Load hyprpm plugins at startup. Hyprland does not load them on its own, and
-- until they are loaded the config parses with `hl.plugin.<name> == nil`, so
-- plugin-provided rules (e.g. the darkwindow rule in hypr/darkwindow.lua) are
-- silently skipped. Loading a plugin makes Hyprland re-parse the config, which
-- is what registers those rules.
o.exec_on_start("hyprpm reload")
