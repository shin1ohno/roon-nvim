local renderer = require("neo-tree.ui.renderer")

local cli = require("roon-nvim.cli")
local config = require("roon-nvim.config")

local M = {
  name = "roon",
  display_name = " Roon ",
}

local HIERARCHIES = {
  { key = "browse", label = "Browse" },
  { key = "albums", label = "Albums" },
  { key = "artists", label = "Artists" },
  { key = "composers", label = "Composers" },
  { key = "genres", label = "Genres" },
  { key = "playlists", label = "Playlists" },
  { key = "internet_radio", label = "Internet Radio" },
}

local DEFAULT_COUNT = 100

-- Roon nodes are keyed by opaque item_key, not filesystem paths. Disable the
-- git-status / filtered-files hooks on the `name` component so it does not try
-- to index `node.path` (nil on every roon node) and explode with
-- "table index is nil" inside neo-tree/git/init.lua.
local NAME = { "name", use_git_status_colors = false, use_filtered_colors = false }

M.default_config = {
  window = {
    mappings = {
      ["<cr>"] = "roon_open",
      ["o"] = "roon_open",
      ["P"] = "roon_play_now",
      ["q"] = "roon_queue",
      ["r"] = "roon_start_radio",
      ["R"] = "roon_refresh",
    },
  },
  -- `subtitle` is already appended to `name` by item_to_node, so we don't need
  -- a separate renderer component for it. The previous layout referenced a
  -- non-existent "subtitle" component and produced "Component subtitle not
  -- found" warnings on every redraw.
  renderers = {
    directory = {
      { "indent" },
      { "icon" },
      NAME,
    },
    item = {
      { "indent" },
      { "icon" },
      NAME,
    },
    message = {
      { "indent", with_markers = false },
      vim.tbl_extend("force", NAME, { highlight = "NeoTreeMessage" }),
    },
  },
}

---Build a node representing an `items` entry from a browse response.
---@param parent_id string
---@param item table
---@param session string
---@return table
local function item_to_node(parent_id, item, session)
  local is_leaf = item.hint == "action" or item.hint == "action_list"
  local id = parent_id .. "/" .. (item.item_key or item.title or "?")
  local subtitle = item.subtitle
  local name = item.title or "(untitled)"
  if subtitle and subtitle ~= "" then
    name = name .. "  " .. subtitle
  end
  return {
    id = id,
    name = name,
    type = is_leaf and "item" or "directory",
    children = is_leaf and nil or {},
    loaded = is_leaf and true or false,
    extra = {
      item_key = item.item_key,
      session = session,
      hint = item.hint,
      subtitle = subtitle,
    },
  }
end

---Synthetic "load more" row for pagination.
---@param parent_id string
---@param offset integer
---@param session string
---@return table
local function more_node(parent_id, offset, session)
  return {
    id = parent_id .. "/#more@" .. tostring(offset),
    name = string.format("… load %d more", DEFAULT_COUNT),
    type = "item",
    loaded = true,
    extra = {
      kind = "more",
      parent_id = parent_id,
      offset = offset,
      session = session,
    },
  }
end

---Execute a roon browse call and return its child nodes.
---@param parent_id string
---@param args string[]
---@param session string
---@param offset integer
---@return table[] nodes
local function fetch_nodes(parent_id, args, session, offset)
  local ok, resp, err = cli.oneshot_sync(args)
  if not ok or not resp then
    return {
      {
        id = parent_id .. "/#err",
        name = "error: " .. (err or "unknown"),
        type = "message",
        loaded = true,
        extra = { kind = "error" },
      },
    }
  end
  local nodes = {}
  for _, item in ipairs(resp.items or {}) do
    table.insert(nodes, item_to_node(parent_id, item, session))
  end
  local total = resp.total or #nodes
  local next_offset = offset + #nodes
  if total > next_offset then
    table.insert(nodes, more_node(parent_id, next_offset, session))
  end
  if #nodes == 0 then
    table.insert(nodes, {
      id = parent_id .. "/#empty",
      name = "(empty)",
      type = "message",
      loaded = true,
      extra = { kind = "empty" },
    })
  end
  return nodes
end

