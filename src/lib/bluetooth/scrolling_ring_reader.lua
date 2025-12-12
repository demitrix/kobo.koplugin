---
-- Scrolling ring input reader for Bluetooth scroll rings.
-- Handles ABS (absolute position) events that scrolling rings generate.
--
-- Scrolling rings send touch events with:
-- - EV_KEY BTN_TOUCH (330) for touch start/end
-- - EV_ABS (type=3) events with ABS_Y (code=1) values
--
-- This module detects scroll direction by comparing the first Y value
-- when touch starts with the last Y value when touch ends:
-- - If last Y > first Y → scroll up
-- - If last Y < first Y → scroll down

local bit = require("bit")
local ffi = require("ffi")
local logger = require("logger")

require("ffi/posix_h")
require("ffi/linux_input_h")

local C = ffi.C

-- Linux input event types and codes
local EV_SYN = 0
local EV_KEY = 1
local EV_ABS = 3
local ABS_Y = 1

local ScrollingRingReader = {
    fd = nil,
    device_path = nil,
    is_open = false,

    -- Callbacks
    key_callbacks = {},
    scroll_callbacks = {},

    -- Y value tracking
    first_y = nil,  -- Y value at touch start
    last_y = nil,   -- Most recent Y value
    in_touch = false,
    
    -- Minimum Y delta to trigger a scroll (prevents accidental triggers)
    min_delta = 200,

    -- Debouncing
    last_scroll_time = 0,
    debounce_interval = 0.15,

    -- Configuration
    invert_scroll = false,
}

---
-- Creates a new ScrollingRingReader instance.
-- @param config table Optional configuration
-- @return table New instance
function ScrollingRingReader:new(config)
    config = config or {}

    local instance = {
        fd = nil,
        device_path = nil,
        is_open = false,
        key_callbacks = {},
        scroll_callbacks = {},
        first_y = nil,
        last_y = nil,
        in_touch = false,
        min_delta = config.min_delta or 200,
        last_scroll_time = 0,
        debounce_interval = config.debounce_interval or 0.15,
        invert_scroll = config.invert_scroll or false,
    }

    setmetatable(instance, self)
    self.__index = self

    return instance
end

---
-- Opens a Bluetooth input device for reading.
-- @param device_path string Path to the input device
-- @return boolean True if successfully opened
function ScrollingRingReader:open(device_path)
    if self.is_open then
        logger.warn("ScrollingRingReader: Already open, closing first")
        self:close()
    end

    local fd = C.open(device_path, bit.bor(C.O_RDONLY, C.O_NONBLOCK, C.O_CLOEXEC))

    if fd < 0 then
        logger.warn("ScrollingRingReader: Failed to open", device_path, "errno:", ffi.errno())
        return false
    end

    self.fd = fd
    self.device_path = device_path
    self.is_open = true
    self:resetScrollState()

    logger.info("ScrollingRingReader: Opened", device_path)

    return true
end

---
-- Closes the input device.
function ScrollingRingReader:close()
    if not self.is_open or not self.fd then
        return
    end

    C.close(self.fd)
    logger.info("ScrollingRingReader: Closed", self.device_path)

    self.fd = nil
    self.device_path = nil
    self.is_open = false
    self:resetScrollState()
end

---
-- Registers a callback for key events.
-- @param callback function Callback(key_code, key_value, time, device_path)
function ScrollingRingReader:registerKeyCallback(callback)
    table.insert(self.key_callbacks, callback)
end

---
-- Registers a callback for scroll events.
-- @param callback function Callback(direction, time, device_path) - direction is "up" or "down"
function ScrollingRingReader:registerScrollCallback(callback)
    table.insert(self.scroll_callbacks, callback)
end

---
-- Clears all registered callbacks.
function ScrollingRingReader:clearCallbacks()
    self.key_callbacks = {}
    self.scroll_callbacks = {}
end

---
-- Gets the current time in seconds.
-- @return number Current time
function ScrollingRingReader:_getCurrentTime()
    local ffiutil = require("ffi/util")
    local sec, usec = ffiutil.gettime()
    return sec + usec / 1000000
end

---
-- Called when touch starts - capture first Y value
function ScrollingRingReader:_onTouchStart()
    logger.dbg("ScrollingRingReader: Touch start")
    self.in_touch = true
    self.first_y = nil
    self.last_y = nil
end

---
-- Called when touch ends - compare first and last Y to determine direction
-- @param time table Event timestamp
function ScrollingRingReader:_onTouchEnd(time)
    logger.dbg("ScrollingRingReader: Touch end, first_y=", self.first_y, "last_y=", self.last_y)
    
    self.in_touch = false
    
    -- Need both first and last Y values
    if self.first_y == nil or self.last_y == nil then
        logger.dbg("ScrollingRingReader: Missing Y values, no scroll")
        self:resetScrollState()
        return
    end
    
    local delta = self.last_y - self.first_y
    
    logger.dbg("ScrollingRingReader: Y delta=", delta, "min_delta=", self.min_delta)
    
    -- Check if movement was large enough
    if math.abs(delta) < self.min_delta then
        logger.dbg("ScrollingRingReader: Delta too small, no scroll")
        self:resetScrollState()
        return
    end
    
    -- Check debounce
    local current_time = self:_getCurrentTime()
    local time_since_last = current_time - self.last_scroll_time
    if time_since_last < self.debounce_interval then
        logger.dbg("ScrollingRingReader: Debouncing")
        self:resetScrollState()
        return
    end
    
    -- Determine direction: positive delta = last > first = scroll up
    local direction
    if delta > 0 then
        direction = self.invert_scroll and "down" or "up"
    else
        direction = self.invert_scroll and "up" or "down"
    end
    
    logger.info("ScrollingRingReader: SCROLL", direction, "delta=", delta)
    
    self.last_scroll_time = current_time
    
    for _, callback in ipairs(self.scroll_callbacks) do
        local ok, err = pcall(callback, direction, time, self.device_path)
        if not ok then
            logger.warn("ScrollingRingReader: Callback error:", err)
        end
    end
    
    self:resetScrollState()
