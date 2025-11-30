addon.name    = 'hitboxdisplay';
addon.author  = 'sruon';
addon.version = '1.0.0';
addon.desc    = 'Displays 3D hitboxes and range visualizations around entities.';
addon.link    = 'https://github.com/sruon/Ashita4-HitboxDisplay';

require('common');
local ffi  = require('ffi');
local d3d8 = require('d3d8');
local bit  = require('bit');
local ui   = require('ui');

local C       = ffi.C;
local d3d8dev = d3d8.get_device();

-- Vertex structure for 3D lines (position + color) - using XYZRHW for screen space
if not pcall(function() ffi.typeof('hitbox_vertex_t') end) then
    ffi.cdef [[
        #pragma pack(push, 1)
        typedef struct {
            float x, y, z, rhw;
            uint32_t color;
        } hitbox_vertex_t;
        #pragma pack(pop)
    ]];
end

local entity_positions = {};
local last_entity_positions = {};
local show_hitboxes = true;

-- Global race modifiers table (used by all range visualizations)
local RACE_DATA =
{
    names     = { 'Tarutaru', 'Hume/Elvaan/Mithra', 'Galka' },
    modifiers = { 0.3, 0.4, 0.8 }
};

-- Predefined AoE radius values
local AOE_RADIUS_VALUES = { 1, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 25, 30, 35, 40, 50 };

-- AoE Circle Configuration
local config =
{
    selected_race      = { 1 },    -- Global race selection: 0=Taru, 1=Hume/Elvaan/Mithra, 2=Galka
    show_center_marker = { true }, -- Show red cross at entity center
    base_aoe           =
    {
        enabled      = { false },
        radius_index = { 7 },             -- Index into AOE_RADIUS_VALUES (default: 10 yalms, 0-based index)
        color        = { 1.0, 0.25, 0.25, 0.37 } -- Red
    },
    melee_range        =
    {
        enabled        = { false },
        show_all_races = { true },                      -- Show all race rings instead of just selected race
        base_color     = { 1.0, 0.25, 0.25, 0.37 },     -- Red for base melee range
        race_colors    = {
            { 1.0, 1.0, 0.0, 0.37 },                    -- Taru: Yellow
            { 0.0, 1.0, 0.0, 0.37 },                    -- Hume/Elvaan/Mithra: Green
            { 0.0, 0.5, 1.0, 0.37 }                     -- Galka: Blue
        },
        race_enabled   = { { true }, { true }, { true } } -- Enable flags for each race
    },
    spell_range        =
    {
        enabled        = { false },
        show_all_races = { true },                      -- Show all race rings instead of just selected race
        radius_index   = { 11 },                        -- Index into AOE_RADIUS_VALUES (default: 20 yalms, 0-based index)
        base_color     = { 0.5, 0.5, 1.0, 0.37 },       -- Blue for base spell range
        race_colors    = {
            { 1.0, 1.0, 0.0, 0.37 },                    -- Taru: Yellow
            { 0.0, 1.0, 0.0, 0.37 },                    -- Hume/Elvaan/Mithra: Green
            { 0.0, 0.5, 1.0, 0.37 }                     -- Galka: Blue
        },
        race_enabled   = { { true }, { true }, { true } } -- Enable flags for each race
    },
    ranged_sweet_spot  =
    {
        enabled          = { false },
        max_range_marker = { true },                                                                          -- Show red 25y max range ring
        weapons          = {
            { name = 'Crossbow',  min = 5.0, max = 8.4, enabled = { true }, color = { 1.0, 0.4, 0.0, 0.5 } }, -- Bright Orange (50% transparent)
            { name = 'Gun',       min = 3.0, max = 4.3, enabled = { true }, color = { 0.8, 0.0, 1.0, 0.5 } }, -- Purple/Violet (50% transparent)
            { name = 'Throw',     min = 0.0, max = 1.3, enabled = { true }, color = { 1.0, 0.0, 0.5, 0.5 } }, -- Hot Pink (50% transparent)
            { name = 'Long Bow',  min = 6.0, max = 9.5, enabled = { true }, color = { 0.0, 0.9, 1.0, 0.5 } }, -- Bright Cyan (50% transparent)
            { name = 'Short Bow', min = 4.0, max = 6.4, enabled = { true }, color = { 0.4, 1.0, 0.0, 0.5 } }  -- Lime Green (50% transparent)
        }
    }
};

-- Pre-compute segment angles for cylinder drawing
local segment_angles = {};
for i = 0, 11 do
    local angle = (i / 12) * 2 * math.pi;
    segment_angles[i] = { math.cos(angle), math.sin(angle) };
end

-- Pre-compute combo box strings for UI
local radius_items = {};
for _, val in ipairs(AOE_RADIUS_VALUES) do
    table.insert(radius_items, string.format('%d', val));
end
local RADIUS_STR = table.concat(radius_items, '\0') .. '\0';
local RACE_STR = table.concat(RACE_DATA.names, '\0') .. '\0';

