-- High-level interactive chart wrapper
local interactive_chart = {}

local line_graph = require("charts/line-graph")
local bar_chart = require("charts/bar-chart")
local interaction = require("interaction/interaction")
local format_module = require("core/format")
local crosshair = require("interaction/crosshair")

---@class InteractiveChartState
---@field id string Unique chart identifier
---@field chart_type string "line_graph" | "bar_chart"
---@field chunk table The allocated chunk
---@field surface LuaSurface The rendering surface
---@field hit_regions HitRegion[] Current hit regions
---@field render_ids LuaRenderObject[] Current render object IDs
---@field highlights table<string, LuaRenderObject> Active highlights by region_id
---@field tooltips table<string, LuaRenderObject[]> Active tooltips by region_id
---@field selected_series table<string, boolean>? Series visibility state
---@field hovered_region string? Currently hovered region ID
---@field options table Last render options
---@field metadata table Last render metadata
---@field ordered_sums table? Last ordered_sums (for line graphs)
---@field hover table<uint, table> Crosshair per player index: {region_id, column, series_name, objects}
---@field hover_opts table? Options of the last get_hover_buttons call (mode, max_buttons)
---@field hover_regions HitRegion[]? Crosshair regions for the current metadata, built on demand
---@field hover_region_index table<string, HitRegion>? hover_regions by id
---@field hover_layout CrosshairLayout? Column geometry for the current metadata

local chart_id_counter = 0
local function generate_chart_id()
	chart_id_counter = chart_id_counter + 1
	return "chart_" .. chart_id_counter
end

-- GUI events only carry tags, so the hover handlers find the chart here. Module state is not saved: a consumer
-- that keeps states in storage re-registers them in on_load (ids from options.id stay the same across loads,
-- generated ids do not).
local registry = {}

---Make a state reachable from charts.events.handle_gui_hover/handle_gui_leave
---@param state InteractiveChartState
function interactive_chart.register(state)
	if state and state.id then
		registry[state.id] = state
		state.hover = state.hover or {}
	end
end

---@param state InteractiveChartState
function interactive_chart.unregister(state)
	if state and state.id and registry[state.id] == state then
		registry[state.id] = nil
	end
end

---@param id string
---@return InteractiveChartState?
function interactive_chart.get_state(id)
	return registry[id]
end

-- Internal helper to clear existing render objects
local function clear_render_objects(state)
	if state.render_ids then
		for _, obj in ipairs(state.render_ids) do
			if obj and obj.valid then
				obj.destroy()
			end
		end
	end
	state.render_ids = {}
end

-- Internal helper to clear highlights
local function clear_highlights(state)
	for region_id, highlight in pairs(state.highlights) do
		if highlight and highlight.valid then
			highlight.destroy()
		end
	end
	state.highlights = {}
end

-- Internal helper to clear tooltips
local function clear_tooltips(state)
	for region_id, tooltip_objs in pairs(state.tooltips) do
		interaction.destroy_render_objects(tooltip_objs)
	end
	state.tooltips = {}
end

---Create an interactive line graph
---@param surface LuaSurface The rendering surface
---@param chunk table The allocated chunk
---@param options table Rendering options (same as render_line_graph plus interaction options)
---@return InteractiveChartState state The chart state
function interactive_chart.create_line_graph(surface, chunk, options)
	local state = {
		id = options.id or generate_chart_id(),
		chart_type = "line_graph",
		chunk = chunk,
		surface = surface,
		hit_regions = {},
		render_ids = {},
		highlights = {},
		tooltips = {},

		selected_series = options.selected_series,
		hovered_region = nil,
		options = options,
		metadata = nil,
		ordered_sums = nil,
		hover = {},
	}
	interactive_chart.register(state)

	-- Initial render
	interactive_chart.redraw_line_graph(state)

	return state
end

---Redraw a line graph (internal)
---@param state InteractiveChartState
function interactive_chart.redraw_line_graph(state)
	clear_render_objects(state)
	clear_highlights(state)
	clear_tooltips(state)

	local ordered_sums, line_ids, metadata = line_graph.render_with_metadata(
		state.surface,
		state.chunk,
		state.options
	)

	state.render_ids = line_ids or {}
	state.metadata = metadata
	state.ordered_sums = ordered_sums

	-- Generate hit regions if we have metadata
	if metadata then
		state.hit_regions = interaction.create_line_graph_hit_regions(
			state.chunk,
			metadata,
			{point_radius = state.options.hit_radius or 0.3}
		)
	else
		state.hit_regions = {}
	end

	state.hover_regions = nil
	state.hover_region_index = nil
	state.hover_layout = nil
	interactive_chart.refresh_hover(state)
end

