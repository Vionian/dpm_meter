local mod = get_mod("dpm_meter")
local UIWidget = require("scripts/managers/ui/ui_widget")

-- ####################################################################################################################
-- # 工具函数：数学与格式化 (MATH & FORMAT)
-- ####################################################################################################################

-- Frame-rate independent smoothing. Unlike `current + delta * dt`, the
-- exponential form reaches the same point in real time at 30/60/144 FPS.
local function smooth_towards(current, target, dt, response)
    current = tonumber(current) or 0
    target = tonumber(target) or 0
    dt = math.max(0, tonumber(dt) or 0)
    response = math.max(0.01, tonumber(response) or 5)

    if dt <= 0 then
        return current
    end

    local blend = 1 - math.exp(-response * dt)
    local value = current + (target - current) * blend

    -- Avoid spending frames rendering an imperceptible tail.
    if math.abs(value - target) < 0.05 then
        return target
    end

    return value
end

-- 格式化为 K 单位 (例如 12500 -> 12.5K)
local function format_k(number)
    if not number then return "0.0K" end
    return string.format("%.1fK", number / 1000)
end

-- ####################################################################################################################
-- # 常量与配置 (CONSTANTS & CONFIG)
-- ####################################################################################################################
local WINDOW_SIZE = 60 -- 滑动窗口大小（秒）
local TEXT_MAX_CHARS = 32
local TEXT_HEIGHT = 42
local gradient_time = 0

local valid_font_types = {
    proxima_nova_bold = true,
    proxima_nova_medium = true,
    machine_medium = true,
    arial = true,
    trim_mono_bold = true,
    itc_novarese_medium = true,
    itc_novarese_bold = true,
    friz_quadrata = true,
    rexlia = true,
}

local function _parse_hex_color(value)
    if type(value) ~= "string" then return nil end

    local hex = value:gsub("^%s+", ""):gsub("%s+$", "")
    hex = hex:gsub("^#", "")
    if #hex == 3 then
        hex = hex:sub(1, 1) .. hex:sub(1, 1) .. hex:sub(2, 2) .. hex:sub(2, 2) .. hex:sub(3, 3) .. hex:sub(3, 3)
    end
    if #hex ~= 6 or not hex:match("^[%da-fA-F]+$") then return nil end

    return {
        tonumber(hex:sub(1, 2), 16),
        tonumber(hex:sub(3, 4), 16),
        tonumber(hex:sub(5, 6), 16),
    }
end

local function _hex_color(value, fallback)
    local color = _parse_hex_color(value)
    if color then return color end
    return _parse_hex_color(fallback) or {255, 255, 255}
end

local function _text_setting(setting_id, fallback)
    local value = mod:get(setting_id)
    if type(value) == "table" then value = value[1] end
    if type(value) ~= "string" or value == "" then
        value = fallback
        mod:set(setting_id, value)
    end
    return value
end

local function _number_setting(setting_id, fallback, minimum, maximum)
    local value = mod:get(setting_id)
    if type(value) == "table" then value = value[1] end
    value = tonumber(value) or fallback
    if minimum then value = math.max(minimum, value) end
    if maximum then value = math.min(maximum, value) end
    return value
end

-- Text inputs were added after the first versions of this mod. Migrate old
-- numeric values before DMF builds its text-input widgets, so the widget
-- always receives a string and old user settings remain useful.
local function _migrate_text_settings()
    local old_gradient_settings = mod:get("gradient_shimmer_speed")
    local has_new_gradient_settings = type(old_gradient_settings) == "string" and old_gradient_settings ~= ""

    local text_defaults = {
        panel_x_offset = "0",
        panel_y_offset = "0",
        font_size = "28",
        anim_speed = "5",
        gradient_animation_speed = "0.35",
        gradient_opacity = "100",
        gradient_shimmer_speed = "0.8",
        gradient_shimmer_strength = "0.75",
    }

    for setting_id, fallback in pairs(text_defaults) do
        local value = mod:get(setting_id)
        if type(value) == "table" then value = value[1] end
        if value == nil or value == "" then value = fallback end
        mod:set(setting_id, tostring(value))
    end

    local color_defaults = {
        {"text_color_hex", "#FFFFFF"},
        {"gradient_start_hex", "#2F4FEE"},
        {"gradient_middle_hex", "#5B9CFF"},
        {"gradient_end_hex", "#3DE8FF"},
    }

    for i = 1, #color_defaults do
        local item = color_defaults[i]
        local value = mod:get(item[1])
        if type(value) == "table" then value = value[1] end
        if not _parse_hex_color(value) then
            -- RGB fields belong to the old UI. New installations and old
            -- installations without hex values get the Discord-like palette.
            value = item[2]
        end
        mod:set(item[1], value)
    end

    if not has_new_gradient_settings and mod:get("gradient_animation") == "flow" then
        mod:set("gradient_animation", "static")
    end
