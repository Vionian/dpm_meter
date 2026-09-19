local mod = get_mod("dpm_meter")

local gradient_mode_options = {
    { text = "gradient_mode_custom", value = "custom" },
    { text = "gradient_mode_text", value = "text" },
    { text = "gradient_mode_off", value = "off" },
}

local gradient_color_count_options = {
    { text = "gradient_colors_two", value = "two" },
    { text = "gradient_colors_three", value = "three" },
}

local gradient_animation_options = {
    { text = "gradient_animation_flow", value = "flow" },
    { text = "gradient_animation_static", value = "static" },
}

local font_type_options = {
    { text = "font_option_proxima_nova_bold", value = "proxima_nova_bold" },
    { text = "font_option_proxima_nova_medium", value = "proxima_nova_medium" },
    { text = "font_option_machine_medium", value = "machine_medium" },
    { text = "font_option_arial", value = "arial" },
    { text = "font_option_trim_mono_bold", value = "trim_mono_bold" },
    { text = "font_option_itc_novarese_medium", value = "itc_novarese_medium" },
    { text = "font_option_itc_novarese_bold", value = "itc_novarese_bold" },
    { text = "font_option_friz_quadrata", value = "friz_quadrata" },
    { text = "font_option_rexlia", value = "rexlia" },
}

-- DMF's current text-input implementation reuses its keybind validator.
-- These compatibility fields are required even though the widget is text-only.
local function text_input(setting_id, default_value)
    return {
        setting_id = setting_id,
        type = "text_input",
        default_value = {},
        keybind_trigger = "pressed",
        keybind_type = "function_call",
        function_name = "dpm_meter_text_input_noop",
        title = setting_id,
    }
end

local function localized_text_input(setting_id, default_value)
    local widget = text_input(setting_id, default_value)
    widget.title = setting_id
    return widget
end

return {
    name = mod:localize("mod_name"),
    description = mod:localize("mod_description"),
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id = "position_group",
                type = "group",
                sub_widgets = {
                    localized_text_input("panel_x_offset", "0"),
                    localized_text_input("panel_y_offset", "0"),
                },
            },
            {
                setting_id = "number_group",
                type = "group",
                sub_widgets = {
                    localized_text_input("font_size", "28"),
                    localized_text_input("anim_speed", "5"),
                },
            },
            {
                setting_id = "font_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "font_type",
                        type = "dropdown",
                        default_value = "proxima_nova_bold",
                        options = font_type_options,
                    },
                },
            },
            {
                setting_id = "gradient_group",
                type = "group",
                sub_widgets = {
                    {
                        setting_id = "gradient_mode",
                        type = "dropdown",
                        default_value = "custom",
                        options = gradient_mode_options,
                    },
                    {
                        setting_id = "gradient_color_count",
                        type = "dropdown",
                        default_value = "three",
                        options = gradient_color_count_options,
                    },
                    {
                        setting_id = "gradient_animation",
                        type = "dropdown",
                        default_value = "static",
                        options = gradient_animation_options,
                    },
                    localized_text_input("gradient_start_hex", "#2F4FEE"),
                    localized_text_input("gradient_middle_hex", "#5B9CFF"),
                    localized_text_input("gradient_end_hex", "#3DE8FF"),
                    localized_text_input("gradient_opacity", "100"),
                    localized_text_input("gradient_animation_speed", "0.35"),
                    {
                        setting_id = "gradient_shimmer",
                        type = "checkbox",
                        default_value = true,
                    },
                    localized_text_input("gradient_shimmer_speed", "0.8"),
                    localized_text_input("gradient_shimmer_strength", "0.75"),
                    localized_text_input("text_color_hex", "#FFFFFF"),
                    {
                        setting_id = "gradient_preview",
                        type = "checkbox",
                        default_value = false,
                    },
                },
            },
        },
    },
}
