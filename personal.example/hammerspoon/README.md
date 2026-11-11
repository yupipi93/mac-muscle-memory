# personal/hammerspoon/

Private Hammerspoon modules. `hammerspoon/init.lua` loads every `*.lua` here last, in
alphabetical order, after the shared config. Use it for what only makes sense on your machine:
a menu bar item for a work tool, a shortcut that opens an internal URL, paths under your home.

```lua
-- personal/hammerspoon/10-example.lua
exampleMenu = hs.menubar.new()      -- keep a global, or the garbage collector removes it
exampleMenu:setTitle("Hi")
```

A module can also load code that lives elsewhere:

```lua
dofile(os.getenv("HOME") .. "/somewhere/private/module.lua")
```

A module that raises an error is reported with an alert and in the Hammerspoon console; the
rest of the config keeps working. Check what loaded with
`hs -c 'return hs.inspect(personalModules)'`. Reload after a change: `hs -c 'hs.reload()'`.