end

pcall(_migrate_text_settings)

-- ####################################################################################################################
-- # 状态管理 (STATE MANAGEMENT)
-- ####################################################################################################################
mod.player_data = {}
mod.player_data_by_id = mod:persistent_table("player_data_by_id")
mod.display_values = mod:persistent_table("display_values") -- 存储用于显示的平滑数值
mod.unit_to_player_id = {}
mod._runtime = mod:persistent_table("runtime")
mod._runtime.reload_count = (mod._runtime.reload_count or 0) + 1
mod.mission_start_time = nil
mod.is_in_gameplay = false
mod._ui_patched_personal = false
-- mod._ui_patched_team 已移除
mod._ui_widget_created_personal = false
-- mod._ui_widget_created_team 已移除

local function _clear_table_in_place(t)
    if type(t) ~= "table" then return end
    for k in pairs(t) do t[k] = nil end
end

function mod.on_reload(self)
    _clear_table_in_place(mod.display_values)
end

function mod.on_game_state_changed(status, state_name)
    if state_name ~= "StateGameplay" then return end

    if status == "enter" then
        if not mod._runtime.in_state_gameplay then
            _clear_table_in_place(mod.player_data_by_id)
            _clear_table_in_place(mod.unit_to_player_id)
            _clear_table_in_place(mod.display_values)
            mod.mission_start_time = nil
            mod.is_in_gameplay = false
            mod._runtime.had_damage_events = false
        end
        mod._runtime.in_state_gameplay = true
        return
    end

    if status == "exit" then
        if mod._runtime.had_damage_events then
            mod:print_summary()
        end
        _clear_table_in_place(mod.player_data_by_id)
        _clear_table_in_place(mod.unit_to_player_id)
        _clear_table_in_place(mod.display_values)
        mod.mission_start_time = nil
        mod.is_in_gameplay = false
        mod._runtime.had_damage_events = false
        mod._runtime.in_state_gameplay = false
    end
end

local get_local_player_safe
local get_local_player_unit_safe

local function _player_unit_from_player(player)
    if not player then return nil end
    local unit = nil
    pcall(function()
        if type(player.player_unit) == "function" then
            unit = player:player_unit()
        else
            unit = player.player_unit
        end
    end)
    return unit
end

local function _player_from_unit(unit)
    if not unit or not Managers.player then return nil end
    for _, player in pairs(Managers.player:players()) do
        if _player_unit_from_player(player) == unit then return player end
    end
    return nil
end

local function _player_id(player)
    if not player then return nil end
    local id = nil
    pcall(function() id = player:account_id() end)
    if type(id) == "string" and id ~= "" then return id end
    return player:name()
end

local function get_player_data_for_player(player)
    if not player then return nil end
    local pid = _player_id(player)
    if not pid then return nil end

    if not mod.player_data_by_id[pid] then
        local name = player:name() or "Unknown"
        mod.player_data_by_id[pid] = {
            player_id = pid,
            name = name,
            damage_history = {}, 
            total_damage_window = 0, 
            total_damage_mission = 0, 
            max_dpm = 0,
            current_dpm = 0,
            is_local = false 
        }
        mod.display_values[pid] = 0
        
        local local_player = get_local_player_safe()
        if player and local_player and player == local_player then
            mod.player_data_by_id[pid].is_local = true
        end
    end
    return mod.player_data_by_id[pid]
end

