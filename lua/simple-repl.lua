local M = {}

local Term = require('simple-repl.term')

-- ~~~~~~~~~~~~~~~~~~~~~~
-- custom types & classes
-- ~~~~~~~~~~~~~~~~~~~~~~

---@class SimpleRepl_ReplOptions
---@field create SimpleRepl_ReplCreateOptions? The options for creating the REPL (only considered on the initial creation)
---@field open SimpleRepl_ReplOpenOptions? The options for opening the REPL in a window

---@class SimpleRepl_ReplCreateOptions
---@field cmd string? The initial command to start the REPL. If this is not provided the REPL will just be a "plain" terminal
---@field path string? The path to start the REPL in (defaults to the current working directory)
---@field callback function? A callback function to execute after the REPL buffer has been created (e.g. to set highlights)

---@class SimpleRepl_ReplOpenOptions
---@field win 'current'|'split'|'vsplit'|'hud'|'none'? In which window to open the REPL
---@field focus boolean? Whether to focus the REPL window afterwards (only relevant if `win` is 'split' or 'vsplit')
---@field hud SimpleRepl_HudOptions? Additional configuration options for the HUD window (only relevant if `win` is 'hud')

---@alias SimpleRepl_ShowHudOptions 'always'|'never'|'if_not_visible'

---@class SimpleRepl_HudOptions
---@field show SimpleRepl_ShowHudOptions? If and when to show the HUD window
---@field config table? The configuration for the HUD window. See `vim.api.nvim_open_win` for all available options

---@class SimpleRepl_SendToReplOptions
---@field new_line string? The new line character to use (default: '\n'). This is used to join the given lines before being send to the terminal. Use for example "<C-o>" with 'rlwrap' to avoid adding to the history
---@field hud SimpleRepl_HudOptions? Options for the HUD window
---@field scroll boolean Should the REPL scroll to the bottom to show the most recent output (default: 'true'). Only considered for the windows in the current tabpage

-- ~~~~~~~~~~~~~~~~~~~~~~
-- local helper functions
-- ~~~~~~~~~~~~~~~~~~~~~~

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

---Show the given terminal in a HUD window
---@param term SimpleRepl_Terminal The terminal to show in the HUD
---@param opts SimpleRepl_HudOptions? Optional options to customize the HUD window
local function show_hud(term, opts)
    opts = vim.tbl_extend('keep', opts or {}, {
        show = 'if_not_visible',
        config = {
            title = ' REPL Output: ' .. term.name .. ' ',
            relative = 'editor',
            border = 'single',
            style = 'minimal',
            anchor = 'NE',
            row = 0,
            col = vim.opt.columns:get(),
            width = math.max(math.floor(vim.opt.columns:get() / 3), 50),
            height = math.max(math.floor(vim.opt.lines:get() / 4), 10),
        }
    })

    -- assess the number of REPL windows on the current tabpage
    local repl_windows, hud_windows, split_windows = 0, {}, 0
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == term.buf then
            repl_windows = repl_windows + 1

            if vim.w[win].simple_repl_hud then
                table.insert(hud_windows, win)
            else
                split_windows = split_windows + 1
            end
        end
    end

    -- check for early returns
    if repl_windows > 0 then
        if not vim.tbl_isempty(hud_windows) then
            if opts.show == 'never' or (opts.show == 'if_not_visible' and split_windows > 0) then
                for _, win in ipairs(hud_windows) do
                    vim.api.nvim_win_close(win, true)
                end
            end

            return
        end

        if opts.show == 'if_not_visible' then
            return
        end
    end

    local win = vim.api.nvim_open_win(term.buf, false, opts.config)
    vim.w[win].simple_repl_hud = true

    vim.api.nvim_buf_attach(term.buf, false, {
        on_lines = function(_, _, _, _, _, last_line_in_updated_range)
            if not vim.api.nvim_win_is_valid(win) then
                return true -- detach if window was closed already
            end
            vim.schedule(function()
                -- if the `scrollback` for the terminal buffer is full line we receive zeros for certain line update events
                -- to avoid jumping to an "invalid" buffer position we just jump to the last line by default
                local line = last_line_in_updated_range
                if last_line_in_updated_range == 0 then
                    line = vim.api.nvim_buf_line_count(term.buf)
                end

                vim.api.nvim_win_set_cursor(win, { line, 0 })
                vim.api.nvim_win_call(win, function()
                    vim.cmd.normal { 'zb', bang = true }
                end)
            end)
        end
    })

    vim.api.nvim_create_autocmd({ 'CursorMoved', 'CmdlineEnter', 'InsertEnter' }, {
        desc = 'Close the REPL HUD on cursor movement',
        pattern = '*',
        once = true,
        callback = function()
            if vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end,
    })
