local repl = {}
local methods = {}
local metatable = { __index = methods }

local repl_cache = {}

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
---@param cmd string[] The last command that was send to the REPL
---@param stdin string[] The data received via STDIN
---@param result string[] The already processed data for this command
---@return boolean finished If the process is finished or if more data is expected
---@return string[]? result The processed data (so far). If `finished` is `true` this is the end result
local function clojure_process(cmd, stdin, result)
    if not cmd then
        return false, nil
    end

    local count = vim.tbl_count(stdin)
    local last_cmd = cmd[vim.tbl_count(cmd)]
    if count > 1 and stdin[count] == "" then
        if vim.endswith(sanitize(stdin[count - 1]), last_cmd) then
            return false, {}
        end
    end

    for _, str in ipairs(stdin) do
        local s = sanitize(str)
        if s ~= "" then
            if result then
                if s:match('^.*=> $') then -- Clojure
                -- if str:match('^%*%s*$') then -- LISP
                    return true, result
                end
                table.insert(result, s)
            end
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

function repl.get(name)
    return repl_cache[name]
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
    local repl_buf = vim.api.nvim_create_buf(false, false)

    -- vim.api.nvim_buf_attach(repl_buf, false, {
    --     on_lines = function(_, _, _, fl, ll, lu)
    --         P(fl..":"..ll..":"..lu)
    --         P(vim.api.nvim_buf_get_lines(repl_buf, fl, lu, false))
    --     end,
    -- })

    local instance = {
        name = name,
        job_id = -1,
        cmd = opts.cmd,
        cwd = opts.cwd,
        bufs = {
            repl = repl_buf,
            out = out_buf,
        },
        -- TODO better naming
        start = false,
        in_progress = false,
        result = nil,
        last_cmd = nil,
        process = function(cmd, data, tmp)
            -- todo
        end,
    }

    setmetatable(instance, metatable)
    repl_cache[name] = instance

    vim.api.nvim_buf_call(repl_buf, function()
        instance.job_id = vim.fn.termopen(vim.o.shell..';#'..name, {
            cwd = vim.fn.fnamemodify(opts.cwd, ':p'),
            on_stdout = function(_, data)
                -- TODO call a custom function that gets start and result etc. passed so that it is easier to customize
                -- TODO some sort of "presets" would be nice
                local done, out = clojure_process(instance.last_cmd, data, instance.result)
                -- local done, out = node_process(instance.last_cmd, data, instance.result)
                P(data)

                if out then
                    vim.api.nvim_buf_set_lines(instance.bufs.out, -1, -1, false, out)
                    instance.result = {}
                end

                if done then
                    instance.result = nil
                    instance.last_cmd = nil
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
        if type(opts.cmd) == "string" then
            instance:send({ opts.cmd }, true)
        elseif type(opts.cmd) == "table" then
            instance:send(opts.cmd, true)
        else
            -- error
        end
    end

    return instance
end

-- TODO don't log this option
---@param cmd table
function methods:send(cmd, skip)
    if type(cmd) ~= "table" or vim.tbl_count(cmd) == 0 then
        return
    end

    if not skip then
        self.last_cmd = cmd
    end
    -- vim.fn.chansend(self.job_id, table.concat(cmd, "\n") .. "\n")
    vim.fn.chansend(self.job_id, table.concat(cmd, "") .. "\n")
end

function methods:open_repl()
    local win = vim.api.nvim_get_current_win()
    vim.cmd.split()
    vim.api.nvim_set_current_buf(self.bufs.repl)
    vim.api.nvim_set_current_win(win)
end

function methods:open_out()
    local win = vim.api.nvim_get_current_win()
    vim.cmd.split()
    vim.api.nvim_set_current_buf(self.bufs.out)
    vim.api.nvim_set_current_win(win)
end

return repl