get_local_player_safe = function()
    if not Managers.player then return nil end
    local player = Managers.player:local_player(1)
    if player then return player end
    return nil
end

get_local_player_unit_safe = function()
    local player = get_local_player_safe()
    if not player then return nil end
    local unit = nil
    pcall(function()
        if type(player.player_unit) == "function" then
            unit = player:player_unit()
        else
            unit = player.player_unit
        end
    end)
    return unit
end

-- ####################################################################################################################
-- # 核心逻辑 (CORE LOGIC)
-- ####################################################################################################################
-- 此处为了节省篇幅，保持了最精简的 Hook 逻辑，与之前一致

local _damage_hook_installed_require = false
local _damage_hook_installed_class = false
local _time_since_last_hook_try = 0
local HOOK_TRY_INTERVAL = 1
local _attack_report_hook_installed = false
local _damage_source_mode = "auto"
local _breed_module = nil

local function _get_breed_module()
    if _breed_module then return _breed_module end
    pcall(function() _breed_module = mod:original_require("scripts/utilities/breed") end)
    if not _breed_module then pcall(function() _breed_module = require("scripts/utilities/breed") end) end
    return _breed_module
end

local function _infer_damage_amount(args)
    if type(args[1]) == "number" and args[1] > 0 then return args[1] end
    for i = 1, #args do
        local v = args[i]
        if type(v) == "number" and v > 0 then return v end
    end
    return nil
end

local function _is_unit_userdata(u)
    if type(u) ~= "userdata" then return false end
    if not Unit or type(Unit.alive) ~= "function" then return true end
    local ok, res = pcall(function() return Unit.alive(u) end)
    return ok and res ~= nil
end

local function _infer_attacking_unit(args)
    local local_unit = get_local_player_unit_safe()
    if local_unit then
        for i = #args, 1, -1 do if args[i] == local_unit then return local_unit end end
    end
    for i = #args, 1, -1 do if _is_unit_userdata(args[i]) then return args[i] end end
    return local_unit
end

local function _handle_add_damage_event(damage_amount, attacking_unit)
    if not Managers.time then return end
    if type(damage_amount) ~= "number" or damage_amount <= 0 then return end
    if not attacking_unit then return end

    local player = _player_from_unit(attacking_unit)
    if not player then return end
    local pid = _player_id(player)
    if not pid then return end

    mod.unit_to_player_id[attacking_unit] = pid
    local t = nil
    pcall(function() t = Managers.time:time("gameplay") end)
    if not t then return end

    if not mod.is_in_gameplay then
        mod.is_in_gameplay = true
        mod.mission_start_time = t
    elseif not mod.mission_start_time then
        mod.mission_start_time = t
    end

    local data = get_player_data_for_player(player)
    if data then
        data.name = player:name() or data.name
        mod._runtime.had_damage_events = true
        table.insert(data.damage_history, {t = t, amount = damage_amount})
        data.total_damage_window = data.total_damage_window + damage_amount
        data.total_damage_mission = data.total_damage_mission + damage_amount
    end
end

local function _install_damage_hook(target)
    mod:hook(target, "add_damage", function(func, self, ...)
        if type(func) ~= "function" then return end
        local args = {...}
        local result = func(self, ...)
        local damage_amount = _infer_damage_amount(args)
        local attacking_unit = _infer_attacking_unit(args)
        _handle_add_damage_event(damage_amount, attacking_unit)
        return result
    end)
end