---Update an interactive line graph with new data
---@param state InteractiveChartState Existing chart state
---@param options table New options (merged with existing)
function interactive_chart.update_line_graph(state, options)
	-- Merge new options with existing
	for key, value in pairs(options) do
		state.options[key] = value
	end

	interactive_chart.redraw_line_graph(state)
end

---Create an interactive bar chart
---@param surface LuaSurface The rendering surface
---@param chunk table The allocated chunk
---@param options table Rendering options (same as render_stacked_bars plus interaction options)
---@return InteractiveChartState state The chart state
function interactive_chart.create_bar_chart(surface, chunk, options)
	local state = {
		id = options.id or generate_chart_id(),
		chart_type = "bar_chart",
		chunk = chunk,
		surface = surface,
		hit_regions = {},
		render_ids = {},
		highlights = {},
		tooltips = {},

		selected_series = nil,
		hovered_region = nil,
		options = options,
		metadata = nil,
		ordered_sums = nil,
		hover = {},
	}
	interactive_chart.register(state)

	-- Initial render
	interactive_chart.redraw_bar_chart(state)

	return state
end

---Redraw a bar chart (internal)
---@param state InteractiveChartState
function interactive_chart.redraw_bar_chart(state)
	clear_render_objects(state)
	clear_highlights(state)
	clear_tooltips(state)

	local line_ids, metadata = bar_chart.render_with_metadata(
		state.surface,
		state.chunk,
		state.options
	)

	state.render_ids = line_ids or {}
	state.metadata = metadata

	-- Generate hit regions if we have metadata
	if metadata then
		state.hit_regions = interaction.create_bar_chart_hit_regions(
			state.chunk,
			metadata
		)
	else
		state.hit_regions = {}
	end
end

---Update an interactive bar chart with new data
---@param state InteractiveChartState Existing chart state
---@param options table New options (merged with existing)
function interactive_chart.update_bar_chart(state, options)
	-- Merge new options with existing
	for key, value in pairs(options) do
		state.options[key] = value
	end

	interactive_chart.redraw_bar_chart(state)
end

---Get hit regions for a chart (for manual hit testing)
---@param state InteractiveChartState
---@return HitRegion[]
function interactive_chart.get_hit_regions(state)
	return state.hit_regions
end

---Handle hover event
---@param state InteractiveChartState The chart state
---@param region_id string The region ID being hovered
---@param player LuaPlayer? The player (for per-player tooltips)
function interactive_chart.on_hover(state, region_id, player)
	-- Find the region
	local region = nil
	for _, r in ipairs(state.hit_regions) do
		if r.id == region_id then
			region = r
			break
		end
	end

	if not region then
		return
	end

	-- Clear previous hover state
	if state.hovered_region and state.hovered_region ~= region_id then
		interactive_chart.on_hover_leave(state, state.hovered_region)
	end

	state.hovered_region = region_id

	-- Create highlight
	if not state.highlights[region_id] then
		state.highlights[region_id] = interaction.create_highlight(
			state.surface,
			region,
			{
				color = {r = 1, g = 1, b = 1, a = 0.4},
				ttl = state.options.ttl or 360,
				width = 2,
			}
		)
	end

	-- Create tooltip
	if not state.tooltips[region_id] then
		local lines = interactive_chart.format_tooltip(state, region)
		local tooltip_pos = {
			x = (region.tile_bounds.left + region.tile_bounds.right) / 2,
			y = region.tile_bounds.top,
		}
		state.tooltips[region_id] = interaction.create_tooltip(
			state.surface,
			tooltip_pos,
			lines,
			{
				ttl = state.options.ttl or 360,
				scale = 0.7,
				offset = {x = 0, y = -0.8},
			}
		)
	end

	-- Call user callback if provided
	if state.options.on_hover then
		state.options.on_hover(region, state)
	end
end

---Handle hover leave event
---@param state InteractiveChartState The chart state
---@param region_id string The region ID being left
function interactive_chart.on_hover_leave(state, region_id)
	-- Destroy highlight
	if state.highlights[region_id] then
		if state.highlights[region_id].valid then
			state.highlights[region_id].destroy()
		end
		state.highlights[region_id] = nil
	end

	-- Destroy tooltip
	if state.tooltips[region_id] then
		interaction.destroy_render_objects(state.tooltips[region_id])
		state.tooltips[region_id] = nil
	end

	if state.hovered_region == region_id then
		state.hovered_region = nil
	end

	-- Call user callback if provided
	if state.options.on_hover_leave then
		state.options.on_hover_leave(region_id, state)
	end
end

