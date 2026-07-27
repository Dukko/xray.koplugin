-- xray_fetch_spec.lua
require("spec.spec_helper")
local fetch = require("xray_fetch")

describe("xray_fetch", function()
    local plugin

    before_each(function()
        plugin = createMockPlugin()
        -- Mix in fetch methods
        for k, v in pairs(fetch) do
            plugin[k] = v
        end
        plugin.cache_manager = {
            saveCache = function() return true end,
            asyncSaveCache = function() return true end,
            loadCache = function() return {} end
        }
    end)

    describe("finalizeXRayData", function()
        it("merges new characters correctly in update mode", function()
            plugin.characters = {
                { name = "Alice", description = "Old description" }
            }
            local new_data = {
                characters = {
                    { name = "Alice", description = "New description" },
                    { name = "Bob", description = "A new character" }
                },
                locations = {},
                historical_figures = {},
                timeline = {}
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", true, true, 10)

            assert.are.equal(2, #plugin.characters)
            assert.are.equal("New description", plugin.characters[1].description)
            assert.are.equal("Bob", plugin.characters[2].name)
        end)

        it("filters non-narrative timeline entries", function()
            plugin.isNonNarrativeChapter = function(self, title)
                return title == "Table of Contents"
            end

            local new_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {
                    { chapter = "Chapter 1", text = "Event 1" },
                    { chapter = "Table of Contents", text = "Event 2" }
                }
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", false, true, 10)

            assert.are.equal(1, #plugin.timeline)
            assert.are.equal("Chapter 1", plugin.timeline[1].chapter)
        end)

        it("aborts and protects existing data when AI returns all-empty results", function()
            -- Set up existing data
            plugin.characters = { { name = "Alice", description = "Existing" } }
            plugin.locations = { { name = "Wonderland", description = "Existing" } }
            plugin.timeline = { { chapter = "Start", page = 1 } }
            plugin.historical_figures = { { name = "Lewis Carroll", biography = "Existing" } }

            local empty_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {}
            }

            -- Spy on cache save to ensure it's NOT called
            local save_called = false
            plugin.cache_manager.saveCache = function()
                save_called = true
                return true
            end

            plugin:finalizeXRayData(empty_data, "Test Title", "Test Author", "Some text", true, true, 20)

            -- Existing data should be UNTOUCHED
            assert.are.equal(1, #plugin.characters)
            assert.are.equal("Alice", plugin.characters[1].name)
            assert.are.equal(1, #plugin.locations)
            assert.are.equal(1, #plugin.timeline)
            assert.are.equal(1, #plugin.historical_figures)
            
            -- Cache save should NOT have happened
            assert.is_false(save_called)
        end)

        it("preserves series_prior timeline entries and updates matching chapter event descriptions on update", function()
            plugin.timeline = {
                { chapter = "[Book 1: Prior]", event = "Prior book summary", page = -999, source = "series_prior" },
                { chapter = "Chapter 1", event = "Old chapter 1 summary", page = 10 }
            }

            local new_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {
                    { chapter = "Chapter 1", event = "Updated chapter 1 summary", page = 10 },
                    { chapter = "Chapter 2", event = "New chapter 2 summary", page = 25 }
                }
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", true, true, 20)

            -- Should contain 3 events total: 1 prior series event, 2 current book events
            assert.are.equal(3, #plugin.timeline)

            -- Prior series event should be preserved
            local prior_found = false
            for _, ev in ipairs(plugin.timeline) do
                if ev.source == "series_prior" then
                    prior_found = true
                    assert.are.equal("[Book 1: Prior]", ev.chapter)
                end
            end
            assert.is_true(prior_found)

            -- Chapter 1 event description should be updated
            local ch1_event
            for _, ev in ipairs(plugin.timeline) do
                if ev.chapter == "Chapter 1" then
                    ch1_event = ev
                end
            end
            assert.is_not_nil(ch1_event)
            assert.are.equal("Updated chapter 1 summary", ch1_event.event)
        end)

        it("preserves series_prior timeline entries during non-merge updates", function()
            plugin.timeline = {
                { chapter = "[Book 1: Prior]", event = "Prior book summary", page = -999, source = "series_prior" },
                { chapter = "Chapter 1", event = "Old summary", page = 10 }
            }

            local new_data = {
                characters = {},
                locations = {},
                historical_figures = {},
                timeline = {
                    { chapter = "Chapter 1", event = "Fresh fetch summary", page = 10 }
                }
            }

            plugin:finalizeXRayData(new_data, "Test Title", "Test Author", "Some text", false, true, 20)

            assert.are.equal(2, #plugin.timeline)
            local prior_found = false
            for _, ev in ipairs(plugin.timeline) do
                if ev.source == "series_prior" then
                    prior_found = true
                end
            end
            assert.is_true(prior_found)
        end)
    end)

    describe("mergeSeriesContext", function()
        it("handles missing description/name fields in characters/locations/terms without crashing", function()
            plugin.characters = {
                { name = "Alice" } -- description is nil
            }
            plugin.locations = {
                { name = "Adua" } -- description is nil
            }
            plugin.terms = {
                { name = "The Union" } -- definition is nil
            }

            local cache_data = {
                books = {
                    [1] = {
                        title = "The Blade Itself",
                        characters = { { name = "Alice", description = "Prior description" } },
                        locations = { { name = "Adua", description = "Capital city" } },
                        terms = { { name = "The Union", definition = "Kingdom" } },
                        timeline = { { event = "War breaks out" } }
                    }
                }
            }

            local series_info = { index = 2, slug = "first_law" }

            -- Should merge prior series data without nil indexing error
            plugin:mergeSeriesContext(cache_data, series_info)

            assert.is_true(#plugin.characters > 0)
            assert.is_true(#plugin.timeline > 0)
            assert.is_true(plugin.series_context_loaded)
        end)
    end)
end)


