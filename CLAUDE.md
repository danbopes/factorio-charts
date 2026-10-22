# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Factorio Charts is a reusable charting library for Factorio 2.0+ mods. It renders line graphs and stacked bar charts on hidden game surfaces, viewable through GUI camera widgets. Developed for Project Cybersyn.

## Testing

Tests require the `factorio-test` mod (optional dependency). Two test frameworks are supported:

1. **factorio-test (interactive)**: Load mod in Factorio, click "Run Tests" in GUI
2. **factorio-test-harness (automated)**: Command-line testing via the harness

Test files are in `tests/` and registered in `tests/init.lua` (for factorio-test) and `tests/harness_init.lua` (for harness). FactorioTest 3.x needs `load_luassert = true` (passed in `tests/init.lua`) for the global `assert` the tests use. The library's `control.lua` does not require `tests/init.lua`, so a runner mod has to register the files.

## Architecture

### Module Structure

```
factorio-charts/
├── charts.lua                      Main entry point (sub-table API + flat aliases)
├── control.lua                     Factorio requirement (minimal)
├── core/
│   ├── rendering.lua               Surface and chunk management
│   ├── colors.lua                  12-color series palette
│   └── format.lua                  Label formatting utilities
├── charts/
│   ├── line-graph.lua              Multi-series line graph rendering
│   ├── bar-chart.lua               Stacked bar chart rendering
│   └── time-series.lua             Multi-resolution time series with cascading aggregation
├── interaction/
│   ├── interaction.lua             Hit testing, coordinate transforms, highlights/tooltips
│   ├── interactive-chart.lua       High-level wrapper with state management, hover registry
│   ├── crosshair.lua               Production-graph crosshair: hover regions, per-player drawing, tooltips
│   └── events.lua                  Event handler registration, on_gui_hover/on_gui_leave forwarding
└── tests/
```

**Grouping rationale:**
- **`core/`** — Shared foundations with no chart-type deps (surface mgmt, colors, formatting)
- **`charts/`** — Chart type implementations (depend on core/, produce rendered output)
- **`interaction/`** — User interaction: hit testing, high-level interactive wrapper, events

### Sub-table API

`charts.lua` exposes functions via named sub-tables. Flat aliases (e.g., `charts.create_surface()`) are preserved for backward compatibility.

| Sub-table | Purpose |
|-----------|---------|
| `charts.surface` | Surface/chunk management: `create`, `allocate_chunk`, `free_chunk`, `get_camera_params`, etc. |
| `charts.render` | Chart rendering: `line_graph`, `stacked_bars`, `time_series`, `*_with_metadata`, `*_with_overlays` |
| `charts.colors` | Color palette: `get_series_colors`, `get_series_color`, `get_grid_color`, `get_label_color`, `get_max_series` |
| `charts.format` | Formatting: `time_label`, `percent_label`, `time_detailed`, `si_label` |
| `charts.interaction` | Hit testing, coordinate transforms, highlights, tooltips, overlay buttons |
| `charts.interactive` | High-level interactive chart wrappers: `create_line_graph`, `on_hover`, `get_hover_buttons`, `set_hover`, `destroy`, etc. |
| `charts.events` | Event registration: `register`, `unregister`, `is_registered`, `get_tick_handler`, `handle_gui_hover`, `handle_gui_leave` |
| `charts.time_series` | Time series data: `create`, `add_datapoint`, `get_average`, `clear` |

### Key Concepts

**Surface Management**: Charts are rendered on hidden Factorio surfaces. `charts.surface.create()` initializes one, then `charts.surface.allocate_chunk()` gives you a 32x32 tile area with lighting. Chunks are reused via a freelist when freed.

**Ring Buffer Data Format**: Line graphs expect data in a ring buffer format:
- `data`: array of `{[series_name]: value}` tables
- `index`: current write position
- `length`: buffer capacity
- Iteration order is `index+1 → length`, then `1 → index` for chronological display

**Rendering Coordinates**: Graphs use pixel-based viewport dimensions (default 900x700) converted to tile coordinates (divide by 32). Graph area has margins for axis labels.

