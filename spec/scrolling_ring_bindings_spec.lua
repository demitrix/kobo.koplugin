---
-- Tests for the scrolling ring bindings manager.

describe("ScrollingRingBindings", function()
    local ScrollingRingBindings
    local UIManager
    local mock_settings
    local instance

    local device_info = { address = "AA:BB:CC:DD:EE:FF", name = "Scrolling Ring" }

    setup(function()
        require("spec/helper")
        ScrollingRingBindings = require("src/scrolling_ring_bindings")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        UIManager:_reset()

        mock_settings = {}

        instance = ScrollingRingBindings:new({
            settings = mock_settings,
        })
        instance:setup(function() end, nil)
        instance.action_lookup_map = nil
    end)

    describe("showActionSelectionMenu", function()
        it("should list available actions in addition to the clear option", function()
            instance:showActionSelectionMenu(device_info, "scroll_up", "Scroll Up")

            local menu = UIManager._shown_widgets[#UIManager._shown_widgets]

            assert.is_not_nil(menu)
            assert.is_table(menu.item_table)
            -- Regression: the list used to contain only "None (clear binding)"
            assert.is_true(#menu.item_table > 1)
        end)

        it("should group actions into non-empty category submenus", function()
            instance:showActionSelectionMenu(device_info, "scroll_up", "Scroll Up")

            local menu = UIManager._shown_widgets[#UIManager._shown_widgets]
            local category_count = 0
            local action_count = 0

            for _, item in ipairs(menu.item_table) do
                if item.sub_item_table then
                    category_count = category_count + 1
                    assert.is_true(#item.sub_item_table > 0)

                    for _, action_item in ipairs(item.sub_item_table) do
                        assert.is_string(action_item.text)
                        assert.is_function(action_item.callback)
                        action_count = action_count + 1
                    end
                end
            end

            assert.is_true(category_count > 0)
            assert.is_true(action_count > 0)
        end)

        it("should store a category-prefixed action ID when an action is selected", function()
            instance:showActionSelectionMenu(device_info, "scroll_up", "Scroll Up")

            local menu = UIManager._shown_widgets[#UIManager._shown_widgets]
            local selected_item, category_name

            for _, item in ipairs(menu.item_table) do
                if item.sub_item_table and item.sub_item_table[1] then
                    selected_item = item.sub_item_table[1]
                    category_name = item.text

                    break
                end
            end

            assert.is_not_nil(selected_item)

            selected_item.callback()

            local stored_id = instance:getDeviceBindings(device_info.address).scroll_up

            assert.is_string(stored_id)
            assert.are.equal(category_name .. ":", stored_id:sub(1, #category_name + 1))
            assert.is_not_nil(instance:getActionById(stored_id))
        end)
    end)

    describe("getActionById", function()
        it("should resolve prefixed action IDs", function()
            local action = instance:getActionById("Reader:next_page")

            assert.is_not_nil(action)
            assert.are.equal("next_page", action.id)
            assert.are.equal("GotoViewRel", action.event)
        end)

        it("should resolve bare action IDs for bindings saved without a prefix", function()
            local action = instance:getActionById("next_page")

            assert.is_not_nil(action)
            assert.are.equal("next_page", action.id)
        end)

        it("should return nil for unknown and nil IDs", function()
            assert.is_nil(instance:getActionById("Reader:does_not_exist"))
            assert.is_nil(instance:getActionById(nil))
        end)
    end)

    describe("onScrollEvent", function()
        it("should dispatch the bound action for a scroll direction", function()
            instance:setBinding(device_info.address, "scroll_up", "Reader:next_page")

            instance:onScrollEvent("up", device_info.address, "/dev/input/event4")

            assert.is_true(#UIManager._send_event_calls > 0)

            local event = UIManager._send_event_calls[1].event

            assert.are.equal("GotoViewRel", event.name)
            assert.are.equal(1, event.args[1])
        end)

        it("should not dispatch anything for an unbound direction", function()
            instance:setBinding(device_info.address, "scroll_up", "Reader:next_page")

            instance:onScrollEvent("down", device_info.address, "/dev/input/event4")

            assert.are.equal(0, #UIManager._send_event_calls)
        end)
    end)

    describe("buildConfigMenuItems", function()
        it("should show the bound action title as the mandatory label", function()
            instance:setBinding(device_info.address, "scroll_up", "Reader:next_page")

            local items = instance:buildConfigMenuItems(device_info)
            local action = instance:getActionById("Reader:next_page")

            assert.are.equal(action.title, items[1].mandatory)
        end)
    end)
end)