--[[
* Multiplies two 4x4 matrices (using D3DXMATRIX)
--]]
local function matrixMultiply(m1, m2)
    if m1 == nil or m2 == nil then
        return nil;
    end

    local result = ffi.new('D3DXMATRIX');
    result._11 = m1._11 * m2._11 + m1._12 * m2._21 + m1._13 * m2._31 + m1._14 * m2._41;
    result._12 = m1._11 * m2._12 + m1._12 * m2._22 + m1._13 * m2._32 + m1._14 * m2._42;
    result._13 = m1._11 * m2._13 + m1._12 * m2._23 + m1._13 * m2._33 + m1._14 * m2._43;
    result._14 = m1._11 * m2._14 + m1._12 * m2._24 + m1._13 * m2._34 + m1._14 * m2._44;
    result._21 = m1._21 * m2._11 + m1._22 * m2._21 + m1._23 * m2._31 + m1._24 * m2._41;
    result._22 = m1._21 * m2._12 + m1._22 * m2._22 + m1._23 * m2._32 + m1._24 * m2._42;
    result._23 = m1._21 * m2._13 + m1._22 * m2._23 + m1._23 * m2._33 + m1._24 * m2._43;
    result._24 = m1._21 * m2._14 + m1._22 * m2._24 + m1._23 * m2._34 + m1._24 * m2._44;
    result._31 = m1._31 * m2._11 + m1._32 * m2._21 + m1._33 * m2._31 + m1._34 * m2._41;
    result._32 = m1._31 * m2._12 + m1._32 * m2._22 + m1._33 * m2._32 + m1._34 * m2._42;
    result._33 = m1._31 * m2._13 + m1._32 * m2._23 + m1._33 * m2._33 + m1._34 * m2._43;
    result._34 = m1._31 * m2._14 + m1._32 * m2._24 + m1._33 * m2._34 + m1._34 * m2._44;
    result._41 = m1._41 * m2._11 + m1._42 * m2._21 + m1._43 * m2._31 + m1._44 * m2._41;
    result._42 = m1._41 * m2._12 + m1._42 * m2._22 + m1._43 * m2._32 + m1._44 * m2._42;
    result._43 = m1._41 * m2._13 + m1._42 * m2._23 + m1._43 * m2._33 + m1._44 * m2._43;
    result._44 = m1._41 * m2._14 + m1._42 * m2._24 + m1._43 * m2._34 + m1._44 * m2._44;
    return result;
end

--[[
* Transforms a 4D vector by a matrix (using D3DXVECTOR4)
--]]
local function vec4Transform(v, m)
    return ffi.new('D3DXVECTOR4', {
        m._11 * v.x + m._21 * v.y + m._31 * v.z + m._41 * v.w,
        m._12 * v.x + m._22 * v.y + m._32 * v.z + m._42 * v.w,
        m._13 * v.x + m._23 * v.y + m._33 * v.z + m._43 * v.w,
        m._14 * v.x + m._24 * v.y + m._34 * v.z + m._44 * v.w,
    });
end

--[[
* Converts world coordinates to screen coordinates
* Note: FFXI uses Y=up/down, Z=forward/back coordinate system
--]]
local function worldToScreen(x, y, z, view, projection, viewport)
    local vPoint = ffi.new('D3DXVECTOR4', { x, z, y, 1.0 });
    local viewProj = matrixMultiply(view, projection);
    local pCamera = vec4Transform(vPoint, viewProj);

    if pCamera.w <= 0.1 then
        return nil, nil;
    end

    local rhw = 1.0 / pCamera.w;
    local pNDC = ffi.new('D3DXVECTOR3', {
        pCamera.x * rhw,
        pCamera.y * rhw,
        pCamera.z * rhw
    });

    -- Very relaxed NDC bounds to allow large circles to render partially off-screen
    -- This prevents aggressive clipping of spell ranges and other large circles
    -- Using 5.0 allows circles to extend well beyond screen edges
    if pNDC.x < -5.0 or pNDC.x > 5.0 or pNDC.y < -5.0 or pNDC.y > 5.0 then
        return nil, nil;
    end

    local screenX = math.floor((pNDC.x + 1) * 0.5 * viewport.Width);
    local screenY = math.floor((1 - pNDC.y) * 0.5 * viewport.Height);

    return screenX, screenY, pNDC.z, rhw;
end

