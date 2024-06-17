# Simple REPL

Simple utility for interacting with any REPL inside Neovim

- Starting a new or opening an existing REPL using the embedded [terminal emulator](http://neovim.io/doc/user/nvim_terminal_emulator.html)
- Send arbitrary text to your REPL from anywhere
- Peek at the latest result even when the REPL is currently not visible in any window

## Installation

> The plugin was implemented and tested with Neovim version `0.10.0`

Use your preferred way of managing plugins to install `simple-repl.nvim`

```lua
-- using https://github.com/folke/lazy.nvim
require('lazy').setup({
    'theblob42/simple-repl'
    -- your other plugins [...]
})
```

The plugin will not perform any automatic setup for you. There is also no `setup` function you have to call before using it. You just have to come up with your own keybindings using the provided functions. See the [usage](#usage) section or jump into the `./examples`

## Usage

> For a more in-depth example have a look into `./examples/clojure.lua` for a "complete" Clojure setup

Create a new REPL or re-open an existing one using the `open_repl` function:

```lua
-- creating a new REPL for Clojure using the 'clj' command in the current working directory
require('simple-repl').open_repl('TestREPL', 'clj')
```

Now we can use the `send_to_repl` function to send arbitrary text to our "TestREPL":

```lua
require('simple-repl').send_to_repl('TestREPL', { '(+ 1 2)' })
```

Usually we would like to have some keybindings for easily sending a visual selection or an operator movement to the REPL. For this you can use the `v_send_to_repl` and `op_send_to_repl` helper functions:

```lua
local r = require('simple-repl')

-- sending text using a VIM motion
vim.keymap.set('n', 'leaders', function()
    r.op_send_to_repl('TestREPL')
end)

-- sending the current visual selection
vim.keymap.set('x', '<leader>s', function()
    r.v_send_to_repl('TestREPL')
end)
```

Use Treesitter to easily extract exactly the code that you want to send to the REPL. There are some helper functions in `lua/simple-repl/tree.lua` which you can use directly or as inspiration for your own custom ones:

```lua
local ts = require('simple-repl.tree')

-- send the current top level form
vim.keymap.set('n', '<localleader>S', function()
    local lines = ts.find_node_by_parent('source', true)
    M.send_to_repl('TestREPL', lines)
end)
```

For more information also check the help files `:help simple-repl` which provide further information about all available functions, their parameters and all available configuration options

## References

- [conjure.nvim](https://github.com/Olical/conjure)
- [repl.nvim](https://github.com/HiPhish/repl.nvim)
- [vim-slime](https://github.com/jpalardy/vim-slime)
