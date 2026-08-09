--[[
Entity Footnotes patch for ultimatejimmy/xray.koplugin
https://github.com/Dukko/xray.koplugin

Underlines AI-identified characters, historical figures, locations, and terms
directly in the reading text and shows a footnote-style popup with the AI
description on tap - the same in-text interaction the plugin already has for
unit conversions. Runs as a chunked, non-blocking scan so page turns stay
responsive.

Install: copy this file into koreader/patches/2-xray-entity-footnotes.lua
Requires: the official xray.koplugin plugin already installed and enabled.
Background: https://github.com/ultimatejimmy/xray.koplugin/pull/100

This patch does not modify xray.koplugin at all. It monkey-patches the
plugin's shared class table at runtime, via KOReader's own
userpatch.registerPatchPluginFunc API (frontend/userpatch.lua) - the
mechanism KOReader itself provides specifically for patching a plugin's
class table from outside, since plugins are dofile()'d rather than
require()'d and never end up in Lua's module cache. All credit for
X-Ray itself goes to ultimatejimmy.
]]

local ok_userpatch, userpatch = pcall(require, "userpatch")
if not ok_userpatch or not userpatch or not userpatch.registerPatchPluginFunc then
    local ok_logger_boot, logger_boot = pcall(require, "logger")
    if ok_logger_boot then
        logger_boot.warn("xray-entity-footnotes patch: userpatch API not available, skipping")
    end
    return
end

local logger = require("logger")
local function log(msg)
    logger.info("EntityFootnotesPatch: " .. tostring(msg))
end

local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local DocSettings = require("docsettings")
local OverlapGroup = require("ui/widget/overlapgroup")

local M = {}

local CATEGORY_LABELS = {
    character = "Character",
    historical_figure = "Historical Figure",
    location = "Location",
    term = "Term",
}

local MIN_TERM_LEN = 3
local MAX_REGEX_LEN = 3000

-- Safe helper for current page
local function _getCurrentPage(plugin)
    if plugin.last_pageno then return plugin.last_pageno end
    if plugin.ui and plugin.ui.paging and plugin.ui.paging.getCurrentPage then
        local ok, pg = pcall(function() return plugin.ui.paging:getCurrentPage() end)
        if ok then return pg end
    end
    if plugin.ui and plugin.ui.pageno then
        return plugin.ui.pageno
    end
    return 1
end