local function _try_install_attack_report_hook()
    if _attack_report_hook_installed then return true end
    if not CLASS or not CLASS.AttackReportManager or type(CLASS.AttackReportManager.add_attack_result) ~= "function" then return false end
    _attack_report_hook_installed = true
    mod:hook(CLASS.AttackReportManager, "add_attack_result", function(func, self, damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, ...)
        if type(func) ~= "function" then return end
        local result = func(self, damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, attack_type, damage_efficiency, ...)
        
        if type(damage) ~= "number" or damage <= 0 then return result end
        if not attacking_unit or not attacked_unit then return result end
        if not _player_from_unit(attacking_unit) then return result end
        
        local Breed = _get_breed_module()
        if not Breed or not Breed.is_minion then return result end
        local unit_data_extension = ScriptUnit.has_extension(attacked_unit, "unit_data_system")
        local breed_or_nil = unit_data_extension and unit_data_extension:breed()
        if not (breed_or_nil and Breed.is_minion(breed_or_nil)) then return result end
        
        local actual_damage = damage
        if attack_result == "died" then
            local health_ext = ScriptUnit.has_extension(attacked_unit, "health_system")
            local max_health = health_ext and health_ext.max_health and health_ext:max_health()
            local damage_taken = health_ext and health_ext.damage_taken and health_ext:damage_taken()
            if type(max_health) == "number" and type(damage_taken) == "number" then
                actual_damage = max_health - damage_taken
            end
        end
        if type(actual_damage) ~= "number" or actual_damage <= 0 then return result end
        _handle_add_damage_event(actual_damage, attacking_unit)
        return result
    end)
    return true
end

local function _try_install_damage_hooks()
    if not _damage_hook_installed_require then
        local ok, health_extension_or_err = pcall(require, "scripts/extension_systems/health/health_extension")
        if ok and health_extension_or_err and type(health_extension_or_err.add_damage) == "function" then
            _install_damage_hook(health_extension_or_err)
            _damage_hook_installed_require = true
        end
    end
    if not _damage_hook_installed_class and not _damage_hook_installed_require then
        if CLASS and CLASS.HealthExtension and type(CLASS.HealthExtension.add_damage) == "function" then
            _install_damage_hook(CLASS.HealthExtension)
            _damage_hook_installed_class = true
        end
    end
end

-- Update Loop
function mod.update(dt)
    gradient_time = gradient_time + math.max(0, tonumber(dt) or 0)
    if not Managers.player or not Managers.ui or not Managers.time then return end

    _time_since_last_hook_try = _time_since_last_hook_try + dt
    if not _damage_hook_installed_require and not _damage_hook_installed_class and _time_since_last_hook_try >= HOOK_TRY_INTERVAL then
        _time_since_last_hook_try = 0
        _try_install_damage_hooks()
    end
    _try_install_attack_report_hook()

    if not mod.is_in_gameplay then 
        local game_mode_name = nil
        if Managers.state and Managers.state.game_mode then
             game_mode_name = Managers.state.game_mode:game_mode_name()
        end
        if game_mode_name and game_mode_name ~= "hub" then mod.is_in_gameplay = true end
        return 
    end
    
    local t = nil
    pcall(function() t = Managers.time:time("gameplay") end)
    if not t then return end

    if not mod.mission_start_time then mod.mission_start_time = t end

    for player_id, data in pairs(mod.player_data_by_id) do
        local history = data.damage_history
        local total_window = data.total_damage_window
        while #history > 0 and (t - history[1].t > WINDOW_SIZE) do
            local expired = table.remove(history, 1)
            total_window = total_window - expired.amount
        end
        data.total_damage_window = total_window
        data.current_dpm = total_window 
        if data.current_dpm > data.max_dpm then data.max_dpm = data.current_dpm end

        -- 动画逻辑
        if not mod.display_values[player_id] then mod.display_values[player_id] = 0 end
        local current_display = mod.display_values[player_id]
        local target_dpm = data.current_dpm
        local speed = mod:get("anim_speed") or 5
        mod.display_values[player_id] = smooth_towards(current_display, target_dpm, dt, speed)
    end
end

-- ####################################################################################################################
-- # UI 渲染 (UI RENDERING)
-- ####################################################################################################################

