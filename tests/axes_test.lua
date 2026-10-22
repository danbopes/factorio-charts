-- Axes, number formatting and the metadata contract hover code builds on
local charts = require("__factorio-charts__/charts")

local EPS = 1e-6

local function near(expected, actual, msg)
    assert.is_true(math.abs(expected - actual) < EPS,
        (msg or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Deterministic ring buffer: "high" peaks at 110000, "low" stays small, so the sort order is fixed.
local function make_series(num_points)
    local data, counts, sum = {}, {high = num_points, low = num_points}, {high = 0, low = 0}
    for i = 1, num_points do
        local high = 55000 + 55000 * math.sin(i / 7)
        local low = 1000 + (i % 10) * 100
        data[i] = {high = high, low = low}
        sum.high = sum.high + high
        sum.low = sum.low + low
    end
    return data, counts, sum
end

local surface_counter = 0
local function with_chunk(fn)
    surface_counter = surface_counter + 1
    local surface_data = charts.create_surface("test-axes-" .. surface_counter)
    local chunk = charts.allocate_chunk(surface_data)
    fn(surface_data.surface, chunk)
    charts.free_chunk(surface_data, chunk)
end

local function render(surface, chunk, num_points, extra)
    local data, counts, sum = make_series(num_points)
    local options = {data = data, index = 0, length = num_points, counts = counts, sum = sum, ttl = 60}
    for k, v in pairs(extra or {}) do
        options[k] = v
    end
    return charts.render_line_graph_with_metadata(surface, chunk, options)
end

local function label_texts(labels)
    local texts = {}
    for i, label in ipairs(labels) do
        texts[i] = label.text
    end
    return texts
end

local function count_types(ids)
    local lines, texts = 0, 0
    for _, obj in ipairs(ids) do
        if obj.type == "line" then lines = lines + 1 elseif obj.type == "text" then texts = texts + 1 end
    end
    return lines, texts
end

-- format.si_label ---------------------------------------------------------------

test("si_label matches the vanilla production graph style", function()
    local cases = {
        {0, "0"}, {0.04, "0"}, {0.5, "0.5"}, {5, "5"}, {9.96, "10"}, {42, "42"}, {950, "950"},
        {999.6, "1k"}, {1000, "1k"}, {1234, "1.2k"}, {9999, "10k"}, {15714, "16k"}, {110000, "110k"},
        {999600, "1M"}, {1200000, "1.2M"}, {3.4e9, "3.4G"}, {-1500, "-1.5k"}, {-0.01, "0"},
    }
    for _, case in ipairs(cases) do
        assert.equals(case[2], charts.format.si_label(case[1]), "si_label(" .. case[1] .. ")")
    end
    assert.equals(charts.format.si_label, charts.format_si_label)
end)

-- Old defaults ------------------------------------------------------------------

test("render without the new options draws exactly the 1.2.0 objects", function()
    with_chunk(function(surface, chunk)
        local data = {}
        for i = 1, 10 do
            data[i] = {only = i * 10}  -- 10..100, so the auto range is exactly 10..100
        end
        local ordered_sums, ids, metadata = charts.render_line_graph_with_metadata(surface, chunk, {
            data = data, index = 0, length = 10, counts = {only = 10}, sum = {only = 550}, ttl = 60,
        })

        -- 5 grid lines + 5 labels + 9 segments, as 1.2.0 drew them.
        assert.equals(19, #ids)
        local lines, texts = count_types(ids)
        assert.equals(14, lines)
        assert.equals(5, texts)

        local expected_bottom = 700 / 32 - 0.5
        near(2.0, metadata.graph_left, "graph_left")
        near(900 / 32 - 0.5, metadata.graph_right, "graph_right")
        near(1, metadata.graph_top, "graph_top")
        near(expected_bottom, metadata.graph_bottom, "graph_bottom")
        near(10, metadata.min_y, "min_y")
        near(100, metadata.max_y, "max_y")

        -- First grid line at the bottom edge, first label "10%" right-aligned in the gutter.
        local first_line = ids[1]
        near(chunk.coord.y + expected_bottom, first_line.from.position.y, "first grid y")
        near(chunk.coord.x + 2.0, first_line.from.position.x, "first grid x")
        assert.equals("10%", ids[2].text)
        assert.equals("right", ids[2].alignment)
        local label_texts_seen = {}
        for i = 2, 10, 2 do
            label_texts_seen[#label_texts_seen + 1] = ids[i].text
        end
        local expected_texts = {}
        for i = 0, 4 do
            expected_texts[i + 1] = charts.format_percent_label(10 + 90 * i / 4)
        end
        assert.same(expected_texts, label_texts_seen)

        assert.is_nil(metadata.seconds_ago)
        assert.is_nil(metadata.x_labels)
    end)
end)

test("x_axis = false renders the same objects as no x_axis", function()
    with_chunk(function(surface, chunk)
        local _, plain_ids, plain = render(surface, chunk, 50)
        local _, off_ids, off = render(surface, chunk, 50, {x_axis = false})
        assert.equals(#plain_ids, #off_ids)
        near(plain.graph_bottom, off.graph_bottom, "graph_bottom")
        assert.is_nil(off.seconds_ago)
    end)
end)

-- X axis labels -----------------------------------------------------------------

test("x_axis over 10 minutes gives 21 minute labels 0..10 like vanilla", function()
    with_chunk(function(surface, chunk)
        local _, ids, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60}})
        assert.equals("minutes", md.x_unit)
        near(0.5, md.x_step, "step")
        assert.equals(21, #md.x_labels)
        local texts = label_texts(md.x_labels)
        assert.equals("0", texts[1])
        assert.equals("9.5", texts[20])
        assert.equals("10", texts[21])
        -- Newest at the right edge, labels move left as they age.
        near(md.plot.right, md.x_labels[1].x, "label 0 x")
        assert.is_true(md.x_labels[2].x < md.x_labels[1].x)
        near(30, md.x_labels[2].seconds_ago, "label 2 seconds_ago")

        local _, plain_ids = render(surface, chunk, 600)
        assert.equals(#plain_ids + 21, #ids)
    end)
end)

test("x_axis over 1 hour labels every 5 minutes", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 360, {x_axis = {ticks_per_point = 600}})
        assert.equals("minutes", md.x_unit)
        near(5, md.x_step, "step")
        assert.equals(13, #md.x_labels)
        assert.equals("60", md.x_labels[13].text)
    end)
end)

test("x_axis over 5 seconds labels half seconds", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 300, {x_axis = {ticks_per_point = 1}})
        assert.equals("seconds", md.x_unit)
        near(0.5, md.x_step, "step")
        assert.same({"0", "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "4.5", "5"}, label_texts(md.x_labels))
    end)
end)

test("x_axis switches to hours above two hours", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 6000}})
        assert.equals("hours", md.x_unit)
        assert.equals("16", md.x_labels[#md.x_labels].text)
    end)
end)

test("auto x labels sit at least 40 px apart at zoom 1", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60}, viewport_width = 400})
        local gap_px = (md.x_labels[1].x - md.x_labels[2].x) * 32
        assert.is_true(gap_px >= 40, "gap " .. gap_px)
        assert.is_true(#md.x_labels < 21)
    end)
