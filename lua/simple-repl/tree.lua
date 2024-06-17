local M = {}

---Search the tree upwards from the current cursor position for a node fulfilling all requirements
---Set `type` to search for the first node that matches the given type
---Set `parent_type` to search for the first node that has a parent of the given type
---Set both to combine both requirements
---@param type string? The type of the node
---@param parent_type string? The type of the parent
---@return TSNode? node The node that fulfills all requirements
local function node_upwards(type, parent_type)
    local node = vim.treesitter.get_node()
    local parent = node and node:parent()

    while node do
        local node_check = not type or node:type() == type
        local parent_check = not parent_type or (parent and parent:type() == parent_type)

        if node_check and parent_check then
            return node
        end

        node = parent
        parent = node and node:parent()
    end
end

---Execute a treesitter query from a given node and return the text of the capture
---Only the first capture with the given name will be returned
---@param node TSNode The starting point node
---@param query vim.treesitter.Query The query to execute
---@param capture string The name of the capture to extract
---@return string[] lines The extracted lines from the treesitter node
local function query_from(node, query, capture)
    for id, n, _, _ in query:iter_captures(node, 0, 0, -1) do
        if query.captures[id] == capture then
            return vim.split(vim.treesitter.get_node_text(n, 0), '\n')
        end
    end

    return {}
end

---Find the first node of a given type and return its text
---@param type string The type of the node to search for
---@return string[] lines The extracted lines from the treesitter node
function M.find_node(type)
    local node = node_upwards(type)
    if node then
        return vim.split(vim.treesitter.get_node_text(node, 0), '\n')
    end
    return {}
end

---Find the first node with a parent of the given type and return its text
---@param parent_type string The type of the parent node to search for
---@return string[] lines The extracted lines from the treesitter node
function M.find_node_by_parent(parent_type)
    local node = node_upwards(nil, parent_type)
    if node then
        return vim.split(vim.treesitter.get_node_text(node, 0), '\n')
    end
    return {}
end

---Find the first node of a given type, execute a query from it and return the text of the capture
---@param type string The type of the node to search for
---@param query vim.treesitter.Query The query to execute
---@param capture string The name of the capture to extract
---@return string[] lines The extracted lines from the capture
function M.query_from_node(type, query, capture)
    local node = node_upwards(type)
    if node then
        return query_from(node, query, capture)
    end
    return {}
end

---Find the first node with a parent of the given type, execute a query from it and return the text of the capture
---@param parent_type string The type of the parent node to search for
---@param query vim.treesitter.Query The query to execute
---@param capture string The name of the capture to extract
---@return string[] lines The extracted lines from the capture
function M.query_from_node_by_parent(parent_type, query, capture)
    local node = node_upwards(nil, parent_type)
    if node then
        return query_from(node, query, capture)
    end
    return {}
end

---Execute a query from the root node and return the text of the capture
---@param query vim.treesitter.Query The query to execute
---@param capture string The name of the capture to extract
---@return string[] lines The extracted lines from the treesitter node
function M.query_from_root(query, capture)
    local root = vim.treesitter.get_node():tree():root()
    if root then
        return query_from(root, query, capture)
    end
    return {}
end

return M
