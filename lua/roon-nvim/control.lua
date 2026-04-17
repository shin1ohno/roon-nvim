local cli = require("roon-nvim.cli")
local config = require("roon-nvim.config")

local M = {}

---Build argv that targets the configured zone (if any).
---@param subcmd string
---@return string[]
local function with_zone(subcmd)
  local args = { subcmd }
  local zone = config.options.zone
  if zone and zone ~= "" then
    table.insert(args, "--zone")
    table.insert(args, zone)
  end
  return args
end

function M.play()
  cli.exec_async(with_zone("play"))
end

function M.pause()
  cli.exec_async(with_zone("pause"))
end

function M.stop()
  cli.exec_async(with_zone("stop"))
end

function M.next()
  cli.exec_async(with_zone("next"))
end

function M.previous()
  cli.exec_async(with_zone("previous"))
end

---Toggle play/pause based on the current zone's state from the watch snapshot.
---Falls back to `play` if state isn't populated yet.
function M.play_pause()
  local state = require("roon-nvim.state")
  local z = state.primary_zone(config.options.zone)
  if z and z.state == "playing" then
    M.pause()
  else
    M.play()
  end
end

return M