--[[
* Creates a cylinder around an entity using 3D line primitives
--]]
local function draw_entity_box(x, y, z, radius, view, projection, viewport)
    if x == nil or y == nil or z == nil or radius == nil then
        return false;
    end

    if radius > 50 then
        return false;
    end

    local centerSX = worldToScreen(x, y, z, view, projection, viewport);
    if centerSX == nil then
        return false;
    end

    local height = radius * 2;
    local segments = 12;

    local corners = {};
    for i = 0, segments - 1 do
        local cx = x + segment_angles[i][1] * radius;
        local cy = y + segment_angles[i][2] * radius;

        corners[i * 2 + 1] = { cx, cy, z - height };
        corners[i * 2 + 2] = { cx, cy, z };
    end

    local screenCorners = {};
    for i = 1, #corners do
        local sx, sy, sz, rhw = worldToScreen(corners[i][1], corners[i][2], corners[i][3], view, projection, viewport);
        if sx == nil then
            return false;
        end
        screenCorners[i] = { sx, sy, sz, rhw };
    end

    local numLines = segments * 3;
    local vertices = ffi.new('hitbox_vertex_t[?]', numLines * 2);
    local color = 0xFFFF00FF;

    local function setVertex(idx, cornerIdx)
        vertices[idx].x = screenCorners[cornerIdx][1];
        vertices[idx].y = screenCorners[cornerIdx][2];
        vertices[idx].z = 0.5;
        vertices[idx].rhw = 1.0;
        vertices[idx].color = color;
    end

    local vidx = 0;
    for i = 0, segments - 1 do
        local bottom1 = i * 2 + 1;
        local top1 = i * 2 + 2;
        local bottom2 = ((i + 1) % segments) * 2 + 1;
        local top2 = ((i + 1) % segments) * 2 + 2;

        setVertex(vidx, bottom1); setVertex(vidx + 1, bottom2); vidx = vidx + 2;
        setVertex(vidx, top1); setVertex(vidx + 1, top2); vidx = vidx + 2;
        setVertex(vidx, bottom1); setVertex(vidx + 1, top1); vidx = vidx + 2;
    end

    d3d8dev:DrawPrimitiveUP(C.D3DPT_LINELIST, numLines, vertices, ffi.sizeof('hitbox_vertex_t'));

    return true;
end

--[[
* Draws a red cross marker at entity center
--]]
local function draw_center_marker(x, y, z, view, projection, viewport)
    local centerX, centerY, centerZ, centerRhw = worldToScreen(x, y, z, view, projection, viewport);
    if centerX ~= nil then
        local dotSize = 10;
        local dotThickness = 2;
        local dotVertices = ffi.new('hitbox_vertex_t[?]', 20);
        local redColor = 0xFFFF0000;
        local idx = 0;

        for offset = -dotThickness, dotThickness do
            dotVertices[idx].x = centerX - dotSize;
            dotVertices[idx].y = centerY + offset;
            dotVertices[idx].z = 0.5;
            dotVertices[idx].rhw = 1.0;
            dotVertices[idx].color = redColor;
            idx = idx + 1;

            dotVertices[idx].x = centerX + dotSize;
            dotVertices[idx].y = centerY + offset;
            dotVertices[idx].z = 0.5;
            dotVertices[idx].rhw = 1.0;
            dotVertices[idx].color = redColor;
            idx = idx + 1;

            dotVertices[idx].x = centerX + offset;
            dotVertices[idx].y = centerY - dotSize;
            dotVertices[idx].z = 0.5;
            dotVertices[idx].rhw = 1.0;
            dotVertices[idx].color = redColor;
            idx = idx + 1;

            dotVertices[idx].x = centerX + offset;
            dotVertices[idx].y = centerY + dotSize;
            dotVertices[idx].z = 0.5;
            dotVertices[idx].rhw = 1.0;
            dotVertices[idx].color = redColor;
            idx = idx + 1;
        end

        d3d8dev:DrawPrimitiveUP(C.D3DPT_LINELIST, 10, dotVertices, ffi.sizeof('hitbox_vertex_t'));
    end
end

--[[
* Converts RGBA floats (0-1) to ARGB hex color
--]]
local function rgba_to_argb(r, g, b, a)
    local ar = math.floor(a * 255);
    local rr = math.floor(r * 255);
    local gg = math.floor(g * 255);
    local bb = math.floor(b * 255);
    return bit.bor(bit.lshift(ar, 24), bit.lshift(rr, 16), bit.lshift(gg, 8), bb);
end

