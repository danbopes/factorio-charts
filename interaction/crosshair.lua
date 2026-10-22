-- Crosshair hover for line graphs, modelled on the vanilla production statistics graph.
-- Factorio reports no mouse position over a camera widget, so hover comes from transparent overlay buttons: this
-- module cuts the plot into button-sized regions, draws the per-player crosshair and builds the default tooltip.
local crosshair = {}

local colors_module = require("core/colors")
local format_module = require("core/format")

local DEFAULT_MAX_BUTTONS = 400
local EPSILON = 1e-6

local WHITE = {r = 1, g = 1, b = 1, a = 1}

---@class CrosshairLayout
---@field plot table {left, top, right, bottom} chunk-relative tiles
---@field columns number
---@field dx number Tiles between columns
---@field x_positions number[] Plot x of each column (1 = oldest)
---@field seconds_ago number[]? Age of each column, nil when the chart has no time axis
---@field series table[] {name, color_index, color, order} in draw order
---@field by_column table<number, table<string, table>> column -> series name -> point

local function plot_rect(metadata)
	-- MERGE(b1): metadata.plot comes from work package A; 1.2.0 metadata only has the graph_* fields.
	if metadata.plot then
		return metadata.plot
	end
	return {
		left = metadata.graph_left,
		top = metadata.graph_top,
		right = metadata.graph_right,
		bottom = metadata.graph_bottom,
	}
end

local function column_count(metadata, plot)
	-- MERGE(b1): metadata.columns comes from work package A.
	if metadata.columns then
		return metadata.columns
	end
	local dx = metadata.dx
	if not dx or dx <= 0 or dx == math.huge or dx ~= dx then
		return 1
	end
	return math.floor((plot.right - plot.left) / dx + 0.5) + 1
end

