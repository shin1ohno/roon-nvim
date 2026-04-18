# roon-nvim

Neovim integration for [roon-rs](https://github.com/shin1ohno/roon-rs)'s `roon` CLI — control a Roon audio system from inside Neovim.

Three surfaces:

- **heirline** player component — live now-playing from `roon watch` (streaming NDJSON)
- **neo-tree** source `roon` — browse Roon's library as a tree, `<CR>` to play
- **telescope** extension `roon` — live search, `<CR>` play-now, `<C-q>` queue, `<C-r>` start-radio

## Requirements

- Neovim ≥ 0.10 (uses `vim.system`)
- `roon` CLI from [roon-rs](https://github.com/shin1ohno/roon-rs) ≥ 0.5.0 on `$PATH`
- A paired Roon Core — run `roon discover` once from a terminal first (also run `roon zone` to pick a default zone)
- `heirline.nvim`, `nvim-neo-tree/neo-tree.nvim`, `nvim-telescope/telescope.nvim`

## Install

### Lazy.nvim

```lua
{
  "shin1ohno/roon-nvim",   -- or: dir = "~/ManagedProjects/roon-nvim" for local dev
  dependencies = {
    "rebelot/heirline.nvim",
    "nvim-neo-tree/neo-tree.nvim",
    "nvim-telescope/telescope.nvim",
  },
  opts = {
    zone = "Qutest",                -- play actions default to this zone
    -- cli  = "roon",               -- override binary location
    -- host = nil, port = nil,      -- override CLI defaults (else uses ~/.config/roon-rs/cli.toml)
    -- watch = { auto_start = true, seek_hz = 1.0 },
  },
  config = function(_, opts)
    require("roon-nvim").setup(opts)
  end,
}
```

### Per-surface wiring

After `setup{}` the core is live (the `roon watch` job starts and `state` is populated), but the three UI surfaces must be wired individually:

#### heirline

Drop the component anywhere in your statusline spec:

```lua
local roon = require("roon-nvim.heirline").component()

require("heirline").setup({
  statusline = {
    -- … your existing sections …
    roon,
  },
})
```

**AstroNvim** users (who drive heirline via `astrocommunity.recipes.heirline-nvchad-statusline` or similar) can extend the existing spec — for example, in `lua/plugins/heirline.lua`:

```lua
return {
  "rebelot/heirline.nvim",
  opts = function(_, opts)
    opts.statusline = opts.statusline or {}
    table.insert(opts.statusline, require("roon-nvim.heirline").component())
    return opts
  end,
}
```

Optional component arguments: `component({ zone = "Kitchen", icons = { playing = "♫" } })`.

#### neo-tree

Add `"roon"` to your existing sources list, then open with `:Neotree roon`:

```lua
{
  "nvim-neo-tree/neo-tree.nvim",
  opts = {
    sources = { "filesystem", "buffers", "git_status", "roon" },
    -- optional: show Roon as a tab in the source selector
    source_selector = {
      winbar = true,
      sources = {
        { source = "filesystem" },
        { source = "buffers" },
        { source = "git_status" },
        { source = "roon", display_name = "♪ Roon" },
      },
    },
  },
}
```

Default bindings inside the Roon tree:

| key    | action                                                      |
| ------ | ----------------------------------------------------------- |
| `<CR>` | directory ⇒ expand/collapse; leaf ⇒ play-now                |
| `P`    | play-now on the current node                                |
| `q`    | queue                                                       |
| `r`    | start-radio                                                 |
| `R`    | refresh                                                     |

#### telescope

```lua
require("telescope").load_extension("roon")
-- then: :Telescope roon search
```

| mapping | action      |
| ------- | ----------- |
| `<CR>`  | play-now    |
| `<C-q>` | queue       |
| `<C-r>` | start-radio |

#### Playback controls (zone-wide)

`setup{}` registers these user commands, targeting the configured `zone`:

| command              | effect                                                |
| -------------------- | ----------------------------------------------------- |
| `:RoonPlay`          | resume                                                |
| `:RoonPause`         | pause                                                 |
| `:RoonStop`          | stop                                                  |
| `:RoonNext`          | next track                                            |
| `:RoonPrevious`      | previous track                                        |
| `:RoonPlayPause`     | toggle — reads current state from `watch`             |
| `:RoonSeek <n>`      | seek to `n` seconds, or `+n` / `-n` for relative      |
| `:RoonSeekForward`   | seek +`steps.seek` seconds (default 10)               |
| `:RoonSeekBack`      | seek -`steps.seek` seconds                            |
| `:RoonVolume <n>`    | set output volume to `n`, or `+n` / `-n` for relative |
| `:RoonVolumeUp`      | +`steps.volume` units (default 5)                     |
| `:RoonVolumeDown`    | -`steps.volume` units                                 |
| `:RoonMute`          | mute the primary output                               |
| `:RoonUnmute`        | unmute                                                |
| `:RoonMuteToggle`    | flip current mute state                               |
| `:RoonStatus`        | pop / toggle the Now Playing card (see below)         |

Seek targets the zone. Volume / mute target the zone's single output when there's one; for grouped zones pick a default output first via `roon output` in a terminal.

Bind them however you like. Example Lazy `keys`:

```lua
keys = {
  { "<leader>mp", "<cmd>RoonPlayPause<cr>",   desc = "Roon play/pause" },
  { "<leader>mn", "<cmd>RoonNext<cr>",        desc = "Roon next" },
  { "<leader>m,", "<cmd>RoonPrevious<cr>",    desc = "Roon previous" },
  { "<leader>ml", "<cmd>RoonSeekForward<cr>", desc = "Roon seek +10s" },
  { "<leader>mh", "<cmd>RoonSeekBack<cr>",    desc = "Roon seek -10s" },
  { "<leader>mk", "<cmd>RoonVolumeUp<cr>",    desc = "Roon volume +5" },
  { "<leader>mj", "<cmd>RoonVolumeDown<cr>",  desc = "Roon volume -5" },
  { "<leader>mM", "<cmd>RoonMuteToggle<cr>",  desc = "Roon mute toggle" },
  { "<leader>mx", "<cmd>RoonStop<cr>",        desc = "Roon stop" },
  { "<leader>mS", "<cmd>RoonStatus<cr>",      desc = "Roon status card" },
},
```

Override the default step sizes via `opts`:

```lua
opts = {
  zone = "Qutest",
  steps = { seek = 15, volume = 2 },
},
```

#### Now Playing card

`:RoonStatus` (or any key you bind) pops a multi-line notification with the currently-playing track, artist, album, playback state icon and a unicode progress bar:

```
♪  Automatic Yes
   Zedd / John Mayer
   Telos

▶  ━━━━━━━━━━━●───────────────────  1:23 / 3:25
```

It routes through `vim.notify`, so whichever notifier you already use (`nvim-notify`, `snacks.nvim`, or the built-in fallback) styles it.

Opt-in auto-pop on every track change:

```lua
opts = {
  zone = "Qutest",
  card = { notify_on_change = true },
},
```

Customise icons / progress bar width / timeout:

```lua
card = {
  bar_width = 40,
  timeout   = 6000,
  icons = { track = "♪", artist = "", album = "", playing = "▶", paused = "⏸" },
},
```

## Local development

During iteration, point Lazy at the local checkout:

```lua
{
  dir = "~/ManagedProjects/roon-nvim",
  dev = true,
  -- same dependencies / opts as above
}
```

## Troubleshooting

- `statusline shows nothing`: confirm the watch job is alive — `:lua print(require("roon-nvim.watch").is_running())`. If false, check `:lua print(require("roon-nvim.config").options.cli)` resolves to a working binary and `roon watch` runs from a shell.
- `play-item returns "no matching action"`: the selected item doesn't have a Play/Queue/Radio action in Roon. Drill one level deeper in neo-tree (to the album's "Play Album" entry) and try again. The error surface includes the list of actual action titles the item offers.
- `empty search results`: try a longer query (< 2 chars are suppressed). Roon's search is weighted toward well-tagged library content.
- `session cursor stuck`: delete `~/.config/roon-rs/sessions/<key>.toml` (neo-tree uses `nvim-neotree`, telescope uses `nvim-telescope`) and retry.

## Architecture

```
┌──────────────────────────┐         ┌──────────────────────────────┐
│    heirline component    │◄────────│  roon-nvim.state (pub/sub)   │
│    (reads on redraw)     │         │    zones / outputs snapshot  │
└──────────────────────────┘         └───────────────▲──────────────┘
                                                     │
┌──────────────────────────┐                         │
│   neo-tree source "roon" │                         │
│   (per-click vim.system) │       ┌─────────────────┴──────────────┐
└──────────────────────────┘       │       roon-nvim.watch          │
                                   │    (long-running jobstart)     │
┌──────────────────────────┐       └────────────────▲───────────────┘
│ telescope ext. "roon"    │                        │
│ (per-keystroke, debounced│                        │
└──────────────────────────┘                        │
             │                                      │
             │          ┌──────────────┐   stream   │
             └────────► │   roon CLI   │◄───────────┘
                        └──────┬───────┘
                               │ MOO+SOOD
                               ▼
                        ┌──────────────┐
                        │  Roon Core   │
                        └──────────────┘
```

## License

Dual MIT / Apache-2.0.
