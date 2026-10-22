-- Line graph rendering
local line_graph = {}

local colors_module = require("core/colors")
local format_module = require("core/format")
local style = require("core/style")

local TILE_PIXELS = 32
-- Height reserved under the plot for X labels when x_axis is on.
local X_LABEL_ROW = 0.7
local X_LABEL_MIN_SPACING_PX = 40
local FIXED_RANGE_GRID_LINES = 5

local time_units = {
	seconds = 1,
	minutes = 60,
	hours = 3600,
}

---Smallest m * 10^k >= raw with m drawn from `multipliers` (ascending, ending in 10)
local function nice_ceil(raw, multipliers)
	if raw <= 0 then
		return 0
	end
	local base = 10 ^ math.floor(math.log(raw, 10))
	for _, m in ipairs(multipliers) do
		-- Tolerance so float noise in raw (0.30000000000000004) does not skip a step.
		if m * base >= raw * (1 - 1e-9) then
			return m * base
		end
	end
	return 10 * base
end

local Y_STEP_MULTIPLIERS = {1, 2, 2.5, 5, 10}
local X_STEP_MULTIPLIERS = {1, 2, 5, 10}

---Expand [lo, hi] to nice tick boundaries with exactly `intervals` equal steps
---@return number lo, number hi
local function nice_range(lo, hi, intervals)
	local step = nice_ceil((hi - lo) / intervals, Y_STEP_MULTIPLIERS)
	if step == 0 then
		return lo, hi
	end
	-- Flooring lo can push the top past hi; each retry moves to the next nice step.
	for _ = 1, 8 do
		local nice_lo = math.floor(lo / step + 1e-9) * step
		local nice_hi = nice_lo + step * intervals
		if nice_hi >= hi - step * 1e-9 then
			return nice_lo, nice_hi
		end
		step = nice_ceil(step * (1 + 1e-6), Y_STEP_MULTIPLIERS)
	end
	return lo, hi
end

local function format_y_label(label_format, value, decimals)
	if type(label_format) == "function" then
		return label_format(value)
	elseif label_format == "time" then
		return format_module.time_label(value, decimals)
	elseif label_format == "si" then
		return format_module.si_label(value, decimals)
	end
	return format_module.percent_label(value, decimals)
end

---Format every Y tick; for "si", "time" and "percent", add decimals until no two adjacent labels read the same
---@param values number[]
---@return string[]
local function format_y_labels(label_format, values)
	local texts
	local function has_duplicate()
		for i = 2, #texts do
			if texts[i] == texts[i - 1] then
				return true
			end
		end
		return false
	end

	local decimals = nil
	for _ = 1, 5 do
		texts = {}
		for i, value in ipairs(values) do
			texts[i] = format_y_label(label_format, value, decimals)
		end
		if (label_format ~= "si" and label_format ~= "time" and label_format ~= "percent") or not has_duplicate() then
			break
		end
		-- si and time already show one decimal below 10, percent shows none.
		decimals = decimals and decimals + 1 or (label_format == "percent" and 1 or 2)
	end
	return texts
end

