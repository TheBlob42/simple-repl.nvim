local M = {}
local repl_cache = {}

-- TODO
-- [X] "repl is ready" message (print this on the first prompt sign being visible)
-- [ ] repl-types (line wise and char wise)
-- [ ] maximum timeout for `send` to not block the editor (or even better never block the editor)
-- [X] autoscroll for log buffer
-- [ ] show the current namespace
-- [ ] autoload the repl namespace for Clojure (disable debugger for SBCL)

---@class SimpleRepl_ReplProcess
---@field cmd string[]? The command that is currently executing
---@field data table? If set use it to collect data from stdin (after `cmd`)
---@field callback function? Callback to execute after the current `cmd` is done
---@field timer uv_timer_t Timer to check for REPL timeouts and other issues

---@class SimpleRepl_ReplConfig
---@field cwd string The working directory of the REPL
---@field cmd string The command to start the REPL
---@field info_prefix string Prefix being used for informatinal messages in the out buffer

---@class SimpleRepl_ReplBuffers
---@field repl number The identifier for the repl buffer
---@field out number The identifier for the out buffer

---@class SimpleRepl_Repl
---@field name string The name of the REPL
---@field job_id number The channel id for the corresponding terminal job
---@field is_ready boolean If the REPL was started and is ready to receive commands
---@field process SimpleRepl_ReplProcess Information about the currently running process
---@field config SimpleRepl_ReplConfig Configuration options for the REPL
---@field buffers SimpleRepl_ReplBuffers The corresponding buffers
local SimpleRepl = {}

---@class SimpleRepl_NewConfig
---@field cmd string The command to start the REPL (e.g. `clj`, `sbcl`, `node`)
---@field cwd string The working directory for the REPL (defaults to cwd)
---@field info_prefix string A prefix used for informational messages in the out buffer (e.g. commentstring)
---@field out_config fun(buf: number) Function to further configure the out buffer (set name, syntax etc.)

