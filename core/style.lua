-- The production-graph look, as measured on Factorio 2.1 with a GUI camera on the chart surface.
-- draw_line is rasterised without anti-aliasing: a width w shows as about ceil(w * camera_zoom) whole screen
-- pixels, never less than 1. Text is anti-aliased, so fractional text scales are fine.
local colors_module = require("core/colors")

local style = {}

-- Cybersyn's camera zoom (display_scale / display_density_scale) on a 4K screen at UI scale 1.5. Assuming it when
-- the consumer gives no zoom keeps 1 px lines there, and the same width still gives 1 px at zoom 1 and 0.75.
style.DEFAULT_ZOOM = 1.5
style.DEFAULT_LINE_PX = 1
style.GRID_PX = 1
style.GRID_LINES = 8

style.LABEL_FONT = "default"
-- About 14 px digits at zoom 1.5 (digit height is roughly 0.71 * font size * scale * zoom), the vanilla graph size.
style.LABEL_SCALE = 0.93

---Width to pass to rendering.draw_line so the line is `px` whole screen pixels thick
---@param px number? Screen pixels (default 1)
---@param zoom number? Camera zoom the chart is viewed at (default style.DEFAULT_ZOOM)
---@return number width
function style.line_width(px, zoom)
	px = px or style.DEFAULT_LINE_PX
	zoom = zoom or style.DEFAULT_ZOOM
	-- Aiming half a pixel below px keeps clear of the ceil() boundary; px / zoom lands on it and float noise
	-- then rounds some zooms up a pixel.
	return (px - 0.5) / zoom
end

---Width of horizontal grid lines at a camera zoom
---@param zoom number?
---@return number width
function style.grid_width(zoom)
	return style.line_width(style.GRID_PX, zoom)
end

---@return table color
function style.grid_color()
	return colors_module.get_grid_color()
end

---@return table color
function style.label_color()
	return colors_module.get_label_color()
end

---@return table[] colors The 12-entry series palette; indices are stable across versions
function style.series_colors()
	return colors_module.get_series_colors()
end

---@param index number 1-based, wraps around
---@return table color
function style.series_color(index)
	return colors_module.get_series_color(index)
end

---Draw an axis label with the chart text style; fields given in `params` win over the style
---@param params table rendering.draw_text parameters (text, surface, target, alignment, ...)
---@return LuaRenderObject
function style.draw_label(params)
	if params.font == nil then params.font = style.LABEL_FONT end
	if params.scale == nil then params.scale = style.LABEL_SCALE end
	if params.color == nil then params.color = colors_module.get_label_color() end
	-- true would cancel the camera zoom and pin text at its zoom-1 size, ignoring the player's UI scale.
	if params.scale_with_zoom == nil then params.scale_with_zoom = false end
	return rendering.draw_text(params)
end

---Centred moving average over `count` slots of `values` (which may hold nils)
---Each output is the mean of the non-nil values within n/2 slots either side, so the window shrinks at the ends
---and next to gaps; a nil slot stays nil. An even n is widened to n + 1. n of nil or <= 1 returns `values` itself.
---@param values (number?)[]
---@param n number? Window size
---@param count number? Number of slots (default #values; pass it when values has nil holes)
---@return (number?)[]
function style.smooth(values, n, count)
	if not n or n <= 1 then
		return values
	end
	count = count or #values
	local half = math.floor(n / 2)
	local out = {}
	for i = 1, count do
		if values[i] ~= nil then
			local total, used = 0, 0
			for k = math.max(1, i - half), math.min(count, i + half) do
				local v = values[k]
				if v ~= nil then
					total = total + v
					used = used + 1
				end
			end
			out[i] = total / used
		end
	end
	return out
end

return style