---Work out X tick positions for an x_axis spec
---@param x_axis table The x_axis option
---@param columns number Number of ring-buffer slots drawn
---@param plot_width number Plot width in tiles
---@return table ticks {unit, unit_seconds, step, seconds_per_column, labels = {{seconds_ago, text}}}
local function compute_x_ticks(x_axis, columns, plot_width)
	local ticks_per_point = x_axis.ticks_per_point or 60
	local seconds_per_column = ticks_per_point / 60
	-- A buffer of N slots stands for N slots of history, so a 600 x 1 s buffer reads "10" minutes at its
	-- left edge like vanilla, even though its oldest sample is one slot newer than that.
	-- A single slot has no width to spread labels over.
	local span = columns > 1 and columns * seconds_per_column or 0

	local fmt = x_axis.format or "auto"
	local unit
	if time_units[fmt] then
		unit = fmt
	elseif span < 120 then
		unit = "seconds"
	elseif span < 7200 then
		unit = "minutes"
	else
		unit = "hours"
	end
	local unit_seconds = time_units[unit]
	local span_units = span / unit_seconds

	local step
	if span_units <= 0 then
		step = 1
	elseif type(x_axis.labels) == "number" and x_axis.labels >= 2 then
		step = nice_ceil(span_units / (x_axis.labels - 1), X_STEP_MULTIPLIERS)
	else
		local plot_px = plot_width * TILE_PIXELS
		local max_intervals = math.max(1, math.floor(plot_px / X_LABEL_MIN_SPACING_PX))
		step = nice_ceil(span_units / max_intervals, X_STEP_MULTIPLIERS)
	end

	local decimals = math.max(0, -math.floor(math.log(step, 10) + 1e-9))
	local labels = {}
	local count = math.floor(span_units / step + 1e-9) + 1
	for k = 0, count - 1 do
		local value = k * step
		local seconds_ago = value * unit_seconds
		local text
		if type(fmt) == "function" then
			text = fmt(seconds_ago)
		else
			text = format_module.axis_number(value, decimals)
		end
		labels[#labels + 1] = {seconds_ago = seconds_ago, value = value, text = text}
	end

	return {
		unit = unit,
		unit_seconds = unit_seconds,
		step = step,
		seconds_per_column = seconds_per_column,
		ticks_per_point = ticks_per_point,
		labels = labels,
	}
end

---Internal render function that optionally collects metadata
---@param surface LuaSurface The rendering surface
---@param chunk table The chunk with coord
---@param options table Rendering options
---@param collect_metadata boolean Whether to collect point positions for interaction
---@return table? ordered_sums Array of {name, sum} sorted by sum descending
---@return LuaRenderObject[]? line_ids Array of render object IDs
---@return table? metadata Graph metadata (only if collect_metadata is true)
local function render_internal(surface, chunk, options, collect_metadata)
	if not chunk or not chunk.coord then
		return nil
	end

	local data = options.data
	local index = options.index
	local length = options.length
	local counts = options.counts
	local sum = options.sum
	local y_range_option = options.y_range
	local fixed_range = type(y_range_option) == "table" and y_range_option or nil
	local label_format = options.label_format or "percent"
	local x_axis = options.x_axis
	if type(x_axis) ~= "table" then
		x_axis = nil
	end
	-- A fixed range like Cybersyn's {0, 100} percent chart reads 0/25/50/75/100 with 5 lines; 8 gives 0, 14, 29...
	local default_grid_lines = fixed_range and FIXED_RANGE_GRID_LINES or style.GRID_LINES
	local num_grid_lines = math.max(2, options.grid_lines or default_grid_lines)
	local selected_series = options.selected_series
	local ttl = options.ttl or 360
	local viewport_width = options.viewport_width or 900
	local viewport_height = options.viewport_height or 700

	local camera_zoom = options.camera_zoom or style.DEFAULT_ZOOM
	local series_width = options.line_width or style.line_width(options.line_px, camera_zoom)
	local grid_width = style.grid_width(camera_zoom)
	local smooth = options.smooth

	local series_colors = style.series_colors()
	local grid_color = style.grid_color()
	local max_lines = colors_module.get_max_series()

	-- Collect and sort ALL series by sum first (for consistent color assignment)
	local all_series = {}
	local all_count = 0
	for name, count in pairs(counts) do
		all_count = all_count + 1
		all_series[all_count] = {name = name, sum = sum[name] or 0}
	end

	if all_count == 0 then
		return nil
	end

	table.sort(all_series, function(a, b)
		if a.sum ~= b.sum then
			return a.sum > b.sum
		end
		return a.name < b.name
	end)

	-- Build color index mapping (series name -> color index based on full sorted list)
	local color_indices = {}
	for i, entry in ipairs(all_series) do
		color_indices[entry.name] = ((i - 1) % max_lines) + 1
	end

	-- Filter to selected series only, preserving sort order
	local show_all = not selected_series or not next(selected_series)
	local ordered_sums = {}
	local datasets = 0
	for _, entry in ipairs(all_series) do
		if show_all or selected_series[entry.name] ~= false then
			datasets = datasets + 1
			ordered_sums[datasets] = {name = entry.name, sum = entry.sum, color_index = color_indices[entry.name]}
		end
	end

	if datasets == 0 then
		return nil
	end

	local to_draw = math.min(datasets, max_lines)

	-- Smoothed copies of the drawn series replace `data` from here on, so the range, the lines and the metadata
	-- all agree; the caller's ring buffer is left alone.
	local raw_data = nil
	if smooth and smooth > 1 then
		raw_data = data
		data = {}
		local order = {}
		for i = index + 1, length do order[#order + 1] = i end
		for i = 1, math.min(index, length) do order[#order + 1] = i end
		for i = 1, length do
			data[i] = {}
		end
		for j = 1, to_draw do
			local name = ordered_sums[j].name
			local values = {}
			for k, slot in ipairs(order) do
				local datum = raw_data[slot]
				values[k] = datum and datum[name]
			end
			local smoothed = style.smooth(values, smooth, #order)
			for k, slot in ipairs(order) do
				data[slot][name] = smoothed[k]
			end
		end
	end

	-- Compute Y-axis range from actual data
	local min_y = math.huge
	local max_y = -math.huge
	local has_data = false
	for i = 1, length do
		local datum = data[i]
		if datum then
			for j = 1, to_draw do
				local name = ordered_sums[j].name
				local val = datum[name]
				if val then
					has_data = true
					if val < min_y then min_y = val end
					if val > max_y then max_y = val end
				end
			end
		end
	end

	if not has_data then
		return nil
	end

	if fixed_range then
		min_y = fixed_range[1]
		max_y = fixed_range[2]
	else
		if y_range_option == "zero" then
			min_y = math.min(min_y, 0)
			max_y = math.max(max_y, 0)
			if min_y == max_y then
				max_y = min_y + 1
			end
		elseif min_y == max_y then
			min_y = min_y - 1
			max_y = max_y + 1
		end
		if options.nice_ticks then
			min_y, max_y = nice_range(min_y, max_y, num_grid_lines - 1)
		end
	end

	-- graph_left must leave room for y-axis labels
	local graph_left = 2.0
	local graph_right = viewport_width / 32 - 0.5  -- Reduced right margin for better fill
	local graph_top = 1
	local graph_bottom = viewport_height / 32 - 0.5  -- Reduced bottom margin
	if x_axis then
		graph_bottom = graph_bottom - X_LABEL_ROW
	end

	local graph_width = graph_right - graph_left
	local graph_height = graph_bottom - graph_top

	local y_range = max_y - min_y
	if y_range == 0 then y_range = 1 end

	-- Each column is one time slot ending at its point: the newest point sits on plot.right and the oldest one slot in
	-- from plot.left, so the left edge is exactly columns x seconds_per_column old, like the vanilla graph.
	local dx = graph_width / length
	local dy = graph_height / y_range

	local entity_pos = chunk.coord
	local line_ids = {}

	-- Initialize metadata for point positions (only if collecting)
	local point_positions = nil
	if collect_metadata then
		point_positions = {}
		for j = 1, to_draw do
			point_positions[ordered_sums[j].name] = {}
		end
	end

	local y_ticks = collect_metadata and {} or nil

	local grid_values = {}
	for i = 0, num_grid_lines - 1 do
		grid_values[i + 1] = min_y + (y_range * i / (num_grid_lines - 1))
	end
	local grid_texts = format_y_labels(label_format, grid_values)

	-- Draw horizontal grid lines with Y-axis labels
	for i = 0, num_grid_lines - 1 do
		local grid_value = grid_values[i + 1]
		local grid_y = graph_bottom - ((grid_value - min_y) * dy)

		-- Grid line
		local id = rendering.draw_line{
			surface = surface,
			color = grid_color,
			width = grid_width,
			from = {entity_pos.x + graph_left, entity_pos.y + grid_y},
			to = {entity_pos.x + graph_right, entity_pos.y + grid_y},
			time_to_live = ttl,
		}
		line_ids[#line_ids + 1] = id

		local label_text = grid_texts[i + 1]
		if y_ticks then
			y_ticks[#y_ticks + 1] = {value = grid_value, y = grid_y, text = label_text}
		end
		local text_id = style.draw_label{
			text = label_text,
			surface = surface,
			target = {entity_pos.x + graph_left - 0.2, entity_pos.y + grid_y},
			alignment = "right",
			vertical_alignment = "middle",
			time_to_live = ttl,
		}
		line_ids[#line_ids + 1] = text_id
	end

	local x_ticks = nil
	if x_axis then
		x_ticks = compute_x_ticks(x_axis, length, graph_width)
		for _, label in ipairs(x_ticks.labels) do
			-- Newest sample sits at the right edge as "0", like the vanilla graph.
			local label_x = graph_right - dx * label.seconds_ago / x_ticks.seconds_per_column
			label.x = label_x

			if x_axis.grid then
				line_ids[#line_ids + 1] = rendering.draw_line{
					surface = surface,
					color = grid_color,
					width = grid_width,
					from = {entity_pos.x + label_x, entity_pos.y + graph_top},
					to = {entity_pos.x + label_x, entity_pos.y + graph_bottom},
					time_to_live = ttl,
				}
			end

			line_ids[#line_ids + 1] = style.draw_label{
				text = label.text,
				surface = surface,
				target = {entity_pos.x + label_x, entity_pos.y + graph_bottom + 0.1},
				alignment = "center",
				vertical_alignment = "top",
				time_to_live = ttl,
			}
		end
	end

	-- Draw lines for each series and optionally track point positions
	local prev = {}
	local x = graph_left + dx

	-- Get first datapoint (oldest)
	local first = data[index + 1]
	if first then
		for j = 1, to_draw do
			local name = ordered_sums[j].name
			local n = first[name]
			if n then
				local y = graph_bottom - ((n - min_y) * dy)
				prev[name] = {x, y}
				-- Record point position if collecting metadata
				if point_positions then
					local points = point_positions[name]
					points[#points + 1] = {
						x = x,
						y = y,
						value = n,
						raw_value = raw_data and raw_data[index + 1][name] or nil,
						data_index = index + 1,
					}
				end
			end
		end
	end

	-- Iterate through data in chronological order
	local ranges = {
		{start = index + 2, stop = length},
		{start = 1, stop = index},
	}

	for _, range in ipairs(ranges) do
		for i = range.start, range.stop do
			x = x + dx
			local datum = data[i]
			local next_points = {}

			for j = to_draw, 1, -1 do
				local entry = ordered_sums[j]
				local name = entry.name
				local point = prev[name]
				local n = datum and datum[name]

				if n then
					local y = graph_bottom - ((n - min_y) * dy)
					local to = {x, y}
					next_points[name] = to

					-- Record point position if collecting metadata
					if point_positions then
						local points = point_positions[name]
						points[#points + 1] = {
							x = x,
							y = y,
							value = n,
							raw_value = raw_data and raw_data[i][name] or nil,
							data_index = i,
						}
					end

					if point then
						local from_pos = {entity_pos.x + point[1], entity_pos.y + point[2]}
						local to_pos = {entity_pos.x + to[1], entity_pos.y + to[2]}

						local id = rendering.draw_line{
							surface = surface,
							color = series_colors[entry.color_index],
							width = series_width,
							from = from_pos,
							to = to_pos,
							time_to_live = ttl,
						}
						line_ids[#line_ids + 1] = id
					end
				else
					next_points[name] = nil
				end
			end
			prev = next_points
		end
	end

	-- Build metadata if collecting
	local metadata = nil
	if collect_metadata then
		metadata = {
			graph_left = graph_left,
			graph_right = graph_right,
			graph_top = graph_top,
			graph_bottom = graph_bottom,
			graph_width = graph_width,
			graph_height = graph_height,
			min_y = min_y,
			max_y = max_y,
			y_range = y_range,
			dx = dx,
			dy = dy,
			point_positions = point_positions,

			columns = length,
			plot = {left = graph_left, top = graph_top, right = graph_right, bottom = graph_bottom},
			series_order = {},
			label_format = label_format,
			y_ticks = y_ticks,
			camera_zoom = camera_zoom,
			line_width = series_width,
			smooth = raw_data and smooth or nil,
		}

		-- Bottom-most first: series are stroked from to_draw down to 1, so entry 1 of ordered_sums ends on top.
		for j = to_draw, 1, -1 do
			local entry = ordered_sums[j]
			metadata.series_order[#metadata.series_order + 1] = {name = entry.name, color_index = entry.color_index}
		end

		local x_positions = {}
		for i = 1, length do
			x_positions[i] = graph_left + i * dx
		end
		metadata.x_positions = x_positions

		if x_ticks then
			local seconds_ago = {}
			for i = 1, length do
				seconds_ago[i] = (length - i) * x_ticks.seconds_per_column
			end
			metadata.seconds_ago = seconds_ago
			metadata.x_labels = x_ticks.labels
			metadata.x_unit = x_ticks.unit
			metadata.x_step = x_ticks.step
			metadata.ticks_per_point = x_ticks.ticks_per_point
		end
	end

	return ordered_sums, line_ids, metadata
end

---Render a line graph to a chunk
---@param surface LuaSurface The rendering surface
---@param chunk table The chunk with coord
---@param options table Rendering options
---  - data: table[] Ring buffer of {[series_name]: value}
---  - index: number Current position in ring buffer
---  - length: number Buffer capacity
---  - counts: table {[series_name]: sample_count}
---  - sum: table {[series_name]: total} for calculating averages
---  - y_range: (table|string)? {min, max} fixed range, "zero" auto max with min pinned at 0, nil auto-scale
---  - label_format: (string|function)? "percent" (default), "time", "si", or function(value) -> string
---  - grid_lines: number? Horizontal grid lines incl. top and bottom (default 8 since 1.3.0, was 5; 5 with a fixed
---    {min, max} y_range)
---  - camera_zoom: number? Zoom of the camera that shows the chart (default 1.5); line widths are derived from it
---  - line_px: number? Series line thickness in screen pixels at camera_zoom (default 1)
---  - line_width: number? Raw draw_line width for the series; wins over line_px
---  - smooth: number? Centred moving average window over the drawn values (odd, e.g. 3; default nil = off)
---  - nice_ticks: boolean? Round an auto-scaled range out to 1/2/2.5/5 x 10^k steps (default false)
---  - x_axis: (table|false)? Time labels under the plot (default false). Fields:
---      ticks_per_point (game ticks per ring-buffer slot, default 60),
---      format ("auto"|"seconds"|"minutes"|"hours"|function(seconds_ago) -> string),
---      labels ("auto" or max label count), grid (vertical grid lines, default false)
---  - selected_series: table? {[name]: bool} Filter (nil = show all, false = hide)
---  - ttl: number? Time to live in ticks (default 360)
---  - viewport_width: number? Viewport width in pixels (default 900)
---  - viewport_height: number? Viewport height in pixels (default 700)
---@return table? ordered_sums Array of {name, sum} sorted by sum descending
---@return LuaRenderObject[]? line_ids Array of render object IDs
function line_graph.render(surface, chunk, options)
	local ordered_sums, line_ids = render_internal(surface, chunk, options, false)
	return ordered_sums, line_ids
end

---Render a line graph and return metadata for interaction
---Same as render() but also returns point positions for hit region generation
---@param surface LuaSurface The rendering surface
---@param chunk table The chunk with coord
---@param options table Same rendering options as render()
---@return table? ordered_sums Array of {name, sum} sorted by sum descending
---@return LuaRenderObject[]? line_ids Array of render object IDs
---@return table? metadata Graph metadata for interaction
function line_graph.render_with_metadata(surface, chunk, options)
	return render_internal(surface, chunk, options, true)
end

return line_graph
