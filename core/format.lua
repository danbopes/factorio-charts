-- Formatting utilities for chart labels
local format_module = {}

local function strip_zeros(text)
	if text:find("%.") then
		text = text:gsub("0+$", ""):gsub("%.$", "")
	end
	return text
end

-- One decimal below 10, whole numbers above, so labels keep two or three significant digits.
-- `decimals` overrides that when a caller needs finer labels to keep adjacent ticks distinct.
local function short_number(x, decimals)
	if decimals then
		return strip_zeros(string.format("%." .. decimals .. "f", x))
	end
	if x < 10 then
		local text = strip_zeros(string.format("%.1f", x))
		if tonumber(text) < 10 then
			return text
		end
	end
	return string.format("%.0f", x)
end

---Format seconds into human readable time for Y-axis labels
---Below 10 of a unit it keeps one decimal, so ticks like 150 s and 180 s read "2.5m" and "3m" instead of "3m" twice.
---@param seconds number
---@param decimals number? Fixed maximum decimals for seconds and minutes (trailing zeros dropped)
---@return string
function format_module.time_label(seconds, decimals)
	if seconds < 60 then
		return short_number(seconds, decimals) .. "s"
	elseif seconds < 3600 then
		return short_number(seconds / 60, decimals) .. "m"
	else
		return string.format("%." .. math.max(1, decimals or 1) .. "f", seconds / 3600) .. "h"
	end
end

---Format a percentage for Y-axis labels
---@param value number The percentage value (0-100)
---@return string
function format_module.percent_label(value)
	return string.format("%.0f%%", value)
end

---Format seconds into detailed human readable time
---@param seconds number
---@return string
function format_module.time_detailed(seconds)
	if seconds < 60 then
		return string.format("%.1fs", seconds)
	elseif seconds < 3600 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return string.format("%dm %.0fs", mins, secs)
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		return string.format("%dh %dm", hours, mins)
	end
end

-- Vanilla production-graph style: "0", "950", "1.2k", "16k", "1.2M".
local si_units = {
	{1e12, "T"},
	{1e9, "G"},
	{1e6, "M"},
	{1e3, "k"},
}


---Format a number with an SI suffix the way Factorio's production graph labels its axis
---@param value number
---@param decimals number? Fixed maximum decimals instead of "one below 10" (trailing zeros dropped)
---@return string
function format_module.si_label(value, decimals)
	if value ~= value then
		return "NaN"
	end
	local magnitude = math.abs(value)
	local unit_index = #si_units + 1
	for i, unit in ipairs(si_units) do
		if magnitude >= unit[1] then
			unit_index = i
			break
		end
	end

	local text
	while true do
		local unit = si_units[unit_index]
		local scaled = unit and magnitude / unit[1] or magnitude
		text = short_number(scaled, decimals)
		-- Rounding can carry into the next unit (999.6k -> "1000k"), which should read "1M".
		if tonumber(text) >= 1000 and unit_index > 1 then
			unit_index = unit_index - 1
		else
			text = text .. (unit and unit[2] or "")
			break
		end
	end

	if value < 0 and text ~= "0" then
		text = "-" .. text
	end
	return text
end

---Format an axis tick value with at most `decimals` decimals and no trailing zeros
---@param value number
---@param decimals number?
---@return string
function format_module.axis_number(value, decimals)
	decimals = decimals or 1
	local text = strip_zeros(string.format("%." .. decimals .. "f", value))
	if text == "-0" then
		text = "0"
	end
	return text
end

return format_module
