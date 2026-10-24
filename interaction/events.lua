-- Event handler registration for interactive charts
local events = {}

local interactive_chart = require("interaction/interactive-chart")

---@class ChartEventHandlers
---@field on_tick function? Additional tick handler to chain

local registered = false
local user_handlers = {}

---Internal tick handler
---@param event EventData.on_tick
local function on_tick_handler(event)
	-- Chain user handler if provided
	if user_handlers.on_tick then
		user_handlers.on_tick(event)
	end
end

---Register event handlers for interactive charts
---@param handlers ChartEventHandlers? Custom handlers to chain
function events.register(handlers)
	if registered then
		return
	end

	user_handlers = handlers or {}

	script.on_event(defines.events.on_tick, on_tick_handler)

	registered = true
end

---Unregister event handlers
function events.unregister()
	if not registered then
		return
	end

	script.on_event(defines.events.on_tick, nil)
	user_handlers = {}
	registered = false
end

---Check if events are registered
---@return boolean
function events.is_registered()
	return registered
end

---Get the tick handler function (for manual integration)
---Useful if your mod already has an on_tick handler and you want to call this manually
---@return function on_tick_handler
function events.get_tick_handler()
	return on_tick_handler
end

local function resolve(event)
	local element = event.element
	if not element or not element.valid then
		return nil
	end
	local tag = element.tags.factorio_charts
	if type(tag) ~= "table" or not tag.chart or not tag.region then
		return nil
	end
	local state = interactive_chart.get_state(tag.chart)
	if not state then
		return nil
	end
	local player = game.get_player(event.player_index)
	if not player then
		return nil
	end
	return state, tag.region, player
end

---Forward on_gui_hover here from the consumer's own handler (a mod has one handler per event, so the library
---never calls script.on_event for GUI events). Draws the crosshair of the tagged chart region.
---@param event EventData.on_gui_hover
---@return boolean handled True when the element was a factorio-charts hover button
function events.handle_gui_hover(event)
	local state, region_id, player = resolve(event)
	if not state then
		return false
	end
	local region = interactive_chart.get_hover_region(state, region_id)
	if region then
		interactive_chart.set_hover(state, player, region)
	else
		-- The buttons are older than the data (a redraw changed the regions): a stale crosshair would mislead.
		interactive_chart.clear_hover(state, player)
	end
	return true
end

---Forward on_gui_leave here. Leave events can arrive after the hover of the next button, so only the player's
---crosshair for this very region is cleared.
---@param event EventData.on_gui_leave
---@return boolean handled True when the element was a factorio-charts hover button
function events.handle_gui_leave(event)
	local state, region_id, player = resolve(event)
	if not state then
		return false
	end
	local entry = state.hover and state.hover[player.index]
	if entry and entry.region_id == region_id then
		interactive_chart.clear_hover(state, player)
	end
	return true
end

return events