local function normalise_series(metadata, opts)
	-- MERGE(b1): metadata.series_order comes from work package A. Until then the interactive wrapper passes its
	-- ordered_sums (same shape: {name, color_index}) through opts.series_order.
	local source = metadata.series_order or opts.series_order
	local series = {}
	if source then
		for i, entry in ipairs(source) do
			local name = type(entry) == "table" and entry.name or entry
			if metadata.point_positions[name] then
				local color_index = type(entry) == "table" and entry.color_index or i
				series[#series + 1] = {
					name = name,
					color_index = color_index,
					color = colors_module.get_series_color(color_index),
				}
			end
		end
	else
		local names = {}
		for name in pairs(metadata.point_positions) do
			names[#names + 1] = name
		end
		table.sort(names)
		for i, name in ipairs(names) do
			series[i] = {name = name, color_index = i, color = colors_module.get_series_color(i)}
		end
	end
	for i, entry in ipairs(series) do
		entry.order = i
	end
	return series
end

---Collect the column geometry the crosshair needs from line graph metadata
---@param metadata table From line_graph.render_with_metadata
---@param opts table? {series_order?, ticks_per_point?}
---@return CrosshairLayout
function crosshair.layout(metadata, opts)
	opts = opts or {}
	local plot = plot_rect(metadata)
	local columns = column_count(metadata, plot)
	local dx = columns > 1 and (plot.right - plot.left) / (columns - 1) or (plot.right - plot.left)

	-- MERGE(b1): x_positions and seconds_ago come from work package A.
	local x_positions = metadata.x_positions
	if not x_positions then
		x_positions = {}
		for i = 1, columns do
			x_positions[i] = plot.left + (i - 1) * dx
		end
	end
	local seconds_ago = metadata.seconds_ago
	if not seconds_ago and opts.ticks_per_point then
		seconds_ago = {}
		for i = 1, columns do
			seconds_ago[i] = (columns - i) * opts.ticks_per_point / 60
		end
	end

	-- Points skip columns where a series has no sample, so the array index is not the column; the x is.
	local by_column = {}
	for name, points in pairs(metadata.point_positions) do
		for _, point in ipairs(points) do
			local column = columns > 1 and math.floor((point.x - plot.left) / dx + 0.5) + 1 or 1
			local slot = by_column[column]
			if not slot then
				slot = {}
				by_column[column] = slot
			end
			slot[name] = point
		end
	end

	return {
		plot = plot,
		columns = columns,
		dx = dx,
		x_positions = x_positions,
		seconds_ago = seconds_ago,
		series = normalise_series(metadata, opts),
		by_column = by_column,
	}
end

---Stable id of the region for a column (and series in cell mode), so tags survive a rebuild of the buttons
---@param column number
---@param series_name string?
---@return string
function crosshair.region_id(column, series_name)
	if series_name then
		return "xh_" .. column .. "_" .. series_name
	end
	return "xh_" .. column
end

---Number of adjacent columns that share one button so the button count stays within budget
---@param columns number
---@param per_column number Buttons per column (series count in cell mode, 1 in column mode)
---@param max_buttons number?
---@return number
function crosshair.group_size(columns, per_column, max_buttons)
	local budget = math.max(1, max_buttons or DEFAULT_MAX_BUTTONS)
	return math.max(1, math.ceil(columns * math.max(1, per_column) / budget))
end

local function clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

---Create hover regions for a line graph: one per (column, series) cell, or one per column
---
---Cell mode splits each column's plot height between the visible series at the midpoints of their y values, so
---the cell under the pointer belongs to the series nearest in y (the series vanilla picks). When columns x series
---exceeds opts.max_buttons, k = ceil(columns * series / max_buttons) adjacent columns share one cell, which then
---reports its centre column: fewer GUI elements at the price of a coarser x resolution.
---@param chunk table Chunk with coord
---@param metadata table Line graph metadata from render_with_metadata
---@param opts table? {mode?: "cell"|"column", max_buttons?: number, series_order?: table[], ticks_per_point?: number, layout?: CrosshairLayout}
---@return HitRegion[] regions
---@return CrosshairLayout? layout
function crosshair.create_regions(chunk, metadata, opts)
	opts = opts or {}
	local regions = {}
	if not chunk or not chunk.coord or not metadata or not metadata.point_positions then
		return regions, nil
	end

	local layout = opts.layout or crosshair.layout(metadata, opts)
	local plot = layout.plot
	local columns = layout.columns
	local series = layout.series
	if #series == 0 then
		return regions, layout
	end

	local column_mode = opts.mode == "column"
	local group = crosshair.group_size(columns, column_mode and 1 or #series, opts.max_buttons)
	local half = layout.dx / 2
	local ox, oy = chunk.coord.x, chunk.coord.y

	for first = 1, columns, group do
		local last = math.min(columns, first + group - 1)
		local centre = math.floor((first + last) / 2)
		local points = layout.by_column[centre]
		if points then
			local left = math.max(plot.left, layout.x_positions[first] - half)
			local right = math.min(plot.right, layout.x_positions[last] + half)
			local seconds = layout.seconds_ago and layout.seconds_ago[centre]

			if column_mode then
				local values = {}
				for _, entry in ipairs(series) do
					local point = points[entry.name]
					if point then
						values[#values + 1] = {
							series_name = entry.name,
							value = point.value,
							graph_y = point.y,
							color = entry.color,
							color_index = entry.color_index,
						}
					end
				end
				if #values > 0 then
					regions[#regions + 1] = {
						id = crosshair.region_id(centre),
						tile_bounds = {left = ox + left, top = oy + plot.top, right = ox + right, bottom = oy + plot.bottom},
						type = "crosshair_column",
						data = {
							column = centre,
							first_column = first,
							last_column = last,
							seconds_ago = seconds,
							graph_x = layout.x_positions[centre],
							values = values,
						},
					}
				end
			else
				local visible = {}
				for _, entry in ipairs(series) do
					local point = points[entry.name]
					if point then
						visible[#visible + 1] = {entry = entry, point = point}
					end
				end
				-- Ties go to the series drawn on top (lowest order), matching what the eye sees.
				table.sort(visible, function(a, b)
					if a.point.y ~= b.point.y then
						return a.point.y < b.point.y
					end
					return a.entry.order < b.entry.order
				end)

				local n = #visible
				for k = 1, n do
					local item = visible[k]
					local top = k == 1 and plot.top or (visible[k - 1].point.y + item.point.y) / 2
					local bottom = k == n and plot.bottom or (item.point.y + visible[k + 1].point.y) / 2
					top = clamp(top, plot.top, plot.bottom)
					bottom = clamp(bottom, plot.top, plot.bottom)
					if bottom - top > EPSILON then
						regions[#regions + 1] = {
							id = crosshair.region_id(centre, item.entry.name),
							tile_bounds = {left = ox + left, top = oy + top, right = ox + right, bottom = oy + bottom},
							type = "crosshair_cell",
							data = {
								column = centre,
								first_column = first,
								last_column = last,
								series_name = item.entry.name,
								value = item.point.value,
								seconds_ago = seconds,
								graph_x = item.point.x,
								graph_y = item.point.y,
								color = item.entry.color,
								color_index = item.entry.color_index,
							},
						}
					end
				end
			end
		end
	end

	return regions, layout
end

-- A triangle strip with mitred joints: one render object per unbroken run instead of one per segment.
local function ribbon_vertices(run, half_width, ox, oy)
	local n = #run
	local normals = {}
	for i = 1, n - 1 do
		local ddx = run[i + 1].x - run[i].x
		local ddy = run[i + 1].y - run[i].y
		local length = math.sqrt(ddx * ddx + ddy * ddy)
		if length < EPSILON then
			normals[i] = normals[i - 1] or {0, -1}
		else
			normals[i] = {-ddy / length, ddx / length}
		end
	end

	local vertices = {}
	for i = 1, n do
		local a = normals[i - 1] or normals[i]
		local b = normals[i] or normals[i - 1]
		local mx, my = a[1] + b[1], a[2] + b[2]
		local length = math.sqrt(mx * mx + my * my)
		local scale = half_width
		if length > EPSILON then
			mx, my = mx / length, my / length
			local cos_half = mx * b[1] + my * b[2]
			-- Spikes would otherwise shoot the mitre out to infinity; cap it at twice the width.
			scale = half_width / math.max(cos_half, 0.5)
		else
			mx, my = b[1], b[2]
		end
		local p = run[i]
		vertices[#vertices + 1] = {ox + p.x + mx * scale, oy + p.y + my * scale}
		vertices[#vertices + 1] = {ox + p.x - mx * scale, oy + p.y - my * scale}
	end
	return vertices
end

-- The base renderer only joins samples in adjacent columns, so the highlight must break at the same gaps.
local function split_runs(points, dx)
	local runs = {}
	local run = nil
	local previous = nil
	for _, point in ipairs(points) do
		if previous and math.abs(point.x - previous.x - dx) < dx * 0.5 then
			run[#run + 1] = point
		else
			run = {point}
			runs[#runs + 1] = run
		end
		previous = point
	end
	return runs
end

---Draw the crosshair for one player
---@param surface LuaSurface
---@param chunk table Chunk with coord
---@param metadata table Line graph metadata
---@param cell table Region data from create_regions (crosshair_cell or crosshair_column)
---@param player LuaPlayer|uint Only this player sees the objects
---@param opts table? {layout?, line_width?: number, series_mode?: "lines"|"polygon", color?: Color, marker_radius?: number, marker_width?: number, ttl?: number, series_order?, ticks_per_point?}
---@return LuaRenderObject[] objects
function crosshair.draw(surface, chunk, metadata, cell, player, opts)
	opts = opts or {}
	local objects = {}
	if not surface or not chunk or not chunk.coord or not metadata or not cell then
		return objects
	end

	local layout = opts.layout or crosshair.layout(metadata, opts)
	local plot = layout.plot
	local ox, oy = chunk.coord.x, chunk.coord.y
	local players = {player}
	local ttl = opts.ttl
	local color = opts.color or WHITE
	local marker_radius = opts.marker_radius or 0.12
	local marker_width = opts.marker_width or 2
	local x = cell.graph_x or layout.x_positions[cell.column]

	objects[#objects + 1] = rendering.draw_line{
		surface = surface,
		color = color,
		width = 1,
		from = {ox + x, oy + plot.top},
		to = {ox + x, oy + plot.bottom},
		players = players,
		time_to_live = ttl,
	}

	if cell.series_name then
		local y = cell.graph_y
		objects[#objects + 1] = rendering.draw_line{
			surface = surface,
			color = color,
			width = 1,
			from = {ox + plot.left, oy + y},
			to = {ox + plot.right, oy + y},
			players = players,
			time_to_live = ttl,
		}

		local points = metadata.point_positions[cell.series_name]
		if points then
			local width = (opts.line_width or 1) * 2
			local series_color = cell.color or WHITE
			for _, run in ipairs(split_runs(points, layout.dx)) do
				if #run >= 2 then
					if opts.series_mode == "polygon" then
						objects[#objects + 1] = rendering.draw_polygon{
							surface = surface,
							color = series_color,
							vertices = ribbon_vertices(run, width / 64, ox, oy),
							players = players,
							time_to_live = ttl,
						}
					else
						for i = 2, #run do
							objects[#objects + 1] = rendering.draw_line{
								surface = surface,
								color = series_color,
								width = width,
								from = {ox + run[i - 1].x, oy + run[i - 1].y},
								to = {ox + run[i].x, oy + run[i].y},
								players = players,
								time_to_live = ttl,
							}
						end
					end
				end
			end
		end

		objects[#objects + 1] = rendering.draw_circle{
			surface = surface,
			color = color,
			radius = marker_radius,
			width = marker_width,
			filled = false,
			target = {ox + x, oy + y},
			players = players,
			time_to_live = ttl,
		}
	elseif cell.values then
		for _, entry in ipairs(cell.values) do
			objects[#objects + 1] = rendering.draw_circle{
				surface = surface,
				color = color,
				radius = marker_radius,
				width = marker_width,
				filled = false,
				target = {ox + x, oy + entry.graph_y},
				players = players,
				time_to_live = ttl,
			}
		end
	end

	return objects
end

---Format a value with the chart's label_format, for tooltips
---@param value number
---@param label_format (string|function)?
---@return LocalisedString
function crosshair.format_value(value, label_format)
	if type(label_format) == "function" then
		return label_format(value)
	elseif label_format == "time" then
		return format_module.time_detailed(value)
	elseif label_format == "si" then
		-- MERGE(b1): format.si_label comes from work package A.
		if format_module.si_label then
			return format_module.si_label(value)
		end
		return string.format("%.0f", value)
	end
	return format_module.percent_label(value)
end

-- A LocalisedString takes at most 20 parameters after the key, so long lists nest.
local function concat(parts)
	if #parts <= 20 then
		local out = {""}
		for i = 1, #parts do
			out[i + 1] = parts[i]
		end
		return out
	end
	local out = {""}
	for i = 1, 19 do
		out[i + 1] = parts[i]
	end
	local rest = {}
	for i = 20, #parts do
		rest[#rest + 1] = parts[i]
	end
	out[21] = concat(rest)
	return out
end

---Default tooltip for a crosshair region, like the vanilla graph's "Sand / 35k - 6.6 minutes ago"
---@param cell table Region data
---@param label_format (string|function)?
---@return LocalisedString
function crosshair.default_tooltip(cell, label_format)
	if cell.series_name then
		local parts = {cell.series_name, "\n", crosshair.format_value(cell.value, label_format)}
		if cell.seconds_ago then
			parts[#parts + 1] = " - "
			parts[#parts + 1] = format_module.time_ago(cell.seconds_ago)
		end
		return concat(parts)
	end

	local parts = {}
	if cell.seconds_ago then
		parts[1] = format_module.time_ago(cell.seconds_ago)
	end
	for _, entry in ipairs(cell.values or {}) do
		if #parts > 0 then
			parts[#parts + 1] = "\n"
		end
		parts[#parts + 1] = entry.series_name
		parts[#parts + 1] = ": "
		parts[#parts + 1] = crosshair.format_value(entry.value, label_format)
	end
	return concat(parts)
end

return crosshair