**Axes (opt-in)**: `x_axis = {ticks_per_point, format, labels, grid}` adds "minutes ago" labels under the plot (newest = 0 at the right edge, plot bottom moves up 0.7 tile); `label_format = "si"`, `grid_lines`, `y_range = "zero"` and `nice_ticks` shape the Y axis. Defaults (`x_axis = false`, 5 grid lines, no nice ticks) keep 1.2.0 renders identical; `tests/axes_test.lua` checks that. Metadata adds `columns`, `x_positions`, `seconds_ago`, `plot`, `series_order` (bottom-most first), `y_ticks`, `x_labels`: hover code (crosshair) builds on these names, so keep them stable. Label helpers in `core/format.lua` take an optional `decimals` so the renderer can keep neighbouring ticks distinct.

**TTL-Based Cleanup**: All rendered objects use `time_to_live` in ticks. No manual cleanup needed for graph lines/text - they auto-expire.

**Resolution Independence**: Use `charts.surface.get_camera_params()` to calculate correct camera position and zoom for any widget size. The viewport dimensions (default 900x700) define the graph layout in tile space. The function computes the zoom needed to fit the graph into the actual widget dimensions:
```lua
local camera = charts.surface.get_camera_params(chunk, {
    viewport_width = 900,   -- Design size (graph layout)
    viewport_height = 700,
    widget_width = actual_widget.width,   -- Actual GUI element size
    widget_height = actual_widget.height,
    fit_mode = "fit",  -- "fit", "fill", or "stretch"
})
-- Returns: {position = {x, y}, zoom = number, offset = {x, y}, ...}
```

**Camera Widget Sizing Trade-off**: Factorio does not expose the actual rendered size of GUI elements at runtime. This creates a trade-off when sizing camera widgets:

1. **Fixed size camera** (recommended for consistency): Set explicit `width` and `height` on the camera widget. The chart will look identical regardless of window size or fullscreen/windowed mode. May leave empty space in larger windows.
   ```lua
   style_mods = { width = 900, height = 700 }
   ```

2. **Stretchable camera**: Use `horizontally_stretchable = true` with `minimal_width`. The camera fills available space, but since you can't query the actual size, you must calculate zoom from fixed dimensions. This causes the chart to appear proportionally smaller in larger windows (more surface area visible at the same zoom level).

For consistent appearance across all screen modes, use fixed-size camera widgets.

### Usage Pattern (Basic)

```lua
local charts = require("__factorio-charts__.charts")
local surface_data = charts.surface.create("my-surface")  -- once in on_init
local chunk = charts.surface.allocate_chunk(surface_data)
charts.render.line_graph(surface_data.surface, chunk, {...})

-- Calculate camera params for resolution-independent display
local camera = charts.surface.get_camera_params(chunk, {
    widget_width = 900,  -- Your actual camera widget dimensions
    widget_height = 700,
})

-- Create GUI camera widget with calculated params
local camera_widget = parent.add{
    type = "camera",
    position = camera.position,
    surface_index = surface_data.surface.index,
    zoom = camera.zoom,
}

charts.surface.free_chunk(surface_data, chunk)  -- when done
```

Note: Flat aliases still work (e.g., `charts.create_surface()`, `charts.render_line_graph()`).

### Interactive Charts

The library provides two approaches for adding hover/click interactions:

**High-Level (Recommended):** Use `charts.interactive` for automatic state management:
```lua
local state = charts.interactive.create_line_graph(surface, chunk, {
    data = ring_buffer, index = idx, length = len,
    counts = counts, sum = sums,
    on_hover = function(region, state) ... end,
    on_click = function(region, button, state) ... end,
})
-- Handle hover: charts.interactive.on_hover(state, region_id, player)
-- Update data: charts.interactive.update_line_graph(state, new_options)
-- Cleanup: charts.interactive.destroy(state)
```

