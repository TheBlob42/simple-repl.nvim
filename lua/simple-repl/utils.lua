local M = {}

---Get the currently selected text (from visual mode)
---@return string[]
function M.get_visual_text()
    -- needed due to inconsistencies with the visual selection otherwise
    -- https://github.com/neovim/neovim/discussions/26092
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

    return lines
end

---Get the text of the next VIM motion (operator mode) and call the provided `callback`
---@param callback fun(l: string[]) Callback function to call with extracted text
function M.get_op_text(callback)
    -- create a new operator function with the given `path` and `name`
    local op_fn = function()
        local row1, col1 = unpack(vim.api.nvim_buf_get_mark(0, "["))
        local row2, col2 = unpack(vim.api.nvim_buf_get_mark(0, "]"))

        local lines = vim.api.nvim_buf_get_text(0, row1 - 1, col1, row2 - 1, col2 + 1, {})

        callback(lines)
    end

    _G.op_repl_fn = op_fn
    vim.opt_local.opfunc = 'v:lua.op_repl_fn'
    vim.api.nvim_feedkeys('g@', 'n', true)
end

return M
