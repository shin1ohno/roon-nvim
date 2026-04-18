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

---Seek within the currently-playing track on the target zone.
---@param seconds integer  absolute seconds (or offset if relative = true)
---@param relative boolean
function M.seek(seconds, relative)
  local args = with_zone("seek")
  table.insert(args, tostring(seconds))
  if relative then
    table.insert(args, "--relative")
  end
  cli.exec_async(args)
end

---Resolve the output-id to target for volume / mute.
---If the target zone has exactly one output we prefer that — otherwise we
---return nil and let the CLI fall back to whatever `roon output` saved.
---@return string|nil output_id
local function primary_output_id()
  local state = require("roon-nvim.state")
  local z = state.primary_zone(config.options.zone)
  if z and z.outputs and #z.outputs == 1 then
    return z.outputs[1].output_id
  end
  return nil
end

local function with_output(args)
  local oid = primary_output_id()
  if oid then
    table.insert(args, "--output-id")
    table.insert(args, oid)
  end
  return args
end

---Set or adjust volume on the primary output.
---@param value number
---@param relative boolean|nil
function M.volume(value, relative)
  local args = { "volume", tostring(value) }
  if relative then
    table.insert(args, "--relative")
  end
  cli.exec_async(with_output(args))
end

---@param on boolean
function M.mute(on)
  local args = { "mute", on and "on" or "off" }
  cli.exec_async(with_output(args))
end

---Toggle mute based on the watch snapshot's current is_muted. No-op if the
---snapshot isn't populated or the zone has no outputs.
function M.mute_toggle()
  local state = require("roon-nvim.state")
  local z = state.primary_zone(config.options.zone)
  if not z or not z.outputs or #z.outputs == 0 then
    return
  end
  local vol = z.outputs[1].volume
  local muted = vol and vol.is_muted == true or false
  M.mute(not muted)
end

return M