---Handle click event
---@param state InteractiveChartState The chart state
---@param region_id string The region ID being clicked
---@param button defines.mouse_button_type The mouse button
---@param player LuaPlayer? The player
function interactive_chart.on_click(state, region_id, button, player)
	-- Find the region
	local region = nil
	for _, r in ipairs(state.hit_regions) do
		if r.id == region_id then
			region = r
			break
		end
	end

	if not region then
		return
	end

	-- Call user callback if provided
	if state.options.on_click then
		state.options.on_click(region, button, state)
	end
end

---Format tooltip lines for a region
---@param state InteractiveChartState
---@param region HitRegion
---@return string[] lines
function interactive_chart.format_tooltip(state, region)
	local lines = {}

	if region.type == "data_point" then
		lines[1] = region.data.series_name
		lines[2] = crosshair.format_value(region.data.value, state.options.label_format)
	elseif region.type == "bar_segment" then
		lines[1] = region.data.phase_name
		lines[2] = format_module.time_detailed(region.data.duration)
	elseif region.type == "legend_item" then
		lines[1] = region.data.series_name
	end

	-- Allow user to customize tooltip
	if state.options.format_tooltip then
		lines = state.options.format_tooltip(region, lines, state)
	end

	return lines
end

---Toggle series visibility
---@param state InteractiveChartState The chart state
---@param series_name string The series to toggle
function interactive_chart.toggle_series(state, series_name)
	if state.chart_type ~= "line_graph" then
		return
	end

	state.selected_series = state.selected_series or {}
	local is_visible = state.selected_series[series_name] ~= false
	state.selected_series[series_name] = not is_visible

	state.options.selected_series = state.selected_series

	interactive_chart.redraw_line_graph(state)
end

---Cleanup all resources
---@param state InteractiveChartState The chart state
function interactive_chart.destroy(state)
	clear_render_objects(state)
	clear_highlights(state)
	clear_tooltips(state)
	for _, entry in pairs(state.hover or {}) do
		interaction.destroy_render_objects(entry.objects or {})
	end
	state.hover = {}
	state.hover_regions = nil
	state.hover_region_index = nil
	state.hover_layout = nil
	interactive_chart.unregister(state)
end

---Get overlay button configurations for a camera widget
---@param state InteractiveChartState The chart state
---@param camera_position table Camera center in tile coordinates
---@param camera_zoom number Zoom level
---@param widget_size table {width, height} in pixels
---@return table[] button_configs
function interactive_chart.get_overlay_buttons(state, camera_position, camera_zoom, widget_size)
	return interaction.generate_overlay_buttons(
		camera_position,
		camera_zoom,
		widget_size,
		state.hit_regions
	)
end

---Perform hit test at a tile position
---@param state InteractiveChartState The chart state
---@param tile_pos table {x, y} in tile coordinates
---@return HitRegion? region
function interactive_chart.hit_test(state, tile_pos)
	return interaction.hit_test(state.hit_regions, tile_pos)
end

---Perform hit test from screen position
---@param state InteractiveChartState The chart state
---@param camera_position table Camera center in tile coordinates
---@param camera_zoom number Zoom level
---@param widget_size table {width, height} in pixels
---@param screen_pos table {x, y} in widget-local pixels
---@return HitRegion? region
function interactive_chart.hit_test_screen(state, camera_position, camera_zoom, widget_size, screen_pos)
	local tile_pos = interaction.screen_to_tile(camera_position, camera_zoom, widget_size, screen_pos)
	return interaction.hit_test(state.hit_regions, tile_pos)
end

-- ============================================================================
-- Crosshair hover (line graphs)
-- ============================================================================

local function ensure_layout(state)
	if not state.hover_layout and state.metadata and state.metadata.plot then
		state.hover_layout = crosshair.layout(state.metadata)
	end
	return state.hover_layout
end

---Crosshair regions for the chart's current data, built on first use after each redraw
---@param state InteractiveChartState
---@return HitRegion[]
function interactive_chart.get_hover_regions(state)
	if state.chart_type ~= "line_graph" or not state.metadata then
		return {}
	end
	if not state.hover_regions then
		local hover_opts = state.hover_opts or {}
		state.hover_regions = crosshair.create_regions(state.chunk, state.metadata, {
			mode = hover_opts.mode,
			max_buttons = hover_opts.max_buttons,
			layout = ensure_layout(state),
		})
		local index = {}
		for _, region in ipairs(state.hover_regions) do
			index[region.id] = region
		end
		state.hover_region_index = index
	end
	return state.hover_regions
end

local function draw_hover(state, player, cell)
	return crosshair.draw(state.surface, state.chunk, state.metadata, cell, player, {
		layout = ensure_layout(state),
		line_width = state.options.line_width,
		series_mode = state.options.hover_series_mode,
		color = state.options.hover_color,
		ttl = state.options.hover_ttl,
	})
end

local function destroy_hover_entry(entry)
	if entry then
		interaction.destroy_render_objects(entry.objects or {})
	end
