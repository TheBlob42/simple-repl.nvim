local repl = {}
local methods = {}
local metatable = { __index = methods }

local repl_cache = {}

-- TODO
---@class ReplProcess
---@field ready boolean Is the REPL process ready to receive commands
---@field cmd string? The command that is currently executing
---@field data table? If set use it to collect data from stdin (usually after `cmd` appeared)

---@class Repl
---@field name string The name of the REPL
---@field job_id number The channel id for the corresponding terminal job

-- TODO
-- [ ] "repl is ready" message (print this on the first prompt sign being visible)
-- [ ] repl-types (line wise and char wise)
-- [ ] maximum timeout for `send` to not block the editor (or even better never block the editor)
-- [ ] pass whole instance to process function ??
-- [X] autoscroll for log buffer

local function sanitize(s)
    return s
        -- https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797
        -- ESC[J, ESC[K, ESC[0K etc. (erase functions)
        -- ESC[1;34m etc. (color mode)
        -- ESC[?25l, ESC[?47h, ESC[?2004h etc. (private modes)
        :gsub('\27%[[m?]?[0-9;]*[mnhlsufABCDEFGHKJ]?', '')
        -- all remaining control characters
        :gsub('%c', '')
end

---Process data received from STDIN of the Clojure REPL
---
---@param stdin string[] The data received via STDIN
---@return boolean finished If the process is finished or should continue
---@return string[]? result The processed data (so far). If `finished` is `true` this is the end result
local function clojure_process(r, stdin)
    if not r.last_cmd then
        return false, nil
    end

    local last_cmd = r.last_cmd[vim.tbl_count(r.last_cmd)]
    local result = r.result and {}

    for _, str in ipairs(stdin) do
        local s = sanitize(str)
        if s ~= "" then
            -- if not r.is_ready then
            --     if s:match('^.*=> $') then
            --         return true, nil
            --     end
            -- else
                if vim.endswith(s, last_cmd) then
                    -- ignore duplicate last command data
                    result = result or {}
                elseif result then
                    if s:match('^.*=> $') then -- Clojure
                    -- if str:match('^%*%s*$') then -- LISP
                        return true, result
                    end
                    table.insert(result, s)
                end
            -- end

        end
    end

    return false, result
end
-- local function clojure_process(cmd, stdin, result)
--     if not cmd then
--         return false, nil
--     end
--
--     local last_cmd = cmd[vim.tbl_count(cmd)]
--     for _, str in ipairs(stdin) do
--         local s = sanitize(str)
--         if s ~= "" then
--             if result then
--                 if s:match('^.*=> $') then -- Clojure
--                 -- if str:match('^%*%s*$') then -- LISP
--                     return true, result
--                 end
--                 table.insert(result, s)
--             elseif vim.endswith(str, last_cmd .. '\r\r') then
--             -- elseif str == last_cmd .. '\r\r' then
--                 result = {}
--             end
--         end
--     end
--
--     return false, result
-- end

local function node_process(cmd, stdin, result)
    if not cmd then
        return false, nil
    end

    if not result and vim.tbl_count(stdin) == 2 and stdin[2] == "" then
        return false, {}
    end

    if result then
        for _, str in ipairs(stdin) do
            str = sanitize(str)
            if str ~= "" then
                if str:match('^>%s*$') then -- NODE
                    return true, result
                end
                table.insert(result, str)
            end
        end
    end

    return false, result
end

function repl.get(name, opts)
    local r = repl_cache[name]
    if r or not opts then
        return r
    end

    return repl.new(name, opts)
end

function repl.new(name, opts)
    opts = vim.tbl_extend("keep", opts or {}, {
        cmd = "",
        cwd = vim.loop.cwd(),
        out = "repl-out://" .. name,
    })

    local out_buf = vim.fn.bufnr(opts.out, 1)
    vim.api.nvim_set_option_value('buftype', 'nofile', { buf = out_buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = out_buf })
    vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = out_buf })
    vim.api.nvim_set_option_value('syntax', 'clojure', { buf = out_buf }) -- TODO configurable
    local repl_buf = vim.api.nvim_create_buf(false, false)

    local instance = {
        name = name,
        job_id = -1,
        is_ready = false,
        config = {
            cwd = opts.cwd,
            cmd = opts.cmd,
        },
        buffers = {
            repl = repl_buf,
            out = out_buf,
        },
        -- TODO better naming
        process = {
          cmd = nil,
          data = nil,
          timer = vim.loop.new_timer(),
        },
        result = nil,
        last_cmd = nil,
    }

    setmetatable(instance, metatable)
    repl_cache[name] = instance

    vim.api.nvim_buf_call(repl_buf, function()
        instance.job_id = vim.fn.termopen(vim.o.shell..';#'..name, {
            cwd = vim.fn.fnamemodify(opts.cwd, ':p'),
            on_stdout = function(_, data)
                instance.process.timer:stop()

                -- ignore changes from the repl buffer directly
                if vim.api.nvim_get_current_buf() == instance.buffers.repl then
                    return
                end

                -- TODO also timer to check on startup issues
                if not instance.is_ready then
                    instance.result = {}
                    local done = clojure_process(instance, data)
                    if done then
                        instance.is_ready = true
                        instance.result = nil
                        instance.last_cmd = nil
                        if instance.cb then
                            local x = instance.cb
                            instance.cb = nil
                            x()
                        end
                    end
                    return
                end

                -- TODO call a custom function that gets start and result etc. passed so that it is easier to customize
                -- TODO some sort of "presets" would be nice
                local done, out = clojure_process(instance, data)
                -- local done, out = node_process(instance.last_cmd, data, instance.result)
                P(data)

                -- if instance.last_cmd and instance.last_cmd ~= "SPECIAL" and out then
                if out then
                    vim.api.nvim_buf_set_lines(instance.buffers.out, -1, -1, false, out)
                    -- scroll to the bottom of the out buffer (autoscroll)
                    vim.api.nvim_buf_call(instance.buffers.out, function()
                        vim.cmd.normal{ "G", bang = true }
                    end)
                    instance.result = {}
                end

                if done then
                    instance.result = nil
                    instance.last_cmd = nil
                    if instance.cb then
                        local x = instance.cb
                        instance.cb = nil
                        x()
                    end
                else
                    instance.process.timer:start(5000, 0, vim.schedule_wrap(function()
                        vim.api.nvim_buf_set_lines(instance.buffers.out, -1, -1, false, { "no data received from REPL..." })
                    end))
                end

                -- local last = instance.last_cmd[vim.tbl_count(instance.last_cmd)]
                -- for _, s in ipairs(data) do
                --     if type(last) == "string" and vim.endswith(s:gsub("%c", ""), last) then
                --         instance.start = true
                --     elseif instance.start then
                --         -- https://stackoverflow.com/questions/75200134/suppressing-the-debugger-in-sbcl-with-emacs-and-slime
                --         -- (defun abc (c h) (declare (ignore h)) (princ c) (clear-input) (abort))
                --         -- (setf *debugger-hook* #'abc)
                --         if s:match('^%*%s*$') then -- SBCL
                --         -- if s:match('^.*=> $') then -- Clojure
                --             local output = vim.iter(instance.result)
                --                 -- :skip(1)
                --                 :map(function(line)
                --                     -- ignore the additional "count" return value
                --                     local new_txt, _ = line:gsub("%c", "")
                --                     return new_txt
                --                 end)
                --                 :totable()
                --             vim.api.nvim_buf_set_lines(instance.bufs.out, -1, -1, false, output)
                --             instance.start = false
                --             instance.result = {}
                --             instance.last_cmd = {}
                --             break
                --         end
                --         table.insert(instance.result, s)
                --     end
                -- end
            end,
        })
    end)

    if opts.cmd ~= "" then
        -- TODO testing with the "READY" callback
        if type(opts.cmd) == "string" then
            instance:send({ opts.cmd }, function()
                P("READY")
            end)
        elseif type(opts.cmd) == "table" then
            instance:send(opts.cmd, function()
                P("READY TABLE")
            end)
        else
            -- error
        end
    end

    return instance
end

---@param cmd table|string
function methods:send(cmd, cb)
    if type(cmd) == "string" then
        cmd = vim.split(cmd, '\n')
    end

    if type(cmd) ~= "table" or vim.tbl_count(cmd) == 0 then
        return
    end

    self.last_cmd = cmd
    self.cb = cb
    -- if not self.is_ready then
    --     self.result = {}
    -- end

    -- TODO test what works more resilient
    vim.fn.chansend(self.job_id, table.concat(cmd, "\n") .. "\n")
    -- vim.fn.chansend(self.job_id, table.concat(cmd, "") .. "\n")
end

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

function methods:open_repl(location)
    return open(self.buffers.repl, location)
end

function methods:open_out(location)
    return open(self.buffers.out, location)
end

return repl
