local M = {}

local Term = require('simple-repl.term')

---Create the simple REPL name
---@param name string? Custom postfix for the REPL name
---@return string
local function simple_repl_name(name)
    local base = 'simple_repl'

    if not name or name == '' then
        return base
    end

    return base..':'..name
end

---@class SimpleRepl_OpenReplOptions
---@field path string? The path to start the REPL in. Only considered if the REPL is newly created
---@field win 'current'|'split'|'vsplit'|'none'? Where to open the REPL window
---@field focus boolean? Whether to focus the REPL window. Only relevant if `win` is 'split' or 'vsplit'

---Create and/or open a REPL named `name`
---
---If a REPL with this name already exists, it will be reused
---If it does NOT exist, a new terminal will be created and `cmd` will be executed (otherwise `cmd` will be ignored)
---By default also opens the REPL in a new split window (using `:split`, can be configured)
---Use this function to create a new REPL or to quickly open an existing one in a window
---
---Configuration options:
---- `path` (string): The path to start the REPL in (defaults to `cwd`). Only considered if the REPL is newly created
---- `win` ('current'|'split'|'vsplit'|'none'): Where to open the REPL window (defaults to `split`)
---- `focus` (boolean): Whether to focus the REPL window (defaults to `false`). Only relevant if `win` is 'split' or 'vsplit'
---
---@param name string The name for the REPL
---@param cmd string The command to start the REPL with
---@param opts SimpleRepl_OpenReplOptions? Configuration options for the REPL
function M.open_repl(name, cmd, opts)
    local repl_name = simple_repl_name(name)
    opts = vim.tbl_extend('keep', opts or {}, {
        path = vim.fn.getcwd(),
        win = 'split',
        focus = false,
    })

    -- make sure the REPL command is actually executed
    if not vim.endswith(cmd, '\n') then
        cmd = cmd .. '\n'
    end

    local term = Term:start(repl_name, {
        cwd = opts.path,
        cmd = cmd,
    })

    if opts.win ~= 'none' then
        term:show({
            location = opts.win,
            focus = opts.focus,
        })
    end
end

---@alias SimpleRepl_ShowHudOptions 'always'|'never'|'if_not_visible'

---@class SimpleRepl_HudOptions
---@field show SimpleRepl_ShowHudOptions? If and when to show the HUD window
---@field config table? The configuration for the HUD window. See `vim.api.nvim_open_win` for all available options

---@class SimpleRepl_SendToReplOptions
---@field new_line string? The new line character to use (default: '\n'). This is used to join the given lines before being send to the terminal. Use for example "<C-o>" with 'rlwrap' to avoid adding to the history
---@field hud SimpleRepl_HudOptions? Options for the HUD window

---Send the given lines to the specific REPL
---If the REPL does not exist, this function will do nothing
---@param name string The custom name of the REPL
---@param lines string[] The lines to send to the REPL
---@param opts SimpleRepl_SendToReplOptions? Optional options for more customization
function M.send_to_repl(name, lines, opts)
    opts = vim.tbl_deep_extend('keep', opts or {}, {
        new_line = '\n',
        hud = {
            show = 'if_not_visible', -- always, never, if_not_visible
            config = {
                title = ' REPL Output: ' .. name .. ' ',
                relative = 'editor',
                border = 'single',
                style = 'minimal',
                anchor = 'NE',
                row = 0,
                col = vim.opt.columns:get(),
                width = math.max(math.floor(vim.opt.columns:get() / 3), 50),
                height = math.max(math.floor(vim.opt.lines:get() / 4), 10),
            },
        }
    })

    local term = Term:get(name)
    if term then
        local repl_text = table.concat(lines, opts.new_line)
        if not vim.endswith(repl_text, opts.new_line) then
            repl_text = repl_text .. opts.new_line
        end
        term:send(repl_text)

        local win = assert(vim.fn.bufwinid(term.buf))

        -- close former hud window if it exists
        if win > 0 and vim.w[win].simple_repl_hud then
            vim.api.nvim_win_close(win, true)
            win = assert(vim.fn.bufwinid(term.buf))
        end

        if opts.hud.show == 'always' or (opts.hud.show == 'if_not_visible' and win == -1) then
            -- TODO can we make this "better"
            -- wait a bit to ensure the REPL output is present and can be considered for the cursor position
            vim.defer_fn(function()
                local repl_lines = vim.api.nvim_buf_get_lines(term.buf, 0, -1, false)
                local latest_text_row = vim.iter(repl_lines)
                    :enumerate()
                    :rfind(function(_, s)
                        return s ~= ''
                    end)

                win = vim.api.nvim_open_win(term.buf, false, opts.hud.config)

                vim.w[win].simple_repl_hud = true
                vim.api.nvim_win_set_cursor(win, { latest_text_row, 0 })
                vim.api.nvim_create_autocmd({ 'CursorMoved', 'CmdlineEnter' }, {
                    pattern = '*',
                    once = true,
                    callback = function()
                        if vim.api.nvim_win_is_valid(win) then
                            vim.api.nvim_win_close(win, true)
                        end
                    end,
                })
            end, 100)
        end
    end
end

---Sent the current visual selection to the specific REPL
---@param name string The name of the REPL
---@param opts SimpleRepl_SendToReplOptions? Optional options for more customization
function M.v_send_to_repl(name, opts)
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

    M.send_to_repl(name, lines, opts)
end

---Send the next VIM  motion (operator mode) to the specific REPL
---@param name string The name of the REPL
---@param opts SimpleRepl_SendToReplOptions? Optional options for more customization
function M.op_send_to_repl(name, opts)
    -- create a new operator function with the given `path` and `name`
    local op_fn = function()
        local row1, col1 = unpack(vim.api.nvim_buf_get_mark(0, "["))
        local row2, col2 = unpack(vim.api.nvim_buf_get_mark(0, "]"))

        local lines = vim.api.nvim_buf_get_text(0, row1 - 1, col1, row2 - 1, col2 + 1, {})

        M.send_to_repl(name, lines, opts)
    end

    _G.op_repl_fn = op_fn
    vim.opt_local.opfunc = 'v:lua.op_repl_fn'
    vim.api.nvim_feedkeys('g@', 'n', true)
end

return M
