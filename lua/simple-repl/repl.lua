local M = {}
local repl_cache = {}

-- TODO
-- [X] "repl is ready" message (print this on the first prompt sign being visible)
-- [-] repl-types (line wise and char wise)
-- [ ] maximum timeout for `send` to not block the editor (or even better never block the editor)
    -- same for the REPL start if something is blocking or weird going on
-- [X] autoscroll for log buffer
-- [ ] show the current namespace
-- [ ] autoload the repl namespace for Clojure (disable debugger for SBCL)

---@class SimpleRepl_ReplProcess
---@field cmd string[]? The command that is currently executing
---@field data table Used to collect data from stdin
---@field callback function? Callback to execute after the current `cmd` is done
---@field timer uv_timer_t Timer to check for REPL timeouts and other issues
---@field wait_for_cmd boolean Indicator if the current STDIN data is scanned for the command or the actual result data

---@class SimpleRepl_ReplConfigFilters
---@field cmd (string | fun(s: string): string)[] Filters to search for the command string
---@field data (string | fun(s: string): string)[] Filters when gathering result data

---@class SimpleRepl_ReplConfig
---@field cwd string The working directory of the REPL
---@field cmd string The command to start the REPL
---@field prompt string The prompt pattern for this REPL 
---@field filter SimpleRepl_ReplConfigFilters Filter options for command and data
---@field info_prefix string Prefix being used for informational messages in the out buffer

---@class SimpleRepl_ReplBuffers
---@field repl number The identifier for the repl buffer
---@field out number The identifier for the out buffer

---@class SimpleRepl_Repl
---@field name string The name of the REPL
---@field job_id number The channel id for the corresponding terminal job
---@field is_ready boolean If the REPL was started and is ready to receive commands
---@field is_logging boolean Is logging activated (usually only needed for debugging and development)
---@field process SimpleRepl_ReplProcess Information about the currently running process
---@field config SimpleRepl_ReplConfig Configuration options for the REPL
---@field buffers SimpleRepl_ReplBuffers The corresponding buffers
local SimpleRepl = {}

---@class SimpleRepl_NewConfigFilters
---@field cmd (string | fun(s: string): string)[]? Filters to search for the command string
---@field data (string | fun(s: string): string)[]? Filters when gathering result data

---@class SimpleRepl_NewConfig
---@field cmd string The command to start the REPL (e.g. `clj`, `sbcl`, `node`)
---@field prompt string The prompt pattern for this REPL (e.g. '%S+=> ', '* ', '> ')
---@field filter SimpleRepl_NewConfigFilters? Filter options for command and data
---@field cwd string? The working directory for the REPL (defaults to cwd)
---@field info_prefix string? A prefix used for informational messages in the out buffer (e.g. commentstring)
---@field out_config fun(buf: number)? Function to further configure the out buffer (set name, syntax etc.)

---Filter the given string `s`
---If `filter` is a string use it as a pattern with `gsub` to remove all occurences
---If `filter` is a function apply it to `s` and return the result
---@param s string
---@param filter string|fun(s: string): string
---@return string
local function sfilter(s, filter)
    local result = s

    if type(filter) == 'string' then
        result = s:gsub(filter, '')
    else
        result = filter(s)
    end

    return result
end

---Process the incoming data from `stdin` for the specific `repl`
---@param repl SimpleRepl_Repl
---@param stdin string[]
local function process_stdin(repl, stdin)
    repl:_log("STDIN: ", stdin)

    local config = repl.config
    local process = repl.process
    if not process.cmd then
        return
    end

    process.timer:stop()

    local done = false
    local cmd = vim.pesc(vim.iter(process.cmd):last())

    if not repl.is_ready then
        cmd = config.prompt
        repl:_log('REPL is not ready yet, changing CMD to prompt: "', cmd, '"')
    end

    for _, str in ipairs(stdin) do
        repl:_log('---')
        if process.wait_for_cmd then
            local s = vim.iter(config.filter.cmd):fold(str, sfilter)

            repl:_log('Searching CMD')
                :_log('Raw String: "', str, '"')
                :_log('Filtered String: "', s, '"')

            if s == '' then
                goto continue
            end

            -- TODO if (raw) str ends with newline and does not match CMD we can probably skip it
            -- preventing the terminal from blocking the whole editor (for too long)

            table.insert(process.data, s)

            if table.concat(process.data, ''):match('.*'..cmd..'%c*$') then
                repl:_log('Found CMD ("', cmd, '")')
                process.wait_for_cmd = false
                process.data = {}
                if not repl.is_ready then
                    done = true
                    repl.is_ready = true
                    break
                end
            end
        else
            local s = vim.iter(config.filter.data):fold(str, sfilter)

            repl:_log('Gathering Data')
                :_log('Raw String: "', str, '"')
                :_log('Filtered String: "', s, '"')

            if s == '' then
                goto continue
            end

            if s:match('^'..config.prompt..'$') then
                repl:_log('Found PROMPT ("^', config.prompt, '$")')
                done = true
                break
            end

            table.insert(process.data, s)
        end
        ::continue::
    end

    repl:_log('---')
        :_log("Data: ", process.data)
        :_log('')

    if not process.wait_for_cmd then
        repl:print(process.data)
        process.data = {}
    end

    if done then
        process.cmd = nil
        process.wait_for_cmd = true
        if process.callback then
            local cb = assert(process.callback)
            process.callback = nil
            cb()
        end
    else
        process.timer:start(5000, 0, vim.schedule_wrap(function()
            repl:print('no data received from REPL', true)
        end))
    end
