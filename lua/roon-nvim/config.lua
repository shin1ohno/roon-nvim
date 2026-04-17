local M = {}

M.defaults = {
  -- Default zone name for play actions. Falls back to the CLI's `roon zone`
  -- selection if nil. String match is done server-side by the CLI.
  zone = nil,
  -- Path to the roon CLI binary. nil ⇒ resolved via $PATH.
  cli = "roon",
  -- Optional CLI overrides. nil ⇒ the CLI uses its saved cli.toml default.
  host = nil,
  port = nil,
  watch = {
    auto_start = true,
    -- Per-zone seek throttle passed to `roon watch --seek-hz`. 0 = every tick.
    seek_hz = 1.0,
    -- Restart backoff seconds (start, max).
    backoff = { 3, 30 },
  },
  -- The two CLI session keys used by the plugin. Keep these stable so the
  -- hierarchy cache at ~/.config/roon-rs/sessions/<key>.toml is reused.
  session = {
    neotree = "nvim-neotree",
    telescope = "nvim-telescope",
  },
  -- Rich "Now Playing" card shown via vim.notify (routes through
  -- nvim-notify / snacks.nvim / whatever the user has).
  card = {
    -- If true, pop the card automatically whenever the target zone's
    -- track changes. Off by default; opt-in for ambient notifications.
    notify_on_change = false,
    -- Toast lifetime in ms (honoured by most notifier backends).
    timeout = 4000,
    bar_width = 30,
    icons = {
      track = "♪",
      artist = "",
      album = "",
      playing = "▶",
      paused = "⏸",
      stopped = "■",
      loading = "⋯",
    },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.apply(user)
  M.options = vim.tbl_deep_extend("force", M.defaults, user or {})
end

return M
