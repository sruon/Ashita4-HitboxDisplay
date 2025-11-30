local imgui = require('imgui');

local ui = {};

-- UI state
ui.show_config_window = { true };

--[[
* Renders the configuration window
* @param config - The addon configuration table
* @param show_hitboxes - The show hitboxes flag
* @param RACE_DATA - Race data table
* @param RADIUS_STR - Pre-computed radius combo string
* @param RACE_STR - Pre-computed race combo string
--]]
function ui.render(config, show_hitboxes, RACE_DATA, RADIUS_STR, RACE_STR)
    if not ui.show_config_window[1] then return show_hitboxes; end

    imgui.SetNextWindowSize({ 450, 500, }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('Hitbox Display Configuration', ui.show_config_window)) then
        if imgui.Checkbox('Show Hitboxes', { show_hitboxes }) then
            show_hitboxes = not show_hitboxes;
        end

        imgui.Checkbox('Show Center Marker', config.show_center_marker);

        imgui.Checkbox('Show Melee Range', config.melee_range.enabled);
        if config.melee_range.enabled[1] then
            imgui.SameLine();
            imgui.Checkbox('Show All Races##melee', config.melee_range.show_all_races);
            imgui.SameLine();
            imgui.SetNextItemWidth(200);
            imgui.ColorEdit4('Melee Color', config.melee_range.base_color);
            for race_idx = 1, 3 do
                imgui.Text('  ' .. RACE_DATA.names[race_idx]);
                imgui.SameLine(140);
                imgui.Checkbox('##melee_race_' .. race_idx, config.melee_range.race_enabled[race_idx]);
                if config.melee_range.race_enabled[race_idx][1] then
                    imgui.SameLine();
                    imgui.SetNextItemWidth(200);
                    imgui.ColorEdit4('##melee_color_' .. race_idx, config.melee_range.race_colors[race_idx]);
                end
            end
        end

        imgui.Checkbox('Show Spell Range', config.spell_range.enabled);
        if config.spell_range.enabled[1] then
            imgui.Checkbox('Show All Races##spell', config.spell_range.show_all_races);
            imgui.SetNextItemWidth(120);
            imgui.Combo('Range##spell', config.spell_range.radius_index, RADIUS_STR);
            imgui.SetNextItemWidth(200);
            imgui.ColorEdit4('Spell Color', config.spell_range.base_color);
            for race_idx = 1, 3 do
                imgui.Text('  ' .. RACE_DATA.names[race_idx]);
                imgui.SameLine(140);
                imgui.Checkbox('##spell_race_' .. race_idx, config.spell_range.race_enabled[race_idx]);
                if config.spell_range.race_enabled[race_idx][1] then
                    imgui.SameLine();
                    imgui.SetNextItemWidth(200);
                    imgui.ColorEdit4('##spell_color_' .. race_idx, config.spell_range.race_colors[race_idx]);
                end
            end
        end

        imgui.Checkbox('Show Ranged Sweet Spot', config.ranged_sweet_spot.enabled);
        if config.ranged_sweet_spot.enabled[1] then
            imgui.Text('Race:');
            imgui.SetNextItemWidth(180);
            imgui.Combo('##RaceSelection', config.selected_race, RACE_STR);
            for i, weapon in ipairs(config.ranged_sweet_spot.weapons) do
                imgui.Text('  ' .. weapon.name .. string.format(' (%.1f-%.1f)', weapon.min, weapon.max));
                imgui.SameLine(200);
                imgui.Checkbox('##weapon_' .. i, weapon.enabled);
                if weapon.enabled[1] then
                    imgui.SameLine();
                    imgui.SetNextItemWidth(200);
                    imgui.ColorEdit4('##weapon_color_' .. i, weapon.color);
                end
            end
        end

        imgui.Checkbox('Show AoE Circle', config.base_aoe.enabled);
        if config.base_aoe.enabled[1] then
            imgui.SameLine();
            imgui.SetNextItemWidth(120);
            imgui.Combo('Radius##aoe', config.base_aoe.radius_index, RADIUS_STR);
            imgui.SameLine();
            imgui.SetNextItemWidth(200);
            imgui.ColorEdit4('AoE Color', config.base_aoe.color);
        end
    end
    imgui.End();

    return show_hitboxes;
end

return ui;