end)

test("x_axis labels = n caps the label count with a nice step", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60, labels = 6}})
        assert.same({"0", "2", "4", "6", "8", "10"}, label_texts(md.x_labels))
    end)
end)

test("x_axis format forces a unit or calls a function", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60, format = "seconds"}})
        assert.equals("seconds", md.x_unit)
        assert.equals("600", md.x_labels[#md.x_labels].text)

        local seen = {}
        local _, _, custom = render(surface, chunk, 600, {x_axis = {
            ticks_per_point = 60,
            format = function(seconds_ago)
                seen[#seen + 1] = seconds_ago
                return seconds_ago .. "s ago"
            end,
        }})
        assert.equals("0s ago", custom.x_labels[1].text)
        near(30, seen[2], "second label seconds")
        assert.equals(#custom.x_labels, #seen)
    end)
end)

test("x_axis reserves a label row and draws centred top-aligned labels", function()
    with_chunk(function(surface, chunk)
        local _, ids, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60}})
        near(700 / 32 - 0.5 - 0.7, md.graph_bottom, "graph_bottom")
        near(md.graph_bottom, md.plot.bottom, "plot.bottom")
        near(md.graph_bottom - md.graph_top, md.graph_height, "graph_height")

        local x_label_objs = 0
        for _, obj in ipairs(ids) do
            if obj.type == "text" and obj.vertical_alignment == "top" then
                x_label_objs = x_label_objs + 1
                assert.equals("center", obj.alignment)
                assert.is_true(obj.target.position.y > chunk.coord.y + md.graph_bottom)
            end
        end
        assert.equals(21, x_label_objs)
    end)
