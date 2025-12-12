---
-- Scrolling ring key binding manager.
-- Handles mapping of scroll gestures from Bluetooth scrolling rings to KOReader actions.
--
-- Unlike standard Bluetooth devices that send key codes, scrolling rings
-- send touch/ABS events. This module interprets scroll directions (up/down)
-- and maps them to configured actions.

local AvailableActions = require("src/lib/bluetooth/available_actions")
local ButtonDialog = require("ui/widget/buttondialog")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local ScrollingRingBindings = InputContainer:extend({
    name = "scrolling_ring_bindings",
    -- Bindings: { device_mac -> { scroll_up: action_id, scroll_down: action_id } }
    device_bindings = {},
    -- Device path to address mapping
    device_path_to_address = {},
    -- Settings reference
    settings = nil,
    save_callback = nil,
    -- Scrolling ring handler reference
    scrolling_ring_handler = nil,
    -- Configuration menu reference
    config_menu = nil,
})

---
-- Basic initialization.
function ScrollingRingBindings:init()
    self.device_bindings = {}
    self.device_path_to_address = {}
end

---
-- Sets up the scrolling ring bindings manager.
-- @param save_callback function Function to call when settings need to be saved
-- @param scrolling_ring_handler table ScrollingRingHandler instance
function ScrollingRingBindings:setup(save_callback, scrolling_ring_handler)
    logger.info("ScrollingRingBindings: setup called")
    self.save_callback = save_callback
    self.scrolling_ring_handler = scrolling_ring_handler

    if self.scrolling_ring_handler then
        logger.info("ScrollingRingBindings: Registering scroll callback with handler")
        -- Register scroll callback
        self.scrolling_ring_handler:registerScrollCallback(function(direction, device_address, device_path)
            logger.info("ScrollingRingBindings: Scroll callback invoked from handler")
            self:onScrollEvent(direction, device_address, device_path)
        end)

        -- Register device callbacks for path mapping
        self.scrolling_ring_handler:registerDeviceOpenCallback(function(device_address, device_path)
            logger.info("ScrollingRingBindings: Device open callback, setting path mapping")
            self:setDevicePathMapping(device_path, device_address)
        end)

        self.scrolling_ring_handler:registerDeviceCloseCallback(function(device_address, device_path)
            logger.info("ScrollingRingBindings: Device close callback, removing path mapping")
            self:removeDevicePathMapping(device_path)
        end)

        logger.info("ScrollingRingBindings: All callbacks registered with handler")
    else
        logger.warn("ScrollingRingBindings: No scrolling_ring_handler provided")
    end

    self:loadBindings()
    logger.info("ScrollingRingBindings: setup complete")
end

---
-- Loads bindings from persistent storage.
function ScrollingRingBindings:loadBindings()
    if not self.settings then
        logger.warn("ScrollingRingBindings: No settings provided, cannot load bindings")
        return
    end

    self.device_bindings = self.settings.scrolling_ring_bindings or {}

    local count = 0
    for _ in pairs(self.device_bindings) do
        count = count + 1
    end

    logger.info("ScrollingRingBindings: Loaded bindings for", count, "devices")
end

---
-- Saves bindings to persistent storage.
function ScrollingRingBindings:saveBindings()
    if not self.settings then
        logger.warn("ScrollingRingBindings: No settings provided, cannot save bindings")
        return
    end

    self.settings.scrolling_ring_bindings = self.device_bindings

    if self.save_callback then
        self.save_callback()
    end

    logger.dbg("ScrollingRingBindings: Saved bindings to persistent storage")
end

---
-- Sets a binding for a scroll direction.
-- @param device_mac string MAC address of the device
-- @param direction string "scroll_up" or "scroll_down"
-- @param action_id string Action ID to bind
function ScrollingRingBindings:setBinding(device_mac, direction, action_id)
    if not self.device_bindings[device_mac] then
        self.device_bindings[device_mac] = {}
    end

    self.device_bindings[device_mac][direction] = action_id
    self:saveBindings()

    logger.dbg("ScrollingRingBindings: Set", direction, "->", action_id, "for device", device_mac)