-- TODO should we always eliminate newlines ??? (charwise REPL)
---Sanitize the given string `s` by removing all terminal escape sequences
---@param s string
---@return string
local function sanitize(s, leave_newlines)
    local result = s
        -- https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797
        -- ESC[J, ESC[K, ESC[0K etc. (erase functions)
        -- ESC[1;34m etc. (color mode)
        -- ESC[?25l, ESC[?47h, ESC[?2004h etc. (private modes)
        :gsub('\27%[[m?]?[0-9;]*[mnhlsufABCDEFGHKJ]?', '')
        -- all remaining control characters
        -- :gsub('%c', '')
    if not leave_newlines then
        result = result:gsub('%c', '')
    end
    return result
end

---TODO
---@param repl SimpleRepl_Repl
---@param stdin string[]
---@param opts table
local function process_charwise_repl(repl, stdin, opts)
    local process = repl.process

    -- if there is not currently set command we should ignore any data from STDIN
    if not process.cmd then
        return
    end

    process.timer:stop()

    if not repl.process.wait_for_cmd and not process.data then
        repl.process.wait_for_cmd = true
        process.data = process.data or {}
    end

    local done = false
    local cmd = vim.pesc(vim.iter(process.cmd):last())
    -- P("CMD")
    -- P(cmd)

    if not repl.is_ready then
        -- TODO
        cmd = opts.repl_prompt
    end

    for _, str in ipairs(stdin) do
        local s = sanitize(str, true)

        -- P(s)
        -- P(process.data)
        if s == '' then
            goto continue
        end

        if repl.process.wait_for_cmd then
            table.insert(process.data, s)
        end

        if not repl.process.wait_for_cmd and process.data then
            -- TODO does this work ??
            if s:match('^'..opts.repl_prompt..'$') then
                done = true
                break
            end

            table.insert(process.data, s)
            goto continue
        end

        if table.concat(process.data, ''):match('.*'..cmd..'%c*$') then
            repl.process.wait_for_cmd = false
            if repl.is_ready then
                process.data = {}
            else
                process.data = nil
                done = true
                repl.is_ready = true
                break
            end
        end
        ::continue::
    end

    if process.data and not repl.process.wait_for_cmd then
        P(process.data)
        -- local text = table.concat(process.data, ''):gsub("\r\r", '\n'):gsub('\r$', '')
        -- vim.api.nvim_buf_set_text(repl.buffers.out, -1, -1, -1, -1, vim.split(text, '\n'))
        -- process.data = {}
    end

    if done then
        -- TODO testing
        if process.data then
            repl:print(process.data)
        end
        process.cmd = nil
        process.data = nil
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

---TODO
---@param repl SimpleRepl_Repl
---@param stdin string[]
---@param opts table
local function process_linewise_repl(repl, stdin, opts)
    local process = repl.process

    -- if there is not currently set command we should ignore any data from STDIN
    if not process.cmd then
        return
    end

    process.timer:stop()

    local done = false
    local cmd = vim.pesc(vim.iter(process.cmd):last())

    if not repl.is_ready then
        cmd = opts.repl_prompt
    end

    for _, str in ipairs(stdin) do
        local s = sanitize(str)

        if s == '' then
            goto continue
        end

        if process.data then
            if s:match('^'..opts.repl_prompt..'$') then
                done = true
                break
            end

            table.insert(process.data, s)
            goto continue
        end

        if s:match('.*'..cmd..'$') then
            if repl.is_ready then
                process.data = {}
            else
                done = true
                repl.is_ready = true
                break
            end
        end
        ::continue::
    end

    if process.data then
        repl:print(process.data)
        process.data = {}
    end

    if done then
        process.cmd = nil
        process.data = nil
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

---Process data received from STDIN of the Clojure REPL
---If `finished` is true, the `cmd` was finished and `result` contains the latest data received
---If `finished` is false, the `cmd` was not finished yet and `result` contains the data collected so far
---
---The `data` parameter might contain data from previous invocations. Add new data to it and return it in
---the end so it can be processed correctly. If it is not set the `cmd` was not yet registered in the REPL output.
---In this case you should monitor for it before starting to collect result data
---
---@param cmd string[] The currently executed command
---@param data string[]? Previous collected data. If present use this to collect more data and return it
---@param stdin string[] The data received via STDIN
---@return boolean finished If the cmd is finished or if more data is expected
---@return string[]? result The collected data
local function clojure_process(cmd, data, stdin)
    local last_cmd = cmd[vim.tbl_count(cmd)]

    for _, str in ipairs(stdin) do
        local s = sanitize(str)
        if s ~= "" then
            -- TODO should only be checked once and then never again (self evaluating)
            -- TODO what about things that evaluate to themself ???
            -- ignore duplicate last command data (should we ???)
            if not data and vim.endswith(s, last_cmd) then
                -- start collecting data (if not done yet)
                data = data or {}
            elseif data then
                if s:match('^.*=> $') then
                -- if str:match('^%*%s*$') then -- LISP
                -- if s:match('^>%s*$') then -- NODE
                    return true, data
                end
                -- TODO check to remove additional prompts that might clutter the output
                s = s:gsub('%S*=> ', '')
                table.insert(data, s)
            end
        end
    end

    return false, data
end

-- TODO for node
local function char_wise_processing(cmd, data, stdin)
    data = data or {}
    local last_cmd = cmd[vim.tbl_count(cmd)]

    for _, str in ipairs(stdin) do
        local s = sanitize(str, true)
        if s ~= '' then
            if s:match('^>%s*$') then
                return true, { table.concat(data, '') }
            end
            table.insert(data, s)
            if vim.endswith(table.concat(data, ''), last_cmd) then
            -- if vim.endswith(s, "\r\r") then
                -- data = {}
                return false, {}
            end
        end
    end

    return false, data
end

---Get or create a REPL with the `name`
---
---If a REPL with the given `name` does not exist but create `opts`
---are provided a new one will be created, otherwise nil is returned
---
---@param name string The name of the REPL
---@param opts any? Options to create a REPL if not existing
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
        config = {
            cwd = opts.cwd,
            cmd = opts.cmd,
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

    ---Reset temporary properties when a command finished successfully
    local finish_processing = function ()
        instance.process.data = nil
        instance.process.cmd = nil
        if instance.process.callback then
            -- the callback might set the another callback
            local cb = assert(instance.process.callback)
            instance.process.callback = nil
            cb()
        end
    end

    ---Start the timer to check for unfinished commands, no REPL updates etc.
    ---@param ms number The timeout value in milliseconds
    ---@param msg string The message to print in the out buffer
    local start_timeout_timer = function(ms, msg)
        instance.process.timer:start(ms, 0, vim.schedule_wrap(function()
            instance:print(msg, true)
        end))
    end

    vim.api.nvim_buf_call(repl_buf, function()
        instance.job_id = vim.fn.termopen(vim.o.shell..';#'..name, {
            cwd = vim.fn.fnamemodify(opts.cwd, ':p'),
            on_stdout = function(_, stdin)
                P(stdin)
                -- process_linewise_repl(instance, stdin, {
                --     repl_prompt = '%S*=> '
                -- })
                process_charwise_repl(instance, stdin, {
                    repl_prompt = '> '
                })
            end,
            -- on_stdout = function(_, data)
            --     -- if there is no command no processing should be done
            --     if not instance.process.cmd then
            --         return
            --     end
            --
            --     -- ignore changes from the repl buffer directly
            --     -- if vim.api.nvim_get_current_buf() == instance.buffers.repl then
            --     --     return
            --     -- end
            --
            --     instance.process.timer:stop()
            --
            --     if not instance.is_ready then
            --         local done = clojure_process(instance.process.cmd, {}, data)
            --         -- local done = char_wise_processing(instance.process.cmd, {}, data)
            --         if done then
            --             instance.is_ready = true
            --             finish_processing()
            --         else
            --             start_timeout_timer(10000, 'REPL is still not ready, did something go wrong?')
            --         end
            --         return
            --     end
            --
            --     local done, out = clojure_process(instance.process.cmd, instance.process.data, data)
            --     -- local done, out = char_wise_processing(instance.process.cmd, instance.process.data, data)
            --
            --     P(data) -- TODO
            --
            --     if out then
            --         -- TODO this might be different for "char based" REPLs like `node`
            --         instance:print(out)
            --         instance.process.data = {}
            --         -- instance.process.data = out
            --     end
            --
            --     if done then
            --         -- TODO char wise testing
            --         -- instance:print(out)
            --         finish_processing()
            --     else
            --         start_timeout_timer(5000, 'no data received from REPL')
            --     end
            -- end,
        })
    end)

    if opts.cmd ~= "" then
        instance:send(opts.cmd, function()
            instance:print("READY", true)
        end)
    else
        instance:print("READY", true)
    end

    return instance
end

---Print the given `text` to the REPL out buffer
---Automatically scrolls to the bottom of the buffer (autoscroll)
---@param text string|string[] The text to print into the REPLs out buffer
---@param info boolean? If the message is considered "informational" and should use the `info_prefix`
function SimpleRepl:print(text, info)
    if type(text) == "string" then
        text = { text }
    end

    if info then
        text = vim.tbl_map(function(s)
            return self.config.info_prefix .. s
        end, text)
    end

    local out = self.buffers.out
    local empty_buffer = vim.api.nvim_buf_line_count(out) == 1 and
        vim.api.nvim_buf_get_lines(out, 0, -1, false)[1] == ''

    if empty_buffer then
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
function SimpleRepl:send(cmd, cb)
    -- TODO testing with node
    -- if self.process.cmd then
    --     print("There is already a commend in progress...")
    --     return
    -- end

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
    self.process.data = nil
    self.process.callback = cb

    vim.fn.chansend(self.job_id, cmd)
    -- TODO test what works more resilient
    -- vim.fn.chansend(self.job_id, table.concat(cmd, "") .. "\n")
end

---Open a given buffer in a (v)split window
---Does NOT switch to the newly opened window
---@param buf number
---@param location? "split"|"vsplit" Default is `vsplit`
---@return integer win The window identifier of the newly opened window
local function open(buf, location)
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

function SimpleRepl:kill()
    -- TODO
    -- out buffer, repl buffer, cache
end

return M
