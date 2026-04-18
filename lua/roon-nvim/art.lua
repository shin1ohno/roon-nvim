---Album art fetcher. Pulls cover images from Roon via `roon image <key>`,
---caches them on disk, and hands off rendering to snacks.nvim's image module
---(Kitty Graphics Protocol under the hood — Kitty / WezTerm / Ghostty).
---The widget module owns the float + placement lifecycle.
local config = require("roon-nvim.config")

local M = {}

local CACHE_DIR = vim.fn.stdpath("cache") .. "/roon-nvim/art"

---Return true if the runtime + terminal can actually render an image.
---Two preconditions: snacks.nvim is loaded, and its terminal detection
---reports a supported emulator. Falls back to false on any error.
---@return boolean
function M.supported()
  local ok_snacks, _ = pcall(require, "snacks")
  if not ok_snacks then
    return false
  end
  -- Snacks loads submodules lazily via __index; `image` and `image.terminal`
  -- resolve on first access. Wrap in pcall so load errors never propagate.
  local ok, supported = pcall(function()
    local img = Snacks and Snacks.image or require("snacks.image")
    if img and img.supports_terminal then
      return img.supports_terminal()
    end
    -- Older snacks versions may not have supports_terminal; accept presence.
    return img ~= nil
  end)
  return ok and supported == true
end

---@param image_key string
---@return string
function M.cache_path(image_key)
  local safe = image_key:gsub("[^%w_-]", "_")
  return CACHE_DIR .. "/" .. safe .. ".jpg"
end

local function ensure_cache_dir()
  vim.fn.mkdir(CACHE_DIR, "p")
end

---Fetch an image for `image_key`. If the cache already holds it, the
---callback fires synchronously in the next event tick with the cached
---path. Otherwise `roon image` is spawned and the callback fires on exit.
---@param image_key string
---@param width_px integer  pixel dimensions for both axes
---@param callback fun(path: string|nil, err: string|nil)
function M.fetch(image_key, width_px, callback)
  if not image_key or image_key == "" then
    callback(nil, "no image_key")
    return
  end
  ensure_cache_dir()
  local path = M.cache_path(image_key)
  if vim.fn.filereadable(path) == 1 then
    vim.schedule(function()
      callback(path, nil)
    end)
    return
  end

  local cli_bin = config.options.cli or "roon"
  local args = {
    cli_bin,
    "image",
    image_key,
    "--width",
    tostring(width_px),
    "--height",
    tostring(width_px),
    "--format",
    "jpeg",
    "-o",
    path,
  }
  if config.options.host then
    table.insert(args, 2, "--host")
    table.insert(args, 3, config.options.host)
  end
  if config.options.port then
    table.insert(args, 2, "--port")
    table.insert(args, 3, tostring(config.options.port))
  end

  vim.system(args, { text = true }, function(result)
    if result.code ~= 0 then
      local err = (result.stderr ~= "" and result.stderr) or ("exit " .. tostring(result.code))
      vim.schedule(function()
        callback(nil, err)
      end)
      return
    end
    vim.schedule(function()
      callback(path, nil)
    end)
  end)
end

return M