end

---
-- Processes an ABS_Y event - just track the values
-- @param y_value number The Y axis value
function ScrollingRingReader:_processYEvent(y_value)
    if not self.in_touch then
        return
    end
    
    -- Capture first Y if not set
    if self.first_y == nil then
        self.first_y = y_value
        logger.dbg("ScrollingRingReader: First Y=", y_value)
    end
    
    -- Always update last Y
    self.last_y = y_value
end

---
-- Resets scroll tracking state.
function ScrollingRingReader:resetScrollState()
    self.first_y = nil
    self.last_y = nil
    self.in_touch = false
end

---
-- Polls for input events from the device.
-- @param timeout_ms number Optional timeout in milliseconds (default: 0)
-- @return table|nil Array of events or nil
function ScrollingRingReader:poll(timeout_ms)
    if not self.is_open or not self.fd then
        return nil
    end

    timeout_ms = timeout_ms or 0

    local pollfd = ffi.new("struct pollfd[1]")
    pollfd[0].fd = self.fd
    pollfd[0].events = C.POLLIN
    pollfd[0].revents = 0

    local result = C.poll(pollfd, 1, timeout_ms)

    if result <= 0 then
        return nil
    end

    if bit.band(pollfd[0].revents, C.POLLERR) ~= 0 or bit.band(pollfd[0].revents, C.POLLHUP) ~= 0 then
        logger.warn("ScrollingRingReader: Poll error or hangup")
        self:close()
        return nil
    end

    if bit.band(pollfd[0].revents, C.POLLIN) == 0 then
        return nil
    end

    local events = {}
    local input_event = ffi.new("struct input_event")
    local event_size = ffi.sizeof("struct input_event")
    local last_event_time = nil

    while true do
        local bytes_read = C.read(self.fd, input_event, event_size)

        if bytes_read < 0 then
            local err = ffi.errno()
            if err == C.EAGAIN then
                break
            elseif err == C.ENODEV then
                logger.warn("ScrollingRingReader: Device removed")
                self:close()
                break
            elseif err == C.EINTR then
                -- Interrupted, retry
            else
                logger.warn("ScrollingRingReader: Read error, errno:", err)
                break
            end
        elseif bytes_read == 0 then
            break
        elseif bytes_read == event_size then
            local ev = {
                type = tonumber(input_event.type),
                code = tonumber(input_event.code),
                value = tonumber(input_event.value),
                time = {
                    sec = tonumber(input_event.time.tv_sec),
                    usec = tonumber(input_event.time.tv_usec),
                },
                source = "scrolling_ring",
                device_path = self.device_path,
            }

            table.insert(events, ev)
            last_event_time = ev.time

            if ev.type == EV_KEY then
                -- BTN_TOUCH (330) tracks touch state
                if ev.code == 330 then
                    if ev.value == 1 then
                        self:_onTouchStart()
                    else
                        self:_onTouchEnd(ev.time)
                    end
                end
                
                -- Trigger key callbacks on press only
                if ev.value == 1 then
                    for _, callback in ipairs(self.key_callbacks) do
                        local ok, err = pcall(callback, ev.code, ev.value, ev.time, self.device_path)
                        if not ok then
                            logger.warn("ScrollingRingReader: Key callback error:", err)
                        end
                    end
                end
            elseif ev.type == EV_ABS then
                if ev.code == ABS_Y then
                    self:_processYEvent(ev.value)
                end
            end
        end
    end

    if #events > 0 then
        return events
    end

    return nil
end

---
-- Checks if the reader is currently open.
-- @return boolean
function ScrollingRingReader:isOpen()
    return self.is_open
end

---
-- Gets the current device path.
-- @return string|nil
function ScrollingRingReader:getDevicePath()
    return self.device_path
end

---
-- Gets the file descriptor.
-- @return number|nil
function ScrollingRingReader:getFd()
    return self.fd
end

---
-- Sets the minimum delta required to trigger a scroll.
-- @param delta number Minimum Y difference between first and last
function ScrollingRingReader:setMinDelta(delta)
    self.min_delta = delta
end

---
-- Sets whether to invert scroll direction.
-- @param invert boolean
function ScrollingRingReader:setInvertScroll(invert)
    self.invert_scroll = invert
end

---
-- Sets the debounce interval.
-- @param interval number Seconds between allowed scroll events
function ScrollingRingReader:setDebounceInterval(interval)
    self.debounce_interval = interval
end

-- Backwards compatibility
function ScrollingRingReader:setScrollThreshold(threshold)
    self.min_delta = threshold
end

function ScrollingRingReader:setUpThreshold(threshold)
    -- No longer used
end

function ScrollingRingReader:setDownThreshold(threshold)
    -- No longer used
end

return ScrollingRingReader