end

---Get or create a REPL with the `name`
---
---If a REPL with the given `name` does not exist but create `opts`
---are provided a new one will be created, otherwise nil is returned
---
---@param name string The name of the REPL
---@param opts SimpleRepl_NewConfig? Options to create a REPL if not existing
---@return SimpleRepl_Repl? repl
function M.get(name, opts)
    local r = repl_cache[name]
    if r or not opts then
        return r
    end

    return SimpleRepl:new(name, opts)
end

---Create a new REPL
---@param name string The name of the REPL. This is used to retrieve the REPL via `require('simple-repl.repl').get(<name>)`
---@param opts SimpleRepl_NewConfig Further configuration options
---@return SimpleRepl_Repl repl
function SimpleRepl:new(name, opts)
    ---@type SimpleRepl_NewConfig
    opts = vim.tbl_extend("keep", opts or {}, {
        cmd = '',
        cwd = vim.loop.cwd(),
        info_prefix = ';; ',
        out_config = nil,
    })

    local out_buf = vim.fn.bufnr('repl-out://'..name, 1)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = out_buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = out_buf })
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = out_buf })
    if opts.out_config then
        opts.out_config(out_buf)
    end
    local repl_buf = vim.api.nvim_create_buf(false, false)

    local instance = {
        name = name,
        job_id = -1,
        is_ready = false,
        is_logging = false,
        config = {
            cwd = opts.cwd,
            cmd = opts.cmd,
            prompt = opts.prompt,
            filter = vim.tbl_deep_extend('keep', opts.filter or {}, {
                cmd = {
                    '.',
                    '\27%[[m?]?[0-9;]*[mnhlsufABCDEFGHKJ]?',
                    '%c',
                },
                data = {
                    '.',
                    '\27%[[m?]?[0-9;]*[mnhlsufABCDEFGHKJ]?',
                    '%c',
                },
            }),
            info_prefix = opts.info_prefix,
        },
        buffers = {
            repl = repl_buf,
            out = out_buf,
        },
        process = {
          cmd = nil,
          data = nil,
          callback = nil,
          timer = vim.loop.new_timer(),
        },
    }

    setmetatable(instance, self)
    self.__index = self
    repl_cache[name] = instance

    instance:print('REPL "'..name..'" is starting...', true)
    vim.api.nvim_buf_call(repl_buf, function()
        instance.job_id = vim.fn.termopen(vim.o.shell..';#'..name, {
            cwd = vim.fn.fnamemodify(opts.cwd, ':p'),
            on_exit = function()
                instance:print('REPL "'..name..'" was closed', true)
                repl_cache[name] = nil
            end,
            on_stdout = function(_, stdin)
                process_stdin(instance, stdin)
            end,
        })
    end)

    instance:send(opts.cmd, function()
        instance:print('REPL "'..name..'" is ready', true)
    end)

    return instance
end

---Print the given `text` to the REPL out buffer
---Automatically scrolls to the bottom of the buffer (autoscroll)
---If the `text` is `nil` or an empty table, this will print nothing
---@param text string|string[]? The text to print into the REPLs out buffer
---@param info boolean? If the message is considered "informational" and should use the `info_prefix`
function SimpleRepl:print(text, info)
    if not text then
        return
    end

    if type(text) == "string" then
        text = { text }
    end

    if vim.tbl_isempty(text) then
        return
    end

    if info then
        text = vim.tbl_map(function(s)
            return self.config.info_prefix .. s
        end, text)
    end

    local out = self.buffers.out

    local is_unloaded = not vim.api.nvim_buf_is_loaded(out)
    local is_empty = vim.api.nvim_buf_line_count(out) == 1 and
        vim.api.nvim_buf_get_lines(out, 0, -1, false)[1] == ''

    if is_unloaded or is_empty then
        vim.api.nvim_buf_set_lines(out, 0, -1, false, text)
    else
        vim.api.nvim_buf_set_lines(out, -1, -1, false, text)
    end

    vim.api.nvim_buf_call(out, function()
        vim.cmd.normal{ "G", bang = true }
    end)
