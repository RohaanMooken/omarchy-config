# omarchy-config

The two Omarchy customizations worth carrying between machines: a custom lock
screen (password draws a circuit board, no visible field) and the
Hypr-DarkWindow rule that kills the white Chromium new-tab flash.

Lives at `~/.config`, so files land where Omarchy already looks for them.

## On a new machine

```bash
cd ~/.config
git init -b main
git remote add origin https://github.com/RohaanMooken/omarchy-config.git
git fetch && git checkout -f main
```

Then wire up both pieces:

```bash
# lock screen: enable the clone, disable the stock one
omarchy plugin enable rohaanmm.lock
omarchy plugin disable omarchy.lock

# darkwindow: hyprpm plugin + one require in hyprland.lua
hyprpm add https://github.com/micha4w/Hypr-DarkWindow && hyprpm enable Hypr-DarkWindow
echo 'require("hypr.darkwindow")' >> ~/.config/hypr/hyprland.lua && hyprctl reload
```

`hyprland.lua` is deliberately not tracked — it is Omarchy's file and its
defaults change between releases. Add the one `require` line by hand instead of
clobbering it.