--[[
* Draws a filled AoE circle on the ground at target position
* inner_radius: optional parameter to create a ring/donut shape (only fills between inner and outer radius)
* draw_outline: optional parameter to draw black outlines on inner and outer edges
--]]
local function draw_aoe_circle(x, y, z, radius, color_rgba, view, projection, viewport, inner_radius, draw_outline,
                               z_offset)
    if x == nil or y == nil or z == nil or radius == nil then
        return false;
    end

    local centerSX = worldToScreen(x, y, z, view, projection, viewport);
    if centerSX == nil then
        return false;
    end

    local segments = 48;
    inner_radius = inner_radius or 0;     -- Default to full circle if no inner radius specified
    draw_outline = draw_outline or false; -- Default to no outline
    z_offset = z_offset or 0.5;           -- Default Z value for screen space

    local aoeColor = rgba_to_argb(color_rgba[1], color_rgba[2], color_rgba[3], color_rgba[4]);

    if inner_radius > 0 then
        -- Draw ring/donut shape using quads between inner and outer radius
        local vertices = ffi.new('hitbox_vertex_t[?]', segments * 6); -- 2 triangles per segment
        local vidx = 0;

        for i = 0, segments - 1 do
            local theta1 = (i / segments) * 2 * math.pi;
            local theta2 = ((i + 1) / segments) * 2 * math.pi;

            -- Outer circle points
            local x1_outer = x + math.cos(theta1) * radius;
            local y1_outer = y + math.sin(theta1) * radius;
            local x2_outer = x + math.cos(theta2) * radius;
            local y2_outer = y + math.sin(theta2) * radius;

            -- Inner circle points
            local x1_inner = x + math.cos(theta1) * inner_radius;
            local y1_inner = y + math.sin(theta1) * inner_radius;
            local x2_inner = x + math.cos(theta2) * inner_radius;
            local y2_inner = y + math.sin(theta2) * inner_radius;

            local sx1_outer, sy1_outer = worldToScreen(x1_outer, y1_outer, z, view, projection, viewport);
            local sx2_outer, sy2_outer = worldToScreen(x2_outer, y2_outer, z, view, projection, viewport);
            local sx1_inner, sy1_inner = worldToScreen(x1_inner, y1_inner, z, view, projection, viewport);
            local sx2_inner, sy2_inner = worldToScreen(x2_inner, y2_inner, z, view, projection, viewport);

            if sx1_outer and sx2_outer and sx1_inner and sx2_inner then
                -- First triangle: inner1, outer1, outer2
                vertices[vidx].x = sx1_inner;
                vertices[vidx].y = sy1_inner;
                vertices[vidx].z = z_offset;
                vertices[vidx].rhw = 1.0;
                vertices[vidx].color = aoeColor;
                vidx = vidx + 1;

                vertices[vidx].x = sx1_outer;
                vertices[vidx].y = sy1_outer;
                vertices[vidx].z = z_offset;
                vertices[vidx].rhw = 1.0;
                vertices[vidx].color = aoeColor;
                vidx = vidx + 1;

                vertices[vidx].x = sx2_outer;
                vertices[vidx].y = sy2_outer;
                vertices[vidx].z = z_offset;
                vertices[vidx].rhw = 1.0;
                vertices[vidx].color = aoeColor;
                vidx = vidx + 1;

                -- Second triangle: inner1, outer2, inner2
                vertices[vidx].x = sx1_inner;
                vertices[vidx].y = sy1_inner;
                vertices[vidx].z = z_offset;
                vertices[vidx].rhw = 1.0;
                vertices[vidx].color = aoeColor;
                vidx = vidx + 1;

                vertices[vidx].x = sx2_outer;
                vertices[vidx].y = sy2_outer;
                vertices[vidx].z = z_offset;
                vertices[vidx].rhw = 1.0;
                vertices[vidx].color = aoeColor;
                vidx = vidx + 1;

                vertices[vidx].x = sx2_inner;
                vertices[vidx].y = sy2_inner;
                vertices[vidx].z = z_offset;
                vertices[vidx].rhw = 1.0;
                vertices[vidx].color = aoeColor;
                vidx = vidx + 1;
            end
        end

        if vidx > 0 then
            d3d8dev:DrawPrimitiveUP(C.D3DPT_TRIANGLELIST, vidx / 3, vertices, ffi.sizeof('hitbox_vertex_t'));
        end

        -- Draw black outlines for the ring
        if draw_outline then
            local blackColor = 0xFF000000;
            local lineVertices = ffi.new('hitbox_vertex_t[?]', segments * 4); -- 2 lines per segment (inner and outer)
            local lvidx = 0;

            for i = 0, segments - 1 do
                local theta1 = (i / segments) * 2 * math.pi;
                local theta2 = ((i + 1) / segments) * 2 * math.pi;

                -- Outer circle line
                local x1_outer = x + math.cos(theta1) * radius;
                local y1_outer = y + math.sin(theta1) * radius;
                local x2_outer = x + math.cos(theta2) * radius;
                local y2_outer = y + math.sin(theta2) * radius;

                local sx1_outer, sy1_outer = worldToScreen(x1_outer, y1_outer, z, view, projection, viewport);
                local sx2_outer, sy2_outer = worldToScreen(x2_outer, y2_outer, z, view, projection, viewport);

                if sx1_outer ~= nil and sx2_outer ~= nil then
                    lineVertices[lvidx].x = sx1_outer;
                    lineVertices[lvidx].y = sy1_outer;
                    lineVertices[lvidx].z = z_offset;
                    lineVertices[lvidx].rhw = 1.0;
                    lineVertices[lvidx].color = blackColor;
                    lvidx = lvidx + 1;

                    lineVertices[lvidx].x = sx2_outer;
                    lineVertices[lvidx].y = sy2_outer;
                    lineVertices[lvidx].z = z_offset;
                    lineVertices[lvidx].rhw = 1.0;
                    lineVertices[lvidx].color = blackColor;
                    lvidx = lvidx + 1;
                end

                -- Inner circle line
                local x1_inner = x + math.cos(theta1) * inner_radius;
                local y1_inner = y + math.sin(theta1) * inner_radius;
                local x2_inner = x + math.cos(theta2) * inner_radius;
                local y2_inner = y + math.sin(theta2) * inner_radius;

                local sx1_inner, sy1_inner = worldToScreen(x1_inner, y1_inner, z, view, projection, viewport);
                local sx2_inner, sy2_inner = worldToScreen(x2_inner, y2_inner, z, view, projection, viewport);

                if sx1_inner ~= nil and sx2_inner ~= nil then
                    lineVertices[lvidx].x = sx1_inner;
                    lineVertices[lvidx].y = sy1_inner;
                    lineVertices[lvidx].z = z_offset;
                    lineVertices[lvidx].rhw = 1.0;
                    lineVertices[lvidx].color = blackColor;
                    lvidx = lvidx + 1;

                    lineVertices[lvidx].x = sx2_inner;
                    lineVertices[lvidx].y = sy2_inner;
                    lineVertices[lvidx].z = z_offset;
                    lineVertices[lvidx].rhw = 1.0;
                    lineVertices[lvidx].color = blackColor;
                    lvidx = lvidx + 1;
                end
            end

            if lvidx > 0 then
                d3d8dev:DrawPrimitiveUP(C.D3DPT_LINELIST, lvidx / 2, lineVertices, ffi.sizeof('hitbox_vertex_t'));
            end
        end
    else
        -- Draw full circle (original triangle fan approach)
        local vertices = ffi.new('hitbox_vertex_t[?]', segments * 3);
        local vidx = 0;

        local centerGroundSX, centerGroundSY = worldToScreen(x, y, z, view, projection, viewport);
        if centerGroundSX then
            for i = 0, segments - 1 do
                local theta1 = (i / segments) * 2 * math.pi;
                local theta2 = ((i + 1) / segments) * 2 * math.pi;

                local x1 = x + math.cos(theta1) * radius;
                local y1 = y + math.sin(theta1) * radius;
                local x2 = x + math.cos(theta2) * radius;
                local y2 = y + math.sin(theta2) * radius;

                local sx1, sy1 = worldToScreen(x1, y1, z, view, projection, viewport);
                local sx2, sy2 = worldToScreen(x2, y2, z, view, projection, viewport);

                if sx1 ~= nil and sx2 ~= nil then
                    vertices[vidx].x = centerGroundSX;
                    vertices[vidx].y = centerGroundSY;
                    vertices[vidx].z = z_offset;
                    vertices[vidx].rhw = 1.0;
                    vertices[vidx].color = aoeColor;
                    vidx = vidx + 1;

                    vertices[vidx].x = sx1;
                    vertices[vidx].y = sy1;
                    vertices[vidx].z = z_offset;
                    vertices[vidx].rhw = 1.0;
                    vertices[vidx].color = aoeColor;
                    vidx = vidx + 1;

                    vertices[vidx].x = sx2;
                    vertices[vidx].y = sy2;
                    vertices[vidx].z = z_offset;
                    vertices[vidx].rhw = 1.0;
                    vertices[vidx].color = aoeColor;
                    vidx = vidx + 1;
                end
            end

            if vidx > 0 then
                d3d8dev:DrawPrimitiveUP(C.D3DPT_TRIANGLELIST, vidx / 3, vertices, ffi.sizeof('hitbox_vertex_t'));
            end

            -- Draw black outline for full circle
            if draw_outline then
                local blackColor = 0xFF000000;
                local lineVertices = ffi.new('hitbox_vertex_t[?]', segments * 2);
                local lvidx = 0;

                for i = 0, segments - 1 do
                    local theta1 = (i / segments) * 2 * math.pi;
                    local theta2 = ((i + 1) / segments) * 2 * math.pi;

                    local x1 = x + math.cos(theta1) * radius;
                    local y1 = y + math.sin(theta1) * radius;
                    local x2 = x + math.cos(theta2) * radius;
                    local y2 = y + math.sin(theta2) * radius;

                    local sx1, sy1 = worldToScreen(x1, y1, z, view, projection, viewport);
                    local sx2, sy2 = worldToScreen(x2, y2, z, view, projection, viewport);

                    if sx1 ~= nil and sx2 ~= nil then
                        lineVertices[lvidx].x = sx1;
                        lineVertices[lvidx].y = sy1;
                        lineVertices[lvidx].z = z_offset;
                        lineVertices[lvidx].rhw = 1.0;
                        lineVertices[lvidx].color = blackColor;
                        lvidx = lvidx + 1;

                        lineVertices[lvidx].x = sx2;
                        lineVertices[lvidx].y = sy2;
                        lineVertices[lvidx].z = z_offset;
                        lineVertices[lvidx].rhw = 1.0;
                        lineVertices[lvidx].color = blackColor;
                        lvidx = lvidx + 1;
                    end
                end

                if lvidx > 0 then
                    d3d8dev:DrawPrimitiveUP(C.D3DPT_LINELIST, lvidx / 2, lineVertices, ffi.sizeof('hitbox_vertex_t'));
                end
            end
        end
    end

    return true;