end)

test("x_axis grid draws one vertical line per label", function()
    with_chunk(function(surface, chunk)
        local _, off_ids = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60}})
        local _, on_ids, md = render(surface, chunk, 600, {x_axis = {ticks_per_point = 60, grid = true}})
        assert.equals(#off_ids + #md.x_labels, #on_ids)
    end)
end)

-- Metadata contract -------------------------------------------------------------

test("metadata carries columns, x_positions, seconds_ago, plot and series_order", function()
    with_chunk(function(surface, chunk)
        local ordered_sums, _, md = render(surface, chunk, 120, {x_axis = {ticks_per_point = 30}})
        assert.equals(120, md.columns)
        assert.equals(120, #md.x_positions)
        near(md.plot.left, md.x_positions[1], "first column at plot.left")
        near(md.plot.right, md.x_positions[120], "last column at plot.right")
        for i = 2, 120 do
            assert.is_true(md.x_positions[i] > md.x_positions[i - 1])
        end
        near(119 * 0.5, md.seconds_ago[1], "oldest seconds_ago")
        near(0, md.seconds_ago[120], "newest seconds_ago")
        assert.equals(30, md.ticks_per_point)

        assert.same({left = md.graph_left, top = md.graph_top, right = md.graph_right, bottom = md.graph_bottom}, md.plot)

        -- Draw order: last entry is stroked last (on top) and is the largest series.
        assert.equals(2, #md.series_order)
        assert.equals(ordered_sums[1].name, md.series_order[2].name)
        assert.equals(ordered_sums[1].color_index, md.series_order[2].color_index)
        assert.equals("low", md.series_order[1].name)

        -- point_positions still line up with the column grid.
        local high_points = md.point_positions.high
        near(md.x_positions[1], high_points[1].x, "point 1 x")
        near(md.x_positions[120], high_points[120].x, "point 120 x")
    end)
end)

test("x_positions honour the ring buffer start", function()
    with_chunk(function(surface, chunk)
        local data, counts, sum = make_series(10)
        local _, _, md = charts.render_line_graph_with_metadata(surface, chunk, {
            data = data, index = 4, length = 10, counts = counts, sum = sum, ttl = 60,
            x_axis = {ticks_per_point = 60},
        })
        -- index 4 means slot 5 is the oldest sample, drawn in column 1.
        assert.equals(5, md.point_positions.high[1].data_index)
        near(md.x_positions[1], md.point_positions.high[1].x, "oldest x")
        near(9, md.seconds_ago[1], "oldest seconds_ago")
    end)
end)

test("single-slot buffer gives finite x_positions", function()
    with_chunk(function(surface, chunk)
        local _, _, md = charts.render_line_graph_with_metadata(surface, chunk, {
            data = {{a = 5}}, index = 0, length = 1, counts = {a = 1}, sum = {a = 5}, ttl = 60,
            x_axis = {ticks_per_point = 60},
        })
        near(md.graph_left, md.x_positions[1], "x")
        assert.equals(1, #md.x_labels)
    end)
end)

-- Y axis ------------------------------------------------------------------------

test("grid_lines sets the number of horizontal lines and labels", function()
    with_chunk(function(surface, chunk)
        local _, five_ids, five = render(surface, chunk, 50)
        local _, eight_ids, eight = render(surface, chunk, 50, {grid_lines = 8})
        assert.equals(5, #five.y_ticks)
        assert.equals(8, #eight.y_ticks)
        assert.equals(#five_ids + 6, #eight_ids)
        near(eight.min_y, eight.y_ticks[1].value, "bottom tick")
        near(eight.max_y, eight.y_ticks[8].value, "top tick")
        near(eight.graph_top, eight.y_ticks[8].y, "top tick y")
    end)
end)

test("y_range zero pins the minimum at 0 and keeps the data max", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 300, {y_range = "zero", label_format = "si", grid_lines = 8})
        near(0, md.min_y, "min_y")
        local data_max = 0
        for _, p in ipairs(md.point_positions.high) do
            if p.value > data_max then data_max = p.value end
        end
        near(data_max, md.max_y, "max_y")
        assert.equals("0", md.y_ticks[1].text)
    end)
end)

test("y_range zero with all-zero data still has a usable range", function()
    with_chunk(function(surface, chunk)
        local _, ids, md = charts.render_line_graph_with_metadata(surface, chunk, {
            data = {{a = 0}, {a = 0}}, index = 0, length = 2, counts = {a = 2}, sum = {a = 0}, ttl = 60,
            y_range = "zero",
        })
        near(0, md.min_y, "min_y")
        near(1, md.max_y, "max_y")
        assert.is_true(#ids > 0)
    end)
end)

test("nice_ticks rounds an auto range out to 1/2/2.5/5 steps", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 300, {
            y_range = "zero", label_format = "si", grid_lines = 8, nice_ticks = true,
        })
        near(0, md.min_y, "min_y")
        near(140000, md.max_y, "max_y")
        assert.same({"0", "20k", "40k", "60k", "80k", "100k", "120k", "140k"}, label_texts(md.y_ticks))

        local _, _, auto = render(surface, chunk, 300, {nice_ticks = true})
        -- Auto (not pinned) range starts on a multiple of the step below the data minimum.
        local step = (auto.max_y - auto.min_y) / 4
        near(0, auto.min_y % step, "min_y on a step")
        assert.is_true(auto.min_y <= 1000)
    end)
end)

test("nice_ticks leaves a fixed y_range alone", function()
    with_chunk(function(surface, chunk)
        local _, _, md = render(surface, chunk, 50, {y_range = {0, 123456}, nice_ticks = true})
        near(0, md.min_y, "min_y")
        near(123456, md.max_y, "max_y")
    end)
end)

-- time_series passthrough -------------------------------------------------------

test("time_series.render fills ticks_per_point from the interval and keeps the caller's table", function()
    surface_counter = surface_counter + 1
    local surface_data = charts.create_surface("test-axes-ts-" .. surface_counter)
    local intervals = charts.create_time_series({
        {name = "10m", ticks = 60, steps = nil, length = 600},
    })
    intervals[1].chunk = charts.allocate_chunk(surface_data)
    for i = 1, 600 do
        charts.add_datapoint(intervals, {a = 1000 + i, b = 500})
    end

    local x_axis = {format = "auto"}
    local ordered_sums = charts.render.time_series(surface_data.surface, intervals, 1, {
        x_axis = x_axis, label_format = "si", y_range = "zero", grid_lines = 8, nice_ticks = true,
    })
    assert.is_table(ordered_sums)
    assert.is_nil(x_axis.ticks_per_point)

    local md = intervals[1].metadata
    assert.is_table(md)
    assert.equals(60, md.ticks_per_point)
    assert.equals("minutes", md.x_unit)
    assert.equals(21, #md.x_labels)
    assert.equals(8, #md.y_ticks)
    near(0, md.min_y, "min_y")

    charts.free_chunk(surface_data, intervals[1].chunk)
end)

-- Adjacent ticks never share a label --------------------------------------------

test("time_label keeps 150 s and 180 s apart and old boundaries intact", function()
    assert.equals("2.5m", charts.format.time_label(150))
    assert.equals("3m", charts.format.time_label(180))
    assert.equals("1.7m", charts.format.time_label(102))
    assert.equals("51s", charts.format.time_label(51))
    assert.equals("0s", charts.format.time_label(0))
    assert.equals("1m", charts.format.time_label(60))
    assert.equals("59m", charts.format.time_label(3540))
    assert.equals("1.0h", charts.format.time_label(3600))
end)

test("bar chart time ticks for a 204 s maximum are all distinct", function()
    local seen = {}
    for i = 0, 4 do
        local text = charts.format.time_label(204 * i / 4)
        assert.is_nil(seen[text], "duplicate label " .. text)
        seen[text] = true
    end
end)

test("si and time Y labels gain decimals instead of repeating", function()
    with_chunk(function(surface, chunk)
        local data = {{a = 10000}, {a = 10100}}
        for _, label_format in ipairs({"si", "time"}) do
            local _, _, md = charts.render_line_graph_with_metadata(surface, chunk, {
                data = data, index = 0, length = 2, counts = {a = 2}, sum = {a = 20100}, ttl = 60,
                label_format = label_format,
            })
            local texts = label_texts(md.y_ticks)
            for i = 2, #texts do
                assert.are_not.equal(texts[i - 1], texts[i], label_format .. " tick " .. i)
            end
        end
    end)
end)
