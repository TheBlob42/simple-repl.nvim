---A simple module to manage terminal buffers
local M = {}

---@class SimpleRepl_Terminal
---@field name string The name of the terminal
---@field buf number The buffer number of the terminal
---@field job_id number The job id of the terminal
---@field send fun(self: SimpleRepl_Terminal, cmd: string|table) Send a command to the terminal
---@field show fun(self: SimpleRepl_Terminal, opts: SimpleRepl_ShowOptions?) Show the terminal in a window
---@field close fun(self: SimpleRepl_Terminal) Close the terminal and clean up

---Retrieve a terminal by its `name` (if it exists)
---@param name string The name of the terminal
---@return SimpleRepl_Terminal? terminal
function M:get(name)
    local buf = vim.fn.bufnr('^term://*'..name..'$')
    if buf > 0 then
        local term = {}
        setmetatable(term, self)
        self.__index = self
        term.name = name
        term.buf = buf
        term.job_id = vim.api.nvim_buf_get_var(assert(buf), 'terminal_job_id')
        return term
    end

    return nil
end

---@class SimpleRepl_StartupOptions
---@field cwd string? The working directory for the terminal (defaults to the current `cwd`)
---@field cmd string|table? The command to execute in the terminal after startup

---Start a new terminal with the given `name`
---If a terminal with this name already exists return it instead
---@param name string The name of the terminal
---@param opts SimpleRepl_StartupOptions? Optional options about the terminal startup
---@return SimpleRepl_Terminal terminal
---@return boolean new_terminal_was_created
function M:start(name, opts)
    local term = M:get(name)
    if term then
        return term, false
    end

    opts = vim.tbl_extend('keep', opts or {}, {
        cwd = vim.loop.cwd(),
        cmd = '',
    })

    term = {}
    setmetatable(term, self)
    self.__index = self

    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_call(buf, function()
        -- `termopen` always uses the current buffer for the connection
        local job_id = vim.fn.termopen(vim.o.shell..';#'..name, {
            cwd = vim.fn.fnamemodify(opts.cwd, ':p'),
            -- on_stdout = function(_, s)
            --     P(s)
            -- end,
        })

        term.name = name
        term.buf = buf
        term.job_id = job_id
    end)

    term:send(opts.cmd)

    return term, true
end

---@alias SimpleRepl_WindowPosition 'current' | 'split' | 'vsplit'

---@class SimpleRepl_ShowOptions
---@field location SimpleRepl_WindowPosition? The location to show the terminal in (defaults to `current`)
---@field focus boolean? Whether to focus the terminal window (defaults to `false`)

---Show the terminal in a window
---@param opts SimpleRepl_ShowOptions? Information where and how to show the terminal
---@return integer win
function M:show(opts)
    opts = vim.tbl_extend('keep', opts or {}, {
        location = 'current',
        focus = false,
    })

    local src_win = vim.api.nvim_get_current_win()
    local win = vim.fn.bufwinid(self.buf)
    if win == -1 then
        if opts.location == 'split' then
            vim.cmd.split()
        elseif opts.location == 'vsplit' then
            vim.cmd.vsplit()
        end

        win = vim.api.nvim_get_current_win()

        if not opts.focus then
            vim.api.nvim_set_current_win(src_win)
        end

        vim.api.nvim_win_set_buf(win, self.buf)
    end

    assert(win)

    vim.api.nvim_win_call(win, function()
        vim.cmd.normal { 'G', bang = true }
    end)

    return win
end

---Execute a command in the terminal
---Make sure that the command ends with a newline character if it should be executed
---@param cmd string|table The command to execute. If its a table it will be joined with newlines ('\n')
function M:send(cmd)
    if not cmd or cmd == '' or cmd == {} then
        return
    end

    if type(cmd) == 'table' then
        cmd = table.concat(cmd, '\n')
    end

    vim.fn.chansend(self.job_id, cmd)
end

---Close the terminal and clean up
function M:close()
    vim.fn.chanclose(self.job_id)
    vim.api.nvim_buf_delete(self.buf, { force = true })
end

return M