end

---
-- Removes a binding for a scroll direction.
-- @param device_mac string MAC address of the device
-- @param direction string "scroll_up" or "scroll_down"
function ScrollingRingBindings:removeBinding(device_mac, direction)
    if not self.device_bindings[device_mac] then
        return
    end

    self.device_bindings[device_mac][direction] = nil
    self:saveBindings()

    logger.dbg("ScrollingRingBindings: Removed", direction, "binding for device", device_mac)
end

---
-- Gets all bindings for a device.
-- @param device_mac string MAC address
-- @return table Bindings { scroll_up: action_id, scroll_down: action_id }
function ScrollingRingBindings:getDeviceBindings(device_mac)
    return self.device_bindings[device_mac] or {}
end

---
-- Gets an action definition by ID.
-- @param action_id string Action ID
-- @return table|nil Action definition
function ScrollingRingBindings:getActionById(action_id)
    for _, action in ipairs(AvailableActions) do
        if action.id == action_id then
            return action
        end
    end

    return nil
end

---
-- Sets device path to address mapping.
-- @param device_path string Path to input device
-- @param device_mac string MAC address
function ScrollingRingBindings:setDevicePathMapping(device_path, device_mac)
    if device_path and device_mac then
        self.device_path_to_address[device_path] = device_mac
        logger.dbg("ScrollingRingBindings: Mapped", device_path, "to", device_mac)
    end
end

---
-- Removes device path mapping.
-- @param device_path string Path to input device
function ScrollingRingBindings:removeDevicePathMapping(device_path)
    if device_path then
        self.device_path_to_address[device_path] = nil
        logger.dbg("ScrollingRingBindings: Removed mapping for", device_path)
    end
end

---
-- Handles a scroll event from a scrolling ring.
-- @param direction string "up" or "down"
-- @param device_address string MAC address of the device
-- @param device_path string Path to the input device
function ScrollingRingBindings:onScrollEvent(direction, device_address, device_path)
    logger.info("ScrollingRingBindings: onScrollEvent called")
    logger.info("ScrollingRingBindings: direction=", direction)
    logger.info("ScrollingRingBindings: device_address=", device_address)
    logger.info("ScrollingRingBindings: device_path=", device_path)

    -- Reset inactivity timer
    UIManager.event_hook:execute("InputEvent")

    local bindings = self.device_bindings[device_address]

    if not bindings then
        logger.warn("ScrollingRingBindings: No bindings for device:", device_address)
        logger.info("ScrollingRingBindings: Available device bindings:")
        for addr, _ in pairs(self.device_bindings) do
            logger.info("  -", addr)
        end
        return
    end

    logger.info("ScrollingRingBindings: Found bindings for device")

    local binding_key = "scroll_" .. direction
    local action_id = bindings[binding_key]

    logger.info("ScrollingRingBindings: Looking for binding_key=", binding_key)
    logger.info("ScrollingRingBindings: action_id=", action_id)

    if not action_id then
        logger.warn("ScrollingRingBindings: No binding for", binding_key, "on device:", device_address)
        logger.info("ScrollingRingBindings: Available bindings for this device:")
        for key, val in pairs(bindings) do
            logger.info("  ", key, "=", val)
        end
        return
    end

    local action = self:getActionById(action_id)

    if not action then
        logger.warn("ScrollingRingBindings: Unknown action:", action_id)
        return
    end

    logger.info("ScrollingRingBindings: TRIGGERING ACTION", action_id, "event=", action.event)

    if action.args then
        logger.info("ScrollingRingBindings: Sending event with args=", action.args)
        UIManager:sendEvent(Event:new(action.event, action.args))
    else
        logger.info("ScrollingRingBindings: Sending event without args")
        UIManager:sendEvent(Event:new(action.event))
    end

    logger.info("ScrollingRingBindings: Event sent successfully")
end

