local M = {}

M.zones = {}
M.outputs = {}

local subscribers = {}

---Subscribe to state mutations. Returns an unsub function.
---@param fn fun()
---@return fun()
function M.subscribe(fn)
  table.insert(subscribers, fn)
  return function()
    for i, g in ipairs(subscribers) do
      if g == fn then
        table.remove(subscribers, i)
        return
      end
    end
  end
end

local function notify()
  for _, fn in ipairs(subscribers) do
    fn()
  end
end

---Return the zone that best matches the configured target name, or any
---currently-playing zone if no name match, or the first known zone.
---@param preferred_name string|nil
---@return table|nil
function M.primary_zone(preferred_name)
  local any
  local first_playing
  for _, z in pairs(M.zones) do
    any = any or z
    if z.state == "playing" and not first_playing then
      first_playing = z
    end
    if preferred_name and z.display_name == preferred_name then
      return z
    end
  end
  return first_playing or any
end

---Apply a single decoded event from `roon watch`.
---@param ev table
function M.apply_event(ev)
  local e = ev.event
  if e == "initial" then
    M.zones = {}
    for _, z in ipairs(ev.zones or {}) do
      M.zones[z.zone_id] = z
    end
    M.outputs = {}
    for _, o in ipairs(ev.outputs or {}) do
      M.outputs[o.output_id] = o
    end
  elseif e == "zone_added" or e == "zone_changed" then
    if ev.zone and ev.zone.zone_id then
      M.zones[ev.zone.zone_id] = ev.zone
    end
  elseif e == "zone_removed" then
    if ev.zone_id then
      M.zones[ev.zone_id] = nil
    end
  elseif e == "zone_seeked" then
    local z = ev.zone_id and M.zones[ev.zone_id]
    if z then
      z.seek_position = ev.seek_position
      z.queue_time_remaining = ev.queue_time_remaining
    end
  elseif e == "output_added" or e == "output_changed" then
    if ev.output and ev.output.output_id then
      M.outputs[ev.output.output_id] = ev.output
    end
  elseif e == "output_removed" then
    if ev.output_id then
      M.outputs[ev.output_id] = nil
    end
  else
    return
  end
  notify()
end

---Reset: forget all state (used when watch restarts).
function M.reset()
  M.zones = {}
  M.outputs = {}
  notify()
end

return M