end

--[[
* event: command
--]]
ashita.events.register('command', 'command_cb', function(e)
    local args = e.command:args();
    if #args == 0 or args[1] ~= '/hitboxdisplay' then
        return;
    end

    e.blocked = true;
    ui.show_config_window[1] = not ui.show_config_window[1];
end);

--[[
* event: d3d_present (for ImGui rendering)
--]]
ashita.events.register('d3d_present', 'imgui_present_cb', function()
    show_hitboxes = ui.render(config, show_hitboxes, RACE_DATA, RADIUS_STR, RACE_STR);
end);

--[[
* event: d3d_present (for hitbox rendering)
--]]
ashita.events.register('d3d_present', 'hitbox_present_cb', function()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if party:GetMemberIsActive(0) == 0 then
        return;
    end

    local player = GetPlayerEntity();
    if player == nil or player.Movement == nil or player.Movement.LocalPosition == nil then
        return;
    end

    local px = player.Movement.LocalPosition.X;
    local py = player.Movement.LocalPosition.Y;
    local pz = player.Movement.LocalPosition.Z;

    local _, viewOrig = d3d8dev:GetTransform(C.D3DTS_VIEW);
    local _, projectionOrig = d3d8dev:GetTransform(C.D3DTS_PROJECTION);
    local _, viewportOrig = d3d8dev:GetViewport();

    if viewOrig == nil or projectionOrig == nil or viewportOrig == nil then
        return;
    end

    -- Copy matrices to prevent garbage collection issues
    local view = ffi.new('D3DXMATRIX');
    ffi.copy(view, viewOrig, ffi.sizeof('D3DXMATRIX'));

    local projection = ffi.new('D3DXMATRIX');
    ffi.copy(projection, projectionOrig, ffi.sizeof('D3DXMATRIX'));

    -- Copy viewport to prevent garbage collection issues
    local viewport = ffi.new('D3DVIEWPORT8');
    ffi.copy(viewport, viewportOrig, ffi.sizeof('D3DVIEWPORT8'));

    local _, oldZEnable = d3d8dev:GetRenderState(C.D3DRS_ZENABLE);
    local _, oldZWriteEnable = d3d8dev:GetRenderState(C.D3DRS_ZWRITEENABLE);
    local _, oldAlphaBlend = d3d8dev:GetRenderState(C.D3DRS_ALPHABLENDENABLE);
    local _, oldSrcBlend = d3d8dev:GetRenderState(C.D3DRS_SRCBLEND);
    local _, oldDestBlend = d3d8dev:GetRenderState(C.D3DRS_DESTBLEND);

    local FVF = bit.bor(C.D3DFVF_XYZRHW, C.D3DFVF_DIFFUSE);
    d3d8dev:SetVertexShader(FVF);
    d3d8dev:SetTexture(0, nil);
    d3d8dev:SetTextureStageState(0, C.D3DTSS_COLOROP, C.D3DTOP_DISABLE);
    d3d8dev:SetRenderState(C.D3DRS_LIGHTING, 0);
    d3d8dev:SetRenderState(C.D3DRS_CULLMODE, C.D3DCULL_NONE);
    d3d8dev:SetRenderState(C.D3DRS_ALPHABLENDENABLE, 1);
    d3d8dev:SetRenderState(C.D3DRS_SRCBLEND, C.D3DBLEND_SRCALPHA);
    d3d8dev:SetRenderState(C.D3DRS_DESTBLEND, C.D3DBLEND_INVSRCALPHA);
    d3d8dev:SetRenderState(C.D3DRS_ZENABLE, C.D3DZB_FALSE);
    d3d8dev:SetRenderState(C.D3DRS_ZWRITEENABLE, 0);

    local total = 0;
    local drawn = 0;

    local new_entity_positions = {};

    for i = 0, 2303 do
        local entity = GetEntity(i);
        if entity ~= nil and entity.WarpPointer ~= 0 then
            if entity.Movement ~= nil and entity.Movement.LocalPosition ~= nil then
                local ex = entity.Movement.LocalPosition.X;
                local ey = entity.Movement.LocalPosition.Y;
                local ez = entity.Movement.LocalPosition.Z;

                if ex ~= nil and ey ~= nil and ez ~= nil then
                    if not (ex == 0 and ey == 0 and ez == 0) then
                        local hitbox = entity.ModelHitboxSize;
                        if hitbox ~= nil and hitbox > 0 and hitbox < 100 then
                            local last_pos = last_entity_positions[i];
                            local position_valid = true;
                            local changeSq = 0;

                            if last_pos then
                                local dx = ex - last_pos.x;
                                local dy = ey - last_pos.y;
                                local dz = ez - last_pos.z;
                                changeSq = dx * dx + dy * dy + dz * dz;

                                if changeSq > 20 * 20 then
                                    position_valid = false;
                                end

                                local hitbox_change = math.abs(hitbox - last_pos.hitbox);
                                if hitbox_change > 10 then
                                    position_valid = false;
                                end
                            end

                            if position_valid then
                                -- If position barely changed, use the cached position to prevent jitter
                                if last_pos and changeSq < 0.0001 then
                                    new_entity_positions[i] = last_pos;
                                else
                                    new_entity_positions[i] = { x = ex, y = ey, z = ez, hitbox = hitbox };
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    last_entity_positions = entity_positions;
    entity_positions = new_entity_positions;

    local targetIndex = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0);

    for i, pos in pairs(entity_positions) do
        local entity = GetEntity(i);
        if entity ~= nil and entity.SpawnFlags ~= 0 and entity.HPPercent > 0 and entity.Status ~= 2 and entity.Status ~= 3 then
            local dx = pos.x - px;
            local dy = pos.y - py;
            local dz = pos.z - pz;
            local distSq = dx * dx + dy * dy + dz * dz;

            if distSq <= 50 * 50 and pos.hitbox ~= nil and pos.hitbox > 0 then
                if show_hitboxes then
                    total = total + 1;
                    if draw_entity_box(pos.x, pos.y, pos.z, pos.hitbox, view, projection, viewport) then
                        drawn = drawn + 1;
                    end
                end

                -- Draw center marker independently of hitbox display
                if config.show_center_marker[1] then
                    draw_center_marker(pos.x, pos.y, pos.z, view, projection, viewport);
                end

                if i == targetIndex then
                    -- Melee range visualization (based on target's hitbox)
                    if config.melee_range.enabled[1] then
                        local base_melee_range = pos.hitbox + 2.0;

                        -- Draw base melee range circle (inner circle)
                        draw_aoe_circle(pos.x, pos.y, pos.z, base_melee_range, config.melee_range.base_color, view,
                            projection, viewport, 0, true);

                        if config.melee_range.show_all_races[1] then
                            -- Draw all race rings
                            local prev_range = base_melee_range;
                            for race_idx = 1, 3 do
                                if config.melee_range.race_enabled[race_idx][1] then
                                    local race_range = base_melee_range + RACE_DATA.modifiers[race_idx];
                                    draw_aoe_circle(pos.x, pos.y, pos.z, race_range,
                                        config.melee_range.race_colors[race_idx], view, projection, viewport, prev_range,
                                        true);
                                    prev_range = race_range;
                                end
                            end
                        else
                            -- Draw only selected race ring
                            local race_mod = RACE_DATA.modifiers[config.selected_race[1] + 1];
                            local melee_range = base_melee_range + race_mod;
                            draw_aoe_circle(pos.x, pos.y, pos.z, melee_range, config.melee_range.base_color, view,
                                projection, viewport, base_melee_range, true);
                        end

                        -- Draw text labels for melee ranges positioned next to the target
                        local targetScreenX, targetScreenY = worldToScreen(pos.x, pos.y, pos.z, view, projection,
                            viewport);
                        if targetScreenX and targetScreenY then
                            -- Position the window to the right of the target with some offset
                            local label_offset_x = 50;  -- Offset from target position
                            local label_offset_y = -50; -- Offset from target position (negative to move up)

                            imgui.SetNextWindowPos({ targetScreenX + label_offset_x, targetScreenY + label_offset_y });
                            imgui.SetNextWindowBgAlpha(0.7);
                            imgui.Begin('Melee Range Info', nil,
                                bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize,
                                    ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoMove,
                                    ImGuiWindowFlags_NoSavedSettings));
                            imgui.TextColored(
                                { config.melee_range.base_color[1], config.melee_range.base_color[2], config.melee_range
                                    .base_color[3], 1.0 },
                                string.format('Base: %.1f', base_melee_range));

                            if config.melee_range.show_all_races[1] then
                                -- Show all race ranges
                                for race_idx = 1, 3 do
                                    if config.melee_range.race_enabled[race_idx][1] then
                                        local race_range = base_melee_range + RACE_DATA.modifiers[race_idx];
                                        local color = config.melee_range.race_colors[race_idx];
                                        imgui.TextColored({ color[1], color[2], color[3], 1.0 },
                                            string.format('%s: %.1f', RACE_DATA.names[race_idx], race_range));
                                    end
                                end
                            else
                                -- Show only selected race
                                local race_mod = RACE_DATA.modifiers[config.selected_race[1] + 1];
                                local melee_range = base_melee_range + race_mod;
                                imgui.TextColored(
                                    { config.melee_range.base_color[1], config.melee_range.base_color[2], config
                                        .melee_range.base_color[3], 1.0 },
                                    string.format('%s: %.1f', RACE_DATA.names[config.selected_race[1] + 1], melee_range));
                            end
                            imgui.End();
                        end
                    end

                    -- Spell range visualization (configurable base range + hitbox)
                    if config.spell_range.enabled[1] then
                        local base_spell_range = AOE_RADIUS_VALUES[config.spell_range.radius_index[1] + 1] + pos.hitbox;

                        -- Draw base spell range circle (inner circle)
                        draw_aoe_circle(pos.x, pos.y, pos.z, base_spell_range, config.spell_range.base_color, view,
                            projection, viewport, 0, true);

                        if config.spell_range.show_all_races[1] then
                            -- Draw all race rings
                            local prev_range = base_spell_range;
                            for race_idx = 1, 3 do
                                if config.spell_range.race_enabled[race_idx][1] then
                                    local race_range = base_spell_range + RACE_DATA.modifiers[race_idx];
                                    draw_aoe_circle(pos.x, pos.y, pos.z, race_range,
                                        config.spell_range.race_colors[race_idx], view, projection, viewport, prev_range,
                                        true);
                                    prev_range = race_range;
                                end
                            end
                        else
                            -- Draw only selected race ring
                            local race_mod = RACE_DATA.modifiers[config.selected_race[1] + 1];
                            local spell_range = base_spell_range + race_mod;
                            draw_aoe_circle(pos.x, pos.y, pos.z, spell_range, config.spell_range.base_color, view,
                                projection, viewport, base_spell_range, true);
                        end

                        -- Draw text labels for spell ranges positioned next to the target
                        local targetScreenX, targetScreenY = worldToScreen(pos.x, pos.y, pos.z, view, projection,
                            viewport);
                        if targetScreenX and targetScreenY then
                            -- Position the window to the right of the melee range info
                            local label_offset_x = 50; -- Offset from target position
                            local label_offset_y = 50; -- Offset from target position (positive to move down, below melee range)

                            imgui.SetNextWindowPos({ targetScreenX + label_offset_x, targetScreenY + label_offset_y });
                            imgui.SetNextWindowBgAlpha(0.7);
                            imgui.Begin('Spell Range Info', nil,
                                bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize,
                                    ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoMove,
                                    ImGuiWindowFlags_NoSavedSettings));
                            imgui.TextColored(
                                { config.spell_range.base_color[1], config.spell_range.base_color[2], config.spell_range
                                    .base_color[3], 1.0 },
                                string.format('Base: %.1f', base_spell_range));

                            if config.spell_range.show_all_races[1] then
                                -- Show all race ranges
                                for race_idx = 1, 3 do
                                    if config.spell_range.race_enabled[race_idx][1] then
                                        local race_range = base_spell_range + RACE_DATA.modifiers[race_idx];
                                        local color = config.spell_range.race_colors[race_idx];
                                        imgui.TextColored({ color[1], color[2], color[3], 1.0 },
                                            string.format('%s: %.1f', RACE_DATA.names[race_idx], race_range));
                                    end
                                end
                            else
                                -- Show only selected race
                                local race_mod = RACE_DATA.modifiers[config.selected_race[1] + 1];
                                local spell_range = base_spell_range + race_mod;
                                imgui.TextColored(
                                    { config.spell_range.base_color[1], config.spell_range.base_color[2], config
                                        .spell_range.base_color[3], 1.0 },
                                    string.format('%s: %.1f', RACE_DATA.names[config.selected_race[1] + 1], spell_range));
                            end
                            imgui.End();
                        end
                    end

                    -- Ranged Sweet Spot Visualization
                    if config.ranged_sweet_spot.enabled[1] then
                        -- Collect enabled weapons and sort by max range (largest first)
                        local enabled_weapons = {};
                        for _, weapon in ipairs(config.ranged_sweet_spot.weapons) do
                            if weapon.enabled[1] then
                                table.insert(enabled_weapons, weapon);
                            end
                        end

                        -- Sort by max range descending (largest first, so smallest renders on top)
                        table.sort(enabled_weapons, function(a, b) return a.max > b.max end);

                        -- Draw all enabled weapon types (largest to smallest)
                        local race_mod = RACE_DATA.modifiers[config.selected_race[1] + 1];
                        for _, weapon in ipairs(enabled_weapons) do
                            -- Calculate min and max ranges (add hitbox and race modifier to the base ranges)
                            local min_range = weapon.min + pos.hitbox + race_mod;
                            local max_range = weapon.max + pos.hitbox + race_mod;

                            -- Draw the sweet spot as a ring from min to max with black outline
                            draw_aoe_circle(pos.x, pos.y, pos.z, max_range, weapon.color, view, projection, viewport,
                                min_range, true);
                        end

                        -- Draw max ranged attack range marker (25 yalms, not modified by hitbox)
                        local red_color = { 1.0, 0.0, 0.0, 1.0 }; -- Solid red
                        draw_aoe_circle(pos.x, pos.y, pos.z, 25.0, red_color, view, projection, viewport, 24.8, true);

                        -- Draw text labels for ranged sweet spots positioned below spell range
                        -- Only show window if at least one weapon is enabled
                        if #enabled_weapons > 0 then
                            local targetScreenX, targetScreenY = worldToScreen(pos.x, pos.y, pos.z, view, projection,
                                viewport);
                            if targetScreenX and targetScreenY then
                                local label_offset_x = 50;
                                local label_offset_y = 150; -- Below spell range info

                                imgui.SetNextWindowPos({ targetScreenX + label_offset_x, targetScreenY + label_offset_y });
                                imgui.SetNextWindowSize({ 300, 0 }, ImGuiCond_FirstUseEver);
                                imgui.SetNextWindowBgAlpha(0.7);
                                imgui.Begin('Ranged Sweet Spot Info', nil,
                                    bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize,
                                        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoMove,
                                        ImGuiWindowFlags_NoSavedSettings));

                                -- Display in same order as rendering (sorted by max range)
                                for _, weapon in ipairs(enabled_weapons) do
                                    local min_range = weapon.min + pos.hitbox + race_mod;
                                    local max_range = weapon.max + pos.hitbox + race_mod;
                                    imgui.TextColored({ weapon.color[1], weapon.color[2], weapon.color[3], 1.0 },
                                        string.format('%s: %.1f - %.1f', weapon.name, min_range, max_range));
                                end

                                imgui.End();
                            end
                        end
                    end

                    -- Base AoE circle (static radius)
                    if config.base_aoe.enabled[1] then
                        local radius = AOE_RADIUS_VALUES[config.base_aoe.radius_index[1] + 1];
                        draw_aoe_circle(pos.x, pos.y, pos.z, radius, config.base_aoe.color, view, projection, viewport, 0,
                            true);
                    end
                end
            end
        end
    end

    d3d8dev:SetRenderState(C.D3DRS_ZENABLE, oldZEnable);
    d3d8dev:SetRenderState(C.D3DRS_ZWRITEENABLE, oldZWriteEnable);
    d3d8dev:SetRenderState(C.D3DRS_ALPHABLENDENABLE, oldAlphaBlend);
    d3d8dev:SetRenderState(C.D3DRS_SRCBLEND, oldSrcBlend);
    d3d8dev:SetRenderState(C.D3DRS_DESTBLEND, oldDestBlend);
end);
