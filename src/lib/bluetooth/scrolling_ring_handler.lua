---
-- Scrolling ring handler for Bluetooth scroll rings.
-- Extends InputDeviceHandler to support devices that send ABS events
-- instead of standard key events.
--
-- This module provides:
-- - Detection of scrolling ring devices
-- - Scroll gesture interpretation
-- - Integration with the existing key bindings system
-- - Configurable scroll sensitivity and direction

local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local ScrollingRingReader = require("src/lib/bluetooth/scrolling_ring_reader")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local ScrollingRingHandler = {
    -- Isolated readers for scrolling ring devices (keyed by device address)
    ring_readers = {},
    -- Callbacks for scroll events
    scroll_callbacks = {},
    -- Callbacks for device events
    device_open_callbacks = {},
    device_close_callbacks = {},
    -- Configuration
    scroll_threshold = 300,
    debounce_interval = 0.15,
    invert_scroll = false,
    -- Polling
    poll_task = nil,
    poll_interval = 0.05, -- 50ms polling interval
    -- Device type detection
    known_scrolling_ring_names = {
        "Scrolling Ring",
        "Wireless Scrolling Ring",
        "BT Ring",
        "Page Turner Ring",
        -- Add more known scrolling ring device names here
    },
}

---
-- Creates a new ScrollingRingHandler instance.
-- @param config table Optional configuration
-- @return table New ScrollingRingHandler instance
function ScrollingRingHandler:new(config)
    config = config or {}

    local instance = {
        ring_readers = {},
        scroll_callbacks = {},
        device_open_callbacks = {},
        device_close_callbacks = {},
        scroll_threshold = config.scroll_threshold or 300,
        debounce_interval = config.debounce_interval or 0.15,
        invert_scroll = config.invert_scroll or false,
        poll_task = nil,
        poll_interval = config.poll_interval or 0.05,
        known_scrolling_ring_names = config.known_scrolling_ring_names or ScrollingRingHandler.known_scrolling_ring_names,
    }

    setmetatable(instance, self)
    self.__index = self

    return instance
end

---
-- Checks if a device might be a scrolling ring based on its name.
-- @param device_name string Name of the device
-- @return boolean True if device appears to be a scrolling ring
function ScrollingRingHandler:isScrollingRingDevice(device_name)
    if not device_name then
        return false
    end

    local lower_name = device_name:lower()

    -- Check against known device names
    for _, known_name in ipairs(self.known_scrolling_ring_names) do
        if lower_name:find(known_name:lower(), 1, true) then
            return true
        end
    end

    -- Heuristic: check for common scrolling ring keywords
    if lower_name:find("scroll") or lower_name:find("ring") or lower_name:find("page.*turn") then
        return true
    end

    return false
end

---
-- Adds a device name to the known scrolling ring list.
-- @param device_name string Name to add
function ScrollingRingHandler:addKnownScrollingRingName(device_name)
    table.insert(self.known_scrolling_ring_names, device_name)
end

---
-- Registers a callback for scroll events.
-- @param callback function Callback function(direction, device_address, device_path)
--   direction: "up" or "down"
function ScrollingRingHandler:registerScrollCallback(callback)
    table.insert(self.scroll_callbacks, callback)

    -- Register with existing readers
    for _, reader_info in pairs(self.ring_readers) do
        reader_info.reader:registerScrollCallback(function(direction, time, device_path)
            callback(direction, reader_info.device_address, device_path)
        end)
    end

    logger.dbg("ScrollingRingHandler: Registered scroll callback")
end

---
-- Registers a callback for device open events.
-- @param callback function Callback function(device_address, device_path)
function ScrollingRingHandler:registerDeviceOpenCallback(callback)
    table.insert(self.device_open_callbacks, callback)
end

---
-- Registers a callback for device close events.
-- @param callback function Callback function(device_address, device_path)
function ScrollingRingHandler:registerDeviceCloseCallback(callback)
    table.insert(self.device_close_callbacks, callback)
end