local function get_custom_color_style()
    local base_color = _hex_color(_text_setting("text_color_hex", "#FFFFFF"), "#FFFFFF")
    local r, g, b = base_color[1], base_color[2], base_color[3]
    local size = _number_setting("font_size", 28, 10, 80)

    -- The text-following mode uses a darker companion colour so the default
    -- gradient still has visible contrast without a background panel.
    local accent = {
        math.floor(r * 0.55 + 25),
        math.floor(g * 0.45 + 35),
        math.floor(b * 0.60 + 45),
    }

    local gradient_mode = mod:get("gradient_mode") or "custom"
    local gradient_start = _hex_color(_text_setting("gradient_start_hex", "#2F4FEE"), "#2F4FEE")
    local gradient_middle = _hex_color(_text_setting("gradient_middle_hex", "#5B9CFF"), "#5B9CFF")
    local gradient_end = _hex_color(_text_setting("gradient_end_hex", "#3DE8FF"), "#3DE8FF")

    if gradient_mode == "text" then
        gradient_start = {r, g, b}
        gradient_middle = {
            math.floor((r + accent[1]) * 0.5 + 0.5),
            math.floor((g + accent[2]) * 0.5 + 0.5),
            math.floor((b + accent[3]) * 0.5 + 0.5),
        }
        gradient_end = {accent[1], accent[2], accent[3]}
    end

    local gradient_strength = _number_setting("gradient_opacity", 100, 0, 100) / 100

    if gradient_mode == "off" then
        gradient_start = {r, g, b}
        gradient_middle = gradient_start
        gradient_end = gradient_start
    end

    local font_type = mod:get("font_type")
    if not valid_font_types[font_type] then font_type = "proxima_nova_bold" end

    return {
        text_color = {r, g, b},
        font_size = size,
        gradient_start = gradient_start,
        gradient_middle = gradient_middle,
        gradient_end = gradient_end,
        gradient_strength = gradient_strength,
        gradient_color_count = mod:get("gradient_color_count") or "three",
        gradient_animation = mod:get("gradient_animation") or "static",
        gradient_animation_speed = _number_setting("gradient_animation_speed", 0.35, 0, 4),
        font_type = font_type,
        shimmer_enabled = mod:get("gradient_shimmer") ~= false,
        shimmer_speed = _number_setting("gradient_shimmer_speed", 0.8, 0, 4),
        shimmer_strength = _number_setting("gradient_shimmer_strength", 0.75, 0, 1),
    }
end

local function _panel_value_for_player(player)
    if not player then return nil end
    local pid = _player_id(player)
    if not pid then return nil end

    if mod:get("gradient_preview") == true then
        return "DPM: 120.2K / 134.4K"
    end

    local data = mod.player_data_by_id[pid]
    if not data then return nil end
    data.name = player:name() or data.name
    
    local display_val = mod.display_values[pid] or 0
    -- Keep the overlay focused on the values themselves; the surrounding HUD
    -- already identifies this as the personal DPM panel.
    return string.format("DPM: %s / %s", format_k(display_val), format_k(data.max_dpm))
end

local function _settings_offset(offset_x_base, offset_y_base, settings_prefix)
    local x_off = _number_setting("panel_x_offset", 0, -400, 1000)
    local y_off = _number_setting("panel_y_offset", 0, -500, 200)
    local extra_x = _number_setting(settings_prefix .. "_x_offset", 0)
    local extra_y = _number_setting(settings_prefix .. "_y_offset", 0)
    return offset_x_base + x_off + extra_x, offset_y_base + y_off + extra_y
end

local function _mix_channel(from, to, progress)
    return math.floor(from + (to - from) * progress + 0.5)
end

local function _mix_color(from, to, progress)
    return {
        _mix_channel(from[1], to[1], progress),
        _mix_channel(from[2], to[2], progress),
        _mix_channel(from[3], to[3], progress),
    }
end

local function _gradient_color_at(custom_style, progress)
    local start_color = custom_style.gradient_start
    local middle_color = custom_style.gradient_middle or start_color
    local end_color = custom_style.gradient_end
    local color_count = custom_style.gradient_color_count
    local animation = custom_style.gradient_animation

    if color_count == "two" then
        middle_color = start_color
    end

    if animation == "flow" and custom_style.gradient_animation_speed > 0 then
        -- A wrapped three-stop cycle gives a seamless moving gradient. The
        -- last stop returns to the first colour, so the loop has no hard jump.
        local phase = (gradient_time * custom_style.gradient_animation_speed) % 1
        progress = (progress + phase) % 1
        if color_count == "two" then
            if progress < 0.5 then
                return _mix_color(start_color, end_color, progress * 2)
            end
            return _mix_color(end_color, start_color, (progress - 0.5) * 2)
        end

        if progress < 0.333333 then
            return _mix_color(start_color, middle_color, progress * 3)
        elseif progress < 0.666667 then
            return _mix_color(middle_color, end_color, (progress - 0.333333) * 3)
        end
        return _mix_color(end_color, start_color, (progress - 0.666667) * 3)
    end

    -- Static mode keeps the selected colours laid out from left to right.
    if color_count == "two" or progress < 0.5 then
        if color_count == "two" then
            return _mix_color(start_color, end_color, progress)
        end
        return _mix_color(start_color, middle_color, progress * 2)
    end
    return _mix_color(middle_color, end_color, (progress - 0.5) * 2)
