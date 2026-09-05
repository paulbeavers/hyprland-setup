--------------------------------------------------------------------------------
--  Input — keyboard, mouse, touchpad, gestures
--------------------------------------------------------------------------------

hl.config({
    input = {
        kb_layout  = "us",
        kb_variant = "",
        kb_model   = "",
        -- Useful extras: "caps:escape" (Caps Lock acts as Escape),
        -- "compose:ralt" (Right Alt becomes a compose key).
        kb_options = "",
        kb_rules   = "",

        follow_mouse  = 1,
        mouse_refocus = false,

        repeat_rate  = 40,
        repeat_delay = 400,

        -- -1.0 to 1.0. 0 is the raw hardware speed.
        sensitivity   = 0,
        accel_profile = "flat",

        numlock_by_default = true,

        touchpad = {
            natural_scroll       = true,
            disable_while_typing = true,
            tap_to_click         = true,
            drag_lock            = true,
            scroll_factor        = 1.0,
            clickfinger_behavior = true,
        },
    },

    binds = {
        -- Pressing the workspace key you are already on sends you back.
        workspace_back_and_forth = false,
        allow_workspace_cycles   = true,
        workspace_center_on      = 1,
    },

    -- Tuning knobs for the swipe gesture below.
    gestures = {
        workspace_swipe_distance       = 300,
        workspace_swipe_cancel_ratio   = 0.4,
        workspace_swipe_create_new     = false,
        workspace_swipe_forever        = true,
        workspace_swipe_direction_lock = true,
    },
})

-- These only fire on a touchpad, so they are harmless on a desktop.
hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 4, direction = "up",      action = "special", args = "magic" })
hl.gesture({ fingers = 4, direction = "down",    action = "special", args = "magic" })
hl.gesture({ fingers = 4, direction = "pinchin", action = "float" })

-- Per-device overrides. Find names with: hyprctl devices
-- hl.device({ name = "logitech-mx-master-3", sensitivity = -0.3 })