end

-- ~~~~~~~~~~~~~~~~~~~~
-- public API functions
-- ~~~~~~~~~~~~~~~~~~~~

---Open a REPL named `name`
---
---If a REPL with this name does not exists it will be created
---Specify the creation details under `opts.create`:
---- `cmd` (string): The initial command to start the REPL
---- `path` (string): The path to start the REPL in (defaults to `cwd`)
---- `callback` (function): A callback function to execute once after the REPL buffer has been created (e.g. to set highlights)
---
---By default the REPL will be opened in a new split window
---Specify where the REPL is being opened under `opts.open`:
---- `win` ('current'|'split'|'vsplit'|'hud'|'none'): Where to open the REPL window (defaults to `split`)
---- `focus` (boolean): Whether to focus the REPL window (defaults to `false`). Only relevant if `win` is 'split' or 'vsplit'
---- `hud` (table): Additional configuration options for the HUD window. Only relevant if `win` is 'hud'
---
---@param name string The name for the REPL
---@param opts SimpleRepl_ReplOptions Configuration options for the REPL
function M.open_repl(name, opts)
    local repl_name = simple_repl_name(name)
    opts = vim.tbl_deep_extend('keep', opts or {}, {
        create = {
            cmd = '',
            path = vim.fn.getcwd(),
            callback = nil,
        },
        open = {
            win = 'split',
            focus = false,
            hud = {
                -- when opening a REPL in the HUD it should be always shown
                show = 'always',
            },
        },
    })

    local cmd = opts.create.cmd

    -- make sure the REPL command is actually executed (if provided)
    if cmd ~= '' and not vim.endswith(cmd, '\n') then
        cmd = cmd .. '\n'
    end

    local term = Term:start(repl_name, {
        cwd = opts.create.path,
        cmd = cmd,
    })

    if opts.open.win ~= 'none' then
        if opts.open.win == 'hud' then
            show_hud(term, opts.open.hud)
        else
            term:show({
                ---@diagnostic disable-next-line: assign-type-mismatch
                location = opts.open.win,
                focus = opts.open.focus,
            })
        end
    end
end

---Send the given lines to the specific REPL
---If the REPL does not exist, this function will do nothing
---@param name string The custom name of the REPL
---@param lines string[] The lines to send to the REPL
---@param opts SimpleRepl_SendToReplOptions? Optional options for more customization
function M.send_to_repl(name, lines, opts)
    opts = vim.tbl_deep_extend('keep', opts or {}, {
        new_line = '\n',
        hud = {
            show = 'if_not_visible',
        },
        scroll = true,
    })

    local term = Term:get(name)
    if term then
        local repl_text = table.concat(lines, opts.new_line)
        if not vim.endswith(repl_text, opts.new_line) then
            repl_text = repl_text .. opts.new_line
        end
        term:send(repl_text)

        -- show the REPL HUD if configured
        show_hud(term, opts.hud)

        -- scroll all REPL windows on the current tabpage to the bottom using `G`
        if opts.scroll then
            for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
                if vim.api.nvim_win_get_buf(win) == term.buf then
                    -- ignore hud windows as they have their own logic of showing the latest line
                    if not vim.w[win].simple_repl_hud then
                        vim.api.nvim_win_call(win, function()
                            vim.cmd.normal { 'G', bang = true }
                        end)
                    end
                end
            end
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