end

local function _text_color_at(custom_style, progress)
    local strength = custom_style.gradient_strength
    local gradient_color = _gradient_color_at(custom_style, progress)

    if custom_style.shimmer_enabled and custom_style.shimmer_speed > 0 then
        -- Discord-like moving specular highlight: a soft white band sweeps
        -- across the letters and wraps without a visible jump.
        local phase = (gradient_time * custom_style.shimmer_speed) % 1
        local center = phase * 1.35 - 0.18
        local distance = math.abs(progress - center)
        local band = math.exp(-(distance * distance) / (2 * 0.08 * 0.08))
        local pulse = 0.82 + 0.18 * math.sin(gradient_time * custom_style.shimmer_speed * math.pi * 2 * 1.4)
        local shimmer = math.min(1, band * custom_style.shimmer_strength * pulse)
        gradient_color = {
            _mix_channel(gradient_color[1], 255, shimmer),
            _mix_channel(gradient_color[2], 255, shimmer),
            _mix_channel(gradient_color[3], 255, shimmer),
        }
    end

    return {
        255,
        _mix_channel(custom_style.text_color[1], gradient_color[1], strength),
        _mix_channel(custom_style.text_color[2], gradient_color[2], strength),
        _mix_channel(custom_style.text_color[3], gradient_color[3], strength),
    }
end

local function _apply_text_gradient(widget, text, ui_renderer, custom_style, offset_x_base, offset_y_base, settings_prefix)
    if not widget or not widget.style or not widget.content then return end

    local x, y = _settings_offset(offset_x_base, offset_y_base, settings_prefix)
    local style = widget.style.text
    if not style then return end

    local plain_text = text or ""
    local length = #plain_text
    local gradient_text = {}

    -- Darktide's text renderer supports rich-text colour tags. Keeping one
    -- native text pass preserves kerning and punctuation while still applying
    -- a smooth colour transition to every character.
    for index = 1, length do
        local progress = length > 1 and ((index - 1) / (length - 1)) or 0
        local color = _text_color_at(custom_style, progress)
        gradient_text[#gradient_text + 1] = string.format(
            "{#color(%d,%d,%d)}%s{#reset()}",
            color[2], color[3], color[4], string.sub(plain_text, index, index)
        )
    end

    style.font_size = custom_style.font_size
    style.font_type = custom_style.font_type
    style.offset = {x, y, 11}
    style.text_color = {255, custom_style.text_color[1], custom_style.text_color[2], custom_style.text_color[3]}
    widget.content.text = table.concat(gradient_text)
end

-- Keep a single native text pass. Splitting a HUD string into one pass per
-- character breaks punctuation and can cause only a subset of the text to be
-- rendered by the game's widget cache.
local function _create_unified_definition(offset_x_base, offset_y_base, settings_prefix)
    return UIWidget.create_definition({
        {
            value_id = "text",
            style_id = "text",
            pass_type = "text",
            value = "",
            style = {
                font_type = "proxima_nova_bold",
                font_size = 28,
                drop_shadow = false,
                vertical_alignment = "top",
                horizontal_alignment = "left",
                text_vertical_alignment = "center",
                text_horizontal_alignment = "left",
                text_color = {255, 255, 255, 255},
                size = {TEXT_HEIGHT * TEXT_MAX_CHARS, math.max(TEXT_HEIGHT, 120)},
                offset = {offset_x_base, offset_y_base, 11},
            },
            visibility_function = function(content)
                return content.text ~= nil and content.text ~= ""
            end,
        },
    }, "toughness_bar")
