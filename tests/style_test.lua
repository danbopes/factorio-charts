-- The 1.3.0 look: style helpers, smoothing, the out-of-map background and the object budget
local charts = require("__factorio-charts__/charts")

-- 1e-6: render objects store widths as 32-bit floats.
local EPS = 1e-6

local function near(expected, actual, msg)
    assert.is_true(math.abs(expected - actual) < EPS,
        (msg or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local surface_counter = 0
local function new_surface_data()
    surface_counter = surface_counter + 1
    return charts.surface.create("test-style-" .. surface_counter)
end

local function objects_on(surface, object_type)
    local found = {}
    for _, obj in ipairs(rendering.get_all_objects()) do
        if obj.valid and obj.surface.index == surface.index and (not object_type or obj.type == object_type) then
            found[#found + 1] = obj
        end
    end
    return found
end

local function tile_names(surface, chunk)
    local w, h = chunk.tiles_width, chunk.tiles_height
    local c = chunk.coord
    local names = {}
    for _, pos in ipairs({{c.x, c.y}, {c.x + w - 1, c.y}, {c.x, c.y + h - 1}, {c.x + w - 1, c.y + h - 1},
                          {c.x + math.floor(w / 2), c.y + math.floor(h / 2)}}) do
        names[#names + 1] = surface.get_tile(pos[1], pos[2]).name
    end
    return names
end

local ALL_OUT_OF_MAP = {"out-of-map", "out-of-map", "out-of-map", "out-of-map", "out-of-map"}

-- style.line_width ---------------------------------------------------------------

test("style.line_width aims half a pixel below the wanted screen pixels", function()
    near(0.5, charts.style.line_width(1, 1), "1 px at zoom 1")
    near(1 / 3, charts.style.line_width(1, 1.5), "1 px at zoom 1.5")
    near(2 / 3, charts.style.line_width(1, 0.75), "1 px at zoom 0.75")
    near(1.0, charts.style.line_width(2, 1.5), "2 px at zoom 1.5")
    near(1 / 3, charts.style.line_width(), "defaults: 1 px at zoom 1.5")
    assert.equals(1.5, charts.style.DEFAULT_ZOOM)
    near(0.5 / 1.5, charts.style.grid_width(1.5), "grid 1 px at zoom 1.5")
end)

-- style.smooth -------------------------------------------------------------------

test("style.smooth averages a window of 3 and shrinks it at the ends", function()
    local out = charts.style.smooth({1, 2, 3, 4, 10}, 3)
    near(1.5, out[1], "first")
    near(2, out[2], "second")
    near(3, out[3], "third")
    near(17 / 3, out[4], "fourth")
    near(7, out[5], "last")
end)

test("style.smooth keeps nil slots nil and averages only present neighbours", function()
    local out = charts.style.smooth({1, nil, 3, 5}, 3, 4)
    near(1, out[1], "next to a gap")
    assert.is_nil(out[2])
    near(4, out[3], "3 and 5")
    near(4, out[4], "end")
end)

test("style.smooth with n = 1 or nil returns the input unchanged", function()
    local values = {5, 1, 9}
    assert.equals(values, charts.style.smooth(values, 1))
    assert.equals(values, charts.style.smooth(values, nil))
    -- An even window widens to the next odd one.
    assert.same(charts.style.smooth({1, 2, 3, 4, 10}, 3), charts.style.smooth({1, 2, 3, 4, 10}, 2))
end)

-- Line graph options -------------------------------------------------------------

local function ramp_options(extra)
    -- Chronological order is index+1..length then 1..index; index = 2 makes the ring wrap.
    local data = {{v = 40}, {v = 50}, {v = 0}, {v = 30}, {v = 0}}
    local options = {data = data, index = 2, length = 5, counts = {v = 5}, sum = {v = 120}, ttl = 60}
    for k, v in pairs(extra or {}) do
        options[k] = v
    end
    return options
end

test("smooth = 3 averages the drawn values in chronological order and leaves the data alone", function()
    local surface_data = new_surface_data()
    local chunk = charts.allocate_chunk(surface_data)
    local options = ramp_options({smooth = 3})
    local _, _, md = charts.render_line_graph_with_metadata(surface_data.surface, chunk, options)

    -- Chronological values 0, 30, 0, 40, 50 -> 15, 10, 23.33, 30, 45.
    local points = md.point_positions.v
    assert.equals(5, #points)
    local expected = {15, 10, 70 / 3, 30, 45}
    local raw = {0, 30, 0, 40, 50}
    for i = 1, 5 do
        near(expected[i], points[i].value, "smoothed " .. i)
        near(raw[i], points[i].raw_value, "raw " .. i)
    end
    near(10, md.min_y, "range follows the smoothed values")
    near(45, md.max_y, "range max")
    assert.equals(3, md.smooth)
    assert.equals(40, options.data[1].v)
    charts.free_chunk(surface_data, chunk)
end)

test("smooth keeps gaps: no segment is drawn across a missing value", function()
    local surface_data = new_surface_data()
    local chunk = charts.allocate_chunk(surface_data)
    local data = {{v = 1}, {v = 2}, {}, {v = 4}, {v = 5}}
    local _, plain = charts.render_line_graph(surface_data.surface, chunk,
        {data = data, index = 0, length = 5, counts = {v = 4}, sum = {v = 12}, ttl = 60, grid_lines = 2})
    local _, smoothed, md = charts.render_line_graph_with_metadata(surface_data.surface, chunk,
        {data = data, index = 0, length = 5, counts = {v = 4}, sum = {v = 12}, ttl = 60, grid_lines = 2, smooth = 3})
    assert.equals(#plain, #smoothed)
    assert.equals(4, #md.point_positions.v)
    local indices = {}
    for i, point in ipairs(md.point_positions.v) do indices[i] = point.data_index end
    assert.same({1, 2, 4, 5}, indices)
    charts.free_chunk(surface_data, chunk)
end)

test("line_px, camera_zoom and line_width set the series stroke", function()
    local surface_data = new_surface_data()
    local chunk = charts.allocate_chunk(surface_data)
    local function last_width(extra)
        local _, ids = charts.render_line_graph(surface_data.surface, chunk, ramp_options(extra))
        return ids[#ids].width
    end
    near(1 / 3, last_width(nil), "default")
    near(0.5, last_width({camera_zoom = 1}), "zoom 1")
    near(1.0, last_width({line_px = 2}), "2 px at the default zoom")
    near(3, last_width({line_px = 2, line_width = 3}), "raw width wins")
    charts.free_chunk(surface_data, chunk)
end)

-- Object budget ------------------------------------------------------------------

test("300 columns x 6 series draw 1794 segments plus 8 grid lines and 8 labels", function()
    local surface_data = new_surface_data()
    local chunk = charts.allocate_chunk(surface_data)
    local data, counts, sum = {}, {}, {}
    for s = 1, 6 do
        counts["s" .. s] = 300
        sum["s" .. s] = s
    end
    for i = 1, 300 do
        local datum = {}
        for s = 1, 6 do
            datum["s" .. s] = 15000 * s + 10000 * math.sin(i / (10 + s))
        end
        data[i] = datum
    end
    local base = {data = data, index = 300, length = 300, counts = counts, sum = sum, ttl = 60}
    local _, ids = charts.render_line_graph(surface_data.surface, chunk, base)
    assert.equals(1794 + 8 + 8, #ids)
    for _, obj in ipairs(ids) do obj.destroy() end

    base.smooth = 3
    base.x_axis = {ticks_per_point = 120}
    _, ids = charts.render_line_graph(surface_data.surface, chunk, base)
    -- The 10-minute axis adds 21 labels; smoothing adds nothing.
    assert.equals(1794 + 8 + 8 + 21, #ids)
    for _, obj in ipairs(ids) do obj.destroy() end
    charts.free_chunk(surface_data, chunk)
end)

-- Background ---------------------------------------------------------------------

test("create_surface sets always_day and allocate_chunk lays out-of-map without lights", function()
    local surface_data = new_surface_data()
    assert.is_true(surface_data.surface.always_day)
    local chunk = charts.allocate_chunk(surface_data)
    assert.same(ALL_OUT_OF_MAP, tile_names(surface_data.surface, chunk))
    assert.equals(0, #objects_on(surface_data.surface, "light"))
    assert.equals(0, #objects_on(surface_data.surface))
end)

test("restyle_chunk converts a 1.2.0 chunk and is idempotent", function()
    local surface_data = new_surface_data()
    local surface = surface_data.surface
    local chunk = charts.allocate_chunk(surface_data)

    -- Recreate what 1.2.0 left behind: lab tiles, nine lights, frozen half daylight.
    local tiles = {}
    for x = chunk.coord.x, chunk.coord.x + chunk.tiles_width - 1 do
        for y = chunk.coord.y, chunk.coord.y + chunk.tiles_height - 1 do
            tiles[#tiles + 1] = {name = "lab-dark-1", position = {x, y}}
        end
    end
    surface.set_tiles(tiles)
    chunk.light_ids = {}
    for i = 1, 9 do
        chunk.light_ids[i] = rendering.draw_light{sprite = "utility/light_medium", scale = 50, intensity = 10,
            target = {chunk.coord.x + i, chunk.coord.y + i}, surface = surface}
    end
    surface.always_day = false
    surface.daytime = 0.5
    surface.freeze_daytime = true

    charts.surface.restyle_chunk(surface_data, chunk)
    assert.same(ALL_OUT_OF_MAP, tile_names(surface, chunk))
    assert.equals(0, #objects_on(surface, "light"))
    assert.same({}, chunk.light_ids)
    assert.is_true(surface.always_day)

    charts.surface.restyle_chunk(surface_data, chunk)
    assert.same(ALL_OUT_OF_MAP, tile_names(surface, chunk))
    assert.equals(0, #objects_on(surface, "light"))
    assert.same({}, chunk.light_ids)
end)

test("ensure_tile_coverage extends with out-of-map tiles", function()
    local surface_data = new_surface_data()
    local chunk = charts.allocate_chunk(surface_data)
    charts.ensure_tile_coverage(surface_data, chunk, {viewport_width = 1600, viewport_height = 1200})
    assert.equals(52, chunk.tiles_width)
    assert.equals(40, chunk.tiles_height)
    assert.same(ALL_OUT_OF_MAP, tile_names(surface_data.surface, chunk))
end)