end

---Send a `cmd` to the REPL for execution
---If there is already a command in progress this will print a warning and do nothing else
---@param cmd string|string[] The command to execute
---@param cb function? Optional callback function to be called after `cmd` was executed
---@see SimpleRepl_Repl.send_async
function SimpleRepl:send(cmd, cb)
    if self.process.cmd then
        vim.notify('There is already a command in progress for "'..self.name..'"!', vim.log.levels.info, {})
        return
    end

    self:_log('########## SEND CMD ##########')
        :_log('CMD: ', cmd)
        :_log('##############################')

    if type(cmd) == 'table' then
        cmd = table.concat(cmd, '\n')
    end

    if cmd:match('\n') then
        self:print('Executing: ' .. cmd:match('^%C+') .. '...', true)
    end

    if not vim.endswith(cmd, '\n') then
        cmd = cmd .. '\n'
    end

    self.process.cmd = vim.iter(vim.split(cmd, '\n'))
        :rskip(1) -- remove the trailing newline
        :totable()
    self.process.data = {}
    self.process.callback = cb
    self.process.wait_for_cmd = true

    vim.fn.chansend(self.job_id, cmd)
end

---Send multiple commands after another to the REPL for execution
---You can already use the callback of [send](lua://SimpleRepl_Repl.send) for it, but the creates a callback "hell"
---This is similar to the `async/await` functionality of other programming languages
---
---## Example
---```lua
---require('simple.repl.repl').get('REPL'):async_send(function(send)
---    -- these commands are send one after another
---    -- waiting for the previous to finish first
---    send("cmd1")
---    send("cmd2")
---    send("cmd3")
---    -- final code to execute
---end)
---```
---@param fn fun(send: fun(cmd: string|string[]))
---@see SimpleRepl_Repl.send
function SimpleRepl:send_async(fn)
    local cb
    local send = function(cmd)
        coroutine.yield(self:send(cmd, cb))
    end
    cb = coroutine.wrap(function()
        fn(send)
    end)
    cb()
end

---Open a given buffer in a (v)split window
---If the buffer is already visible in a window on the current tabpage do nothing
---Does NOT switch to the buffer window
---@param buf number
---@param location? "split"|"vsplit" Default is `vsplit`
---@return integer win The window identifier of the buffer related window
local function open(buf, location)
    local buf_win = vim.fn.bufwinid(buf)
    if buf_win ~= -1 then
        return buf_win
    end

    local win = vim.api.nvim_get_current_win()

    location = location or 'vsplit'
    if location == 'split' then
        vim.cmd.split()
    else
        vim.cmd.vsplit()
    end
    vim.api.nvim_set_current_buf(buf)

    local new_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(win)
    return new_win
end

---Open the REPL buffer in a split window
---@param location "split"|"vsplit"? Default is `vsplit`
---@return integer win The window id of the newly opened window
function SimpleRepl:open_repl(location)
    return open(self.buffers.repl, location)
end

---Open the OUT buffer in a split window
---@param location "split"|"vsplit"? Default is `vsplit`
---@return integer win The window id of the newly opened window
function SimpleRepl:open_out(location)
    return open(self.buffers.out, location)
end

---Kill the REPL job and remove the REPL from cache
function SimpleRepl:kill()
    vim.fn.jobstop(self.job_id)
    vim.api.nvim_buf_delete(self.buffers.repl, { force = true })
end

---(De)Activate logging for this REPL
---@param val boolean
---@return SimpleRepl_Repl repl Enable fluent method chaining
function SimpleRepl:logging(val)
    self.is_logging = val
    return self
end

---Log to a REPL specific log file for inspection
---All passed parameters will be concatenated to a single line
---For multiple lines you have to call this function multiple times
---
---If logging is **not** activated this function does **nothing**
---
---@param ... any
---@return SimpleRepl_Repl repl Enable fluent method chaining
---@see SimpleRepl_Repl.logging
function SimpleRepl:_log(...)
    if self.is_logging then
        ---@diagnostic disable-next-line: param-type-mismatch
        local file = vim.fs.joinpath(vim.fn.stdpath('log'), 'simple-repl-' .. self.name .. '-log.txt')
        local line = table.concat(vim.iter({...})
            :map(function(s)
                if type(s) ~= "string" then
                    -- make sure the "thing" is in a human-readable state
                    s = vim.inspect(s)
                end
                return s
            end)
            :totable(), '')
        vim.fn.writefile({ line }, file, 'as')
    end
    return self
end

---Open the corresponding log file for this REPL in the current window
function SimpleRepl:open_log_file()
    ---@diagnostic disable-next-line: param-type-mismatch
    local file = vim.fs.joinpath(vim.fn.stdpath('log'), 'simple-repl-' .. self.name .. '-log.txt')
    if vim.loop.fs_stat(file) then
        vim.cmd.e(file)
    else
        vim.notify("No log file exists for REPL '"..self.name.."'", vim.log.level.warning, {})
    end
end

-- ~~~~~~~~~~~
-- for testing
-- ~~~~~~~~~~~

function M.v_send_to_repl(name)
    -- needed due to inconsistencies with the visual selection otherwise (see also: https://github.com/neovim/neovim/discussions/26092)
    local mode = vim.fn.mode()
    if mode == 'v' or mode == 'V' or mode == '\22' then
        vim.cmd.normal { vim.api.nvim_replace_termcodes('<ESC>', true, false, true), bang = true }
    end

    local row1, col1 = unpack(vim.api.nvim_buf_get_mark(0, '<'))
    local row2, col2 = unpack(vim.api.nvim_buf_get_mark(0, '>'))

    local lines
    if col1 == 0 and col2 == vim.v.maxcol then
        lines = vim.api.nvim_buf_get_lines(0, row1 - 1, row2, false)
    else
        lines = vim.api.nvim_buf_get_text(0, row1 - 1, col1, row2 - 1, col2 + 1, {})
    end

    M.get(name):send(lines)
end

vim.keymap.set('n', '<leader>xp', function()
    M.get('python', {
        cmd = 'python',
        prompt = '>>> ',
        out_config = function(b)
            vim.api.nvim_set_option_value('syntax', 'python', { buf = b })
            vim.keymap.set('n', '<localleader>r', function()
                M.get('python'):open_repl("split")
            end, { buffer = b })
        end,
    }):open_out()
end, { desc = 'python' })

vim.keymap.set('x', '<leader>xp', function()
    M.v_send_to_repl('python')
end, {})

vim.keymap.set('n', '<leader>xn', function()
    M.get('node', {
        cmd = 'node',
        prompt = '> ',
        out_config = function(b)
            vim.api.nvim_set_option_value('syntax', 'javascript', { buf = b })
            vim.keymap.set('n', '<localleader>r', function()
                M.get('node'):open_repl("split")
            end, { buffer = b })
        end,
    }):open_out()
end, { desc = 'node' })

vim.keymap.set('x', '<leader>xn', function()
    M.v_send_to_repl('node')
end, {})

vim.keymap.set('n', '<leader>xC', function()
    M.get('clj_extended', {
        cmd = 'clojure -Sdeps "{:deps {com.bhauman/rebel-readline {:mvn/version \\"0.1.4\\"}}}" -m rebel-readline.main',
        prompt = '%S+=> ',
        out_config = function(b)
            vim.api.nvim_set_option_value('syntax', 'clojure', { buf = b })
            vim.keymap.set('n', '<localleader>r', function()
                M.get('clj_extended'):open_repl("split")
            end, { buffer = b })
        end,
    }):open_out()
end, { desc = 'clojure extended' })

vim.keymap.set('x', '<leader>xC', function()
    M.v_send_to_repl('clj_extended')
end, {})

vim.keymap.set('n', '<leader>xl', function()
    M.get('sbcl', {
        cmd = 'rlwrap sbcl',
        -- cmd = 'sbcl',
        prompt = '%* ',
        filter = {
            cmd = {
                function(s)
                    if vim.endswith(s, '\r\r') or s:match('%* $') then
                        return s
                    end
                    return ''
                end,
                '\27%[[m?]?[0-9;]*[mnhlsufABCDEFGHKJ]?',
                '%c',
            } ,
        },
        out_config = function(b)
            vim.api.nvim_set_option_value('syntax', 'lisp', { buf = b })
            vim.keymap.set('n', '<localleader>r', function()
                M.get('sbcl'):open_repl("split")
            end, { buffer = b })
        end,
    }):open_out()
end, { desc = 'lisp' })

vim.keymap.set('x', '<leader>xl', function()
    M.v_send_to_repl('sbcl')
end, {})

vim.keymap.set('n', '<leader>xc', function()
    M.get('clojure', {
        cmd = 'clojure',
        prompt = '%S+=> ',
        out_config = function(b)
            vim.api.nvim_set_option_value('syntax', 'clojure', { buf = b })
            vim.keymap.set('n', '<localleader>r', function()
                M.get('clojure'):open_repl("split")
            end, { buffer = b })
        end,
    }):open_out()
end, { desc = 'clojure' })

vim.keymap.set('n', '<leader>xL', function()
    M.get('clojure'):open_log_file()
end, { desc = 'open clojure repl logs' })

vim.keymap.set('x', '<leader>xc', function()
    M.v_send_to_repl('clojure')
end, {})

return M