local function escape_pattern(s)
    -- Backslash-escape for the search engine's own regex flavor, not Lua patterns -
    -- a leading "%" here (Lua's own escape prefix) would be passed through literally
    -- instead of escaping the special character for the engine doing the matching.
    local esc = s:gsub("([%-%+%.%?%*%^%$%(%)%[%]%%%\\])", "\\%1")
    esc = esc:gsub("%s+", "\\s+")
    return esc
end

local function _normalize(s)
    return (s or ""):gsub("\194\160", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- Builds a name/alias -> {entity, category, canonical} lookup plus the flat list of
-- unique lowercase search terms, from the already-fetched entity lists.
local function _collectEntityTerms(self, settings)
    local groups = {
        { list = self.characters, category = "character", enabled = settings.entity_cat_characters ~= false },
        { list = self.historical_figures, category = "historical_figure", enabled = settings.entity_cat_historical_figures ~= false },
        { list = self.locations, category = "location", enabled = settings.entity_cat_locations ~= false },
        { list = self.terms, category = "term", enabled = settings.entity_cat_terms ~= false },
    }

    local lookup = {}
    local terms = {}

    for _, group in ipairs(groups) do
        if group.enabled and group.list then
            for _, entity in ipairs(group.list) do
                local names = {}
                if entity.name and entity.name ~= "" then table.insert(names, entity.name) end
                if entity.aliases and type(entity.aliases) == "table" then
                    for _, alias in ipairs(entity.aliases) do
                        if type(alias) == "string" and alias ~= "" then table.insert(names, alias) end
                    end
                end
                for _, n in ipairs(names) do
                    local clean = _normalize(n)
                    if #clean >= MIN_TERM_LEN then
                        local lower = clean:lower()
                        if not lookup[lower] then
                            lookup[lower] = { entity = entity, category = group.category, canonical = entity.name }
                            table.insert(terms, lower)
                        end
                    end
                end
            end
        end
    end

    return terms, lookup
end

-- Splits terms into word-boundary-safe regex chunks, each under MAX_REGEX_LEN, to stay
-- within the text engine's regex size limits on large libraries of entities.
local function _buildChunks(terms)
    table.sort(terms, function(a, b) return #a > #b end)

    local boundary_both = {}
    local boundary_none = {}
    for _, t in ipairs(terms) do
        local esc = escape_pattern(t)
        if t:match("^[%w]") and t:match("[%w]$") then
            table.insert(boundary_both, esc)
        else
            table.insert(boundary_none, esc)
        end
    end

    local function chunk_list(list, wrap_both)
        local chunks = {}
        local current = {}
        local current_len = 0
        for _, esc in ipairs(list) do
            if current_len + #esc + 1 > MAX_REGEX_LEN and #current > 0 then
                table.insert(chunks, current)
                current = {}
                current_len = 0
            end
            table.insert(current, esc)
            current_len = current_len + #esc + 1
        end
        if #current > 0 then table.insert(chunks, current) end

        local patterns = {}
        for _, c in ipairs(chunks) do
            local body = table.concat(c, "|")
            -- crengine's findAllText regex doesn't reliably honor \b as a zero-width word
            -- boundary assertion (a short alias like "Han" can still match as a bare
            -- substring inside "than"). Character classes are a much more basic regex
            -- feature and work reliably, so boundaries are enforced by capturing one
            -- literal non-word character (or start/end of text) on each side instead.
            -- The captured boundary chars get stripped back off in finishScan below.
            table.insert(patterns, wrap_both
                and ("(^|[^A-Za-z0-9_])(" .. body .. ")([^A-Za-z0-9_]|$)")
                or ("(" .. body .. ")"))
        end
        return patterns
    end

    local bounded_patterns = chunk_list(boundary_both, true)
    local patterns = {}
    for _, p in ipairs(bounded_patterns) do table.insert(patterns, p) end
    for _, p in ipairs(chunk_list(boundary_none, false)) do table.insert(patterns, p) end
    return patterns, #bounded_patterns
end

-- ===== Overlay mount (paintTo) =====

function M:clearEntityUnderlines()
    self.entity_boxes = nil
    self.entity_xp_matches = nil
    self.entity_matches_by_page = nil
    if self.ui and self.ui.view and self.ui.view.dialog then
        UIManager:setDirty(self.ui.view.dialog, "ui")
    end
end

-- Buckets matches by page once (at scan/load time) so _resolveEntityHighlightBoxes only has
-- to call the expensive getScreenBoxesFromPositions on matches near the current page, instead
-- of every match in the whole book on every single page turn. Only rolling (reflowable)
-- documents expose the cheap doc:getPageFromXPointer lookup this relies on; paginated
-- documents (PDF etc.) fall back to the unbucketed full-list resolve.
local function _buildMatchesByPage(self, doc, matches)
    if not self.ui or not self.ui.rolling or not doc or not doc.getPageFromXPointer then
        return nil
    end
    local by_page = {}
    for _, m in ipairs(matches) do
        local ok, page = pcall(doc.getPageFromXPointer, doc, m.start_xp)
        if ok and page then
            by_page[page] = by_page[page] or {}
            table.insert(by_page[page], m)
        end
    end
    return by_page
end

function M:mountEntityUnderlineOverlay()
    if self._entity_paintTo_wrapped then return end
    local view = self.ui and self.ui.view
    if not view then return end
    local plugin = self
    local orig = view.paintTo
    view.paintTo = function(view_self, bb, x, y)
        orig(view_self, bb, x, y)
        local ok, err = pcall(function() plugin:_drawEntityUnderlines(bb) end)
        if not ok then
            log("draw error: " .. tostring(err))
        end
    end
    self._entity_paintTo_wrapped = true
end

local function _getEntityCacheSig(self)
    local doc = self.ui and self.ui.document
    if not doc then return "" end
    local page = _getCurrentPage(self)
    local pos = ""
    if doc.getCurrentPos then
        pcall(function() pos = doc:getCurrentPos() end)
    end
    local hash = ""
    if doc.getDocumentRenderingHash then
        pcall(function() hash = doc:getDocumentRenderingHash() end)
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return table.concat({ tostring(page), tostring(pos), tostring(hash), tostring(sw), tostring(sh) }, "|")
end

function M:_resolveEntityHighlightBoxes()
    local sig = _getEntityCacheSig(self)
    if self._entity_box_cache_sig == sig and self.entity_boxes then
        return
    end

    self._entity_box_cache_sig = sig
    local doc = self.ui and self.ui.document
    if not doc or not self.entity_xp_matches or #self.entity_xp_matches == 0 then
        self.entity_boxes = {}
        return
    end

    -- If matches are bucketed by page, only resolve the handful near the current page
    -- instead of every match in the whole book (a name mentioned hundreds of times would
    -- otherwise make every page turn scan the entire book's match list).
    local matches_to_resolve = self.entity_xp_matches
    if self.entity_matches_by_page then
        local page = _getCurrentPage(self)
        matches_to_resolve = {}
        for _, pg in ipairs({ page - 1, page, page + 1 }) do
            local bucket = self.entity_matches_by_page[pg]
            if bucket then
                for _, m in ipairs(bucket) do table.insert(matches_to_resolve, m) end
            end
        end
    end

    -- Resolve each match to its screen box(es) first, keeping multi-line-wrapped matches
    -- grouped together (a single match can produce several boxes, one per visual line).
    local groups = {}
    for _, match in ipairs(matches_to_resolve) do
        local ok, boxes = pcall(doc.getScreenBoxesFromPositions, doc, match.start_xp, match.end_xp, true)
        if ok and boxes and #boxes > 0 then
            local group_boxes = {}
            local top_y, top_x = nil, nil
            for _, box in ipairs(boxes) do
                table.insert(group_boxes, {
                    x = box.x,
                    y = box.y,
                    w = box.w,
                    h = box.h,
                    matched_text = match.matched_text,
                    category = match.category,
                    entity_name = match.entity_name,
                })
                if not top_y or box.y < top_y or (box.y == top_y and box.x < top_x) then
                    top_y, top_x = box.y, box.x
                end
            end
            table.insert(groups, {
                key = (match.category or "") .. "|" .. (match.entity_name or ""),
                sort_y = top_y,
                sort_x = top_x,
                boxes = group_boxes,
            })
        end
    end

    -- Reading order (top-to-bottom, then left-to-right) so the per-page dedup below keeps
    -- whichever mention appears first on the page, not an arbitrary one.
    table.sort(groups, function(a, b)
        if a.sort_y ~= b.sort_y then return a.sort_y < b.sort_y end
        return a.sort_x < b.sort_x
    end)

    -- Only underline the first occurrence of a given entity per page - repeated mentions of
    -- the same name in the same paragraph/page would otherwise clutter the text.
    local seen = {}
    local resolved = {}
    for _, group in ipairs(groups) do
        if not seen[group.key] then
            seen[group.key] = true
            for _, box in ipairs(group.boxes) do
                table.insert(resolved, box)
            end
        end
    end

    self.entity_boxes = resolved
end

local function _checkEntitySettingsChanged(self)
    local settings = self.ai_helper and self.ai_helper.settings or {}
    local enabled = settings.entity_footnotes_enabled ~= false
    local cat_c = settings.entity_cat_characters ~= false
    local cat_h = settings.entity_cat_historical_figures ~= false
    local cat_l = settings.entity_cat_locations ~= false
    local cat_t = settings.entity_cat_terms ~= false
    local style = settings.unit_underline_style or "wavy"
    local thickness = settings.unit_underline_thickness or 2
    local intensity = settings.unit_underline_intensity or "light"

    if self.last_entity_settings_state == nil then
        self.last_entity_settings_state = {
            enabled = enabled, cat_c = cat_c, cat_h = cat_h, cat_l = cat_l, cat_t = cat_t,
            style = style, thickness = thickness, intensity = intensity,
        }
        return false, false
    end

    local state = self.last_entity_settings_state
    local scan_changed = (state.enabled ~= enabled) or (state.cat_c ~= cat_c) or
                         (state.cat_h ~= cat_h) or (state.cat_l ~= cat_l) or (state.cat_t ~= cat_t)
    local draw_changed = (state.style ~= style) or (state.thickness ~= thickness) or (state.intensity ~= intensity)

    if scan_changed or draw_changed then
        self.last_entity_settings_state = {
            enabled = enabled, cat_c = cat_c, cat_h = cat_h, cat_l = cat_l, cat_t = cat_t,
            style = style, thickness = thickness, intensity = intensity,
        }
    end

    return scan_changed, draw_changed
end

function M:_drawEntityUnderlines(bb)
    local scan_needed, redraw_needed = _checkEntitySettingsChanged(self)
    if scan_needed then
        log("Entity settings changed, refreshing entity scan")
        self:scanBookForEntities()
        self._entity_box_cache_sig = nil
    elseif redraw_needed then
        self._entity_box_cache_sig = nil

        local settings = self.ai_helper and self.ai_helper.settings or {}
        if settings.entity_footnotes_enabled == false then
            self:clearEntityUnderlines()
        elseif not self.entity_xp_matches then
            local cache_loaded = self:loadEntityCache()
            if not cache_loaded then
                self:scanBookForEntities()
            end
        end
    end

    local settings = self.ai_helper and self.ai_helper.settings or {}
    if settings.entity_footnotes_enabled == false then return end

    self:_resolveEntityHighlightBoxes()
    if not self.entity_boxes or #self.entity_boxes == 0 then return end

    local underline_style = settings.unit_underline_style or "wavy"
    if underline_style == "invisible" then return end

    local raw_thickness = tonumber(settings.unit_underline_thickness) or 2
    local thickness = Screen:scaleBySize(raw_thickness)
    local intensity = settings.unit_underline_intensity or "light"

    local grey = 150
    if intensity == "light" then
        grey = 200
    elseif intensity == "dark" then
        grey = 30
    end

    for _, box in ipairs(self.entity_boxes) do
        if box.x and box.y and box.w and box.h then
            self._draw_underline(bb, box, underline_style, grey, thickness, raw_thickness, self.path)
        end
    end
end

-- ===== Cache =====

function M:_getEntityCachePath()
    if not self.ui or not self.ui.document or not self.ui.document.file then return nil end
    local sidecar = DocSettings:getSidecarDir(self.ui.document.file)
    if not sidecar then return nil end
    return sidecar .. "/xray_entity_cache.cache"
end

-- Signature covers both the enabled categories and the entity data itself (name lists),
-- so the cache self-invalidates once the AI has fetched more characters/locations/etc,
-- without needing to hook every fetch completion path.
local function _getEntitySettingsSignature(self, settings)
    local function sig_list(list)
        local parts = {}
        if list then
            for _, e in ipairs(list) do
                table.insert(parts, e.name or "")
            end
        end
        return table.concat(parts, ",")
    end

    local cat_c = settings.entity_cat_characters ~= false
    local cat_h = settings.entity_cat_historical_figures ~= false
    local cat_l = settings.entity_cat_locations ~= false
    local cat_t = settings.entity_cat_terms ~= false

    return table.concat({
        "v1",
        tostring(cat_c), tostring(cat_h), tostring(cat_l), tostring(cat_t),
        sig_list(self.characters), sig_list(self.historical_figures),
        sig_list(self.locations), sig_list(self.terms),
    }, "|")
end

function M:loadEntityCache(expected_sig)
    local cache_file = self:_getEntityCachePath()
    if not cache_file then return false end

    local f = io.open(cache_file, "r")
    if not f then return false end

    local signature = f:read("*l")
    if not signature then
        f:close()
        return false
    end
    signature = signature:gsub("%s+$", "")

    local settings = self.ai_helper and self.ai_helper.settings or {}
    expected_sig = expected_sig or _getEntitySettingsSignature(self, settings)
    if signature ~= expected_sig then
        f:close()
        return false
    end

    local matches = {}
    for line in f:lines() do
        line = line:gsub("\r", "")
        local start_xp, end_xp, matched_text, category, entity_name = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)$")
        if start_xp then
            table.insert(matches, {
                start_xp = start_xp,
                end_xp = end_xp,
                matched_text = matched_text,
                category = category,
                entity_name = entity_name,
            })
        end
    end
    f:close()

    self.entity_xp_matches = matches
    self.entity_matches_by_page = _buildMatchesByPage(self, self.ui and self.ui.document, matches)
    self._entity_box_cache_sig = nil
    log("loadEntityCache: loaded " .. tostring(#matches) .. " matches from cache")
    if self.ui and self.ui.view then
        if self.ui.view.dialog then
            UIManager:setDirty(self.ui.view.dialog, "ui")
        end
        UIManager:setDirty(nil, "ui")
    end
    return true
end

function M:saveEntityCache(signature)
    local cache_file = self:_getEntityCachePath()
    if not cache_file then return end

    local settings = self.ai_helper and self.ai_helper.settings or {}
    signature = signature or _getEntitySettingsSignature(self, settings)

    local dir = cache_file:match("^(.+)/[^/]+$")
    if dir then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then
            if lfs.attributes(dir, "mode") ~= "directory" then
                lfs.mkdir(dir)
            end
        end
    end

    local ok, err = pcall(function()
        local f, open_err = io.open(cache_file, "w")
        if f then
            f:write(signature .. "\n")
            for _, m in ipairs(self.entity_xp_matches or {}) do
                local matched_clean = (m.matched_text or ""):gsub("\r", " "):gsub("\n", " ")
                local name_clean = (m.entity_name or ""):gsub("\r", " "):gsub("\n", " ")
                f:write(string.format("%s\t%s\t%s\t%s\t%s\n",
                    tostring(m.start_xp or ""),
                    tostring(m.end_xp or ""),
                    matched_clean,
                    m.category or "",
                    name_clean))
            end
            f:close()
        else
            log("saveEntityCache: failed to open cache: " .. tostring(open_err))
        end
    end)
    if not ok then
        log("saveEntityCache: unexpected error writing cache: " .. tostring(err))
    end
end

-- ===== Scan =====

function M:scanBookForEntities(force)
    if not self.ui or not self.ui.document then return end

    local settings = self.ai_helper and self.ai_helper.settings or {}
    if settings.entity_footnotes_enabled == false then
        self:clearEntityUnderlines()
        return
    end

    if self._entity_scan_in_progress then return end

    local resolved_sig = _getEntitySettingsSignature(self, settings)
    if not force then
        local cache_loaded = self:loadEntityCache(resolved_sig)
        if cache_loaded then
            log("scanBookForEntities: returning early due to cached hits")
            return
        end
    end

    local terms, lookup = _collectEntityTerms(self, settings)
    if #terms == 0 then
        -- Mark as "scanned, nothing to show" (not nil) so the paint-time check in
        -- _drawEntityUnderlines doesn't treat this as "never scanned" and rescan every repaint.
        self.entity_xp_matches = {}
        self.entity_boxes = {}
        self.entity_matches_by_page = nil
        self._entity_box_cache_sig = nil
        if self.ui and self.ui.view and self.ui.view.dialog then
            UIManager:setDirty(self.ui.view.dialog, "ui")
        end
        return
    end

    self._entity_scan_in_progress = true
    local doc = self.ui.document
    local Notification = require("ui/widget/notification")

    -- Runs as a chunked background task: one regex chunk is matched per event-loop tick
    -- (scheduleIn(0, step) yields back to UIManager between chunks) instead of looping
    -- through every chunk inside a single blocking call. Unlike the unit converter, which
    -- only scans once per book open, this scan re-runs every time new entity data arrives
    -- (fetchMoreCharacters/fetchMoreTerms/mergeSeriesContext), so it must not freeze
    -- reading/input while it works.
    local patterns, bounded_pattern_count = _buildChunks(terms)
    local total_patterns = math.max(1, #patterns)
    local hits = {}
    local idx = 0

    local function finishScan()
        local ok_finish, err_finish = pcall(function()
            -- Deduplicate overlapping hits by end xpointer, keeping the longest match
            local unique_hits = {}
            for _, hit in ipairs(hits) do
                local end_xp = hit["end"]
                if not unique_hits[end_xp] or #hit.matched_text > #unique_hits[end_xp].matched_text then
                    unique_hits[end_xp] = hit
                end
            end

            local xp_matches = {}
            for _, hit in pairs(unique_hits) do
                local matched = _normalize(hit.matched_text or "")
                if hit.__bounded then
                    -- Strip the boundary character(s) the pattern captured on purpose
                    -- (see _buildChunks) before looking the term up.
                    matched = matched:gsub("^[^%w]+", ""):gsub("[^%w]+$", "")
                end
                local entry = lookup[matched:lower()]
                if entry then
                    table.insert(xp_matches, {
                        start_xp = hit.start,
                        end_xp = hit["end"],
                        matched_text = matched,
                        category = entry.category,
                        entity_name = entry.canonical,
                    })
                end
            end

            self.entity_xp_matches = xp_matches
            self.entity_matches_by_page = _buildMatchesByPage(self, doc, xp_matches)
            self._entity_box_cache_sig = nil
            log("scanBookForEntities: found " .. tostring(#xp_matches) .. " entity mentions")

            UIManager:show(Notification:new{
                text = tostring(#xp_matches) .. " footnotes found",
                timeout = 3,
                toast = true,
            })
            if self.ui and self.ui.view then
                if self.ui.view.dialog then
                    UIManager:setDirty(self.ui.view.dialog, "ui")
                end
                UIManager:setDirty(nil, "ui")
            end

            UIManager:scheduleIn(0.5, function()
                if not self.destroyed then
                    self:saveEntityCache(resolved_sig)
                end
            end)
        end)

        self._entity_scan_in_progress = false
        if not ok_finish then
            log("scanBookForEntities finish error: " .. tostring(err_finish))
        end
    end

    local function step()
        if self.destroyed or not self.ui or not self.ui.document then
            self._entity_scan_in_progress = false
            return
        end

        idx = idx + 1
        local pat = patterns[idx]
        if not pat then
            finishScan()
            return
        end

        local is_bounded = idx <= bounded_pattern_count
        local ok1, hits1 = pcall(function()
            return doc:findAllText(pat, true, 0, 5000, true)
        end)
        if ok1 and hits1 then
            for _, h in ipairs(hits1) do
                h.__bounded = is_bounded
                table.insert(hits, h)
            end
        else
            log("scanBookForEntities: findAllText pcall failed (non-fatal): " .. tostring(hits1))
        end

        -- Yield back to the event loop between chunks so page turns, taps, and menu
        -- input keep being processed while the scan continues in the background.
        UIManager:scheduleIn(0, step)
    end

    if total_patterns >= 3 then
        UIManager:show(Notification:new{
            text = self.loc:t("entity_scanning_book") or "Scanning book for footnotes...",
            timeout = 2,
            toast = true,
        })
    end

    UIManager:scheduleIn(0, step)
end

-- ===== Tooltip / footnote popup =====

local function _getPopupFontSize(plugin)
    local size
    if plugin and plugin.ui and plugin.ui.font and plugin.ui.font.configurable then
        size = plugin.ui.font.configurable.font_size
    elseif G_reader_settings then
        size = G_reader_settings:readSetting("cre_font_size")
              or G_reader_settings:readSetting("kopt_font_size")
    end
    if size then return size end
    if Screen.scaleBySize then
        return Screen:scaleBySize(22)
    end
    return 22
end

local function getFontSafe(preferred_family, size)
    if preferred_family and preferred_family ~= "" then
        local ok, credoc = pcall(require, "document/credocument")
        if ok and credoc and credoc.engineInit then
            local ok2, cre = pcall(credoc.engineInit, credoc)
            if ok2 and cre and cre.getFontFaceFilenameAndFaceIndex then
                local filename, faceindex = cre.getFontFaceFilenameAndFaceIndex(preferred_family)
                if not filename then
                    filename, faceindex = cre.getFontFaceFilenameAndFaceIndex(preferred_family, nil, true)
                end
                if filename then
                    local face_ok, face = pcall(Font.getFace, Font, filename, size, faceindex)
                    if face_ok and face then return face end
                end
            end
        end
    end
    return Font:getFace("cfont", size)
end

local EntityFootnote = InputContainer:extend{
    box = nil,
    entity = nil,
    category = nil,
    title_text = "",
    description_text = "",
    plugin = nil,
    timeout = 8,
    timer_handle = nil,
    _closed = false,
}

function EntityFootnote:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local sc = function(n) return Screen:scaleBySize(n) end

    local fs = _getPopupFontSize(self.plugin)
    local doc_family
    if self.plugin and self.plugin.ui and self.plugin.ui.font then
        doc_family = self.plugin.ui.font.font_face
    end
    if not doc_family and G_reader_settings then
        doc_family = G_reader_settings:readSetting("cre_font_family")
    end
    local face = getFontSafe(doc_family, fs)
    local small_face = getFontSafe(doc_family, math.max(12, fs - 4))

    local pad_h = 24
    local pad_v = math.floor(fs * 0.55)
    local card_w = math.floor(math.min(sw, sh) * 0.82)
    local text_w = card_w - pad_h * 2

    local vg = VerticalGroup:new{ align = "left" }
    table.insert(vg, TextBoxWidget:new{
        text = self.title_text,
        face = face,
        width = text_w,
        bold = true,
    })

    local label = CATEGORY_LABELS[self.category]
    if label then
        table.insert(vg, VerticalSpan:new{ width = math.max(2, math.floor(fs * 0.15)) })
        table.insert(vg, TextBoxWidget:new{
            text = label,
            face = small_face,
            width = text_w,
        })
    end

    table.insert(vg, VerticalSpan:new{ width = math.max(6, math.floor(fs * 0.35)) })
    table.insert(vg, TextBoxWidget:new{
        text = self.description_text,
        face = face,
        width = text_w,
    })

    local card = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = sc(2),
        color = Blitbuffer.COLOR_DARK_GRAY,
        radius = 0,
        padding_top = pad_v,
        padding_bottom = pad_v,
        padding_left = pad_h,
        padding_right = pad_h,
        width = card_w,
        vg,
    }

    local card_size = card:getSize()
    card_w = card_size.w
    local card_h = math.min(card_size.h, sh - sc(40))

    local margin = sc(10)
    local box = self.box
    local ref_x = box.x + box.w / 2
    local ref_bottom = box.y + box.h
    local ref_top = box.y

    local arrow_w = sc(16)
    local arrow_h = sc(8)
    local border_px = sc(2)

    local popup_x = math.max(0, math.min(sw - card_w, math.floor(ref_x - card_w / 2)))
    local popup_y
    local popup_below_word
    if ref_bottom + margin + card_h <= sh then
        popup_y = ref_bottom + margin
        popup_below_word = true
    else
        popup_y = ref_top - margin - card_h - arrow_h + border_px
        popup_below_word = false
    end

    if popup_below_word then
        popup_y = math.max(arrow_h - border_px, math.min(sh - card_h, popup_y))
    else
        popup_y = math.max(0, math.min(sh - card_h - arrow_h + border_px, popup_y))
    end
    card.overlap_offset = { popup_x, popup_y }

    local apex_min = popup_x + arrow_w / 2 + sc(4)
    local apex_max = popup_x + card_w - arrow_w / 2 - sc(4)
    local apex_x
    if apex_min <= apex_max then
        apex_x = math.max(apex_min, math.min(apex_max, ref_x))
    else
        apex_x = popup_x + card_w / 2
    end

    local arrow_x = math.floor(apex_x - arrow_w / 2)
    local arrow_y
    local arrow_dir
    if popup_below_word then
        arrow_dir = "up"
        arrow_y = popup_y - arrow_h + border_px
    else
        arrow_dir = "down"
        arrow_y = popup_y + card_h - border_px
    end

    local PointerArrowClass = self.plugin and self.plugin._PointerArrow
    local arrow
    if PointerArrowClass then
        arrow = PointerArrowClass:new{
            width = arrow_w,
            height = arrow_h,
            direction = arrow_dir,
            apex_offset = arrow_w / 2,
            border_size = border_px,
            border_color = Blitbuffer.COLOR_DARK_GRAY,
            fill_color = Blitbuffer.COLOR_WHITE,
        }
        arrow.overlap_offset = { arrow_x, arrow_y }
    end

    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        TapOutside = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh }
            }
        }
    }

    local children = { dimen = Geom:new{ w = sw, h = sh }, card }
    if arrow then table.insert(children, arrow) end
    self[1] = OverlapGroup:new(children)
end

function EntityFootnote:onTapOutside()
    self:dismiss()
    return true
end

function EntityFootnote:onClose()
    self:dismiss()
    return true
end

function EntityFootnote:dismiss()
    if self.timer_handle then
        pcall(function() self.timer_handle:cancel() end)
        self.timer_handle = nil
    end
    if not self._closed then
        self._closed = true
        UIManager:close(self)
    end
end

function EntityFootnote:onShow()
    if self.timeout and self.timeout > 0 then
        local this = self
        self.timer_handle = UIManager:scheduleIn(self.timeout, function()
            if not this._closed then
                this:dismiss()
            end
        end)
    end
    UIManager:setDirty(self, "ui")
    return true
end

function M:_findEntityByNameAndCategory(name, category)
    local list
    if category == "character" then list = self.characters
    elseif category == "historical_figure" then list = self.historical_figures
    elseif category == "location" then list = self.locations
    elseif category == "term" then list = self.terms
    end
    if not list then return nil end

    local lower = (name or ""):lower()
    for _, e in ipairs(list) do
        if (e.name or ""):lower() == lower then return e end
    end
    return nil
end

function M:showEntityFootnote(box)
    if not box then return end
    local entity = self:_findEntityByNameAndCategory(box.entity_name, box.category)
    if not entity then return end

    local desc
    if box.category == "term" then
        desc = entity.definition or entity.expanded
    elseif self.resolveDescriptionForPage then
        local current_page = _getCurrentPage(self)
        desc = self:resolveDescriptionForPage(entity, current_page)
    else
        desc = entity.description or entity.biography
    end
    if not desc or desc == "" or desc == "---" then
        desc = self.loc:t("entity_no_description") or "No description available yet."
    end

    local settings = self.ai_helper and self.ai_helper.settings or {}
    local timeout = tonumber(settings.entity_tooltip_timeout) or 8

    local footnote = EntityFootnote:new{
        box = box,
        entity = entity,
        category = box.category,
        title_text = entity.name or box.matched_text or "",
        description_text = desc,
        plugin = self,
        timeout = timeout,
    }
    UIManager:show(footnote)
end

-- ===== Tap handling =====

-- Mount tap handler via monkey patching self.ui.highlight.onTap. Chains after the unit
-- converter's tap handler (if mounted), so both features can coexist without conflicting.
function M:mountEntityTapHandler()
    if self._entityTapHandler_wrapped then return end
    local plugin = self
    local hl = self.ui and self.ui.highlight
    if not hl then return end
    local orig_tap = hl.onTap
    hl.onTap = function(hl_self, _, ges)
        if ges and plugin:_handleEntityTap(ges) then return true end
        if orig_tap then return orig_tap(hl_self, _, ges) end
    end
    self._entityTapHandler_wrapped = true
end

function M:_handleEntityTap(ges)
    local settings = self.ai_helper and self.ai_helper.settings or {}
    if settings.entity_footnotes_enabled == false then return false end

    if not self.entity_boxes or #self.entity_boxes == 0 then
        return false
    end
    local tx, ty = ges.pos.x, ges.pos.y
    for _, box in ipairs(self.entity_boxes) do
        if tx >= box.x and tx <= box.x + box.w
        and ty >= box.y - 6 and ty <= box.y + box.h + 6 then
            self:showEntityFootnote(box)
            return true
        end
    end
    return false
end

-- userpatch.registerPatchPluginFunc hands us the actual, in-use plugin class table
-- (via PluginLoader:createPluginInstance) every time a new instance is about to be
-- created - this runs once per book/FileManager open, so the guard below makes sure
-- we only apply our monkey-patches to the class table once, not once per open.
userpatch.registerPatchPluginFunc("xray", function(XRayPlugin)
if XRayPlugin.__entity_footnotes_patched then return end
XRayPlugin.__entity_footnotes_patched = true

-- Apply the mixin onto the shared plugin class table, exactly like xray.koplugin's own
-- main.lua does for its built-in modules (safeRequireMixin/applyMixin).
for k, v in pairs(M) do
    XRayPlugin[k] = v
end

-- xray.koplugin's own Localization:t() falls back to returning the raw key string
-- itself for any key it doesn't recognize (translation = fallbacks[key] or key), never
-- nil - so the "self.loc:t(key) or english_text" pattern used throughout this patch
-- never actually falls through to our english_text. These entries get injected
-- straight into the shared translations table below so :t() finds a real value
-- before it ever reaches that fallback.
local ENTITY_FOOTNOTES_EN_STRINGS = {
    menu_entity_footnotes = "Entity Footnotes",
    entity_footnotes_enabled = "Enable Entity Footnotes",
    entity_manual_scan_button = "Scan/Rescan",
    entity_style_settings = "Style & Underline Settings",
    menu_entity_categories = "Entity Categories",
    entity_cat_characters = "Characters",
    entity_cat_historical_figures = "Historical Figures",
    entity_cat_locations = "Locations",
    entity_cat_terms = "Terms",
    entity_scanning_book = "Scanning book for footnotes...",
    entity_no_description = "No description available yet.",
}

-- Hook per-document init: mounts the underline/tap overlays and kicks off the first scan,
-- the same setup steps the plugin's own init already performs for the unit converter.
local orig_init = XRayPlugin.init
function XRayPlugin:init(...)
    local ret = orig_init(self, ...)
    local ok, err = pcall(function()
        -- self.loc:init() (called by orig_init above) reloads self.loc.translations
        -- from scratch on every book open, so this has to be redone every time too,
        -- not just once.
        if self.loc and self.loc.translations then
            for k, v in pairs(ENTITY_FOOTNOTES_EN_STRINGS) do
                if not self.loc.translations[k] or self.loc.translations[k] == "" then
                    self.loc.translations[k] = v
                end
            end
        end

        local settings = self.ai_helper and self.ai_helper.settings or {}
        if self.mountEntityUnderlineOverlay then self:mountEntityUnderlineOverlay() end
        if self.mountEntityTapHandler then self:mountEntityTapHandler() end
        if self.scanBookForEntities and settings.entity_footnotes_enabled ~= false then
            self:scanBookForEntities()
        end
    end)
    if not ok then
        log("init hook error: " .. tostring(err))
    end
    return ret
end

-- Hook the X-Ray menu: getSubMenuItems is called fresh every time the menu opens, so this
-- doesn't need to run at any particular startup phase relative to menu construction.
local orig_getSubMenuItems = XRayPlugin.getSubMenuItems
function XRayPlugin:getSubMenuItems(...)
    local items = orig_getSubMenuItems(self, ...)
    if not items then return items end

    local entity_menu_entry = {
        is_entity_footnotes = true,
        text = self.loc:t("menu_entity_footnotes") or "Entity Footnotes",
        keep_menu_open = true,
        sub_item_table = {
            {
                text = self.loc:t("entity_footnotes_enabled") or "Enable Entity Footnotes",
                checked_func = function()
                    return self.ai_helper.settings.entity_footnotes_enabled ~= false
                end,
                callback = function()
                    local current = self.ai_helper.settings.entity_footnotes_enabled ~= false
                    self.ai_helper:saveSettings({ entity_footnotes_enabled = not current })
                    if self.scanBookForEntities then self:scanBookForEntities() end
                end
            },
            {
                text = self.loc:t("entity_manual_scan_button") or "Scan/Rescan",
                keep_menu_open = true,
                callback = function()
                    if self.scanBookForEntities then self:scanBookForEntities(true) end
                end,
                separator = true,
            },
            {
                text = self.loc:t("entity_style_settings") or "Style & Underline Settings",
                keep_menu_open = true,
                callback = function()
                    self:showUnitStyleCard()
                end
            },
            {
                text = self.loc:t("menu_entity_categories") or "Entity Categories",
                keep_menu_open = true,
                sub_item_table = {
                    {
                        text = self.loc:t("entity_cat_characters") or "Characters",
                        checked_func = function()
                            return self.ai_helper.settings.entity_cat_characters ~= false
                        end,
                        callback = function()
                            local curr = self.ai_helper.settings.entity_cat_characters ~= false
                            self.ai_helper:saveSettings({ entity_cat_characters = not curr })
                            if self.scanBookForEntities then self:scanBookForEntities(true) end
                        end
                    },
                    {
                        text = self.loc:t("entity_cat_historical_figures") or "Historical Figures",
                        checked_func = function()
                            return self.ai_helper.settings.entity_cat_historical_figures ~= false
                        end,
                        callback = function()
                            local curr = self.ai_helper.settings.entity_cat_historical_figures ~= false
                            self.ai_helper:saveSettings({ entity_cat_historical_figures = not curr })
                            if self.scanBookForEntities then self:scanBookForEntities(true) end
                        end
                    },
                    {
                        text = self.loc:t("entity_cat_locations") or "Locations",
                        checked_func = function()
                            return self.ai_helper.settings.entity_cat_locations ~= false
                        end,
                        callback = function()
                            local curr = self.ai_helper.settings.entity_cat_locations ~= false
                            self.ai_helper:saveSettings({ entity_cat_locations = not curr })
                            if self.scanBookForEntities then self:scanBookForEntities(true) end
                        end
                    },
                    {
                        text = self.loc:t("entity_cat_terms") or "Terms",
                        checked_func = function()
                            return self.ai_helper.settings.entity_cat_terms ~= false
                        end,
                        callback = function()
                            local curr = self.ai_helper.settings.entity_cat_terms ~= false
                            self.ai_helper:saveSettings({ entity_cat_terms = not curr })
                            if self.scanBookForEntities then self:scanBookForEntities(true) end
                        end
                    },
                }
            }
        },
        separator = true,
    }

    table.insert(items, math.max(1, #items), entity_menu_entry)
    return items
end

log("applied to xray.koplugin class table")
end)

log("Entity Footnotes patch registered")
