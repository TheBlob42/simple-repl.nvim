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
-- [x] replace %c but leave \t in there
-- [x] python double enter needed...

---@class SimpleRepl_ReplProcess
---@field cmd string[]? The command that is currently executing
---@field data table Used to collect data from STDIN
---@field next function? Next step callback function
---@field callback function? Callback to execute after the current `cmd` is done
---@field timer uv_timer_t Timer to check for REPL timeouts and other issues

---@class SimpleRepl_ReplConfig
---@field cwd string The working directory of the REPL
---@field cmd string The command to start the REPL
---@field prompt string The prompt pattern for this REPL 
---@field filter (string | fun(s: string): string)[] Filter options for STDIN
---@field info_prefix string Prefix being used for informational messages in the out buffer
---@field newline string The string to use for a newline (defaults to '\n')

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

---@class SimpleRepl_NewFilterConfig
---@field replace boolean? Should the default filters be completely replaced? Otherwise the custom filter options are appended to them
---@field filter (string | fun(s: string): string)[] Filter options for STDIN. Either a string used with `gsub` or a function. The filters are applied in the exact order they are given

---@class SimpleRepl_NewConfig
---@field cmd string The command to start the REPL (e.g. `clj`, `sbcl`, `node`)
---@field prompt string The prompt pattern for this REPL (e.g. '%S+=> ', '* ', '> ')
---@field filter_config SimpleRepl_NewFilterConfig? Filter configuration for this REPL
---@field cwd string? The working directory for the REPL (defaults to cwd)
---@field info_prefix string? A prefix used for informational messages in the out buffer (e.g. commentstring)
---@field out_config fun(buf: number)? Function to further configure the out buffer (set name, syntax etc.)
---@field newline string? The string to use for a newline (defaults to '\n')
---@field on_ready fun(repl: SimpleRepl_Repl)? Callback function when the REPL is ready

---Filter the given string `s`
---If `filter` is a string use it as a pattern with `gsub` to remove all occurrences
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

---Process incoming `stdin` data for `repl`
---
---This includes:
---- Filtering the data by removing unwanted parts (e.g. escape sequences, cursors motions etc.)
---- Searching for the executed command string (this separates REPL input from output)
---- Printing any output that has not been filtered and is not part of the executed command string
---@param repl SimpleRepl_Repl The specific REPL
---@param stdin string[] The incoming data via STDIN
local function process_line_stdin(repl, stdin)
    repl:_log('-------')
        :_log("STDIN: ", stdin)

    local config = repl.config
    local process = repl.process
    if not process.cmd then
        return
    end

    process.timer:stop()

    local done = false
    ---@type string?
    local cmd = process.cmd[1]

    if not repl.is_ready then
        repl:_log('REPL is not ready yet!')
        cmd = nil
    end

    for _, str in ipairs(stdin) do
        local s = vim.iter(config.filter):fold(str, sfilter)

        -- remove multiple prompts on the same line (e.g. 'user=> user=> ')
        -- remove prompt prefixes for output values (e.g. 'user=> 1234')
        -- only a single prompt without any trailing string is desired (e.g. "user=> ")
        local prompt_filter, n = s:gsub('^'..config.prompt, '')
        while n > 0 and not s:match('^'..config.prompt..'$') do
            s = prompt_filter
            prompt_filter, n = s:gsub('^'..config.prompt, '')
        end

        repl:_log('---')
            :_log('RAW string: "', str, '"')
            :_log('FILTERED string: "', s, '"')

        if s:match('^'..config.prompt..'$') then
            if cmd then
                goto continue -- intermediate prompts (we are NOT done yet)
            end

            repl:_log('Found final PROMPT: "^', config.prompt, '$"')
            done = true
            repl.is_ready = true
            break
        end

        if not repl.is_ready then
            goto continue
        end

        table.insert(process.data, s)
        local data_string = table.concat(process.data, '')
        repl:_log('Data string: "', data_string, '"')

        -- no CMD just print everything that comes in
        -- data is not part of CMD must be output
        if not (cmd and vim.startswith(cmd, data_string)) then
            if cmd then
                if cmd == '' then
                    repl:_log('Skip empty input!') -- empty strings are not printed
                else
                    repl:_log('CMD: "', cmd, '"')
                        :_log('Does not start with "', data_string, '" --> PRINT')
                end
            else
                repl:_log('No CMD anymore --> PRINT')
            end
            repl:print(data_string)
            process.data = {}
            goto continue
        end

        if data_string:match('.*'..vim.pesc(cmd)..'%c*$') then
            repl:_log('Found CMD: "', cmd, '"')
            process.data = {}
            process.cmd = vim.iter(process.cmd):skip(1):totable()
            cmd = process.cmd[1]

            if cmd then
                repl:_log('Next CMD is: "', cmd, '"')
            else
                repl:_log('No next CMD!')
            end
        end
        ::continue::
    end

    if done then
        repl:_log("DONE")
        process.cmd = nil
        if process.callback then
            local cb = assert(process.callback)
            process.callback = nil
            cb()
        end
        return
    else
        process.timer:start(5000, 0, vim.schedule_wrap(function()
            repl:print('no data received from REPL', true)
        end))
    end


    if process.next then
        process.next()
    end