end

---Show the crosshair for one player: vertical line at the column, horizontal line and marker at the point, the
---hovered series redrawn twice as thick. Other players see nothing. Does not re-render the graph.
---@param state InteractiveChartState
---@param player LuaPlayer
---@param cell table A crosshair region or its data
function interactive_chart.set_hover(state, player, cell)
	if not state or not player or not player.valid or not cell or not state.metadata then
		return
	end
	local data = cell.data or cell
	if not data.column then
		return
	end
	state.hover = state.hover or {}
	destroy_hover_entry(state.hover[player.index])
	state.hover[player.index] = {
		region_id = crosshair.region_id(data.column, data.series_name),
		column = data.column,
		series_name = data.series_name,
		objects = draw_hover(state, player, data),
	}
	if state.options.on_hover then
		state.options.on_hover(data, player, state)
	end
end

---Remove a player's crosshair
---@param state InteractiveChartState
---@param player LuaPlayer|uint Player or player index
function interactive_chart.clear_hover(state, player)
	if not state or not state.hover or not player then
		return
	end
	local index = type(player) == "number" and player or player.index
	local entry = state.hover[index]
	if not entry then
		return
	end
	destroy_hover_entry(entry)
	state.hover[index] = nil
	if state.options.on_hover_leave then
		local player_object = type(player) == "number" and game.get_player(player) or player
		state.options.on_hover_leave(player_object, state)
	end
end

---Redraw every player's crosshair against the current data (called after a redraw). A crosshair whose
---region no longer exists is removed.
---@param state InteractiveChartState
function interactive_chart.refresh_hover(state)
	if not state.hover or not next(state.hover) then
		return
	end
	local regions_index = nil
	if state.metadata then
		interactive_chart.get_hover_regions(state)
		regions_index = state.hover_region_index
	end
	for player_index, entry in pairs(state.hover) do
		destroy_hover_entry(entry)
		local region = regions_index and regions_index[entry.region_id]
		local player = game.get_player(player_index)
		if region and player and player.valid then
			entry.objects = draw_hover(state, player, region.data)
		else
			state.hover[player_index] = nil
		end
	end
end

---Find a crosshair region by id
---@param state InteractiveChartState
---@param region_id string
---@return HitRegion?
function interactive_chart.get_hover_region(state, region_id)
	interactive_chart.get_hover_regions(state)
	return state.hover_region_index and state.hover_region_index[region_id]
end

---Overlay button configs for crosshair hover, ready for charts.interaction.create_overlay_buttons
---
---Each config carries tags {factorio_charts = {chart = state.id, region = region.id}}, a native tooltip and
---raise_hover_events = true. Positions are in GUI units: camera tiles are 32 * camera_zoom * density / scale GUI
---units wide, so pass opts.player (or opts.gui_zoom) unless the camera uses Cybersyn's zoom formula
---display_scale / display_density_scale, for which the default gui_zoom of 1 is exact.
---@param state InteractiveChartState
---@param camera_info table From setup_camera_widget: {position, zoom, widget_width, widget_height}
---@param opts table? {mode?: "cell"|"column", max_buttons?: number, format_tooltip?: fun(cell, state): LocalisedString, player?: LuaPlayer, gui_zoom?: number}
---@return table[] button_configs
function interactive_chart.get_hover_buttons(state, camera_info, opts)
	opts = opts or {}
	if not camera_info or state.chart_type ~= "line_graph" then
		return {}
	end

	local previous = state.hover_opts
	state.hover_opts = {mode = opts.mode, max_buttons = opts.max_buttons}
	if not previous or previous.mode ~= opts.mode or previous.max_buttons ~= opts.max_buttons then
		state.hover_regions = nil
		state.hover_region_index = nil
		state.hover_layout = nil
	end
	local regions = interactive_chart.get_hover_regions(state)

	local gui_zoom = opts.gui_zoom
	if not gui_zoom then
		local player = opts.player
		if player and player.valid and camera_info.zoom then
			gui_zoom = camera_info.zoom * player.display_density_scale / player.display_scale
		else
			gui_zoom = 1
		end
	end

	local configs = interaction.generate_overlay_buttons(
		camera_info.position,
		gui_zoom,
		{width = camera_info.widget_width, height = camera_info.widget_height},
		regions
	)

	local label_format = state.options.label_format
	local format_tooltip = opts.format_tooltip
	for _, config in ipairs(configs) do
		local data = config.region.data
		if format_tooltip then
			config.tooltip = format_tooltip(data, state)
		else
			config.tooltip = crosshair.default_tooltip(data, label_format)
		end
		config.tags = {factorio_charts = {chart = state.id, region = config.region_id}}
		config.raise_hover_events = true
	end
	return configs
end

return interactive_chart
