local cc = require("neo-tree.sources.common.commands")
local utils = require("neo-tree.utils")

local cli = require("roon-nvim.cli")
local config = require("roon-nvim.config")
local source = require("neo-tree.sources.roon")

local M = {}

local function current(state)
  return state.tree:get_node()
end

---Invoke play-item against the currently-focused leaf node.
---@param state table
---@param action string
local function play(state, action)
  local node = current(state)
  if not node then
    return
  end
  local extra = node.extra or {}
  if extra.kind == "more" then
    source.load_more(state, node)
    return
  end
  if not extra.item_key then
    vim.notify("roon: node has no item_key", vim.log.levels.WARN)
    return
  end
  local session = extra.session or config.options.session.neotree
  local zone = config.options.zone
  cli.play_item_async(session, extra.item_key, zone, action)
end

---<CR>: directory ⇒ toggle, more ⇒ load page, leaf ⇒ play-now.
function M.roon_open(state)
  local node = current(state)
  if not node then
    return
  end
  if node.type == "directory" then
    source.toggle_directory(state, node)
    return
  end
  if node.extra and node.extra.kind == "more" then
    source.load_more(state, node)
    return
  end
  play(state, "play-now")
end

function M.roon_play_now(state)
  play(state, "play-now")
end

function M.roon_queue(state)
  play(state, "queue")
end

function M.roon_start_radio(state)
  play(state, "start-radio")
end

function M.toggle_node(state)
  cc.toggle_node(state, utils.wrap(source.toggle_directory, state))
end

cc._add_common_commands(M)

return M
