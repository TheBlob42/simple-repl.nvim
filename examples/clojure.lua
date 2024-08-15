--[[
    Example configuration for the Clojure programming language

    The following features will be showcased:
    - Starting and (re)opening a Clojure REPL
    - Send the current visual selection to the REPL
    - Send the next VIM motion to the REPL
    - Sending the whole buffer to the REPL
    - Simple usage of the Treesitter utility functions
        - Sending the whole buffer to the REPL
        - Sending the closest form to the REPL
        - Sending the root form to the REPL
    - Advanced usage of Treesitter queries
        - Running all tests in the current namespace
        - Running the single test at the current cursor position

    Install this configuration by copying the contents into your configuration ftplugin file for Clojure (`after/ftplugin/clojure.lua`) or use a FileType autocommand. However this example was intended to be used as inspiration for your own configuration. So feel free to adjust it to your needs
--]]
local repl = require('simple-repl')

--[[
    This is the name we're gonna use for our Clojure REPL
    In this configuration we're only having exactly one Clojure REPL
    If you have a different workflow and would need multiple REPLs, you would need multiple names and a custom way to differentiate between them
--]]
local repl_name = 'clojure'

-- This keybinding starts our Clojure REPL (if it was not started yet) and opens it in a split window
vim.keymap.set('n', '<localleader>c', function()
    -- The REPL process here is started via the `clj` command (https://clojure.org/guides/deps_and_cli)
    -- For better performance (with less interactive features) use `clojure` instead
    -- For more REPL features you can also use `clojure -Sdeps "{:deps {com.bhauman/rebel-readline {:mvn/version \"0.1.4\"}}}" -m rebel-readline.main`
    repl.open_repl(repl_name, 'clj', {
        --[[
            Search upwards for the "root" directory of the project which contains the `deps.edn` file
            We want to start the REPL in this directory to also load all dependencies
            If you're using a different build system (Leiningen, Boot, etc.) you would need to adjust this to another file
            If you do not specify anything for `path` the REPL will be started in the current working directory of Neovim
        --]]
        path = vim.fs.root(0, 'deps.edn')
    })
end, { desc = 'Open Clojure REPL' })

--[[
    The `clj` CLI uses rlwrap (https://github.com/hanslub42/rlwrap) for history and line editing
    To avoid having all the sent commands in the REPL history we're using "<C-o>" instead of "<CR>" for newlines
    This way we're having the REPL history for all the commands that we enter manually there and do not clutter it with what we send
    This is a feature of `rlwrap` NOT of Neovim itself or the `simple-repl` plugin
    If you don't like this behaviour you can remove the `opts` table from the keybindings below (the default for newlines is "\n")
--]]
local opts = { new_line = vim.api.nvim_replace_termcodes('<C-o>', true, false, true) }

-- In visual-mode, send the current selection to the REPL
vim.keymap.set('x', '<localleader>e', function()
    repl.v_send_to_repl(repl_name, opts)
end, { desc = 'Send selection to REPL' })

-- Switch to operator-mode, send the next VIM motion to the REPL
vim.keymap.set('n', '<localleader>eo', function()
    repl.op_send_to_repl(repl_name, opts)
end, { desc = 'Send VIM motion to REPL' })

-- #######################
-- Simple Treesitter Usage
-- #######################

--[[
    This section showcases some of the easy Treesitter utility functions provided by the simple-repl plugin
    They are used to find a specific node by type. For this they search upwards from the current cursor position till they find a match
    They return the text for the found node which then can be send to the REPL
    
    - `find_node` searches for the first node that matches the given type
    - `find_node_by_parent` searches for the first node with a parent of the given type
    
    NOTE: All these functions live in the `tree.lua` file and are not loaded by default
--]]
local ts = require('simple-repl.tree')

-- Send the whole buffer to the REPL
vim.keymap.set('n', '<localleader>eb', function()
    -- Here we're searching upwards from the current cursor position for a `source` node which in Clojure marks the root of the buffer
    local text = ts.find_node('source')
    repl.send_to_repl(repl_name, text, opts)
end, { desc = 'Send the whole buffer to REPL' })

-- Send the closest form to the REPL
vim.keymap.set('n', '<localleader>ee', function()
    -- Here we're searching upwards from the current cursor position for a `list_lit` node which marks the closest list form
    local text = ts.find_node('list_lit')
    repl.send_to_repl(repl_name, text, opts)
end, { desc = 'Send current form to REPL' })

-- Send the root form to the REPL
vim.keymap.set('n', '<localleader>eE', function()
    -- In this case we're searching for the node that is a direct child of the root of the buffer, indicating the top-level form
    local text = ts.find_node_by_parent('source')
    repl.send_to_repl(repl_name, text, opts)
end, { desc = 'Send root form to REPL' })

-- #########################
-- Advanced Treesitter Usage
-- #########################

--[[
   The following section is about writing your own Treesitter queries to extract arbitrary information from your code to send it to the REPL
   The use case in our example is to either run the single test at the current cursor position or all tests in the current namespace of a Clojure file
   
   For both scenarios we need the name of the namespace and for the single test additionally the name of the current top-level form
   The simple-repl plugin provides a few helper functions to make it easier to execute such queries from a specific position (Treesitter node) in the current buffer
   Neither this plugin nor this documentation example attempts to teach you how to actually write Treesitter queries, for this please refer to the official documentation
--]]

-- #####################
-- Some Helper Functions

-- Just a helper function to avoid typing too much when parsing a Treesitter query
local function query(s)
    return vim.treesitter.query.parse(repl_name, s)
end

---Extract the namespace from the current Clojure buffer
local function get_namespace()
    -- Execute a Treesitter query from the root of the buffer and retrieve the text of the given capture
    -- Here we are searching for the namespace definition and extracting the name of the namespace
    return ts.query_from_root(query('((sym_lit) @ns (#eq? @ns "ns") (sym_lit) @ns-name)'), 'ns-name')[1]
end

---Extract the name of the current top-level form
local function get_root_form()
    -- Search upwards for the first node that has a parent of the type `source`, execute the query and retrieve the text of the given capture
    -- Here we are searching for the top level form and extracting the name of it
    return ts.query_from_node_by_parent('source', query('((list_lit (sym_lit) (sym_lit) @name))'), 'name')[1]
end

-- ##################
-- Actual Keybindings

-- Keybinding to execute all tests in the current namespace
-- For this we only extract the namespace and use `clojure.test/run-tests` for the execution
vim.keymap.set('n', '<localleader>tT', function()
    local namespace = get_namespace()
    if namespace then
        repl.send_to_repl(repl_name, {"(clojure.test/run-tests '"..namespace..")"}, opts)
    end
end, { desc = 'Run all tests in the current namespace' })

-- Keybinding to execute the single test at the current cursor position
-- For this we extract the namespace and the name of the current top-level form
-- We then use `clojure.test/test-vars` to run only the single test in the REPL
vim.keymap.set('n', '<localleader>tt', function()
    local namespace = get_namespace()
    local name = get_root_form()
    if namespace and name and namespace ~= name then
        repl.send_to_repl(repl_name, {"(clojure.test/test-vars [#'"..namespace.."/"..name.."])"}, opts)
    end
end, { desc = 'Run the test at cursor position' })