end

-- 【关键修改】只修改个人面板 (Personal Panel)
local function _patch_personal_panel_definitions(instance)
    if not instance or not instance.widget_definitions then return end
    -- 个人面板偏移：X=360, Y=0 (Y设为0以实现单行居中效果)
    instance.widget_definitions.dpm_meter_text = _create_unified_definition(360, 0, "personal")
    mod._ui_patched_personal = true
end

local _personal_defs_path = "scripts/ui/hud/elements/personal_player_panel/hud_element_personal_player_panel_definitions"

-- 【关键修改】只 Hook 个人面板的定义
mod:hook_require(_personal_defs_path, _patch_personal_panel_definitions)

pcall(function()
    local instance = mod:original_require(_personal_defs_path)
    _patch_personal_panel_definitions(instance)
end)

local function _ensure_panel_widget(self)
    if not self then return nil end
    self._widgets_by_name = self._widgets_by_name or {}
    local existing = self._widgets_by_name.dpm_meter_text
    if existing then
        if type(self._widgets) == "table" then
            local found = false
            for i = 1, #self._widgets do
                if self._widgets[i] == existing then found = true break end
            end
            if not found then table.insert(self._widgets, existing) end
        end
        return existing
    end

    local definitions = self._definitions
    local widget_definitions = definitions and definitions.widget_definitions
    local def = widget_definitions and widget_definitions.dpm_meter_text
    if not def then return nil end

    if type(self._create_widget) == "function" then
        local ok, widget = pcall(function() return self:_create_widget("dpm_meter_text", def) end)
        if ok and widget then
            self._widgets_by_name.dpm_meter_text = widget
            if type(self._widgets) == "table" then table.insert(self._widgets, widget) end
            return widget
        end
    end
    return nil
end

local function _update_personal_player_features(func, self, dt, t, player, ui_renderer)
    func(self, dt, t, player, ui_renderer)

    local widget = _ensure_panel_widget(self)
    if not widget then return end
    widget.dirty = true
    mod._ui_widget_created_personal = true

    local value = _panel_value_for_player(player)
    local custom_style = get_custom_color_style()
    local text = value or "-- / --"
    _apply_text_gradient(widget, text, ui_renderer, custom_style, 360, 0, "personal")
end

-- 【关键修改】只 Hook 个人面板的 Update
mod:hook("HudElementPersonalPlayerPanel", "_update_player_features", _update_personal_player_features)

-- ####################################################################################################################
-- # 回合结束总结 (SUMMARY)
-- ####################################################################################################################

mod.print_summary = function(self)
    mod:echo("=== DPM 统计报告 ===")
    if next(mod.player_data_by_id) == nil then return end
    
    local t = nil
    if Managers.time then pcall(function() t = Managers.time:time("gameplay") end) end
    local duration_min = 1
    if t and mod.mission_start_time then
        duration_min = (t - mod.mission_start_time) / 60
        if duration_min < 0.1 then duration_min = 0.1 end
    end

    for _, data in pairs(mod.player_data_by_id) do
        local avg_dpm = data.total_damage_mission / duration_min
        local msg = string.format("%s - 最高: %s | 平均: %s", 
            data.name, 
            format_k(data.max_dpm), 
            format_k(avg_dpm))
        mod:echo(msg)
    end
end

mod:command("dpm_reset", "重置 DPM 数据", function()
    mod.player_data = {}
    _clear_table_in_place(mod.player_data_by_id)
    _clear_table_in_place(mod.unit_to_player_id)
    _clear_table_in_place(mod.display_values)
    mod._runtime.had_damage_events = false
    if Managers.time then
        pcall(function() mod.mission_start_time = Managers.time:time("gameplay") end)
    end
    mod:echo("DPM Meter 已重置")
end)

mod:command("dpm_preview", "切换 DPM 渐变预览", function()
    local enabled = mod:get("gradient_preview") ~= true
    mod:set("gradient_preview", enabled, true)
    mod:echo(enabled and "DPM 渐变预览：开启（再次输入 dpm_preview 关闭）" or "DPM 渐变预览：关闭")
end)