---Render the top-level list of hierarchies. Called from navigate.
---@param state table
---@param callback fun()|nil
local function show_root(state, callback)
  local session = config.options.session.neotree
  local roots = {}
  for _, h in ipairs(HIERARCHIES) do
    table.insert(roots, {
      id = "roon://" .. h.key,
      name = h.label,
      type = "directory",
      children = {},
      loaded = false,
      extra = {
        kind = "hierarchy",
        hierarchy = h.key,
        session = session,
      },
    })
  end
  state.path = "roon://"
  renderer.show_nodes(roots, state, nil, callback)
end

---Load (or re-load) a hierarchy's children into `node`.
---@param state table
---@param node table
---@param callback fun()|nil
local function load_hierarchy(state, node, callback)
  local extra = node.extra
  local session = extra.session or config.options.session.neotree
  local args =
    { "browse", "--session", session, "--hierarchy", extra.hierarchy, "--pop-all", "--count", tostring(DEFAULT_COUNT) }
  local children = fetch_nodes(node:get_id(), args, session, 0)
  renderer.show_nodes(children, state, node:get_id(), callback)
end

---Load a drill-down (children of an arbitrary item_key).
---@param state table
---@param node table
---@param callback fun()|nil
local function load_item(state, node, callback)
  local extra = node.extra
  local session = extra.session or config.options.session.neotree
  local args = { "browse", "--session", session, "--item-key", extra.item_key, "--count", tostring(DEFAULT_COUNT) }
  local children = fetch_nodes(node:get_id(), args, session, 0)
  renderer.show_nodes(children, state, node:get_id(), callback)
end

---Expand a directory node, fetching children if not yet loaded.
---Flips loaded=true BEFORE the CLI call to prevent double-fetch.
---@param state table
---@param node table
function M.toggle_directory(state, node)
  node = node or state.tree:get_node()
  if not node then
    return
  end
  if node.type ~= "directory" then
    return
  end
  if node.loaded == false then
    node.loaded = true
    if node.extra and node.extra.kind == "hierarchy" then
      load_hierarchy(state, node)
    else
      load_item(state, node)
    end
  elseif node:is_expanded() then
    node:collapse()
    renderer.redraw(state)
  else
    node:expand()
    renderer.redraw(state)
  end
end

---Fetch and splice in the next page of a "#more" row's parent.
---@param state table
---@param node table
function M.load_more(state, node)
  local extra = node.extra
  if not extra or extra.kind ~= "more" then
    return
  end
  local parent = state.tree:get_node(extra.parent_id)
  if not parent then
    return
  end
  local session = extra.session or config.options.session.neotree
  local args = { "browse", "--session", session, "--item-key", parent.extra.item_key or nil }
  -- If parent is a hierarchy node, switch args accordingly.
  if parent.extra and parent.extra.kind == "hierarchy" then
    args = {
      "browse",
      "--session",
      session,
      "--hierarchy",
      parent.extra.hierarchy,
      "--offset",
      tostring(extra.offset),
      "--count",
      tostring(DEFAULT_COUNT),
    }
  else
    table.insert(args, "--offset")
    table.insert(args, tostring(extra.offset))
    table.insert(args, "--count")
    table.insert(args, tostring(DEFAULT_COUNT))
  end
  local new_nodes = fetch_nodes(parent:get_id(), args, session, extra.offset)
  -- Remove the #more node itself; the last entry of new_nodes may be a new #more.
  local existing = parent:get_child_ids()
  local filtered = {}
  for _, id in ipairs(existing) do
    local child = state.tree:get_node(id)
    if not (child and child.extra and child.extra.kind == "more") then
      table.insert(filtered, child)
    end
  end
  -- Rebuild: keep existing + append new.
  local combined = {}
  for _, c in ipairs(filtered) do
    table.insert(combined, c)
  end
  for _, c in ipairs(new_nodes) do
    table.insert(combined, c)
  end
  renderer.show_nodes(combined, state, parent:get_id())
end

---@param state table
---@param path string|nil
---@param path_to_reveal string|nil
---@param callback fun()|nil
function M.navigate(state, path, path_to_reveal, callback)
  state.dirty = false
  show_root(state, callback)
end

function M.setup(_config, _global_config)
  -- No event subscriptions needed for v0.1.
end

return M