**Low-Level:** Use `charts.interaction` primitives directly for full control:
```lua
-- Render with metadata
local ordered_sums, line_ids, metadata = charts.render.line_graph_with_metadata(...)
-- Create hit regions
local hit_regions = charts.interaction.create_line_graph_hit_regions(chunk, metadata)
-- Convert screen position to tile coordinates
local tile_pos = charts.interaction.screen_to_tile(camera_pos, zoom, widget_size, screen_pos)
-- Hit test
local region = charts.interaction.hit_test(hit_regions, tile_pos)
-- Create visual feedback
local highlight = charts.interaction.create_highlight(surface, region)
local tooltip = charts.interaction.create_tooltip(surface, tile_pos, {"Line 1", "Line 2"})
```

**Overlay Buttons:** Factorio doesn't expose mouse position over cameras. Use transparent buttons:
```lua
-- Generate button configs from hit regions
local buttons = charts.interaction.generate_overlay_buttons(camera_pos, zoom, widget_size, hit_regions)
-- buttons[i] = {region_id, style_mods, region}

-- Or create buttons directly on a GUI element
local created = charts.interaction.create_overlay_buttons(parent, button_configs, {
    button_style = "my_transparent_button_style",
    widget_width = 900,
    widget_height = 700,
})
```

**Crosshair hover (line graphs):** `interaction/crosshair.lua` builds button regions from the metadata contract
(`columns`, `plot`, `x_positions`, `series_order` bottom-most first, `seconds_ago`) and draws the per-player
crosshair (`players = {player}`; the thick series is one `draw_polygon` triangle strip per unbroken run by
default). Consumer wiring, three parts: a transparent button style in data.lua (empty graphical sets, padding 0,
minimal size 1); `charts.interactive.get_hover_buttons(state, camera_info, {player = player})` passed to
`charts.interaction.create_overlay_buttons(camera, configs, {button_style = ...})`; and the consumer's own
`script.on_event` handlers for `on_gui_hover` / `on_gui_leave` calling `charts.events.handle_gui_hover(e)` /
`handle_gui_leave(e)`. Buttons are tagged `{factorio_charts = {chart = state.id, region = region_id}}`; states
register by id in a module table (give `options.id` so ids survive save/load, and `charts.interactive.register`
storage-held states in `on_load`). Leave events can arrive after the next hover, so `handle_gui_leave` only clears
the crosshair of the region being left. Region ids are `xh_<column>[_<series>]`, stable across rebuilds. The
FactorioTest run is headless with no player, so the per-player tests in `tests/crosshair_test.lua` skip there; the
lab's `chartlab` mod repeats them on a graphical host (`remote.call("chartlab", "verify_hover", 1)`).

**Time Series:** Multi-resolution data storage with cascading aggregation (like RRDtool):
```lua
-- Define intervals: each level aggregates 'steps' samples from the previous
local interval_defs = {
    {name = "5s",  ticks = 1,   steps = 6,   length = 300},  -- 1 sample/tick, 5 min buffer
    {name = "1m",  ticks = 6,   steps = 10,  length = 600},  -- avg of 6 samples, 10 min buffer
    {name = "10m", ticks = 60,  steps = nil, length = 600},  -- avg of 10 samples, 100 min buffer
}
local intervals = charts.time_series.create(interval_defs)

-- Allocate chunk for rendering (store in interval)
intervals[1].chunk = charts.surface.allocate_chunk(surface_data)

-- Add data each tick - automatically cascades to coarser intervals
charts.time_series.add_datapoint(intervals, {series1 = 50, series2 = 75})

-- Render a specific interval (handles lifecycle: cleanup, render, hit regions, caching)
local ordered_sums, hit_regions = charts.render.time_series(surface, intervals, 1, {
    selected_series = nil,  -- or {series1 = true, series2 = false}
    y_range = {0, 100},     -- fixed range, or nil for auto-scale
    label_format = "percent", -- or "time", "si"
    x_axis = {format = "auto"}, -- optional; ticks_per_point defaults to the interval's ticks
    viewport_width = 900,
    viewport_height = 700,
})
```