---
-- Shows the configuration menu for a scrolling ring device.
-- @param device_info table Device information with address and name
function ScrollingRingBindings:showConfigMenu(device_info)
    if not device_info or not device_info.address then
        logger.warn("ScrollingRingBindings: Invalid device_info")
        return
    end

    if self.config_menu then
        UIManager:close(self.config_menu)
        self.config_menu = nil
    end

    local device_mac = device_info.address
    local device_name = device_info.name ~= "" and device_info.name or device_mac
    local menu_items = self:buildConfigMenuItems(device_info)

    self.config_menu = Menu:new({
        title = _("Scroll Bindings for: ") .. device_name,
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    })

    UIManager:show(self.config_menu)
end

---
-- Builds menu items for the configuration menu.
-- @param device_info table Device information
-- @return table Menu items
function ScrollingRingBindings:buildConfigMenuItems(device_info)
    local device_mac = device_info.address
    local bindings = self:getDeviceBindings(device_mac)
    local menu_items = {}

    -- Scroll Up binding
    local scroll_up_action = bindings.scroll_up and self:getActionById(bindings.scroll_up)

    table.insert(menu_items, {
        text = _("Scroll Up"),
        mandatory = scroll_up_action and scroll_up_action.title or _("Not assigned"),
        callback = function()
            self:showActionSelectionMenu(device_info, "scroll_up", _("Scroll Up"))
        end,
    })

    -- Scroll Down binding
    local scroll_down_action = bindings.scroll_down and self:getActionById(bindings.scroll_down)

    table.insert(menu_items, {
        text = _("Scroll Down"),
        mandatory = scroll_down_action and scroll_down_action.title or _("Not assigned"),
        callback = function()
            self:showActionSelectionMenu(device_info, "scroll_down", _("Scroll Down"))
        end,
    })

    -- Separator
    table.insert(menu_items, {
        text = "─────────────",
        enabled = false,
    })

    -- Settings
    table.insert(menu_items, {
        text = _("Scroll settings"),
        callback = function()
            self:showScrollSettingsMenu(device_info)
        end,
    })

    return menu_items
end

---
-- Shows the action selection menu for a scroll direction.
-- @param device_info table Device information
-- @param direction string "scroll_up" or "scroll_down"
-- @param direction_title string Display title for the direction
function ScrollingRingBindings:showActionSelectionMenu(device_info, direction, direction_title)
    local device_mac = device_info.address
    local bindings = self:getDeviceBindings(device_mac)
    local current_action_id = bindings[direction]

    local menu_items = {}

    -- Add "None" option to clear binding
    table.insert(menu_items, {
        text = _("None (clear binding)"),
        checked_func = function()
            return current_action_id == nil
        end,
        callback = function()
            self:removeBinding(device_mac, direction)
            self:refreshConfigMenu(device_info)

            UIManager:show(InfoMessage:new({
                text = direction_title .. _(" binding cleared"),
                timeout = 2,
            }))
        end,
    })

    -- Add all available actions
    for _, action in ipairs(AvailableActions) do
        table.insert(menu_items, {
            text = action.title,
            checked_func = function()
                return current_action_id == action.id
            end,
            callback = function()
                self:setBinding(device_mac, direction, action.id)
                self:refreshConfigMenu(device_info)

                UIManager:show(InfoMessage:new({
                    text = direction_title .. " → " .. action.title,
                    timeout = 2,
                }))
            end,
        })
    end

    local action_menu = Menu:new({
        title = _("Select action for: ") .. direction_title,
        item_table = menu_items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
    })

    UIManager:show(action_menu)
end