end

---Get the REPL by `name`
---
---If a REPL with the given `name` exists it will be returned from cache
---If it does NOT exist AND you passed the REPL `opts` a new one will be created
---
---```lua
---repl.get('existing') -- the existing REPL will be returned from cache
---repl.get('non-existing') -- returns `nil`
---repl.get('existing', {...}) -- the existing REPL will be returned from cache
---repl.get('non-existing', {...}) -- a new REPL will be created and returned
---```
---@overload fun(name: string): SimpleRepl_Repl?
---@param name string The name of the REPL
---@param opts SimpleRepl_NewConfig Options to create a REPL if not existing
---@return SimpleRepl_Repl repl
function M.get(name, opts)
    local r = repl_cache[name]
    if r then
        return r
    end

    if opts then
        return SimpleRepl:new(name, opts)
    end
end

---The default filter options that should be used for any REPLs STDIN data
---Strings are used with `"string_to_filter":gsub('<string>', '')`
---Functions take a string parameter and return a string for more complex filter applications
local default_filter = {
    -- bracketed mode (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h2-Bracketed-Paste-Mode)
    '\27%[%?2004h.*\27%[%?2004l',
    '^.*\27%[%?2004l',
    -- replace deletions one after another
    function(s)
        local str, x = s:gsub('.\b', '', 1)
        while x > 0 do
            str, x = str:gsub('.\b', '', 1)
        end
        return str
    end,
    -- remove terminal escape sequences
    '\27%[[m?]?[0-9;]*[mnhlsufABCDEFGHKJ]?',
    -- remove all control characters except tabs
    function(s)
        s = s:gsub('\t', '!TAB!')
             :gsub('%c', '')
             :gsub('!TAB!', '\t')
        return s
    end,
}

---Create a new REPL
---@param name string The name of the REPL. This is used to retrieve the REPL via `require('simple-repl.repl').get(<name>)`
---@param opts SimpleRepl_NewConfig Further configuration options
---@return SimpleRepl_Repl repl
function SimpleRepl:new(name, opts)
    ---@type SimpleRepl_NewConfig
    opts = vim.tbl_extend("keep", opts or {}, {
        cmd = '',
        on_ready = nil,
        cwd = vim.loop.cwd(),
        info_prefix = ';; ',
        out_config = nil,
        newline = '\n',
        filter_config = nil,
    })

    local out_buf = vim.fn.bufnr('repl-out://'..name, 1)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = out_buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = out_buf })
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = out_buf })
    if opts.out_config then
        opts.out_config(out_buf)
    end
    local repl_buf = vim.api.nvim_create_buf(false, false)

    -- create the filter options for this REPL
    local filter = default_filter
    if opts.filter_config then
        if opts.filter_config.replace then
            filter = opts.filter_config.filter
        else
            filter = { unpack(default_filter) }
            for _, f in ipairs(opts.filter_config.filter) do
                table.insert(filter, f)
            end
        end
    end

    local instance = {
        name = name,
        job_id = -1,
        is_ready = false,
        is_logging = false,
        config = {
            cwd = opts.cwd,
            cmd = opts.cmd,
            prompt = opts.prompt,
            newline = opts.newline,
            filter = filter,
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

    ---@type SimpleRepl_Repl
    instance = setmetatable(instance, self)
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
                process_line_stdin(instance, stdin)
            end,
        })
    end)

    instance:send(opts.cmd, {
        callback = function()
            instance:print('REPL "'..name..'" is ready', true)
            if opts.on_ready then
                opts.on_ready(instance)
            end
        end })

    return instance
end