---
-- Clears all registered callbacks.
function ScrollingRingHandler:clearCallbacks()
    self.scroll_callbacks = {}
    self.device_open_callbacks = {}
    self.device_close_callbacks = {}

    for _, reader_info in pairs(self.ring_readers) do
        reader_info.reader:clearCallbacks()
    end
end

---
-- Opens a scrolling ring input device.
-- @param device_info table Device information with address and name
-- @param device_path string Path to the input device
-- @param show_messages boolean Whether to show UI messages
-- @return boolean True if successfully opened
function ScrollingRingHandler:openScrollingRingDevice(device_info, device_path, show_messages)
    if show_messages == nil then
        show_messages = true
    end

    logger.info("ScrollingRingHandler: openScrollingRingDevice called")
    logger.info("ScrollingRingHandler: device_info.address=", device_info.address)
    logger.info("ScrollingRingHandler: device_info.name=", device_info.name)
    logger.info("ScrollingRingHandler: device_path=", device_path)

    if not device_path then
        logger.warn("ScrollingRingHandler: No device path provided")

        if show_messages then
            UIManager:show(InfoMessage:new({
                text = _("Scrolling ring device not found.\nPlease reconnect the device."),
                timeout = 3,
            }))
        end

        return false
    end

    logger.info("ScrollingRingHandler: Opening scrolling ring device:", device_path, "for", device_info.address)

    local reader = ScrollingRingReader:new({
        scroll_threshold = self.scroll_threshold,
        debounce_interval = self.debounce_interval,
        invert_scroll = self.invert_scroll,
    })

    logger.info("ScrollingRingHandler: Created ScrollingRingReader with threshold=", self.scroll_threshold)

    local success = reader:open(device_path)

    if not success then
        logger.warn("ScrollingRingHandler: Failed to open scrolling ring reader for", device_path)

        if show_messages then
            UIManager:show(InfoMessage:new({
                text = _("Failed to open scrolling ring device.\nYou may need to reconnect the device."),
                timeout = 3,
            }))
        end

        return false
    end

    logger.info("ScrollingRingHandler: Reader opened successfully")

    -- Register scroll callbacks
    logger.info("ScrollingRingHandler: Registering", #self.scroll_callbacks, "scroll callbacks")
    for i, callback in ipairs(self.scroll_callbacks) do
        logger.info("ScrollingRingHandler: Registering scroll callback", i)
        reader:registerScrollCallback(function(direction, time, path)
            logger.info("ScrollingRingHandler: Scroll callback wrapper invoked, direction=", direction)
            callback(direction, device_info.address, path)
        end)
    end

    self.ring_readers[device_info.address] = {
        reader = reader,
        device_path = device_path,
        device_address = device_info.address,
        device_name = device_info.name,
    }

    logger.info("ScrollingRingHandler: Stored reader in ring_readers table")

    -- Call device open callbacks
    for _, callback in ipairs(self.device_open_callbacks) do
        local ok, err = pcall(callback, device_info.address, device_path)

        if not ok then
            logger.warn("ScrollingRingHandler: Device open callback error:", err)
        end
    end

    if show_messages then
        UIManager:show(InfoMessage:new({
            text = _("Scrolling ring ready at ") .. device_path,
            timeout = 2,
        }))
    end

    -- Start polling if not already running
    logger.info("ScrollingRingHandler: Starting polling")
    self:startPolling()

    return true
end

---
-- Closes a scrolling ring device.
-- @param device_info table Device information with address
function ScrollingRingHandler:closeScrollingRingDevice(device_info)
    local reader_info = self.ring_readers[device_info.address]

    if not reader_info then
        logger.dbg("ScrollingRingHandler: No reader for", device_info.address)
        return
    end

    local device_path = reader_info.device_path

    logger.info("ScrollingRingHandler: Closing scrolling ring for", device_info.address)

    reader_info.reader:close()
    self.ring_readers[device_info.address] = nil

    -- Call device close callbacks
    for _, callback in ipairs(self.device_close_callbacks) do
        local ok, err = pcall(callback, device_info.address, device_path)

        if not ok then
            logger.warn("ScrollingRingHandler: Device close callback error:", err)
        end
    end

    -- Stop polling if no more readers
    if not self:hasReaders() then
        self:stopPolling()
    end
end

---
-- Starts polling for scrolling ring input events.
function ScrollingRingHandler:startPolling()
    if self.poll_task then
        logger.dbg("ScrollingRingHandler: Already polling")
        return
    end

    logger.info("ScrollingRingHandler: Starting scroll ring input polling")
    logger.info("ScrollingRingHandler: Number of ring_readers:", self:_countReaders())

    local poll_count = 0
    local function poll()
        if self:hasReaders() then
            poll_count = poll_count + 1
            if poll_count % 100 == 0 then
                logger.dbg("ScrollingRingHandler: Poll cycle", poll_count)
            end
            self:pollAllReaders(0)
            self.poll_task = UIManager:scheduleIn(self.poll_interval, poll)
        else
            self.poll_task = nil
            logger.info("ScrollingRingHandler: Stopped polling (no readers)")
        end
    end

    self.poll_task = UIManager:scheduleIn(self.poll_interval, poll)
    logger.info("ScrollingRingHandler: Poll task scheduled with interval:", self.poll_interval)
end

---
-- Helper to count readers
function ScrollingRingHandler:_countReaders()
    local count = 0
    for _ in pairs(self.ring_readers) do
        count = count + 1
    end
    return count
end

---
-- Stops polling for input events.
function ScrollingRingHandler:stopPolling()
    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
        logger.dbg("ScrollingRingHandler: Stopped polling")
    end
end

---
-- Polls all scrolling ring readers for events.
-- @param timeout_ms number Timeout in milliseconds
-- @return table|nil Array of events or nil
function ScrollingRingHandler:pollAllReaders(timeout_ms)
    local all_events = {}

    for address, reader_info in pairs(self.ring_readers) do
        local events = reader_info.reader:poll(timeout_ms)

        if events then
            for _, ev in ipairs(events) do
                ev.device_address = address
                table.insert(all_events, ev)
            end
        end
    end

    if #all_events > 0 then
        return all_events
    end

    return nil
end

---
-- Checks if any readers are open.
-- @return boolean True if at least one reader is open
function ScrollingRingHandler:hasReaders()
    for _, reader_info in pairs(self.ring_readers) do
        if reader_info.reader:isOpen() then
            return true
        end
    end

    return false
end

---
-- Gets the reader for a specific device.
-- @param device_address string MAC address
-- @return table|nil Reader info or nil
function ScrollingRingHandler:getReader(device_address)
    return self.ring_readers[device_address]
end

---
-- Updates scroll configuration for all readers.
-- @param config table Configuration with scroll_threshold, debounce_interval, invert_scroll
function ScrollingRingHandler:updateConfiguration(config)
    if config.scroll_threshold then
        self.scroll_threshold = config.scroll_threshold
    end

    if config.debounce_interval then
        self.debounce_interval = config.debounce_interval
    end

    if config.invert_scroll ~= nil then
        self.invert_scroll = config.invert_scroll
    end

    -- Update existing readers
    for _, reader_info in pairs(self.ring_readers) do
        if config.scroll_threshold then
            reader_info.reader:setScrollThreshold(config.scroll_threshold)
        end

        if config.debounce_interval then
            reader_info.reader:setDebounceInterval(config.debounce_interval)
        end

        if config.invert_scroll ~= nil then
            reader_info.reader:setInvertScroll(config.invert_scroll)
        end
    end
end

---
-- Closes all scrolling ring devices.
function ScrollingRingHandler:closeAll()
    self:stopPolling()

    for address, reader_info in pairs(self.ring_readers) do
        logger.info("ScrollingRingHandler: Closing reader for", address)
        reader_info.reader:close()
    end

    self.ring_readers = {}
end

return ScrollingRingHandler