---
-- Shows the scroll settings menu.
-- @param device_info table Device information
function ScrollingRingBindings:showScrollSettingsMenu(device_info)
    if not self.scrolling_ring_handler then
        UIManager:show(InfoMessage:new({
            text = _("Scroll settings not available"),
            timeout = 2,
        }))
        return
    end

    local buttons = {
        {
            {
                text = _("Invert scroll direction"),
                callback = function()
                    local current = self.scrolling_ring_handler.invert_scroll
                    self.scrolling_ring_handler:updateConfiguration({
                        invert_scroll = not current,
                    })

                    -- Save to settings
                    if self.settings then
                        self.settings.scrolling_ring_invert = not current
                        if self.save_callback then
                            self.save_callback()
                        end
                    end

                    UIManager:show(InfoMessage:new({
                        text = _("Scroll direction ") .. (not current and _("inverted") or _("normal")),
                        timeout = 2,
                    }))
                end,
            },
        },
        {
            {
                text = _("Increase sensitivity"),
                callback = function()
                    local current = self.scrolling_ring_handler.scroll_threshold
                    local new_threshold = math.max(100, current - 50)
                    self.scrolling_ring_handler:updateConfiguration({
                        scroll_threshold = new_threshold,
                    })

                    if self.settings then
                        self.settings.scrolling_ring_threshold = new_threshold
                        if self.save_callback then
                            self.save_callback()
                        end
                    end

                    UIManager:show(InfoMessage:new({
                        text = _("Sensitivity increased (threshold: ") .. new_threshold .. ")",
                        timeout = 2,
                    }))
                end,
            },
            {
                text = _("Decrease sensitivity"),
                callback = function()
                    local current = self.scrolling_ring_handler.scroll_threshold
                    local new_threshold = math.min(800, current + 50)
                    self.scrolling_ring_handler:updateConfiguration({
                        scroll_threshold = new_threshold,
                    })

                    if self.settings then
                        self.settings.scrolling_ring_threshold = new_threshold
                        if self.save_callback then
                            self.save_callback()
                        end
                    end

                    UIManager:show(InfoMessage:new({
                        text = _("Sensitivity decreased (threshold: ") .. new_threshold .. ")",
                        timeout = 2,
                    }))
                end,
            },
        },
        {
            {
                text = _("Reset to defaults"),
                callback = function()
                    self.scrolling_ring_handler:updateConfiguration({
                        scroll_threshold = 300,
                        debounce_interval = 0.15,
                        invert_scroll = false,
                    })

                    if self.settings then
                        self.settings.scrolling_ring_threshold = 300
                        self.settings.scrolling_ring_debounce = 0.15
                        self.settings.scrolling_ring_invert = false
                        if self.save_callback then
                            self.save_callback()
                        end
                    end

                    UIManager:show(InfoMessage:new({
                        text = _("Scroll settings reset to defaults"),
                        timeout = 2,
                    }))
                end,
            },
        },
    }

    local dialog = ButtonDialog:new({
        title = _("Scroll Ring Settings"),
        title_align = "center",
        buttons = buttons,
    })

    UIManager:show(dialog)
end

---
-- Refreshes the configuration menu.
-- @param device_info table Device information
function ScrollingRingBindings:refreshConfigMenu(device_info)
    if not self.config_menu then
        return
    end

    local menu_items = self:buildConfigMenuItems(device_info)
    self.config_menu:switchItemTable(nil, menu_items)
end

---
-- Clears all bindings for a device.
-- @param device_mac string MAC address
function ScrollingRingBindings:clearDeviceBindings(device_mac)
    if self.device_bindings[device_mac] then
        self.device_bindings[device_mac] = nil
        self:saveBindings()
        logger.dbg("ScrollingRingBindings: Cleared all bindings for", device_mac)
    end
end

---
-- Applies saved settings to the scrolling ring handler.
function ScrollingRingBindings:applySettings()
    if not self.settings or not self.scrolling_ring_handler then
        return
    end

    local config = {}

    if self.settings.scrolling_ring_threshold then
        config.scroll_threshold = self.settings.scrolling_ring_threshold
    end

    if self.settings.scrolling_ring_debounce then
        config.debounce_interval = self.settings.scrolling_ring_debounce
    end

    if self.settings.scrolling_ring_invert ~= nil then
        config.invert_scroll = self.settings.scrolling_ring_invert
    end

    if next(config) then
        self.scrolling_ring_handler:updateConfiguration(config)
        logger.info("ScrollingRingBindings: Applied saved settings")
    end
end

return ScrollingRingBindings