---Print the given `text` to the REPL out buffer
---Automatically scrolls to the bottom of the buffer (autoscroll)
---If the `text` is `nil` or an empty table, this will print nothing
---@param text string|string[]? The text to print into the REPLs out buffer
---@param info boolean? If the message is considered "informational" and should use the `info_prefix`
---@return SimpleRepl_Repl repl For method chaining
function SimpleRepl:print(text, info)
    if not text then
        return self
    end

    if type(text) == "string" then
        text = { text }
    end

    if vim.tbl_isempty(text) then
        return self
    end

    if vim.iter(text):all(function(t) return t == '' end) then
        return self
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

    return self
end

---Send the next line of `lines` to the `repl`
---@param repl SimpleRepl_Repl The REPL to send the next line to
---@param lines string[] The remaining lines that need to be processed
local function send_next_line(repl, lines)
    local line = lines[1]

    repl:_log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~')
        :_log('Send next line: "', line, '"')
        :_log('~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~')

    local rest = vim.iter(lines):skip(1):totable()

    repl.process.next = nil
    if vim.tbl_count(rest) > 0 then
        repl.process.next = function()
            send_next_line(repl, rest)
        end
    end

    vim.fn.chansend(repl.job_id, line..repl.config.newline)
end

---Send a `cmd` to the REPL for execution
---
---If there is already a command in progress this will print a warning and do nothing else
---This behavior can be overwritten by setting the `force` option (e.g. to send an abort command)
---
---You can also specify an optional `callback` that is executed once the command has finished
---@param cmd string|string[] The command to execute
---@param opts { callback: fun(), force: boolean }? Additional configuration options
---@see SimpleRepl_Repl.send_async
function SimpleRepl:send(cmd, opts)
    opts = vim.tbl_extend('keep', opts or {}, {
        force = false,
        callback = nil,
    })

    if self.process.cmd and not opts.force then
        vim.notify('There is already a command in progress for "'..self.name..'"!', vim.log.levels.info, {})
        return
    end

    if type(cmd) == 'string' then
        cmd = vim.split(cmd, '\n')
    end

    if vim.tbl_count(cmd) > 1 then
        self:print('Executing: ' .. cmd[1]:gsub('^%s*', '') .. '...', true)
    end

    self.process.cmd = cmd
    self.process.data = {}
    self.process.callback = opts.callback

    self:_log('########## SEND CMD ##########')
        :_log(self.process.cmd)
        :_log('##############################')

    send_next_line(self, self.process.cmd)
end

---Send multiple commands after another to the REPL for execution
---You can already use the callback of [send](lua://SimpleRepl_Repl.send) for it, but the creates a "callback hell"
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
---The `print` function of the REPL can be passed as an optional function parameter
---This is useful to print updates about the overall process
---```lua
---require('simple.repl.repl').get('REPL'):async_send(function(send, p)
---    p("Starting", true)
---    send({ "..." })
---    p("Almost done", true)
---    send({ "..." })
---    p("Done", true)
---end)
---```
---@param fn fun(send: fun(cmd: string|string[]), print: fun(msg: string, info: boolean)?)
---@see SimpleRepl_Repl.send
---@see SimpleRepl_Repl.print
function SimpleRepl:send_async(fn)
    local cb
    local send = function(cmd)
        coroutine.yield(self:send(cmd, { callback = cb }))
    end
    local prnt = function(text, info)
        self:print(text, info)
    end

    cb = coroutine.wrap(function()
        fn(send, prnt)
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

---TODO we need to surpass the cmd check in `send`
function SimpleRepl:abort()
    local abort = vim.api.nvim_replace_termcodes('<C-c>', true, false, true)
    self:send({ abort })
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

---Return the logfile path for the REPL named `name`
---@param name string Name of the corresponding REPL
---@return string path The logfile path (absolute)
local function get_log_file(name)
    ---@diagnostic disable-next-line: param-type-mismatch
    return vim.fs.joinpath(vim.fn.stdpath('log'), 'simple-repl-' .. name .. '-log.txt')
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
        local line = table.concat(vim.iter({...})
            :map(function(s)
                if type(s) ~= "string" then
                    -- make sure the "thing" is in a human-readable state
                    s = vim.inspect(s)
                end
                return s
            end)
            :totable(), '')
        vim.fn.writefile({ line }, get_log_file(self.name), 'as')
    end
    return self
end

---Open the corresponding log file for this REPL in the current window
function SimpleRepl:open_log_file()
    local file = get_log_file(self.name)
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
        filter_config = {
            filter = {
                '^%.%.%. '
            }
        },
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
        filter_config = {
            filter = {
                '^%.%.%. ',
            }
        },
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

vim.keymap.set('n', '<leader>xl', function()
    M.get('sbcl', {
        cmd = 'rlwrap sbcl',
        prompt = '%* ',
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
