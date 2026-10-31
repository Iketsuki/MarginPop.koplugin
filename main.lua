local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local RenderText = require("ui/rendertext")
local RenderImage = require("ui/renderimage")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local MARKER_V2 = "KOPOPZH2\n"
local MARKER_V1 = "KOPOPZH1\n"
local POSITION_SETTING = "marginpop_positions_v2"
local DIRTY_SETTING = "marginpop_positions_dirty_v2"
local PENDING_ANNOTATIONS_SETTING = "marginpop_pending_annotations_v1"
local SIDECAR_ANNOTATIONS_SETTING = "marginpop_annotations_v1"
local EMOJI_HISTORY_SETTING = "marginpop_emoji_history_v1"
local EMOJI_FAVORITES_SETTING = "marginpop_emoji_favorites_v1"
local PAGE_OFFSET_SETTING = "marginpop_page_offset_v1"
local PDF_REFLOW_ANCHOR_MODE_SETTING = "marginpop_pdf_reflow_anchor_mode_v1"
local PDF_EMBED_NOTES_SETTING = "marginpop_embed_pdf_notes_v1"
local PDF_NOTE_DELETES_SETTING = "marginpop_pdf_note_deletes_v1"
local PDF_NOTE_SERIAL_SETTING = "marginpop_pdf_note_serial_v1"
local ANNOTATION_EDITOR_FULLSCREEN_SETTING = "marginpop_annotation_editor_fullscreen_v1"
local CONTEXT_FORMATS_SETTING = "marginpop_context_formats_v1"
local EXPORT_CONTEXT_SETTING = "marginpop_export_context_v1"
local PDF_MARKER_INDEX_SETTING = "marginpop_pdf_marker_index_v1"
local ANNOTATION_MARGIN_WIDTH_SETTING = "marginpop_annotation_margin_width_v1"
local ANNOTATION_MARGIN_SIDE_SETTING = "marginpop_annotation_margin_side_v1"
local ANNOTATION_SHOW_TEXT_SETTING = "marginpop_annotation_show_text_v1"
local ANNOTATION_SHOW_TEXT_EPUB_SETTING = "marginpop_annotation_show_text_epub_v1"
local ANNOTATION_SHOW_TEXT_TXT_SETTING = "marginpop_annotation_show_text_txt_v1"
local ANNOTATION_SHOW_TEXT_PDF_SETTING = "marginpop_annotation_show_text_pdf_v1"
local ANNOTATION_FONT_SIZE_SETTING = "marginpop_annotation_font_size_v1"
local ANNOTATION_EMOJI_POSITION_SETTING = "marginpop_annotation_emoji_position_v1"
local ANNOTATION_PDF_REFLOW_EMOJI_POSITION_SETTING =
    "marginpop_pdf_reflow_emoji_position_v1"
local ANNOTATION_SHOW_TEXT_REFLOW_SETTING = "marginpop_annotation_show_text_reflow_v1"
local ANNOTATION_SELECTION_DEFAULT_SETTING = "marginpop_annotation_selection_default_v1"
local EMBEDDED_POS_PREFIX = "@KOPOP_POS "
local EMBEDDED_EMOJI_PREFIX = "@KOPOP_EMOJI "
local EMBEDDED_EMOJI_SIZE_PREFIX = "@KOPOP_EMOJI_SIZE "
local EMBEDDED_XPOINTER_PREFIX = "@KOPOP_XPOINTER "
local EMOJI_SIZE_SETTING = "marginpop_emoji_size"
local PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."
local KOREADER_DIR = PLUGIN_DIR:match("^(.*)/plugins/[^/]+$") or PLUGIN_DIR
local DEFAULT_EXPORT_DIR = KOREADER_DIR .. "/popupExport"

-- Keep the plugin loadable if an older installation has not copied the new
-- artwork/catalog yet; the add-mode gesture must still work for plain dots.
local faces_loaded, loaded_faces = pcall(dofile, PLUGIN_DIR .. "/faces.lua")
local FACE_EMOJIS = faces_loaded and type(loaded_faces) == "table" and loaded_faces or {}
local FACE_NAME_BY_CODE = {}
for _, face in ipairs(FACE_EMOJIS) do
    FACE_NAME_BY_CODE[face.code] = face.name
end
local AVAILABLE_FACE_EMOJIS

local function available_face_emojis()
    if AVAILABLE_FACE_EMOJIS then return AVAILABLE_FACE_EMOJIS end
    AVAILABLE_FACE_EMOJIS = {}
    for _, face in ipairs(FACE_EMOJIS) do
        if lfs.attributes(PLUGIN_DIR .. "/openmoji-black/" .. face.code .. ".svg", "mode") == "file" then
            AVAILABLE_FACE_EMOJIS[#AVAILABLE_FACE_EMOJIS + 1] = face
        end
    end
    return AVAILABLE_FACE_EMOJIS
end

local function emoji_tag(code)
    if not code then return nil end
    local name = FACE_NAME_BY_CODE[code] or code
    local tag = name:lower():gsub("[^%w]+", "_"):gsub("^_", ""):gsub("_$", "")
    return tag ~= "" and tag or "emoji"
end

local function emoji_label(code)
    if not code then return _("No emoji") end
    return FACE_NAME_BY_CODE[code] or _("Emoji")
end

-- Visual marker stays small, while the tappable/holdable area is much larger.
local MARKER_DIAMETER = Screen:scaleBySize(10)
local TAP_DIAMETER = Screen:scaleBySize(34)
local MARKER_BORDER = math.max(1, Screen:scaleBySize(1))
local DEFAULT_ANNOTATION_MARGIN_WIDTH = 56
local DEFAULT_ANNOTATION_FONT_SIZE = 2
local DEFAULT_ANNOTATION_EMOJI_SIZE = 12
local DEFAULT_CONTEXT_FORMATS = {
    book = "Book: {title}",
    chapter = "Chapter: {chapter}",
    page = "Page: {page}",
}

local ACTIVE = rawget(_G, "__marginpop_active")
if not ACTIVE then
    ACTIVE = setmetatable({}, { __mode = "k" })
    rawset(_G, "__marginpop_active", ACTIVE)
end

local MarginPop = WidgetContainer:extend{
    name = "marginpop",
    is_doc_only = true,
    pdf_reflow_anchor_mode = "nearest",
}

local function starts_with(s, prefix)
    return type(s) == "string" and s:sub(1, #prefix) == prefix
end

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function popup_width(text, face)
    local longest = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local measured = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, line, true).x
        longest = math.max(longest, measured)
    end
    local padding = Screen:scaleBySize(36)
    return math.floor(clamp(
        longest + padding,
        Screen:getWidth() * 0.24,
        Screen:getWidth() * 0.78
    ))
end

local function payload_version_and_text(contents)
    if type(contents) ~= "string" then return end
    contents = contents:gsub("\r\n", "\n")

    if starts_with(contents, MARKER_V2) then
        local rest = contents:sub(#MARKER_V2 + 1)
        local x, y, after_pos = rest:match(
            "^@KOPOP_POS%s+([%+%-%.%dEe]+)%s+([%+%-%.%dEe]+)%s*\n(.*)$"
        )
        if x and y then
            rest = after_pos or ""
        end
        local emoji, after_emoji = rest:match("^@KOPOP_EMOJI%s+([%x%-]+)\n(.*)$")
        if emoji then
            rest = after_emoji or ""
        end
        local emoji_size
        if emoji then
            local saved_size, after_size = rest:match("^@KOPOP_EMOJI_SIZE%s+(%d+)\n(.*)$")
            if saved_size then
                emoji_size = tonumber(saved_size)
                if not emoji_size or emoji_size < 2 or emoji_size > 64 then
                    emoji_size = nil
                end
                rest = after_size or ""
            end
        end
        local xpointer, after_xpointer = rest:match("^@KOPOP_XPOINTER%s+([^\n]+)\n(.*)$")
        if xpointer then
            rest = after_xpointer or ""
        end
        if not x then rest = rest:gsub("^%s+", "") end
        return 2, rest, tonumber(x), tonumber(y), emoji, emoji_size, xpointer
    end
    if starts_with(contents, MARKER_V1) then
        return 1, contents:sub(#MARKER_V1 + 1):gsub("^%s+", ""), nil, nil
    end
end

local function build_v2_payload(text, x, y, emoji, emoji_size, xpointer)
    local payload = MARKER_V2
    if x and y then
        payload = payload .. string.format("%s%.6f %.6f\n", EMBEDDED_POS_PREFIX, x, y)
    end
    if emoji and emoji:match("^[%x%-]+$") then
        payload = payload .. EMBEDDED_EMOJI_PREFIX .. emoji .. "\n"
        if emoji_size then
            payload = payload .. EMBEDDED_EMOJI_SIZE_PREFIX .. emoji_size .. "\n"
        end
    end
    if type(xpointer) == "string" and xpointer:match("%S")
        and not xpointer:find("[\r\n]") then
        payload = payload .. EMBEDDED_XPOINTER_PREFIX .. xpointer .. "\n"
    end
    return payload .. (text or "")
end

local function marker_key(page, index)
    return string.format("p%d:%d", page, index)
end

local function safe_filename(text)
    local name = (text or ""):lower():gsub("[^%w%-_]+", "-")
        :gsub("^%-+", ""):gsub("%-+$", "")
    return name ~= "" and name:sub(1, 48) or "annotation"
end

local function truncate_utf8(text, max_bytes)
    if #text <= max_bytes then return text end
    local pos, last = 1, 0
    while pos <= #text do
        local first = text:byte(pos)
        local length = first < 0x80 and 1 or first < 0xE0 and 2
            or first < 0xF0 and 3 or 4
        if pos + length - 1 > max_bytes - 3 then break end
        pos = pos + length
        last = pos - 1
    end
    return text:sub(1, last) .. "..."
end

local function annotation_entry_key(entry)
    return entry.marker and ("pdf:" .. entry.marker.key)
        or ("sidecar:" .. tostring(entry.index))
end

function MarginPop:_activate()
    if self.ui and self.ui.document then
        ACTIVE[self.ui] = self
    end
end

function MarginPop:_loadPositions()
    self.positions = {}
    self.dirty_positions = {}
    self.pending_annotations = {}

    if not (self.ui and self.ui.doc_settings) then
        return
    end

    self.positions = self.ui.doc_settings:readSetting(POSITION_SETTING) or {}
    self.pending_annotations = self.ui.doc_settings:readSetting(PENDING_ANNOTATIONS_SETTING) or {}
    self.emoji_size = tonumber(self.ui.doc_settings:readSetting(EMOJI_SIZE_SETTING))
        or DEFAULT_ANNOTATION_EMOJI_SIZE
    self.emoji_size = clamp(self.emoji_size, 2, 64)
    local saved_dirty = self.ui.doc_settings:readSetting(DIRTY_SETTING)
    if saved_dirty then
        self.dirty_positions = saved_dirty
    else
        -- Migration from v2.0/v2.1: every sidecar position predates PDF
        -- embedding, so treat it as pending and flush it on the next clean
        -- close/manual write.
        for key in pairs(self.positions) do
            self.dirty_positions[key] = "move"
        end
    end
end

function MarginPop:_savePositions()
    if self.ui and self.ui.doc_settings then
        self.ui.doc_settings:saveSetting(POSITION_SETTING, self.positions or {})
        self.ui.doc_settings:saveSetting(DIRTY_SETTING, self.dirty_positions or {})
        self.ui.doc_settings:saveSetting(PENDING_ANNOTATIONS_SETTING, self.pending_annotations or {})
        if self.ui.doc_settings.flush then
            local ok, saved = pcall(self.ui.doc_settings.flush, self.ui.doc_settings)
            if not ok or not saved then
                logger.warn("PDF popup sidecar save failed:", saved)
                return false
            end
        end
        return true
    end
    return false
end

function MarginPop:_writePdfOnce()
    local doc = self.ui.document
    if self.pdf_write_attempted then
        doc.is_edited = false
        error("PDF already saved in this reading session")
    end
    local original_size = lfs.attributes(doc.file, "size")
    if not original_size then
        doc.is_edited = false
        error("cannot read original PDF size")
    end
    if self.open_pdf_size and original_size ~= self.open_pdf_size then
        doc.is_edited = false
        error("PDF changed on disk during this reading session")
    end
    self.pdf_write_attempted = true
    local ok, err = pcall(doc.writeDocument, doc)
    if ok then
        ok, err = pcall(function()
            local check = require("ffi/mupdf").openDocument(doc.file)
            local valid, validation_error = pcall(function()
                local pages = check:getPages()
                if pages ~= doc.info.number_of_pages then
                    error("saved PDF page count changed")
                end
                for page_number = 1, pages do
                    local page = check:openPage(page_number)
                    page:close()
                end
            end)
            check:close()
            if not valid then error(validation_error) end
        end)
    end
    if not ok then
        -- An incremental save only appends bytes. Restore the previous valid
        -- revision if the write or fresh-document validation failed.
        local rollback_ok, rollback_error = pcall(function()
            local ffi = require("ffi")
            require("ffi/posix_h")
            local current_size = lfs.attributes(doc.file, "size")
            if not current_size or current_size < original_size then
                error("PDF shrank during save")
            end
            local fd = ffi.C.open(doc.file, ffi.C.O_WRONLY)
            if fd < 0 then error("cannot open PDF for rollback") end
            local truncated = ffi.C.ftruncate(fd, original_size)
            ffi.C.close(fd)
            if truncated ~= 0 then error("cannot truncate PDF to previous revision") end
        end)
        if not rollback_ok then logger.warn("PDF popup rollback failed:", rollback_error) end
        -- Do not let PdfDocument:close() retry the failed save.
        doc.is_edited = false
        error(err)
    end
    doc.is_edited = false
end

function MarginPop:_dirtyCount()
    local count = 0
    for _ in pairs(self.dirty_positions or {}) do
        count = count + 1
    end
    return count
end

function MarginPop:_setDirty(mode)
    if self.ui and self.ui.dialog then
        UIManager:setDirty(self.ui.dialog, mode or "ui")
    end
end

function MarginPop:_loadGlobalPreferences()
    local settings = rawget(_G, "G_reader_settings")
    if not settings then return end

    local fullscreen = settings:readSetting(ANNOTATION_EDITOR_FULLSCREEN_SETTING)
    self.annotation_editor_fullscreen = fullscreen == true
    local formats = settings:readSetting(CONTEXT_FORMATS_SETTING)
    self.context_formats = {}
    for _, kind in ipairs({ "book", "chapter", "page" }) do
        local value = type(formats) == "table" and formats[kind] or nil
        self.context_formats[kind] = type(value) == "string"
            and value or DEFAULT_CONTEXT_FORMATS[kind]
    end
    local export_context = settings:readSetting(EXPORT_CONTEXT_SETTING)
    self.export_context = {}
    for _, kind in ipairs({ "book", "chapter", "page" }) do
        local value = type(export_context) == "table" and export_context[kind] or nil
        self.export_context[kind] = value == nil and true or value == true
    end
    self.annotate_selection_by_default =
        settings:readSetting(ANNOTATION_SELECTION_DEFAULT_SETTING) == true
end

function MarginPop:init()
    self.marker_cache = {}
    self.emoji_cache = {}
    self.last_emoji_positions = { markers = {}, annotations = {} }
    self.emoji_size = DEFAULT_ANNOTATION_EMOJI_SIZE
    self.positions = {}
    self.dirty_positions = {}
    self.pending_annotations = {}
    self.pending_replay_failed = false
    self.pending_pdf_note_deletes = {}
    self.pdf_note_serial = 0
    self.embed_pdf_notes = true
    self.pending_pdf_note_updates = nil
    self.sidecar_annotations = {}
    self.emoji_history = {}
    self.emoji_favorites = {}
    self.add_mode = false
    self.annotate_mode = false
    self.move_selected = nil
    self.move_selected_annotation = nil
    self.move_once = false
    self.annotation_editor_fullscreen = false
    self.pdf_marker_index = nil
    self.pdf_marker_index_signature = nil
    self.pdf_marker_index_invalid = false
    self.pdf_marker_index_building = false
    self.pdf_marker_index_generation = 0
    self.context_formats = {}
    self.export_context = { book = true, chapter = true, page = true }
    self.annotation_margin_width = DEFAULT_ANNOTATION_MARGIN_WIDTH
    self.annotation_margin_side = "right"
    self.annotation_emoji_position = "left"
    self.annotation_pdf_reflow_emoji_position = "same"
    self.show_annotation_text_epub = true
    self.show_annotation_text_txt = true
    self.show_annotation_text_pdf = true
    self.show_annotation_text_pdf_reflow = false
    self.annotation_font_size = DEFAULT_ANNOTATION_FONT_SIZE
    self.annotate_selection_by_default = false
    self.pdf_margin_document = nil
    self.pdf_base_page_margin = nil
    self.pdf_applied_page_margin = nil
    self.typeset_margin_state = nil
    self.pdf_write_attempted = false
    self.open_pdf_path = self.ui and self.ui.document and self.ui.document.file
    self.open_pdf_size = self.open_pdf_path
        and lfs.attributes(self.open_pdf_path, "size")

    self:_loadGlobalPreferences()
    self:onDispatcherRegisterActions()
    self:_activate()
    self:_loadPositions()
    self:_installHooks()

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    if self.ui and self.ui.view and self.ui.view.registerViewModule then
        self.ui.view:registerViewModule("marginpop_markers", self)
    end
end

function MarginPop:onDispatcherRegisterActions()
    -- Refresh a registration left in memory by a plugin reload. Saved
    -- gestures refer to the action key and continue to work.
    Dispatcher:removeAction("marginpop_add_dot")
    Dispatcher:registerAction("marginpop_add_dot", {
        category = "none",
        event = "MarginPopAddDot",
        title = _("MarginPop: Add Annotation"),
        general = true,
    })
    Dispatcher:removeAction("marginpop_annotation_list")
    Dispatcher:registerAction("marginpop_annotation_list", {
        category = "none",
        event = "MarginPopAnnotationList",
        title = _("MarginPop: Annotation List"),
        general = true,
    })
end

function MarginPop:onMarginPopAddDot()
    local already_active = self.annotate_mode or self.add_mode
    self:_setAnnotationMode(true)
    if already_active then
        UIManager:show(Notification:new{
            text = _("Annotation mode is already active."), timeout = 2,
        })
    end
    return true
end

function MarginPop:onMarginPopAnnotationList()
    local ok, results, index_complete = pcall(
        self._collectAnnotationSearchResults, self, "", nil)
    if not ok then
        logger.err("MarginPop could not load annotations:", results)
        self:_notice(_("Could not load the annotation list. Check the KOReader log."))
        return true
    end
    if not index_complete then
        self:_startPdfMarkerIndexBuild()
    end
    if #results == 0 then
        self:_notice(index_complete and _("No annotations found in this book.")
            or _("PDF annotation indexing is running. Reopen the list when it finishes."))
        return true
    end
    self:_showAnnotationResults("", nil, results, {})
    return true
end

function MarginPop:onReaderReady()
    self:_activate()
    self.pdf_marker_index_generation = (self.pdf_marker_index_generation or 0) + 1
    self.pdf_marker_index_building = false
    self:_loadPositions()
    self:_loadSidecarAnnotations()
    self.marker_cache = {}
    self:_replayPendingAnnotations()
    self:_normalizePdfMarkerPositions()
    self:_capturePdfPageMargin()
    self:_applyAnnotationMargins()
    self:_registerSelectionMenuItem()
    local path = self.ui and self.ui.document and self.ui.document.file
    if path ~= self.open_pdf_path then
        self.pdf_write_attempted = false
        self.open_pdf_path = path
        self.open_pdf_size = path and lfs.attributes(path, "size")
    end
end

function MarginPop:onSuspend()
    self:_savePositions()
    self:_saveSidecarAnnotations()
end

function MarginPop:onCloseDocument()
    self:_restorePdfPageMargin()
    -- Sidecar is the crash-safe journal while reading. On a clean close, batch
    -- pending marker changes and portable PDF note comments into one PDF write.
    local flushed, _, flush_error
    if self.pending_replay_failed then
        flushed, flush_error = false, "pending popup replay did not finish"
    else
        local notes_staged, note_error = self:_syncSidecarNotesToPdf()
        if not notes_staged then
            flushed, flush_error = false, note_error
        else
            flushed, _, flush_error = self:_flushPendingToPdf(true, true)
        end
    end
    local saved = flushed
    local doc = self.ui and self.ui.document
    if not flushed then
        logger.warn("PDF popup close-time save failed:", flush_error)
        if doc then doc.is_edited = false end
    elseif doc and doc.is_pdf and doc.is_edited then
        -- No positions were pending, but add/edit may have changed annotations.
        local ok, err = pcall(self._writePdfOnce, self)
        saved = ok
        if not ok then logger.warn("PDF popup close-time save failed:", err) end
    end
    if saved and not self.pending_replay_failed then
        self.pending_annotations = {}
        if self.pending_pdf_note_updates then
            for _, update in ipairs(self.pending_pdf_note_updates) do
                update.annotation.pdf_export = update.snapshot
            end
            self.pending_pdf_note_deletes = {}
            self.pending_pdf_note_updates = nil
        end
    end
    self:_savePositions()
    if not self:_saveSidecarAnnotations() then
        logger.warn("MarginPop sidecar could not be saved after document close")
        self:_notice(_("The PDF may be saved, but MarginPop could not update its sidecar journal."))
    end
    self.annotate_mode = false
    self.add_mode = false
    self.pdf_marker_index_generation = (self.pdf_marker_index_generation or 0) + 1
    self.pdf_marker_index_building = false
    self.move_selected = nil
    self.move_selected_annotation = nil
    self.move_once = false
    for _, image in pairs(self.emoji_cache) do
        if image then image:free() end
    end
    self.emoji_cache = {}
    if self.ui then
        ACTIVE[self.ui] = nil
    end
end

function MarginPop:_loadSidecarAnnotations()
    local settings = self.ui and self.ui.doc_settings
    if not settings then return end
    local annotations = settings:readSetting(SIDECAR_ANNOTATIONS_SETTING)
    local history = settings:readSetting(EMOJI_HISTORY_SETTING)
    local favorites = settings:readSetting(EMOJI_FAVORITES_SETTING)
    local pending_pdf_deletes = settings:readSetting(PDF_NOTE_DELETES_SETTING)
    if annotations ~= nil and type(annotations) ~= "table" then
        logger.warn("PDF popup annotation sidecar has an invalid annotation list")
    end
    if history ~= nil and type(history) ~= "table" then
        logger.warn("PDF popup annotation sidecar has invalid emoji history")
    end
    if favorites ~= nil and type(favorites) ~= "table" then
        logger.warn("PDF popup annotation sidecar has invalid emoji favorites")
    end
    self.sidecar_annotations = {}
    for _, annotation in ipairs(type(annotations) == "table" and annotations or {}) do
        if type(annotation) == "table" and type(annotation.anchor) == "table"
            and (annotation.text == nil or type(annotation.text) == "string")
            and (annotation.emoji == nil or type(annotation.emoji) == "string") then
            local snapshot = annotation.pdf_export
            local box = type(snapshot) == "table"
                and type(snapshot.boxes) == "table" and snapshot.boxes[1]
            if snapshot ~= nil and not (type(snapshot) == "table"
                and tonumber(snapshot.page) and type(snapshot.contents) == "string"
                and type(box) == "table" and type(box.x) == "number"
                and type(box.y) == "number" and type(box.w) == "number"
                and type(box.h) == "number") then
                annotation.pdf_export = nil
                logger.warn("PDF popup cleared invalid embedded-note metadata")
            end
            if annotation.pdf_note_id ~= nil
                and type(annotation.pdf_note_id) ~= "number"
                and type(annotation.pdf_note_id) ~= "string" then
                annotation.pdf_note_id = nil
            end
            if annotation.title ~= nil and type(annotation.title) ~= "string" then
                annotation.title = nil
                logger.warn("PDF popup cleared an invalid annotation title")
            end
            if annotation.emoji_size ~= nil then
                local size = tonumber(annotation.emoji_size)
                if size and size >= 2 and size <= 64 then
                    annotation.emoji_size = math.floor(size)
                else
                    annotation.emoji_size = nil
                    logger.warn("PDF popup cleared an invalid annotation emoji size")
                end
            end
            annotation.emoji_tag = emoji_tag(annotation.emoji)
            self.sidecar_annotations[#self.sidecar_annotations + 1] = annotation
        else
            logger.warn("PDF popup skipped an invalid sidecar annotation")
        end
    end
    self.pending_pdf_note_deletes = {}
    for _, snapshot in ipairs(type(pending_pdf_deletes) == "table" and pending_pdf_deletes or {}) do
        local box = type(snapshot) == "table"
            and type(snapshot.boxes) == "table" and snapshot.boxes[1]
        if type(snapshot) == "table" and tonumber(snapshot.page)
            and type(snapshot.contents) == "string"
            and type(box) == "table" and type(box.x) == "number"
            and type(box.y) == "number" and type(box.w) == "number"
            and type(box.h) == "number" then
            self.pending_pdf_note_deletes[#self.pending_pdf_note_deletes + 1] = snapshot
        end
    end
    self.emoji_history = {}
    for _, code in ipairs(type(history) == "table" and history or {}) do
        if type(code) == "string" then
            self.emoji_history[#self.emoji_history + 1] = code
        end
    end
    self.emoji_favorites = {}
    for _, code in ipairs(type(favorites) == "table" and favorites or {}) do
        if type(code) == "string" then
            self.emoji_favorites[#self.emoji_favorites + 1] = code
        end
    end
    self.page_offset = tonumber(settings:readSetting(PAGE_OFFSET_SETTING)) or 0
    self.annotation_margin_width = clamp(
        tonumber(settings:readSetting(ANNOTATION_MARGIN_WIDTH_SETTING))
            or DEFAULT_ANNOTATION_MARGIN_WIDTH, 0, 200)
    local margin_side = settings:readSetting(ANNOTATION_MARGIN_SIDE_SETTING)
    self.annotation_margin_side = margin_side == "left" and "left" or "right"
    local emoji_position = settings:readSetting(ANNOTATION_EMOJI_POSITION_SETTING)
    if emoji_position ~= "left" and emoji_position ~= "right"
        and emoji_position ~= "near_item" then
        emoji_position = "left"
    end
    self.annotation_emoji_position = emoji_position
    local legacy_show_text = settings:readSetting(ANNOTATION_SHOW_TEXT_SETTING)
    if legacy_show_text == nil then legacy_show_text = true end
    local show_text_epub = settings:readSetting(ANNOTATION_SHOW_TEXT_EPUB_SETTING)
    self.show_annotation_text_epub = show_text_epub == nil
        and legacy_show_text ~= false or show_text_epub == true
    local show_text_txt = settings:readSetting(ANNOTATION_SHOW_TEXT_TXT_SETTING)
    self.show_annotation_text_txt = show_text_txt == nil
        and legacy_show_text ~= false or show_text_txt == true
    local show_text_pdf = settings:readSetting(ANNOTATION_SHOW_TEXT_PDF_SETTING)
    self.show_annotation_text_pdf = show_text_pdf == nil
        and legacy_show_text ~= false or show_text_pdf == true
    local reflow_emoji_position =
        settings:readSetting(ANNOTATION_PDF_REFLOW_EMOJI_POSITION_SETTING)
    if reflow_emoji_position ~= "same" and reflow_emoji_position ~= "left"
        and reflow_emoji_position ~= "near_item" and reflow_emoji_position ~= "right" then
        reflow_emoji_position = "same"
    end
    self.annotation_pdf_reflow_emoji_position = reflow_emoji_position
    self.show_annotation_text_pdf_reflow =
        settings:readSetting(ANNOTATION_SHOW_TEXT_REFLOW_SETTING) == true
    self.annotation_font_size = clamp(
        tonumber(settings:readSetting(ANNOTATION_FONT_SIZE_SETTING))
            or DEFAULT_ANNOTATION_FONT_SIZE, 1, 24)
    self.pdf_note_serial = tonumber(settings:readSetting(PDF_NOTE_SERIAL_SETTING)) or 0
    self.embed_pdf_notes = settings:readSetting(PDF_EMBED_NOTES_SETTING)
    if self.embed_pdf_notes == nil then
        self.embed_pdf_notes = true
    end
    self.pdf_reflow_anchor_mode = settings:readSetting(PDF_REFLOW_ANCHOR_MODE_SETTING)
    if self.pdf_reflow_anchor_mode ~= "line_right" then
        self.pdf_reflow_anchor_mode = "nearest"
    end
end

function MarginPop:_saveSidecarAnnotations()
    local settings = self.ui and self.ui.doc_settings
    if not settings then return false end
    settings:saveSetting(SIDECAR_ANNOTATIONS_SETTING, self.sidecar_annotations or {})
    settings:saveSetting(EMOJI_HISTORY_SETTING, self.emoji_history or {})
    settings:saveSetting(EMOJI_FAVORITES_SETTING, self.emoji_favorites or {})
    settings:saveSetting(PAGE_OFFSET_SETTING, self.page_offset or 0)
    settings:saveSetting(ANNOTATION_MARGIN_WIDTH_SETTING,
        self.annotation_margin_width or DEFAULT_ANNOTATION_MARGIN_WIDTH)
    settings:saveSetting(ANNOTATION_MARGIN_SIDE_SETTING,
        self.annotation_margin_side == "left" and "left" or "right")
    settings:saveSetting(ANNOTATION_EMOJI_POSITION_SETTING,
        self.annotation_emoji_position or "left")
    settings:saveSetting(ANNOTATION_PDF_REFLOW_EMOJI_POSITION_SETTING,
        self.annotation_pdf_reflow_emoji_position or "same")
    settings:saveSetting(ANNOTATION_SHOW_TEXT_SETTING,
        self.show_annotation_text_epub ~= false)
    settings:saveSetting(ANNOTATION_SHOW_TEXT_EPUB_SETTING,
        self.show_annotation_text_epub ~= false)
    settings:saveSetting(ANNOTATION_SHOW_TEXT_TXT_SETTING,
        self.show_annotation_text_txt ~= false)
    settings:saveSetting(ANNOTATION_SHOW_TEXT_PDF_SETTING,
        self.show_annotation_text_pdf ~= false)
    settings:saveSetting(ANNOTATION_SHOW_TEXT_REFLOW_SETTING,
        self.show_annotation_text_pdf_reflow == true)
    settings:saveSetting(ANNOTATION_FONT_SIZE_SETTING,
        self.annotation_font_size or DEFAULT_ANNOTATION_FONT_SIZE)
    settings:saveSetting(PDF_REFLOW_ANCHOR_MODE_SETTING,
        self.pdf_reflow_anchor_mode or "nearest")
    settings:saveSetting(PDF_EMBED_NOTES_SETTING, self.embed_pdf_notes ~= false)
    settings:saveSetting(PDF_NOTE_DELETES_SETTING, self.pending_pdf_note_deletes or {})
    settings:saveSetting(PDF_NOTE_SERIAL_SETTING, self.pdf_note_serial or 0)
    settings:saveSetting(EMOJI_SIZE_SETTING, self.emoji_size or DEFAULT_ANNOTATION_EMOJI_SIZE)
    if settings.flush then
        local ok, saved = pcall(settings.flush, settings)
        if not ok or not saved then
            logger.warn("PDF popup annotation sidecar save failed:", saved)
            return false
        end
    end
    return true
end

function MarginPop:_buildPdfNoteContents(annotation)
    local lines = {}
    if annotation.emoji then
        lines[#lines + 1] = EMBEDDED_EMOJI_PREFIX .. annotation.emoji
        local tag = annotation.emoji:lower():gsub("[^%w]+", "_")
        for _, face in ipairs(FACE_EMOJIS) do
            if face.code == annotation.emoji then
                tag = face.name:lower():gsub("[^%w]+", "_"):gsub("^_", ""):gsub("_$", "")
                break
            end
        end
        lines[#lines + 1] = "#" .. (tag ~= "" and tag or "emoji")
    end
    if annotation.text and annotation.text ~= "" then
        lines[#lines + 1] = annotation.text
    end
    return table.concat(lines, "\n")
end

function MarginPop:_pdfNoteSnapshot(annotation)
    local doc = self.ui and self.ui.document
    local anchor = annotation and annotation.anchor or {}
    if not (doc and doc.is_pdf) then
        return nil, _("The current document is not a PDF.")
    end

    local page, x, y
    if anchor.type == "pdf_native" then
        page, x, y = anchor.page, anchor.x, anchor.y
    elseif anchor.type == "pdf_fixed" or anchor.type == "pdf_page" then
        page = anchor.page
        local dimensions = page and doc:getNativePageDimensions(page)
        if dimensions and type(anchor.rel_x) == "number"
            and type(anchor.rel_y) == "number" then
            x, y = anchor.rel_x * dimensions.w, anchor.rel_y * dimensions.h
        end
    elseif anchor.type == "xpointer" and type(anchor.xpointer) == "table" then
        page, x, y = anchor.xpointer.page, anchor.xpointer.x, anchor.xpointer.y
    end
    if not (tonumber(page) and type(x) == "number" and type(y) == "number") then
        return nil, _("This annotation does not have a PDF page position.")
    end
    page = tonumber(page)
    local dimensions = doc:getNativePageDimensions(page)
    if not (dimensions and dimensions.w and dimensions.h) then
        return nil, _("Could not get the PDF page dimensions for this annotation.")
    end

    if not annotation.pdf_note_id then
        self.pdf_note_serial = (self.pdf_note_serial or 0) + 1
        annotation.pdf_note_id = self.pdf_note_serial
    end
    local serial = tonumber(annotation.pdf_note_id) or 0
    local box_size = 4
    local x_offset = (serial % 3) * 2
    local y_offset = (math.floor(serial / 3) % 3) * 2
    local left = clamp(x - box_size / 2 + x_offset, 0.5, dimensions.w - box_size)
    local top = clamp(y - box_size / 2 + y_offset, 0.5, dimensions.h - box_size)
    local contents = self:_buildPdfNoteContents(annotation)
    if contents == "" then
        return nil, _("An empty annotation cannot be embedded in the PDF.")
    end
    return {
        page = page,
        boxes = {{ x = left, y = top, w = box_size, h = box_size }},
        contents = contents,
        id = annotation.pdf_note_id,
    }
end

local function pdf_note_boxes_match(left_boxes, right_boxes)
    local left = left_boxes and left_boxes[1]
    local right = right_boxes and right_boxes[1]
    return left and right
        and math.abs(left.x - right.x) < 0.01
        and math.abs(left.y - right.y) < 0.01
        and math.abs(left.w - right.w) < 0.01
        and math.abs(left.h - right.h) < 0.01
end

local function pdf_note_snapshots_match(left, right)
    return left and right and left.page == right.page
        and left.contents == right.contents
        and pdf_note_boxes_match(left.boxes, right.boxes)
end

function MarginPop:_findPdfNote(snapshot)
    local doc = self.ui and self.ui.document
    if not (doc and doc._document and snapshot and snapshot.page) then return nil end
    local page = doc._document:openPage(snapshot.page)
    local ok, annotations = pcall(page.getEmbeddedAnnotations, page)
    page:close()
    if not ok then error(annotations) end
    for _, annotation in ipairs(annotations or {}) do
        if annotation.contents == snapshot.contents
            and pdf_note_boxes_match(annotation.boxes, snapshot.boxes) then
            return annotation
        end
    end
    return nil
end

function MarginPop:_deletePdfNote(snapshot)
    local doc = self.ui.document
    local existing = self:_findPdfNote(snapshot)
    if not existing then return end
    local ok, result = pcall(doc.deleteHighlight, doc, snapshot.page, {
        pboxes = existing.boxes,
    })
    if not ok or result == false then
        error("could not delete an embedded MarginPop PDF note: " .. tostring(result))
    end
    if self:_findPdfNote(snapshot) then
        error("embedded MarginPop PDF note deletion could not be verified")
    end
end

function MarginPop:_createPdfNote(snapshot)
    local doc = self.ui.document
    local existing = self:_findPdfNote(snapshot)
    if existing then return end
    local item = { pboxes = snapshot.boxes }
    doc:saveHighlight(snapshot.page, item)
    doc:updateHighlightContents(snapshot.page, item, snapshot.contents)
    if not self:_findPdfNote(snapshot) then
        error("embedded MarginPop PDF note could not be verified")
    end
end

function MarginPop:_updatePdfNote(old_snapshot, new_snapshot)
    local doc = self.ui.document
    local existing = self:_findPdfNote(old_snapshot)
    if not existing then
        self:_createPdfNote(new_snapshot)
        return
    end
    doc:updateHighlightContents(old_snapshot.page, {
        pboxes = existing.boxes,
    }, new_snapshot.contents)
    if not self:_findPdfNote(new_snapshot) then
        error("updated MarginPop PDF note could not be verified")
    end
end

function MarginPop:_syncSidecarNotesToPdf()
    local doc = self.ui and self.ui.document
    self.pending_pdf_note_updates = nil
    if not (doc and doc.is_pdf and doc._document and self.embed_pdf_notes) then
        return true
    end

    local updates = {}
    for _, annotation in ipairs(self.sidecar_annotations or {}) do
        local snapshot, err = self:_pdfNoteSnapshot(annotation)
        if not snapshot then
            logger.warn("MarginPop skipped a PDF note without a native page anchor:", err)
            self:_notice(_("Could not embed a MarginPop note: ") .. tostring(err))
        else
            local previous = annotation.pdf_export
            if not pdf_note_snapshots_match(previous, snapshot) then
                updates[#updates + 1] = { annotation = annotation, snapshot = snapshot }
            end
        end
    end
    if #updates == 0 and #self.pending_pdf_note_deletes == 0 then return true end

    if not (doc._checkIfWritable and doc:_checkIfWritable() == true) then
        local err = _("This PDF is not writable; MarginPop notes remain in the sidecar.")
        self:_notice(err)
        return false, err
    end

    if not self:_saveSidecarAnnotations() then
        local err = _("Could not journal PDF note export state in the book sidecar.")
        self:_notice(err)
        return false, err
    end

    local ok, err = pcall(function()
        for _, update in ipairs(updates) do
            local annotation = update.annotation
            local previous = annotation.pdf_export
            local desired = update.snapshot
            if previous and previous.page == desired.page
                and pdf_note_boxes_match(previous.boxes, desired.boxes) then
                if not pdf_note_snapshots_match(previous, desired) then
                    if self:_findPdfNote(previous) then
                        self:_updatePdfNote(previous, desired)
                    else
                        self:_createPdfNote(desired)
                    end
                end
            else
                if previous then self:_deletePdfNote(previous) end
                self:_createPdfNote(desired)
            end
        end
        for _, snapshot in ipairs(self.pending_pdf_note_deletes or {}) do
            self:_deletePdfNote(snapshot)
        end
    end)
    if not ok then
        doc.is_edited = false
        logger.warn("MarginPop PDF note staging failed:", err)
        self:_notice(_("PDF note embedding failed; notes remain safe in the book sidecar."))
        self.pending_pdf_note_updates = nil
        return false, tostring(err)
    end
    self.pending_pdf_note_updates = updates
    return true
end

function MarginPop:_show(text)
    local face = Font:getFace("infofont")
    local message = {
        text = text,
        face = face,
        show_icon = false,
        width = popup_width(text, face),
        dismissable = true,
        alignment = "left",
        lang = "en",
    }

    local char_count = #util.splitToChars(text)
    local _, line_breaks = text:gsub("\n", "")
    if char_count > 240 or line_breaks > 8 then
        message.height = math.floor(Screen:getHeight() * 0.58)
    end

    UIManager:show(InfoMessage:new(message))
end

function MarginPop:_notice(text)
    UIManager:show(InfoMessage:new{
        text = text,
        show_icon = false,
        timeout = 2,
    })
end

function MarginPop:_getPageMarkers(page)
    if self.marker_cache[page] then
        return self.marker_cache[page]
    end

    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc._document) then
        self.marker_cache[page] = {}
        return self.marker_cache[page]
    end

    local ok, raw_page = pcall(doc._document.openPage, doc._document, page)
    if not ok or not raw_page then
        self.marker_cache[page] = {}
        return self.marker_cache[page]
    end

    local ok_ann, annots = pcall(raw_page.getEmbeddedAnnotations, raw_page)
    pcall(raw_page.close, raw_page)
    if not ok_ann or type(annots) ~= "table" then
        self.marker_cache[page] = {}
        return self.marker_cache[page]
    end

    local markers = {}
    local marker_index = 0
    for _, annot in ipairs(annots) do
        local version, text, embedded_x, embedded_y, emoji, emoji_size, xpointer =
            payload_version_and_text(annot.contents)
        if version and type(annot.boxes) == "table" and #annot.boxes > 0 then
            local native_box = annot.boxes[1]
            local page_box = doc:nativeToPageRectTransform(page, native_box)
            if page_box then
                marker_index = marker_index + 1
                markers[#markers + 1] = {
                    key = marker_key(page, marker_index),
                    page = page,
                    index = marker_index,
                    version = version,
                    text = text,
                    emoji = emoji,
                    emoji_size = emoji_size,
                    xpointer = xpointer,
                    embedded_x = embedded_x,
                    embedded_y = embedded_y,
                    native_boxes = annot.boxes,
                    base_x = page_box.x + page_box.w / 2,
                    base_y = page_box.y + page_box.h / 2,
                }
            end
        end
    end

    self.marker_cache[page] = markers
    return markers
end

function MarginPop:_getVisiblePages()
    local view = self.ui and self.ui.view
    if not view then return {} end

    if view.getCurrentPageList then
        local pages = view:getCurrentPageList()
        if pages and #pages > 0 then
            return pages
        end
    end

    local doc = self.ui and self.ui.document
    if doc and doc.getCurrentPage then
        return { doc:getCurrentPage() }
    end
    return {}
end

function MarginPop:_isReflowedPdf()
    local doc = self.ui and self.ui.document
    return doc and doc.is_pdf
        and (self.ui.rolling ~= nil
            or (doc.configurable and tonumber(doc.configurable.text_wrap) == 1))
end

function MarginPop:_shouldShowAnnotationText()
    local doc = self.ui and self.ui.document
    if doc and doc.is_pdf and self:_isReflowedPdf() then
        return self.show_annotation_text_pdf_reflow == true
    end
    if doc and doc.is_pdf then
        return self.show_annotation_text_pdf ~= false
    end
    local path = doc and type(doc.file) == "string" and doc.file:lower() or ""
    if path:match("%.txt$") or path:match("%.text$") then
        return self.show_annotation_text_txt ~= false
    end
    return self.show_annotation_text_epub ~= false
end

function MarginPop:_getAnnotationEmojiPosition()
    if self:_isReflowedPdf()
        and self.annotation_pdf_reflow_emoji_position
        and self.annotation_pdf_reflow_emoji_position ~= "same" then
        return self.annotation_pdf_reflow_emoji_position
    end
    return self.annotation_emoji_position or "left"
end

function MarginPop:_getMarkerPagesForView()
    return self:_getVisiblePages()
end

function MarginPop:_markerPageCenter(marker)
    local moved = self.positions and self.positions[marker.key]
    if moved and moved.x and moved.y then
        return moved.x, moved.y
    end

    -- A pending reset deliberately masks an embedded PDF position until the
    -- next PDF flush succeeds.
    if self.dirty_positions and self.dirty_positions[marker.key] == "reset" then
        return marker.base_x, marker.base_y
    end

    if marker.embedded_x and marker.embedded_y then
        return marker.embedded_x, marker.embedded_y
    end
    return marker.base_x, marker.base_y
end

function MarginPop:_pdfNativePositionFromReflow(page_pos, word)
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and page_pos and page_pos.page) then return nil end
    local dimensions = doc:getNativePageDimensions(page_pos.page)

    local function valid_position(position)
        return position and position.x and position.y and dimensions
            and dimensions.w and dimensions.h
            and position.x >= 0 and position.x <= dimensions.w
            and position.y >= 0 and position.y <= dimensions.h
    end

    if not word and doc.getWordFromPosition then
        local ok, result = pcall(doc.getWordFromPosition, doc, page_pos)
        if ok and result then word = result end
    end
    if word and word.pos and word.pos.page and word.pos.x and word.pos.y then
        local native = {
            page = word.pos.page,
            x = word.pos.x,
            y = word.pos.y,
        }
        if self.pdf_reflow_anchor_mode == "line_right"
            and word.pbox and word.pbox.x and word.pbox.y
            and word.pbox.w and word.pbox.h then
            native.x = word.pbox.x + word.pbox.w
            native.y = word.pbox.y + word.pbox.h / 2
        end
        if valid_position(native) then return native, word end
    end

    local kopt = doc.koptinterface
    if kopt and kopt.reflowToNativePosTransform
        and page_pos.x and page_pos.y then
        local ok, native = pcall(kopt.reflowToNativePosTransform, kopt, doc,
            page_pos.page, { x = page_pos.x, y = page_pos.y }, { x = 0.5, y = 0.5 })
        if ok and valid_position(native) then
            return { page = native.page or page_pos.page, x = native.x, y = native.y }
        end
    end

    if dimensions and dimensions.w and dimensions.h then
        return {
            page = page_pos.page,
            x = dimensions.w / 2,
            y = dimensions.h / 2,
        }
    end
    return nil
end

function MarginPop:_pdfNativeToScreenCenter(page, native_x, native_y)
    local doc = self.ui and self.ui.document
    local view = self.ui and self.ui.view
    if not (doc and view and page and native_x and native_y) then return nil end

    local pos = { page = page, x = native_x, y = native_y }
    if self:_isReflowedPdf() then
        local kopt = doc.koptinterface
        if not (kopt and kopt.nativeToReflowPosTransform) then return nil end
        local ok, reflow_pos = pcall(kopt.nativeToReflowPosTransform, kopt, doc, page, pos)
        if not (ok and reflow_pos and reflow_pos.x and reflow_pos.y) then return nil end
        pos = reflow_pos
    end

    local rect = view:pageToScreenTransform(page, Geom:new{
        x = pos.x - 0.5,
        y = pos.y - 0.5,
        w = 1,
        h = 1,
    })
    if not rect then return nil end
    return rect.x + rect.w / 2, rect.y + rect.h / 2
end

function MarginPop:_normalizePdfMarkerPositions()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf) then return end

    local previous_positions = {}
    local previous_dirty = {}
    local changed, reset_count = false, 0
    for key, moved in pairs(self.positions or {}) do
        if type(moved) == "table" and type(moved.x) == "number"
            and type(moved.y) == "number" then
            local page = tonumber(key:match("^p(%d+):"))
            local dimensions = page and doc:getNativePageDimensions(page)
            if dimensions and dimensions.w and dimensions.h then
                local outside_native_page = moved.x < 0 or moved.x > dimensions.w
                    or moved.y < 0 or moved.y > dimensions.h
                if outside_native_page then
                    previous_positions[key] = moved
                    previous_dirty[key] = self.dirty_positions[key]
                    local native
                    if self:_isReflowedPdf() then
                        native = self:_pdfNativePositionFromReflow({
                            page = page,
                            x = moved.x,
                            y = moved.y,
                        })
                    end
                    if native then
                        self.positions[key] = {
                            x = native.x,
                            y = native.y,
                            coordinate_space = "native",
                        }
                        self.dirty_positions[key] = "move"
                    else
                        self.positions[key] = nil
                        self.dirty_positions[key] = nil
                        reset_count = reset_count + 1
                    end
                    changed = true
                elseif moved.coordinate_space ~= "native" then
                    local original = {}
                    for field, value in pairs(moved) do
                        original[field] = value
                    end
                    previous_positions[key] = original
                    moved.coordinate_space = "native"
                    changed = true
                end
            end
        end
    end
    if changed and not self:_savePositions() then
        for key, moved in pairs(previous_positions) do
            self.positions[key] = moved
            self.dirty_positions[key] = previous_dirty[key]
        end
        logger.warn("Could not normalize legacy PDF reflow marker positions")
        self:_notice(_("Could not repair old PDF marker positions; they may need to be moved again."))
    elseif reset_count > 0 then
        self:_notice(_("Some invalid old marker positions were reset to their original PDF locations."))
    end
end

function MarginPop:_markerScreenCenter(marker)
    local view = self.ui and self.ui.view
    if not view then return nil end

    if self:_isReflowedPdf() then
        local moved = self.positions and self.positions[marker.key]
        local xpointer = (moved and moved.xpointer) or marker.xpointer
        local doc = self.ui.document
        if xpointer and doc.getScreenPositionFromXPointer then
            local ok, screen_y, screen_x = pcall(
                doc.getScreenPositionFromXPointer, doc, xpointer)
            if ok and type(screen_x) == "number" and type(screen_y) == "number" then
                return screen_x, screen_y
            end
        end
    end

    local page_x, page_y = self:_markerPageCenter(marker)
    return self:_pdfNativeToScreenCenter(marker.page, page_x, page_y)
end

function MarginPop:_findMarkerAt(pos, v2_only)
    if not pos then return nil end

    local half = TAP_DIAMETER / 2
    local nearest
    for _, page in ipairs(self:_getMarkerPagesForView()) do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            if not v2_only or marker.version == 2 then
                local center = self.last_emoji_positions
                    and self.last_emoji_positions.markers[marker.key]
                local x, y
                if center then
                    x, y = center.x, center.y
                else
                    local anchor_x, anchor_y = self:_markerScreenCenter(marker)
                    x, y = self:_defaultEmojiCenter(anchor_x, anchor_y, marker)
                end
                if x and y and math.abs(pos.x - x) <= half
                    and math.abs(pos.y - y) <= half then
                    local dx = pos.x - x
                    local dy = pos.y - y
                    local distance = dx * dx + dy * dy
                    if not nearest or distance < nearest.distance then
                        nearest = {
                            distance = distance,
                            marker = marker,
                        }
                    end
                end
            end
        end
    end

    return nearest and nearest.marker or nil
end

function MarginPop:_moveSelectedToScreenPos(pos)
    local view = self.ui and self.ui.view
    local selected = self.move_selected
    if not (view and selected and pos) then return false end

    local page_pos = view:screenToPageTransform(pos)
    if not (page_pos and page_pos.page) then return true end
    if page_pos.page ~= selected.page then
        self:_notice(_("Choose a new location on the same page."))
        return true
    end

    local move_x, move_y = page_pos.x, page_pos.y
    if self:_isReflowedPdf() then
        local native = self:_pdfNativePositionFromReflow(page_pos)
        if not native then
            self:_notice(_("Could not map this reflow position to the PDF page."))
            return true
        end
        move_x, move_y = native.x, native.y
    end

    local previous_position = self.positions[selected.key]
    local previous_dirty = self.dirty_positions[selected.key]
    local xpointer
    if not self:_isReflowedPdf() then
        xpointer = self:_getXPointerAtPagePosition(page_pos)
    end
    self.positions[selected.key] = {
        x = move_x,
        y = move_y,
        xpointer = xpointer,
        coordinate_space = "native",
    }
    self.dirty_positions[selected.key] = "move"
    if not self:_savePositions() then
        self.positions[selected.key] = previous_position
        self.dirty_positions[selected.key] = previous_dirty
        self:_notice(_("Could not save the marker position; check sidecar storage."))
        return true
    end
    self.move_selected = nil
    self:_setDirty("ui")
    return true
end

function MarginPop:_addMarkerAtScreenPos(pos)
    local anchor = self:_getAnnotationAnchor(pos)
    if not anchor then
        self:_notice(_("No nearby text could be anchored at this location."))
        self:_setAnnotationMode(false)
        return true
    end
    self:_newSidecarAnnotation(anchor)
    return true
end

function MarginPop:_openEmojiGrid(dialog, current, on_selected)
    local available = available_face_emojis()
    if #available == 0 then
        self:_notice(_("OpenMoji SVG files were not found; install the complete plugin folder."))
        return
    end
    local ok, EmojiGrid = pcall(dofile, PLUGIN_DIR .. "/emoji_grid.lua")
    if not ok then
        self:_notice(_("Could not open the emoji picker: ") .. tostring(EmojiGrid))
        return
    end
    local keyboard_was_visible = dialog:isKeyboardVisible()
    if keyboard_was_visible then dialog:onCloseKeyboard() end
    local function restore_keyboard()
        if keyboard_was_visible and not dialog._marginpop_closed then
            UIManager:scheduleIn(0.05, function()
                if not dialog._marginpop_closed and dialog._input_widget then
                    dialog:onShowKeyboard()
                end
            end)
        end
    end
    UIManager:show(EmojiGrid:new{
        faces = available,
        assets_dir = PLUGIN_DIR .. "/openmoji-black",
        selected = current,
        page = EmojiGrid.pageForCode(available, current),
        history = self.emoji_history,
        favorites = self.emoji_favorites,
        on_history_hold = function(code)
            self:_toggleEmojiFavorite(code)
        end,
        on_favorite_hold = function(code)
            self:_toggleEmojiFavorite(code)
        end,
        on_select = function(code)
            on_selected(code)
            restore_keyboard()
        end,
        on_cancel = restore_keyboard,
    })
end

function MarginPop:_makeInlineEmojiRows(selected, on_selected)
    if #FACE_EMOJIS == 0 then return nil end
    local ok, EmojiGrid = pcall(dofile, PLUGIN_DIR .. "/emoji_grid.lua")
    if not ok or not (EmojiGrid and EmojiGrid.makeQuickRows) then
        logger.warn("MarginPop could not load inline emoji controls:", EmojiGrid)
        return nil
    end
    local available = available_face_emojis()
    return EmojiGrid.makeQuickRows{
        faces = available,
        assets_dir = PLUGIN_DIR .. "/openmoji-black",
        selected = selected,
        history = self.emoji_history,
        favorites = self.emoji_favorites,
        on_select = on_selected,
    }
end

function MarginPop:_attachInlineEmojiRows(dialog, quick_rows)
    if not quick_rows then return end
    dialog:addWidget(quick_rows)
end

function MarginPop:_getXPointerAtPagePosition(pos)
    local doc = self.ui and self.ui.document
    if not (doc and doc.getWordFromPosition and pos) then return nil end
    local ok, word = pcall(doc.getWordFromPosition, doc, pos)
    if not ok or not word then return nil end
    local xpointer = word.pos0 or word.pos1 or word.pos
    return type(xpointer) == "string" and xpointer or nil
end

function MarginPop:_promptNewMarkerText(page_pos, initial_text)
    local doc = self.ui.document
    local xpointer = self:_getXPointerAtPagePosition(page_pos)
    local emoji
    local dialog
    local context_buttons = self:_contextQuickButtons({
        anchor = { page = page_pos.page },
    }, function()
        return dialog
    end)
    local quick_emoji_rows = self:_makeInlineEmojiRows(emoji, function(code)
        emoji = code
    end)
    dialog = InputDialog:new{
        title = _("New PDF Marker Note"),
        input = initial_text or "",
        allow_newline = true,
        fullscreen = self.annotation_editor_fullscreen,
        condensed = true,
        add_scroll_buttons = true,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                self:_setAddMode(false)
            end },
            { text = _("Emoji…"), callback = function()
                self:_openEmojiGrid(dialog, emoji, function(code) emoji = code end)
            end },
            context_buttons[1],
            context_buttons[2],
            context_buttons[3],
            { text = _("Add"), is_enter_default = true, callback = function()
                local contents = dialog:getInputText() or ""
                if contents:match("^%s*$") and not emoji then
                    self:_notice(_("Enter a note or choose an emoji."))
                    return
                end
                local was_edited = doc.is_edited

                -- A tiny highlight supplies the native PDF annotation anchor.
                -- The normal-sized circle remains a KOReader view overlay.
                local item = { pboxes = {{
                    x = page_pos.x - 1, y = page_pos.y - 1, w = 2, h = 2,
                }} }
                local pending = {
                    kind = "add", page = page_pos.page,
                    x = page_pos.x, y = page_pos.y,
                    xpointer = xpointer,
                    text = contents, emoji = emoji, emoji_size = self.emoji_size,
                }
                table.insert(self.pending_annotations, pending)
                if not self:_savePositions() then
                    table.remove(self.pending_annotations)
                    self:_notice(_("Could not save the pending marker record; check sidecar storage."))
                    return
                end
                local created = false
                local ok, err = pcall(function()
                    doc:saveHighlight(page_pos.page, item)
                    created = true
                    local payload = build_v2_payload(contents, page_pos.x, page_pos.y,
                        emoji, self.emoji_size, xpointer)
                    doc:updateHighlightContents(page_pos.page, item, payload)
                    local raw_page = doc._document:openPage(page_pos.page)
                    local annots = raw_page:getEmbeddedAnnotations()
                    raw_page:close()
                    local found = false
                    for _, annot in ipairs(annots or {}) do
                        if annot.contents == payload then
                            found = true
                            break
                        end
                    end
                    if not found then error("new annotation contents were not stored") end
                end)
                if not ok then
                    for index, entry in ipairs(self.pending_annotations) do
                        if entry == pending then
                            table.remove(self.pending_annotations, index)
                            break
                        end
                    end
                    self:_savePositions()
                    if created then
                        -- Remove the unsaved in-memory annotation so retrying
                        -- Add cannot create a duplicate marker.
                        pcall(doc.deleteHighlight, doc, page_pos.page, item)
                        doc.is_edited = was_edited
                        self.marker_cache[page_pos.page] = nil
                        self:_setDirty("ui")
                    end
                    self:_notice(_("Could not add the marker or save the PDF: ") .. tostring(err))
                    return
                end

                self.marker_cache[page_pos.page] = nil
                self:_invalidatePdfMarkerIndex()
                for _, marker in ipairs(self:_getPageMarkers(page_pos.page)) do
                    if marker.version == 2 and marker.text == contents
                        and marker.embedded_x and marker.embedded_y
                        and math.abs(marker.embedded_x - page_pos.x) < 0.00001
                        and math.abs(marker.embedded_y - page_pos.y) < 0.00001 then
                        pending.key = marker.key
                        break
                    end
                end
                self:_savePositions()
                self:_addToEmojiHistory(emoji)
                if not self:_saveSidecarAnnotations() then
                    self:_notice(_("The PDF annotation was saved, but emoji history was not."))
                end
                self:_setDirty("ui")
                UIManager:close(dialog)
                self:_setAddMode(false)
            end },
        }},
    }
    self:_attachInlineEmojiRows(dialog, quick_emoji_rows)
    local inherited_close_widget = dialog.onCloseWidget
    function dialog:onCloseWidget(...)
        self._marginpop_closed = true
        self.plugin:_setAddMode(false)
        if inherited_close_widget then
            return inherited_close_widget(self, ...)
        end
    end
    dialog.plugin = self
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_editMarker(marker)
    local doc = self.ui and self.ui.document
    if not (doc and doc._checkIfWritable and doc:_checkIfWritable() == true) then
        self:_notice(_("This PDF is not writable; its marker cannot be edited."))
        self:_setAddMode(false)
        return true
    end
    -- KOPOPZH1 has a baked-in circle, so only its text can be changed.
    self:_promptEditMarker(marker)
    return true
end

function MarginPop:_deleteSidecarAnnotation(annotation, index, dialog)
    if not (annotation and type(self.sidecar_annotations) == "table") then
        return false
    end
    if not index or self.sidecar_annotations[index] ~= annotation then
        index = nil
        for candidate, item in ipairs(self.sidecar_annotations) do
            if item == annotation then
                index = candidate
                break
            end
        end
    end
    if not index then
        self:_notice(_("This annotation is no longer in the book list."))
        return false
    end

    local queued_delete_index
    if self.embed_pdf_notes and annotation.pdf_export then
        table.insert(self.pending_pdf_note_deletes, annotation.pdf_export)
        queued_delete_index = #self.pending_pdf_note_deletes
    end
    table.remove(self.sidecar_annotations, index)
    if not self:_saveSidecarAnnotations() then
        if queued_delete_index then
            table.remove(self.pending_pdf_note_deletes, queued_delete_index)
        end
        table.insert(self.sidecar_annotations, index, annotation)
        self:_notice(_("Could not delete the annotation from the book sidecar."))
        return false
    end
    self:_setAnnotationMode(false)
    if dialog then
        UIManager:close(dialog)
    end
    self:_setDirty("ui")
    return true
end

function MarginPop:_showAnnotationActionMenu(annotation, index, marker)
    local item = annotation or marker
    if type(item) ~= "table" then return false end
    local note = type(item.title) == "string" and item.title or ""
    local body = type(item.text) == "string" and item.text or ""
    local preview = note
    if body ~= "" then
        preview = preview ~= "" and (preview .. "\n" .. body) or body
    end
    preview = util.fixUtf8(preview, "�"):gsub("[%c]+", " ")
    if preview == "" then
        preview = item.emoji and emoji_label(item.emoji) or _("Empty annotation")
    end
    preview = truncate_utf8(preview, 240)
    local title = item.emoji
        and (emoji_label(item.emoji) .. "\n" .. preview) or preview
    local dialog
    local can_edit_marker = true
    if marker then
        local doc = self.ui and self.ui.document
        can_edit_marker = doc and doc._checkIfWritable
            and doc:_checkIfWritable() == true
    end
    dialog = ButtonDialog:new{
        title = title,
        title_align = "left",
        width_factor = 0.98,
        shrink_unneeded_width = true,
        anchor = function()
            return { y = Screen:getHeight() - Screen:scaleBySize(12) }
        end,
        rows_per_page = 1,
        buttons = {{
            { text = _("Delete"), enabled = annotation ~= nil or can_edit_marker,
                callback = function()
                    if annotation then
                        self:_deleteSidecarAnnotation(annotation, index, dialog)
                    else
                        self:_deleteMarker(marker, dialog)
                    end
                end },
            { text = _("Edit"), enabled = annotation ~= nil or can_edit_marker,
                callback = function()
                    UIManager:close(dialog)
                    UIManager:scheduleIn(0.05, function()
                        if annotation then
                            self:_promptSidecarAnnotation(annotation, index)
                        else
                            self:_editMarker(marker)
                        end
                    end)
                end },
            { text = _("Move"), enabled = annotation ~= nil
                    or (can_edit_marker and marker.version == 2),
                callback = function()
                    self:_beginAnnotationMove(annotation, marker, dialog)
                end },
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    return true
end

function MarginPop:_deleteMarker(marker, dialog)
    local pending = {
        kind = "delete",
        key = marker.key,
        page = marker.page,
        native_boxes = marker.native_boxes,
    }
    local previous, previous_index
    for index, entry in ipairs(self.pending_annotations) do
        if entry.key == marker.key then
            previous, previous_index = entry, index
            self.pending_annotations[index] = pending
            break
        end
    end
    if not previous then
        table.insert(self.pending_annotations, pending)
    end
    if not self:_savePositions() then
        if previous_index then
            self.pending_annotations[previous_index] = previous
        else
            table.remove(self.pending_annotations)
        end
        self:_notice(_("Could not save the pending marker deletion; check sidecar storage."))
        return
    end

    local doc = self.ui.document
    local ok, result = pcall(doc.deleteHighlight, doc, marker.page, {
        pboxes = marker.native_boxes,
    })
    self.marker_cache[marker.page] = nil
    self:_invalidatePdfMarkerIndex()
    if not ok or result == false then
        self:_notice(_("PDF marker deletion is pending and will be retried on reopen: ")
            .. tostring(result))
        return
    end
    self.marker_cache[marker.page] = nil
    self:_invalidatePdfMarkerIndex()
    self:_setDirty("ui")
    self:_setAddMode(false)
    UIManager:close(dialog)
end

function MarginPop:_promptEditMarker(marker, draft)
    local doc = self.ui.document
    local emoji = draft and draft.emoji or marker.emoji
    if draft then emoji = draft.emoji end
    local dialog
    local quick_emoji_rows
    local context_buttons = self:_contextQuickButtons({
        anchor = { page = marker.page },
    }, function()
        return dialog
    end)
    quick_emoji_rows = self:_makeInlineEmojiRows(emoji, function(code)
        emoji = code
        if quick_emoji_rows and quick_emoji_rows.setSelected then
            quick_emoji_rows:setSelected(code)
        end
    end)
    local function toggle_editor_layout()
        local fullscreen = not self.annotation_editor_fullscreen
        if not self:_setAnnotationEditorFullscreen(fullscreen) then return end
        local marker_draft = {
            text = dialog:getInputText() or "",
            emoji = emoji,
        }
        UIManager:close(dialog)
        self:_promptEditMarker(marker, marker_draft)
    end
    local function save_marker(move_after_save)
        local text = dialog:getInputText() or ""
        if text:match("^%s*$") and not emoji then
            self:_notice(_("Enter a note or choose an emoji."))
            return
        end
        if text == marker.text and emoji == marker.emoji then
            if move_after_save then
                self:_beginAnnotationMove(nil, marker, dialog)
            else
                UIManager:close(dialog)
                self:_setAddMode(false)
            end
            return
        end

        local chosen_size = emoji and (marker.emoji_size or self.emoji_size) or nil
        local payload = marker.version == 2
            and build_v2_payload(text, marker.embedded_x, marker.embedded_y,
                emoji, chosen_size, marker.xpointer)
            or MARKER_V1 .. text
        local pending
        for _, entry in ipairs(self.pending_annotations) do
            if entry.key == marker.key then
                pending = entry
                break
            end
        end
        local newly_pending = not pending
        if not pending then
            pending = { kind = "edit", key = marker.key }
            table.insert(self.pending_annotations, pending)
        end
        local previous_text = pending.text
        local previous_emoji = pending.emoji
        local previous_size = pending.emoji_size
        pending.text = text
        pending.emoji = emoji
        pending.emoji_size = chosen_size
        if not self:_savePositions() then
            if newly_pending then
                table.remove(self.pending_annotations)
            else
                pending.text = previous_text
                pending.emoji = previous_emoji
                pending.emoji_size = previous_size
            end
            self:_notice(_("Could not save the pending marker record; check sidecar storage."))
            return
        end
        local updated = false
        local ok, err = pcall(function()
            doc:updateHighlightContents(marker.page,
                { pboxes = marker.native_boxes }, payload)

            -- updateHighlightContents silently succeeds if its PDF annotation lookup misses.
            -- Verify this exact anchor.
            local raw_page = doc._document:openPage(marker.page)
            local annots = raw_page:getEmbeddedAnnotations()
            raw_page:close()
            local target = marker.native_boxes[1]
            for _, annot in ipairs(annots or {}) do
                local box = annot.boxes and annot.boxes[1]
                if annot.contents == payload and box
                    and math.abs(box.x - target.x) < 0.01
                    and math.abs(box.y - target.y) < 0.01 then
                    updated = true
                    break
                end
            end
            if not updated then error("annotation contents were not updated") end
        end)
        self.marker_cache[marker.page] = nil
        self:_invalidatePdfMarkerIndex()
        if ok and updated then
            marker.text = text
            marker.emoji = emoji
            marker.emoji_size = chosen_size
            self:_addToEmojiHistory(emoji)
            if not self:_saveSidecarAnnotations() then
                self:_notice(_("The PDF annotation was saved, but emoji history was not."))
            end
            self:_setDirty("ui")
            if move_after_save then
                self:_beginAnnotationMove(nil, marker, dialog)
            else
                UIManager:close(dialog)
                self:_setAddMode(false)
            end
        elseif not ok then
            self:_notice(_("PDF marker update is pending and will be retried on reopen: ") .. tostring(err))
        end
    end
    local buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                self:_setAddMode(false)
            end },
            { text = _("Emoji…"), enabled = marker.version == 2,
                callback = function()
                    self:_openEmojiGrid(dialog, emoji, function(code)
                        emoji = code
                        if quick_emoji_rows and quick_emoji_rows.setSelected then
                            quick_emoji_rows:setSelected(code)
                        end
                    end)
                end },
            { text = _("Save"), is_enter_default = true, callback = function()
                save_marker(false)
            end },
        },
        { context_buttons[1], context_buttons[2], context_buttons[3] },
        {
            { text = self.annotation_editor_fullscreen
                    and _("Use compact editor") or _("Use full-screen editor"),
                callback = toggle_editor_layout },
            { text = _("Delete"), callback = function()
                self:_deleteMarker(marker, dialog)
            end },
        },
    }
    if marker.version == 2 then
        table.insert(buttons, {
            { text = _("Save & Move"), callback = function()
                save_marker(true)
            end },
        })
    end
    dialog = InputDialog:new{
        title = marker.version == 2 and _("Edit PDF Marker Note and Emoji") or _("Edit PDF Marker Note"),
        input = draft and draft.text or marker.text,
        allow_newline = true,
        fullscreen = self.annotation_editor_fullscreen,
        condensed = true,
        add_scroll_buttons = true,
        buttons = buttons,
    }
    self:_attachInlineEmojiRows(dialog, quick_emoji_rows)
    local inherited_close_widget = dialog.onCloseWidget
    function dialog:onCloseWidget(...)
        self._marginpop_closed = true
        self.plugin:_setAddMode(false)
        if inherited_close_widget then
            return inherited_close_widget(self, ...)
        end
    end
    dialog.plugin = self
    UIManager:show(dialog)
    dialog:onShowKeyboard()
    return true
end

function MarginPop:_findMarkerByKey(key)
    local page, index = key:match("^p(%d+):(%d+)$")
    page, index = tonumber(page), tonumber(index)
    if not (page and index) then return nil end

    for _, marker in ipairs(self:_getPageMarkers(page)) do
        if marker.index == index then
            return marker
        end
    end
end

function MarginPop:_replayPendingAnnotations()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc._document) then return end
    self.pending_replay_failed = false
    local rekeyed = false
    local had_pending = #(self.pending_annotations or {}) > 0

    local function has_payload(page_number, payload, target_box)
        local page = doc._document:openPage(page_number)
        local annotations = page:getEmbeddedAnnotations()
        page:close()
        for _, annotation in ipairs(annotations or {}) do
            local box = annotation.boxes and annotation.boxes[1]
            if annotation.contents == payload and (not target_box
                or (box and math.abs(box.x - target_box.x) < 0.01
                    and math.abs(box.y - target_box.y) < 0.01)) then
                return true
            end
        end
        return false
    end

    for _, pending in ipairs(self.pending_annotations or {}) do
        local ok, err = pcall(function()
            if pending.kind == "add" then
                local payload = build_v2_payload(pending.text, pending.x, pending.y,
                    pending.emoji, pending.emoji_size, pending.xpointer)
                if not has_payload(pending.page, payload) then
                    local item = { pboxes = {{
                        x = pending.x - 1, y = pending.y - 1, w = 2, h = 2,
                    }} }
                    doc:saveHighlight(pending.page, item)
                    doc:updateHighlightContents(pending.page, item, payload)
                    if not has_payload(pending.page, payload) then
                        error("pending popup was not restored")
                    end
                    self.marker_cache[pending.page] = nil
                end
                for _, marker in ipairs(self:_getPageMarkers(pending.page)) do
                    if marker.version == 2 and marker.text == pending.text
                        and marker.embedded_x and marker.embedded_y
                        and math.abs(marker.embedded_x - pending.x) < 0.00001
                        and math.abs(marker.embedded_y - pending.y) < 0.00001 then
                        if pending.key and pending.key ~= marker.key then
                            self.positions[marker.key] = self.positions[pending.key]
                            self.dirty_positions[marker.key] = self.dirty_positions[pending.key]
                            self.positions[pending.key] = nil
                            self.dirty_positions[pending.key] = nil
                        end
                        if pending.key ~= marker.key then
                            pending.key = marker.key
                            rekeyed = true
                        end
                        break
                    end
                end
            elseif pending.kind == "edit" then
                local marker = self:_findMarkerByKey(pending.key)
                if not marker then error("pending popup target was not found") end
                local payload = marker.version == 2
                    and build_v2_payload(pending.text, marker.embedded_x,
                        marker.embedded_y, pending.emoji, pending.emoji_size,
                        marker.xpointer)
                    or MARKER_V1 .. pending.text
                local target = marker.native_boxes[1]
                if not has_payload(marker.page, payload, target) then
                    doc:updateHighlightContents(marker.page,
                        { pboxes = marker.native_boxes }, payload)
                    if not has_payload(marker.page, payload, target) then
                        error("pending popup edit was not restored")
                    end
                    self.marker_cache[marker.page] = nil
                end
            elseif pending.kind == "delete" then
                local marker
                local target = pending.native_boxes and pending.native_boxes[1]
                if target and pending.page then
                    for _, candidate in ipairs(self:_getPageMarkers(pending.page)) do
                        local box = candidate.native_boxes and candidate.native_boxes[1]
                        if box and math.abs(box.x - target.x) < 0.01
                            and math.abs(box.y - target.y) < 0.01 then
                            marker = candidate
                            break
                        end
                    end
                else
                    marker = self:_findMarkerByKey(pending.key)
                end
                if marker then
                    doc:deleteHighlight(marker.page, {
                        pboxes = marker.native_boxes,
                    })
                    self.marker_cache[marker.page] = nil
                    if has_payload(marker.page,
                        marker.version == 2
                            and build_v2_payload(marker.text, marker.embedded_x,
                                marker.embedded_y, marker.emoji, marker.emoji_size,
                                marker.xpointer)
                            or MARKER_V1 .. marker.text,
                        marker.native_boxes[1]) then
                        error("pending popup deletion was not restored")
                    end
                end
            else
                error("unknown pending popup operation")
            end
        end)
        if not ok then
            self.pending_replay_failed = true
            logger.warn("PDF popup pending change replay failed:", err)
        end
    end
    if rekeyed then self:_savePositions() end
    if had_pending then self:_invalidatePdfMarkerIndex() end
end

function MarginPop:_flushPendingToPdf(write_now, quiet)
    local pending = self:_dirtyCount()
    if pending == 0 then
        return true, 0
    end

    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc._document) then
        return false, 0, _("The current document is not a writable PDF.")
    end

    local can_write = doc._checkIfWritable and doc:_checkIfWritable()
    if can_write ~= true then
        if not quiet then
            self:_notice(_("This PDF is not writable; marker positions remain safe in the sidecar."))
        end
        return false, 0, _("PDF is not writable")
    end

    local updated_keys = {}
    local updated_count = 0

    for key, state in pairs(self.dirty_positions or {}) do
        local marker = self:_findMarkerByKey(key)
        if marker and marker.version == 2 and marker.native_boxes then
            local x, y
            if state ~= "reset" then
                local moved = self.positions[key]
                if moved then
                    x, y = moved.x, moved.y
                end
            end

            local contents = build_v2_payload(marker.text, x, y,
                marker.emoji, marker.emoji_size,
                (self.positions[key] and self.positions[key].xpointer) or marker.xpointer)
            local ok_update, result = pcall(
                doc.updateHighlightContents,
                doc,
                marker.page,
                { pboxes = marker.native_boxes },
                contents
            )
            if not ok_update or result == false then
                doc.is_edited = false
                if not quiet then
                    self:_notice(_("Could not write PDF annotations; pending positions remain in the sidecar."))
                end
                return false, updated_count, tostring(result)
            end

            marker.embedded_x = x
            marker.embedded_y = y
            local moved = self.positions[key]
            marker.xpointer = (moved and moved.xpointer) or marker.xpointer
            updated_keys[#updated_keys + 1] = key
            updated_count = updated_count + 1
        end
    end

    if updated_count == 0 then
        return true, 0
    end

    if write_now then
        local ok_write, err = pcall(self._writePdfOnce, self)
        if not ok_write then
            if not quiet then
                self:_notice(_("Could not save the PDF; pending positions remain in the sidecar."))
            end
            return false, updated_count, tostring(err)
        end

        -- The single incremental save has persisted all in-memory PDF edits, including
        -- any ordinary KOReader PDF annotations that were already pending.
        doc.is_edited = false

        -- Once durable in the PDF, the sidecar stops overriding it. This makes
        -- the PDF authoritative after a successful flush and prevents stale
        -- clean sidecar positions from winning after the file is moved/copied.
        for _, key in ipairs(updated_keys) do
            self.positions[key] = nil
            self.dirty_positions[key] = nil
        end
        self:_savePositions()
    end

    return true, updated_count
end

-- TAP BEHAVIOUR
-- Normal mode:
--   tap annotation -> show its actions; long-press -> edit it
--   elsewhere -> normal KOReader tap/page-turn behaviour
-- After choosing Save & Move:
--   next tap -> place that annotation
-- Adding mode:
--   empty page tap -> enter text, optionally choose a face, then create an annotation
--   annotation tap -> show its actions
function MarginPop:_handleTap(readerlink, ges)
    local ui = readerlink and readerlink.ui
    local doc = ui and ui.document
    local view = readerlink and readerlink.view
    if not (ges and ges.pos and doc and view) then
        return false
    end

    if self.move_once and (self.move_selected or self.move_selected_annotation) then
        if self.move_selected_annotation then
            return self:_moveSidecarAnnotationTo(ges.pos)
        end
        local consumed = self:_moveSelectedToScreenPos(ges.pos)
        self.move_once = self.move_selected ~= nil
        return consumed
    end
    local sidecar_annotation, sidecar_index = self:_findSidecarAnnotationAt(ges.pos)
    if sidecar_annotation then
        self:_showAnnotationActionMenu(sidecar_annotation, sidecar_index)
        return true
    end

    if self.annotate_mode then
        if doc.is_pdf and doc._document then
            local existing_marker = self:_findMarkerAt(ges.pos, false)
            if existing_marker then
                return self:_showAnnotationActionMenu(nil, nil, existing_marker)
            end
        end
        local anchor = self:_getAnnotationAnchor(ges.pos)
        if not anchor then
            self:_notice(_("No nearby text could be anchored at this location."))
            self:_setAnnotationMode(false)
            return true
        end
        self:_newSidecarAnnotation(anchor)
        return true
    end

    if not (doc.is_pdf and doc._document) then
        return false
    end

    local marker = self:_findMarkerAt(ges.pos, false)
    if marker then
        return self:_showAnnotationActionMenu(nil, nil, marker)
    end

    -- Keep normal navigation usable outside active placement and move actions.
    return false
end

function MarginPop:_handleAnnotationHold(ges)
    if not (ges and ges.pos) then return false end
    local annotation, index = self:_findSidecarAnnotationAt(ges.pos)
    if annotation then
        self:_promptSidecarAnnotation(annotation, index)
        return true
    end

    local marker = self:_findMarkerAt(ges.pos, false)
    if marker then
        return self:_editMarker(marker)
    end
    return false
end

function MarginPop:_installHooks()
    if not rawget(_G, "__marginpop_readerlink_hook_v2_1") then
        local ok, ReaderLink = pcall(require, "apps/reader/modules/readerlink")
        if ok and ReaderLink and type(ReaderLink.onTap) == "function" then
            local original_onTap = ReaderLink.onTap
            ReaderLink.onTap = function(readerlink, event, ges)
                local instance = readerlink and readerlink.ui and ACTIVE[readerlink.ui]
                if instance then
                    local ok_hit, consumed = pcall(instance._handleTap, instance, readerlink, ges)
                    if ok_hit and consumed then
                        return true
                    end
                end
                return original_onTap(readerlink, event, ges)
            end
            rawset(_G, "__marginpop_readerlink_hook_v2_1", true)
        end
    end

    if not rawget(_G, "__marginpop_readerhighlight_hook_v2_2") then
        local ok, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
        if ok and ReaderHighlight then
            local original_onShowHighlightMenu = ReaderHighlight.onShowHighlightMenu
            local original_onHold = ReaderHighlight.onHold
            local original_onHoldPan = ReaderHighlight.onHoldPan
            local original_onHoldRelease = ReaderHighlight.onHoldRelease
            local hold_hook_already_installed =
                rawget(_G, "__marginpop_readerhighlight_hook_v2_1")

            if type(original_onShowHighlightMenu) == "function" then
                ReaderHighlight.onShowHighlightMenu = function(readerhighlight, ...)
                    local instance = readerhighlight and readerhighlight.ui
                        and ACTIVE[readerhighlight.ui]
                    if instance then
                        instance:_registerSelectionMenuItem()
                        if instance.annotate_selection_by_default then
                            local ok_add, consumed = pcall(
                                instance._addAnnotationFromSelection, instance, readerhighlight)
                            if ok_add and consumed then return true end
                            if not ok_add then
                                logger.err("MarginPop could not annotate the selection:", consumed)
                            end
                        end
                    end
                    return original_onShowHighlightMenu(readerhighlight, ...)
                end
            end

            if not hold_hook_already_installed and type(original_onHold) == "function" then
                ReaderHighlight.onHold = function(readerhighlight, event, ges)
                    local instance = readerhighlight and readerhighlight.ui
                        and ACTIVE[readerhighlight.ui]
                    if instance then
                        local ok_hold, consumed = pcall(
                            instance._handleAnnotationHold, instance, ges)
                        if ok_hold and consumed then return true end
                    end
                    return original_onHold(readerhighlight, event, ges)
                end
            end

            if not hold_hook_already_installed and type(original_onHoldPan) == "function" then
                ReaderHighlight.onHoldPan = function(readerhighlight, event, ges)
                    local instance = readerhighlight and readerhighlight.ui
                        and ACTIVE[readerhighlight.ui]
                    if instance and instance.move_once then
                        return true
                    end
                    return original_onHoldPan(readerhighlight, event, ges)
                end
            end

            if not hold_hook_already_installed and type(original_onHoldRelease) == "function" then
                ReaderHighlight.onHoldRelease = function(readerhighlight, ...)
                    local instance = readerhighlight and readerhighlight.ui
                        and ACTIVE[readerhighlight.ui]
                    if instance and instance.move_once then
                        return true
                    end
                    return original_onHoldRelease(readerhighlight, ...)
                end
            end

            rawset(_G, "__marginpop_readerhighlight_hook_v2_2", true)
        end
    end

    if not rawget(_G, "__marginpop_typeset_margin_hook_v1") then
        local ok, ReaderTypeset = pcall(require, "apps/reader/modules/readertypeset")
        if ok and ReaderTypeset and type(ReaderTypeset.onSetPageMargins) == "function" then
            local original_onSetPageMargins = ReaderTypeset.onSetPageMargins
            ReaderTypeset.onSetPageMargins = function(typeset, margins, ...)
                local instance = typeset and typeset.ui and ACTIVE[typeset.ui]
                local document = typeset and typeset.ui and typeset.ui.document
                local extra = instance and instance:_shouldShowAnnotationText()
                    and tonumber(instance.annotation_margin_width) or 0
                if instance and document
                    and (not document.is_pdf or instance:_isReflowedPdf())
                    and type(margins) == "table" then
                    local state = instance.typeset_margin_state
                    local base_margins
                    local same_as_applied = state and state.typeset == typeset
                        and state.document == document and type(state.applied) == "table"
                        and #margins == #state.applied
                    if same_as_applied then
                        for index, value in ipairs(margins) do
                            if math.abs((tonumber(value) or 0)
                                - (tonumber(state.applied[index]) or 0)) > 0.000001 then
                                same_as_applied = false
                                break
                            end
                        end
                    end
                    if same_as_applied then
                        base_margins = state.base
                    else
                        base_margins = {}
                        for index, value in ipairs(margins) do
                            base_margins[index] = value
                        end
                        state = { typeset = typeset, document = document }
                        instance.typeset_margin_state = state
                        state.base = base_margins
                    end
                    local adjusted = {}
                    for index, value in ipairs(base_margins) do
                        adjusted[index] = value
                    end
                    if extra > 0 then
                        local side_index = instance.annotation_margin_side == "left" and 1 or 3
                        adjusted[side_index] = (tonumber(adjusted[side_index]) or 0) + extra
                    end
                    state.applied = adjusted
                    return original_onSetPageMargins(typeset, adjusted, ...)
                end
                return original_onSetPageMargins(typeset, margins, ...)
            end
            rawset(_G, "__marginpop_typeset_margin_hook_v1", true)
        end
    end

    if not rawget(_G, "__marginpop_pdf_margin_hook_v2") then
        local ok, ReaderView = pcall(require, "apps/reader/modules/readerview")
        if ok and ReaderView then
            local original_onSetViewMode = ReaderView.onSetViewMode
            if type(original_onSetViewMode) == "function" then
                ReaderView.onSetViewMode = function(readerview, ...)
                    local result = original_onSetViewMode(readerview, ...)
                    local instance = readerview and readerview.ui
                        and ACTIVE[readerview.ui]
                    local document = readerview and readerview.ui
                        and readerview.ui.document
                    if instance and document and document.is_pdf then
                        local ui = readerview.ui
                        UIManager:scheduleIn(0.05, function()
                            if ui.document == document and ACTIVE[ui] == instance then
                                instance:_applyAnnotationMargins()
                            end
                        end)
                    end
                    return result
                end
            end
        end
        if ok and ReaderView and type(ReaderView.onMarginUpdate) == "function" then
            local original_onMarginUpdate = ReaderView.onMarginUpdate
            ReaderView.onMarginUpdate = function(readerview, ...)
                local instance = readerview and readerview.ui and ACTIVE[readerview.ui]
                local document = readerview and readerview.ui and readerview.ui.document
                local reflow_margins_available = instance and instance:_isReflowedPdf()
                    and type(instance:_getAnnotationBaseMargins()) == "table"
                if instance and document and document.is_pdf and not reflow_margins_available then
                    instance:_applyPdfPageMargin()
                end
                return original_onMarginUpdate(readerview, ...)
            end
            rawset(_G, "__marginpop_pdf_margin_hook_v2", true)

            if type(ReaderView.onCloseDocument) == "function"
                and not rawget(_G, "__marginpop_pdf_margin_restore_hook_v1") then
                local original_onCloseDocument = ReaderView.onCloseDocument
                ReaderView.onCloseDocument = function(readerview, ...)
                    local instance = readerview and readerview.ui
                        and ACTIVE[readerview.ui]
                    if instance then
                        instance:_restorePdfPageMargin()
                    end
                    return original_onCloseDocument(readerview, ...)
                end
                rawset(_G, "__marginpop_pdf_margin_restore_hook_v1", true)
            end
        end
    end
end

function MarginPop:_getAnnotationAnchor(pos)
    local doc = self.ui and self.ui.document
    local view = self.ui and self.ui.view
    if not (doc and view and pos) then return nil end

    local page_pos = view:screenToPageTransform(pos)
    if not (page_pos and page_pos.page) then return nil end
    local is_reflow = self.ui.rolling ~= nil
        or (doc.configurable and tonumber(doc.configurable.text_wrap) == 1)

    if doc.is_pdf and not is_reflow then
        if not (page_pos.x and page_pos.y) then return nil end
        local dimensions = doc:getNativePageDimensions(page_pos.page)
        if not (dimensions and dimensions.w and dimensions.h) then return nil end
        return {
            type = "pdf_fixed",
            page = page_pos.page,
            rel_x = page_pos.x / dimensions.w,
            rel_y = page_pos.y / dimensions.h,
        }
    end

    local ok, word = pcall(doc.getWordFromPosition, doc, page_pos)
    if doc.is_pdf then
        local native, pdf_word = self:_pdfNativePositionFromReflow(
            page_pos, ok and word or nil)
        if native then
            return {
                type = "pdf_native",
                page = native.page,
                x = native.x,
                y = native.y,
                quote = pdf_word and pdf_word.word or "",
            }
        end
    end
    local xpointer = ok and word and (word.pos0 or word.pos1 or word.pos)
    if type(xpointer) ~= "string" then xpointer = nil end
    local quote = ok and word and (word.word or "")
    if not xpointer and doc.getTextFromPositions then
        local got_text, text = pcall(doc.getTextFromPositions, doc, page_pos, page_pos)
        if got_text and text then
            xpointer = text.pos0 or text.pos1
            quote = text.text or quote
        end
    end
    if type(xpointer) ~= "string" then xpointer = nil end
    if not xpointer then
        if doc.is_pdf and page_pos.page then
            local dimensions = doc:getNativePageDimensions(page_pos.page)
            local rel_x, rel_y = 0.5, 0.5
            if dimensions and dimensions.w and dimensions.h
                and page_pos.x and page_pos.y then
                rel_x = page_pos.x / dimensions.w
                rel_y = page_pos.y / dimensions.h
            end
            return {
                type = "pdf_page",
                page = page_pos.page,
                rel_x = rel_x,
                rel_y = rel_y,
                quote = quote,
            }
        end
        return nil
    end
    return {
        type = "xpointer",
        xpointer = xpointer,
        page = page_pos.page,
        quote = quote,
    }
end

function MarginPop:_annotationScreenCenter(annotation)
    local anchor = annotation and annotation.anchor
    local doc = self.ui and self.ui.document
    local view = self.ui and self.ui.view
    if not (anchor and doc and view) then return nil end

    if anchor.type == "pdf_native" and doc.is_pdf then
        return self:_pdfNativeToScreenCenter(anchor.page, anchor.x, anchor.y)
    end
    if doc.is_pdf and anchor.type == "xpointer"
        and type(anchor.xpointer) == "table" then
        local position = anchor.xpointer
        if position.page and position.x and position.y then
            return self:_pdfNativeToScreenCenter(position.page, position.x, position.y)
        end
    end

    if (anchor.type == "pdf_fixed" or anchor.type == "pdf_page") and doc.is_pdf then
        local is_reflow = self.ui.rolling ~= nil
            or (doc.configurable and tonumber(doc.configurable.text_wrap) == 1)
        if not (anchor.page and type(anchor.rel_x) == "number"
            and type(anchor.rel_y) == "number" and view.pageToScreenTransform) then
            return nil
        end
        local dimensions = doc:getNativePageDimensions(anchor.page)
        if not (dimensions and dimensions.w and dimensions.h) then return nil end
        local x = anchor.rel_x * dimensions.w
        local y = anchor.rel_y * dimensions.h
        if anchor.type == "pdf_page" and is_reflow then
            local rect = view:pageToScreenTransform(anchor.page, Geom:new{
                x = x - 0.5,
                y = y - 0.5,
                w = 1,
                h = 1,
            })
            if not rect then return nil end
            return rect.x + rect.w / 2, rect.y + rect.h / 2
        end
        local point = Geom:new{
            x = x - 0.5,
            y = y - 0.5,
            w = 1,
            h = 1,
        }
        if anchor.type == "pdf_fixed" then
            return self:_pdfNativeToScreenCenter(anchor.page, x, y)
        end
        local rect = view:pageToScreenTransform(anchor.page, point)
        if not rect then return nil end
        return rect.x + rect.w / 2, rect.y + rect.h / 2
    end

    if anchor.xpointer and doc.getScreenPositionFromXPointer then
        local ok, screen_y, screen_x = pcall(
            doc.getScreenPositionFromXPointer, doc, anchor.xpointer)
        if ok and type(screen_y) == "number" and type(screen_x) == "number" then
            return screen_x, screen_y
        end
    end
    return nil
end

function MarginPop:_findSidecarAnnotationAt(pos)
    if not pos then return nil end
    local visible_pages
    local doc = self.ui and self.ui.document
    if doc and doc.is_pdf then
        visible_pages = {}
        for _, page in ipairs(self:_getVisiblePages()) do
            visible_pages[page] = true
        end
    end
    local nearest
    local half = TAP_DIAMETER / 2
    for index, annotation in ipairs(self.sidecar_annotations or {}) do
        local anchor = annotation.anchor or {}
        local anchor_page = anchor.page
            or (type(anchor.xpointer) == "table" and anchor.xpointer.page)
        if not visible_pages or not anchor_page or visible_pages[anchor_page] then
            local center = self.last_emoji_positions
                and self.last_emoji_positions.annotations[annotation]
            local x, y
            if center then
                x, y = center.x, center.y
            else
                local anchor_x, anchor_y = self:_annotationScreenCenter(annotation)
                x, y = self:_defaultEmojiCenter(anchor_x, anchor_y, annotation)
            end
            if x and y and math.abs(pos.x - x) <= half
                and math.abs(pos.y - y) <= half then
                local dx, dy = pos.x - x, pos.y - y
                local distance = dx * dx + dy * dy
                if not nearest or distance < nearest.distance then
                    nearest = { distance = distance, annotation = annotation, index = index }
                end
            end
        end
    end
    return nearest and nearest.annotation, nearest and nearest.index
end

function MarginPop:_addToEmojiHistory(code)
    if not code then return end
    for index, existing in ipairs(self.emoji_history) do
        if existing == code then
            table.remove(self.emoji_history, index)
            break
        end
    end
    table.insert(self.emoji_history, 1, code)
    while #self.emoji_history > 12 do table.remove(self.emoji_history) end
end

function MarginPop:_toggleEmojiFavorite(code)
    for index, existing in ipairs(self.emoji_favorites) do
        if existing == code then
            table.remove(self.emoji_favorites, index)
            if not self:_saveSidecarAnnotations() then
                table.insert(self.emoji_favorites, index, code)
                self:_notice(_("Could not update emoji favorites in the book sidecar."))
                return false
            end
            return false
        end
    end
    table.insert(self.emoji_favorites, code)
    if not self:_saveSidecarAnnotations() then
        table.remove(self.emoji_favorites)
        self:_notice(_("Could not update emoji favorites in the book sidecar."))
        return false
    end
    return true
end

function MarginPop:_newSidecarAnnotation(anchor, quote)
    local context = self:_contextValues({ anchor = anchor })
    local annotation = {
        id = string.format("%d-%d", os.time(), #self.sidecar_annotations + 1),
        anchor = anchor,
        text = quote and quote ~= "" and ('"' .. quote .. '"') or "",
        emoji = nil,
        emoji_size = self.emoji_size,
        chapter = context.chapter,
    }
    self:_promptSidecarAnnotation(annotation)
end

function MarginPop:_contextValues(annotation)
    local doc = self.ui and self.ui.document
    local anchor = annotation and annotation.anchor or {}
    local page = anchor.page
    if not page and type(anchor.xpointer) == "table" then
        page = anchor.xpointer.page
    end
    if not page and doc and doc.getCurrentPage then
        page = doc:getCurrentPage()
    end
    local title = doc and doc.info and doc.info.title
    if not title or title == "" then
        title = doc and doc.file and doc.file:match("([^/]+)$") or ""
    end
    local chapter
    local toc = self.ui and self.ui.toc
    if toc and toc.getTocTitleByPage then
        local ok, value = pcall(toc.getTocTitleByPage, toc, page or 1)
        if ok then chapter = value end
    end
    return {
        title = title,
        chapter = chapter or "",
        page = tostring((tonumber(page) or 1) + (self.page_offset or 0)),
    }
end

function MarginPop:_insertableContext(annotation, kind)
    local values = self:_contextValues(annotation)
    local format = self.context_formats[kind] or DEFAULT_CONTEXT_FORMATS[kind]
    return (format or ""):gsub("{([%w_]+)}", function(key)
        if values[key] ~= nil then
            return tostring(values[key])
        end
        return "{" .. key .. "}"
    end)
end

function MarginPop:_insertContextIntoEditor(dialog, annotation, kind)
    local input = dialog and dialog._input_widget
    if not (input and type(input.addChars) == "function") then
        logger.warn("MarginPop could not insert context into the annotation editor")
        self:_notice(_("Could not insert context into the annotation."))
        return false
    end
    local text = dialog:getInputText() or ""
    local separator = text ~= "" and not text:match("%s$") and " " or ""
    input:addChars(separator .. self:_insertableContext(annotation, kind))
    return true
end

function MarginPop:_saveGlobalPreference(key, value)
    local settings = rawget(_G, "G_reader_settings")
    if not settings then return false end
    settings:saveSetting(key, value)
    if settings.flush then
        local ok, saved = pcall(settings.flush, settings)
        if not ok or not saved then
            logger.warn("MarginPop global preference save failed:", saved)
            return false
        end
    end
    return true
end

function MarginPop:_editContextFormat(kind)
    local dialog
    local buttons = {{
        { text = _("Cancel"), id = "close", callback = function()
            UIManager:close(dialog)
        end },
        { text = _("Save"), is_enter_default = true, callback = function()
            local formats = {}
            for key, value in pairs(self.context_formats) do
                formats[key] = value
            end
            formats[kind] = dialog:getInputText() or ""
            if not self:_saveGlobalPreference(CONTEXT_FORMATS_SETTING, formats) then
                self:_notice(_("Could not save the global context format."))
                return
            end
            self.context_formats = formats
            UIManager:close(dialog)
        end },
    }}
    if kind == "page" then
        table.insert(buttons, {
            { text = _("Page number offset…"), callback = function()
                self:_editPageOffset()
            end },
        })
    end
    dialog = InputDialog:new{
        title = string.format(_("Edit global %s insertion format"), kind),
        description = _("Use {title}, {chapter}, or {page}. Add a line break only if wanted."),
        input = self.context_formats[kind] or DEFAULT_CONTEXT_FORMATS[kind],
        buttons = buttons,
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_editPageOffset()
    local dialog
    dialog = InputDialog:new{
        title = _("Page number offset for this book"),
        input = tostring(self.page_offset or 0),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Save"), callback = function()
                local offset = tonumber(dialog:getInputText())
                if not offset then
                    self:_notice(_("Enter a valid page offset."))
                    return
                end
                local previous_offset = self.page_offset
                self.page_offset = math.floor(offset)
                if not self:_saveSidecarAnnotations() then
                    self.page_offset = previous_offset
                    self:_notice(_("Could not save the page offset to the book sidecar."))
                    return
                end
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_contextQuickButtons(annotation, get_dialog)
    return {
        {
            text = _("Book"),
            callback = function()
                self:_insertContextIntoEditor(get_dialog(), annotation, "book")
            end,
            hold_callback = function() self:_editContextFormat("book") end,
        },
        {
            text = _("Chapter"),
            callback = function()
                self:_insertContextIntoEditor(get_dialog(), annotation, "chapter")
            end,
            hold_callback = function() self:_editContextFormat("chapter") end,
        },
        {
            text = _("Page"),
            callback = function()
                self:_insertContextIntoEditor(get_dialog(), annotation, "page")
            end,
            hold_callback = function() self:_editContextFormat("page") end,
        },
    }
end

function MarginPop:_promptSidecarAnnotation(annotation, index)
    local emoji = annotation.emoji
    local initial_input = annotation.editor_input
        or ((annotation.title or "") .. "\n" .. (annotation.text or ""))
    local dialog
    local quick_emoji_rows
    local context_buttons = self:_contextQuickButtons(annotation, function()
        return dialog
    end)
    quick_emoji_rows = self:_makeInlineEmojiRows(emoji, function(code)
        emoji = code
        if quick_emoji_rows and quick_emoji_rows.setSelected then
            quick_emoji_rows:setSelected(code)
        end
    end)
    local function toggle_editor_layout()
        local fullscreen = not self.annotation_editor_fullscreen
        if not self:_setAnnotationEditorFullscreen(fullscreen) then return end
        local draft = {}
        for key, value in pairs(annotation) do
            draft[key] = value
        end
        draft.editor_input = dialog:getInputText() or ""
        draft.emoji = emoji
        UIManager:close(dialog)
        self:_promptSidecarAnnotation(draft, index)
    end
    local function save_annotation(move_after_save)
        local editor_text = dialog:getInputText() or ""
        local title, text = editor_text:match("^([^\r\n]*)\r?\n(.*)$")
        if title == nil then
            title, text = "", editor_text
        end
        title = title:match("^%s*(.-)%s*$")
        if text:match("^%s*$") and not emoji then
            self:_notice(_("Enter a note or choose an emoji."))
            return
        end
        local saved_annotation = {}
        for key, value in pairs(annotation) do
            saved_annotation[key] = value
        end
        saved_annotation.text = text
        saved_annotation.emoji = emoji
        saved_annotation.title = title ~= "" and title or nil
        saved_annotation.editor_input = nil
        saved_annotation.emoji_tag = emoji_tag(emoji)
        saved_annotation.emoji_size = saved_annotation.emoji_size or self.emoji_size
        local previous_annotation = index and self.sidecar_annotations[index]
        local previous_history = {}
        for history_index, code in ipairs(self.emoji_history) do
            previous_history[history_index] = code
        end
        self:_addToEmojiHistory(emoji)
        if index then
            self.sidecar_annotations[index] = saved_annotation
        else
            table.insert(self.sidecar_annotations, saved_annotation)
        end
        if not self:_saveSidecarAnnotations() then
            if index then
                self.sidecar_annotations[index] = previous_annotation
            else
                table.remove(self.sidecar_annotations)
            end
            self.emoji_history = previous_history
            self:_notice(_("Could not save this annotation to the book sidecar."))
            return
        end
        self:_setDirty("ui")
        if move_after_save then
            self:_beginAnnotationMove(saved_annotation, nil, dialog)
        else
            self:_setAnnotationMode(false)
            UIManager:close(dialog)
        end
    end
    local buttons = {
        {
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                self:_setAnnotationMode(false)
            end },
            { text = _("Emoji…"), callback = function()
                self:_openEmojiGrid(dialog, emoji, function(code)
                    emoji = code
                    if quick_emoji_rows and quick_emoji_rows.setSelected then
                        quick_emoji_rows:setSelected(code)
                    end
                end)
            end },
        },
        { context_buttons[1], context_buttons[2], context_buttons[3],
            { text = self.annotation_editor_fullscreen
                    and _("Use compact editor") or _("Use full-screen editor"),
                callback = toggle_editor_layout },
        },
        { { text = _("Save"), is_enter_default = true, callback = function()
            save_annotation(false)
        end } },
    }
    if index then
        table.insert(buttons[3], 1, {
            text = _("Delete"),
            callback = function()
                self:_deleteSidecarAnnotation(annotation, index, dialog)
            end,
        })
        table.insert(buttons[3], {
            text = _("Save & Move"), callback = function()
                save_annotation(true)
            end,
        })
    end
    dialog = InputDialog:new{
        title = index and _("Edit annotation") or _("New annotation"),
        description = _("First line is the optional title; write the annotation below it."),
        input = initial_input,
        allow_newline = true,
        fullscreen = self.annotation_editor_fullscreen,
        condensed = true,
        add_scroll_buttons = true,
        buttons = buttons,
    }
    self:_attachInlineEmojiRows(dialog, quick_emoji_rows)
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_beginAnnotationMove(annotation, marker, dialog)
    if dialog then
        UIManager:close(dialog)
    end
    self.annotate_mode = false
    self.add_mode = false
    self.move_selected = marker
    self.move_selected_annotation = annotation
    self.move_once = true
    self:_setDirty("ui")
    self:_notice(_("Tap the new location to move this annotation."))
end

function MarginPop:_moveSidecarAnnotationTo(pos)
    local selected = self.move_selected_annotation
    if not selected then return false end
    local anchor = self:_getAnnotationAnchor(pos)
    if not anchor then
        self:_notice(_("No text anchor was found at that location."))
        return true
    end
    local previous_anchor = selected.anchor
    selected.anchor = anchor
    if not self:_saveSidecarAnnotations() then
        selected.anchor = previous_anchor
        self:_notice(_("Could not save the moved annotation to the book sidecar."))
        return true
    end
    self.move_selected_annotation = nil
    self:_setAnnotationMode(false)
    self:_setDirty("ui")
    return true
end

function MarginPop:_addAnnotationFromSelection(reader_highlight)
    local selection = reader_highlight and reader_highlight.selected_text
    if not (selection and selection.pos0 and selection.pos1) then return false end
    local doc = self.ui and self.ui.document
    if not doc then return false end

    local position = selection.pos1
    local page_box = type(selection.pboxes) == "table"
        and selection.pboxes[#selection.pboxes]
    local page = type(position) == "table" and position.page
        or (type(page_box) == "table" and page_box.page)
        or (type(selection.pos0) == "table" and selection.pos0.page)
    if doc.is_pdf and not page then
        local visible_pages = self:_getVisiblePages()
        page = visible_pages[#visible_pages]
    end
    local native_x = type(position) == "table" and position.x
    local native_y = type(position) == "table" and position.y
    if type(page_box) == "table" then
        native_x = native_x or (page_box.x and page_box.w
            and page_box.x + page_box.w)
        native_y = native_y or (page_box.y and page_box.h
            and page_box.y + page_box.h / 2)
    end
    local dimensions = doc.is_pdf and page
        and doc:getNativePageDimensions(page)
    if dimensions and dimensions.w and dimensions.h and native_x and native_y then
        native_x = clamp(native_x, 0, dimensions.w)
        native_y = clamp(native_y, 0, dimensions.h)
    end
    local reflow = self.ui.rolling ~= nil
        or (doc.configurable and tonumber(doc.configurable.text_wrap) == 1)
    local anchor
    if doc.is_pdf and page and native_x and native_y then
        if reflow then
            anchor = {
                type = "pdf_native",
                page = page,
                x = native_x,
                y = native_y,
            }
        else
            if dimensions and dimensions.w and dimensions.h then
                anchor = {
                    type = "pdf_fixed",
                    page = page,
                    rel_x = native_x / dimensions.w,
                    rel_y = native_y / dimensions.h,
                }
            end
        end
    elseif not doc.is_pdf then
        anchor = {
            type = "xpointer",
            xpointer = position,
            page = type(position) == "table" and position.page
                or (type(selection.pos0) == "table"
                    and selection.pos0.page or nil),
        }
    elseif doc.is_pdf and page then
        local rel_x, rel_y = 0.5, 0.5
        if dimensions and dimensions.w and dimensions.h
            and native_x and native_y then
            rel_x = native_x / dimensions.w
            rel_y = native_y / dimensions.h
        end
        anchor = { type = "pdf_page", page = page, rel_x = rel_x, rel_y = rel_y }
    end
    if not anchor then
        self:_notice(_("Could not anchor the selected text."))
        return false
    end

    local quote = util.cleanupSelectedText(selection.text or "")
    reader_highlight:onClose()
    UIManager:scheduleIn(0.05, function()
        if self.ui and self.ui.document == doc then
            self:_newSidecarAnnotation(anchor, quote)
        end
    end)
    return true
end

function MarginPop:_registerSelectionMenuItem()
    local highlight = self.ui and self.ui.highlight
    if not (highlight and highlight.addToHighlightDialog) then return end
    if highlight._marginpop_annotation_item then return end
    highlight:addToHighlightDialog("02_marginpop_annotation", function(reader_highlight)
        return {
            text = _("Add annotation"),
            callback = function()
                self:_addAnnotationFromSelection(reader_highlight)
            end,
        }
    end)
    highlight._marginpop_annotation_item = true
end

function MarginPop:_invalidatePdfMarkerIndex()
    self.pdf_marker_index = nil
    self.pdf_marker_index_invalid = true
    self.pdf_marker_index_generation = (self.pdf_marker_index_generation or 0) + 1
end

function MarginPop:_getPdfMarkerIndex(scan_all)
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc.info) then return {}, true end

    local attributes = doc.file and lfs.attributes(doc.file) or {}
    local signature = table.concat({
        doc.file or "",
        tostring(attributes and attributes.size or ""),
        tostring(attributes and attributes.modification or ""),
    }, "|")
    if self.pdf_marker_index and not self.pdf_marker_index_invalid
        and self.pdf_marker_index_signature == signature then
        return self.pdf_marker_index, true
    end

    local settings = self.ui and self.ui.doc_settings
    local cached = settings and settings:readSetting(PDF_MARKER_INDEX_SETTING)
    if not self.pdf_marker_index_invalid and type(cached) == "table"
        and cached.signature == signature and type(cached.entries) == "table" then
        local valid = true
        for _, entry in ipairs(cached.entries) do
            if type(entry) ~= "table" or type(entry.page) ~= "number"
                or type(entry.key) ~= "string"
                or (entry.text ~= nil and type(entry.text) ~= "string")
                or (entry.emoji ~= nil and type(entry.emoji) ~= "string") then
                valid = false
                break
            end
        end
        if valid then
            self.pdf_marker_index = cached.entries
            self.pdf_marker_index_signature = signature
            return self.pdf_marker_index, true
        end
    end

    if not scan_all then
        local entries = {}
        for _, page in ipairs(self:_getMarkerPagesForView()) do
            for _, marker in ipairs(self:_getPageMarkers(page)) do
                entries[#entries + 1] = {
                    page = marker.page,
                    key = marker.key,
                    text = marker.text or "",
                    emoji = marker.emoji,
                    version = marker.version,
                }
            end
        end
        return entries, false
    end

    local entries = {}
    for page = 1, doc.info.number_of_pages or 0 do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            entries[#entries + 1] = {
                page = marker.page,
                key = marker.key,
                text = marker.text or "",
                emoji = marker.emoji,
                version = marker.version,
            }
        end
        self.marker_cache[page] = nil
    end

    self.pdf_marker_index = entries
    self.pdf_marker_index_signature = signature
    self.pdf_marker_index_invalid = false
    if settings then
        settings:saveSetting(PDF_MARKER_INDEX_SETTING, {
            signature = signature,
            entries = entries,
        })
        if settings.flush then
            local ok, saved = pcall(settings.flush, settings)
            if not ok or not saved then
                logger.warn("MarginPop could not persist the PDF annotation index:", saved)
            end
        end
    end
    return entries, true
end

function MarginPop:_startPdfMarkerIndexBuild()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc.info) or self.pdf_marker_index_building then
        return false
    end
    local _, complete = self:_getPdfMarkerIndex(false)
    if complete then return false end

    self.pdf_marker_index_building = true
    local generation = (self.pdf_marker_index_generation or 0) + 1
    self.pdf_marker_index_generation = generation
    local path = doc.file
    local page_count = tonumber(doc.info.number_of_pages) or 0
    local page = 1
    local entries = {}
    local failed_pages = 0

    UIManager:show(Notification:new{
        text = _("Indexing PDF annotations in the background."),
        timeout = 3,
    })

    local function finish()
        self.pdf_marker_index_building = false
        if self.pdf_marker_index_generation ~= generation
            or self.ui.document ~= doc then
            return
        end
        self.pdf_marker_index = entries
        self.pdf_marker_index_signature = table.concat({
            path or "",
            tostring(lfs.attributes(path or "", "size") or ""),
            tostring(lfs.attributes(path or "", "modification") or ""),
        }, "|")
        self.pdf_marker_index_invalid = failed_pages > 0
        if failed_pages == 0 then
            local settings = self.ui.doc_settings
            if settings then
                settings:saveSetting(PDF_MARKER_INDEX_SETTING, {
                    signature = self.pdf_marker_index_signature,
                    entries = entries,
                    complete = true,
                })
                if settings.flush then
                    local ok, saved = pcall(settings.flush, settings)
                    if not ok or not saved then
                        logger.warn("MarginPop could not persist the PDF annotation index:", saved)
                    end
                end
            end
            self:_notice(_("PDF annotation indexing is complete. Reopen the list for all pages."))
        else
            logger.warn("MarginPop could not index", failed_pages, "PDF page(s)")
            self:_notice(_("PDF annotation indexing finished with unreadable pages."))
        end
    end

    local function scan_next_batch()
        if self.pdf_marker_index_generation ~= generation or self.ui.document ~= doc then
            self.pdf_marker_index_building = false
            return
        end
        local batch_end = math.min(page + 1, page_count)
        while page <= batch_end do
            local ok, markers = pcall(self._getPageMarkers, self, page)
            if ok then
                for _, marker in ipairs(markers) do
                    entries[#entries + 1] = {
                        page = marker.page,
                        key = marker.key,
                        text = marker.text or "",
                        emoji = marker.emoji,
                        version = marker.version,
                    }
                end
            else
                failed_pages = failed_pages + 1
                logger.warn("MarginPop could not index PDF page", page, markers)
            end
            self.marker_cache[page] = nil
            page = page + 1
        end
        if page <= page_count then
            UIManager:scheduleIn(0.05, scan_next_batch)
        else
            finish()
        end
    end

    if page_count == 0 then
        finish()
    else
        UIManager:scheduleIn(0.05, scan_next_batch)
    end
    return true
end

function MarginPop:_resolveIndexedPdfMarker(entry)
    local indexed = entry and entry.marker
    if not indexed then return nil end
    for _, marker in ipairs(self:_getPageMarkers(indexed.page)) do
        if marker.key == indexed.key then
            return marker
        end
    end
end

function MarginPop:_collectAnnotationSearchResults(query, emoji_filter)
    local results = {}
    local normalized_query = (query or ""):lower()
    local function matches(annotation)
        if type(annotation) ~= "table" then return false end
        local title = type(annotation.title) == "string" and annotation.title or ""
        local note = type(annotation.text) == "string" and annotation.text or ""
        local emoji = type(annotation.emoji) == "string" and annotation.emoji or nil
        local text = title .. "\n" .. note
        local name = emoji_label(emoji)
        local tag = emoji_tag(emoji) or ""
        local searchable = (text .. "\n" .. name .. "\n#" .. tag):lower()
        local text_match = normalized_query == ""
            or searchable:find(normalized_query, 1, true)
        local emoji_match = not emoji_filter or emoji == emoji_filter
        return text_match and emoji_match
    end
    for index, annotation in ipairs(self.sidecar_annotations or {}) do
        if type(annotation) == "table" and matches(annotation) then
            results[#results + 1] = { annotation = annotation, index = index }
        end
    end
    local doc = self.ui and self.ui.document
    local marker_index_complete = true
    if doc and doc.is_pdf then
        local marker_index
        marker_index, marker_index_complete = self:_getPdfMarkerIndex(false)
        for _, marker in ipairs(marker_index) do
            if type(marker) == "table" and type(marker.key) == "string"
                and matches(marker) then
                results[#results + 1] = { marker = marker }
            end
        end
    end
    return results, marker_index_complete
end

function MarginPop:_collectAllHistoryAnnotations()
    local settings_ok, DocSettings = pcall(require, "docsettings")
    local history_ok, ReadHistory = pcall(require, "readhistory")
    if not settings_ok or not history_ok then
        return nil, _("KOReader document history is unavailable.")
    end
    if type(ReadHistory.hist) ~= "table" then
        return nil, _("KOReader document history could not be read.")
    end

    local current_doc = self.ui and self.ui.document
    local current_path = current_doc and current_doc.file
    local paths, seen_paths = {}, {}
    local function add_path(path)
        if type(path) == "string" and path ~= "" and not seen_paths[path] then
            seen_paths[path] = true
            paths[#paths + 1] = path
        end
    end
    for _, history_entry in ipairs(ReadHistory.hist) do
        if type(history_entry) == "table" then
            add_path(history_entry.file)
        end
    end
    add_path(current_path)

    local results, skipped = {}, 0
    for _, path in ipairs(paths) do
        local metadata
        if path == current_path then
            metadata = self.ui.doc_settings
        end
        if not metadata and lfs.attributes(path, "mode") == "file" then
            local opened, value = pcall(DocSettings.open, DocSettings, path)
            if opened then
                metadata = value
            else
                skipped = skipped + 1
                logger.warn("MarginPop could not read document sidecar:", path, value)
            end
        end

        if metadata then
            local title = path:match("([^/]+)$") or path
            local doc_props = metadata:readSetting("doc_props")
            if type(doc_props) == "table" then
                local stored_title = doc_props.title or doc_props.book_title
                if type(stored_title) == "string" and stored_title ~= "" then
                    title = stored_title
                end
            end
            if path == current_path and current_doc.info and current_doc.info.title
                and current_doc.info.title ~= "" then
                title = current_doc.info.title
            end
            local page_offset = tonumber(metadata:readSetting(PAGE_OFFSET_SETTING)) or 0
            local annotations = metadata:readSetting(SIDECAR_ANNOTATIONS_SETTING)
            for _, annotation in ipairs(type(annotations) == "table" and annotations or {}) do
                if type(annotation) == "table" then
                    results[#results + 1] = {
                        annotation = annotation,
                        book_path = path,
                        book_title = title,
                        chapter = annotation.chapter,
                        page_offset = page_offset,
                    }
                end
            end

            local cached_index = metadata:readSetting(PDF_MARKER_INDEX_SETTING)
            local attributes = lfs.attributes(path) or {}
            local signature = table.concat({
                path,
                tostring(attributes.size or ""),
                tostring(attributes.modification or ""),
            }, "|")
            if type(cached_index) == "table" and cached_index.signature == signature
                and type(cached_index.entries) == "table" then
                for _, marker in ipairs(cached_index.entries) do
                    if type(marker) == "table" and type(marker.page) == "number"
                        and type(marker.key) == "string"
                        and (marker.text == nil or type(marker.text) == "string")
                        and (marker.emoji == nil or type(marker.emoji) == "string") then
                        results[#results + 1] = {
                            marker = marker,
                            book_path = path,
                            book_title = title,
                            chapter = marker.chapter,
                            page_offset = page_offset,
                        }
                    end
                end
            end
        end
    end
    return results, skipped
end

function MarginPop:_exportAllHistoryAnnotations(group)
    local entries, skipped = self:_collectAllHistoryAnnotations()
    if not entries then
        self:_notice(skipped)
        return
    end
    if #entries == 0 then
        self:_notice(_("No saved annotations were found in reading history."))
        return
    end
    self:_exportAnnotations(entries, {
        history_group = group,
        skipped = skipped,
    })
end

function MarginPop:_exportAnnotations(entries, options)
    options = options or {}
    local doc = self.ui and self.ui.document
    local title = doc and doc.info and doc.info.title
    if not title or title == "" then
        title = doc and doc.file and doc.file:match("([^/]+)$") or "Book"
    end
    local export_context = self.export_context or {
        book = true, chapter = true, page = true,
    }
    local export_dialog
    local function export_to(path_text, separate_files)
        local directory = (path_text or ""):match("^%s*(.-)%s*$")
        if directory == "" or directory:find("%z") or directory:sub(1, 1) ~= "/" then
            self:_notice(_("Enter an absolute folder path."))
            return
        end
        if directory ~= "/" then directory = directory:gsub("/+$", "") end
        local attributes = lfs.attributes(directory)
        if attributes and attributes.mode ~= "directory" then
            self:_notice(_("The export path exists but is not a folder."))
            return
        elseif not attributes then
            local created, create_error = lfs.mkdir(directory)
            if not created then
                self:_notice(_("Could not create the export folder: ") .. tostring(create_error))
                return
            end
        end

        local function write_file(stem, contents)
            local path = directory .. "/" .. stem .. ".md"
            local suffix = 2
            while lfs.attributes(path) do
                path = directory .. "/" .. stem .. "-" .. suffix .. ".md"
                suffix = suffix + 1
            end
            local file, open_error = io.open(path, "wb")
            if not file then return false, open_error end
            local wrote, write_error = file:write(contents)
            if not wrote then
                file:close()
                return false, write_error
            end
            local closed, close_error = file:close()
            if not closed then return false, close_error end
            return true
        end

        local function markdown_for(entry, index)
            local item = entry.annotation or entry.marker
            local anchor = item.anchor or {}
            local page = entry.marker and entry.marker.page
                or anchor.page
                or (type(anchor.xpointer) == "table" and anchor.xpointer.page)
            page = tonumber(page)
            if page then
                page = page + (tonumber(entry.page_offset) or self.page_offset or 0)
            end
            local source = entry.marker and "PDF annotation" or "Book sidecar annotation"
            local heading = (item.title or ""):gsub("[\r\n]+", " ")
            if heading:match("^%s*$") then
                heading = string.format(_("Annotation %d"), index)
            end
            local lines = { "# " .. heading, "" }
            local book_title = entry.book_title or title
            local chapter = entry.chapter or item.chapter
            if not chapter and (not entry.book_path or entry.book_path == (doc and doc.file)) then
                chapter = self:_contextValues(item).chapter
            end
            if export_context.book then
                lines[#lines + 1] = "- Book: "
                    .. tostring(book_title):gsub("[\r\n]", " ")
            end
            if export_context.chapter and chapter and chapter ~= "" then
                lines[#lines + 1] = "- Chapter: "
                    .. tostring(chapter):gsub("[\r\n]", " ")
            end
            lines[#lines + 1] = "- Source: " .. source
            if export_context.page and page then
                lines[#lines + 1] = "- Page: " .. tostring(page)
            end
            if item.emoji then
                lines[#lines + 1] = "- Emoji: " .. emoji_label(item.emoji)
                lines[#lines + 1] = "- Emoji code: `" .. item.emoji .. "`"
                lines[#lines + 1] = "- Tags: #" .. emoji_tag(item.emoji)
            end
            lines[#lines + 1] = ""
            lines[#lines + 1] = item.text or ""
            lines[#lines + 1] = ""
            return table.concat(lines, "\n")
        end

        if options.history_group == "annotation" then
            for index, entry in ipairs(entries) do
                local item = entry.annotation or entry.marker
                local stem = string.format("%03d-%s-%s", index,
                    safe_filename(entry.book_title or title),
                    safe_filename(item.title or item.text or item.emoji or "annotation"))
                local saved, save_error = write_file(stem, markdown_for(entry, index))
                if not saved then
                    self:_notice(_("Export stopped; could not save a note: ")
                        .. tostring(save_error))
                    return
                end
            end
        elseif options.history_group == "book" or options.history_group == "chapter" then
            local groups, by_key = {}, {}
            for index, entry in ipairs(entries) do
                local group_value = entry.book_title or title
                local key = entry.book_path or group_value
                local stem = safe_filename(group_value)
                if options.history_group == "chapter" then
                    local item = entry.annotation or entry.marker
                    local chapter = tostring(
                        entry.chapter or item.chapter or _("No chapter"))
                    key = key .. "\0" .. chapter
                    stem = stem .. "-" .. safe_filename(chapter)
                end
                local group = by_key[key]
                if not group then
                    group = { stem = stem, entries = {} }
                    by_key[key] = group
                    groups[#groups + 1] = group
                end
                group.entries[#group.entries + 1] = {
                    entry = entry,
                    index = index,
                }
            end
            for _, group in ipairs(groups) do
                local documents = {}
                for _, grouped_entry in ipairs(group.entries) do
                    documents[#documents + 1] = markdown_for(
                        grouped_entry.entry, grouped_entry.index)
                end
                local saved, save_error = write_file(
                    group.stem .. "-annotations",
                    table.concat(documents, "\n---\n\n"))
                if not saved then
                    self:_notice(_("Export stopped; could not save a note: ")
                        .. tostring(save_error))
                    return
                end
            end
        elseif separate_files then
            for index, entry in ipairs(entries) do
                local item = entry.annotation or entry.marker
                local stem = string.format("%03d-%s", index,
                    safe_filename(item.title or item.text or item.emoji or "annotation"))
                local saved, save_error = write_file(stem, markdown_for(entry, index))
                if not saved then
                    self:_notice(_("Export stopped; could not save a note: ")
                        .. tostring(save_error))
                    return
                end
            end
        else
            local documents = {}
            for index, entry in ipairs(entries) do
                documents[#documents + 1] = markdown_for(entry, index)
            end
            local saved, save_error = write_file(
                safe_filename(title) .. "-annotations", table.concat(documents, "\n---\n\n"))
            if not saved then
                self:_notice(_("Could not export annotations: ") .. tostring(save_error))
                return
            end
        end
        UIManager:close(export_dialog)
        local message = string.format(_("Exported %d annotation(s) to %s"),
            #entries, directory)
        if options.skipped and options.skipped > 0 then
            message = message .. " " .. string.format(
                _("Skipped %d unreadable book sidecar(s)."), options.skipped)
        end
        self:_notice(message)
    end

    local function toggle_export_context(kind)
        local updated = {}
        for key, value in pairs(export_context) do
            updated[key] = value
        end
        updated[kind] = not updated[kind]
        if not self:_saveGlobalPreference(EXPORT_CONTEXT_SETTING, updated) then
            self:_notice(_("Could not save global export metadata preferences."))
            return
        end
        self.export_context = updated
        export_context = updated
        UIManager:setDirty(export_dialog, "ui")
    end

    local function context_button(kind, label)
        return {
            text_func = function()
                return string.format(_("%s: %s"), label,
                    export_context[kind] and _("included") or _("omitted"))
            end,
            callback = function()
                toggle_export_context(kind)
            end,
        }
    end

    local action_buttons
    if options.history_group then
        action_buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(export_dialog)
            end },
            { text = _("Export"), is_enter_default = true, callback = function()
                export_to(export_dialog:getInputText(), false)
            end },
        }}
    else
        action_buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(export_dialog)
            end },
            { text = _("Separate Markdown files"), callback = function()
                export_to(export_dialog:getInputText(), true)
            end },
            { text = _("One Markdown file"), is_enter_default = true, callback = function()
                export_to(export_dialog:getInputText(), false)
            end },
        }}
    end
    action_buttons[#action_buttons + 1] = {
        context_button("book", _("Book")),
        context_button("chapter", _("Chapter")),
        context_button("page", _("Page")),
    }

    export_dialog = InputDialog:new{
        title = options.history_group
            and _("Export annotation history") or _("Export selected annotations"),
        input = DEFAULT_EXPORT_DIR,
        buttons = action_buttons,
    }
    UIManager:show(export_dialog)
    export_dialog:onShowKeyboard()
end

function MarginPop:_openAnnotationSearchEntry(entry, dialog)
    UIManager:close(dialog)
    local doc = self.ui and self.ui.document
    if entry.marker then
        local marker = entry.marker.native_boxes and entry.marker
            or self:_resolveIndexedPdfMarker(entry)
        if not marker then
            self:_invalidatePdfMarkerIndex()
            self:_notice(_("That PDF annotation is no longer available. Reopen the list to refresh it."))
            return
        end
        if marker.xpointer and self.ui.rolling and self.ui.rolling.onGotoXPointer then
            self.ui.rolling:onGotoXPointer(marker.xpointer)
        elseif marker.xpointer and doc and doc.gotoXPointer then
            doc:gotoXPointer(marker.xpointer)
        elseif marker.page and self.ui.paging and self.ui.paging.onGotoPage then
            self.ui.paging:onGotoPage(marker.page)
        end
        self:_setDirty("ui")
        self:_editMarker(marker)
        return
    end

    local annotation = entry.annotation
    local anchor = annotation.anchor or {}
    if type(anchor.xpointer) == "string"
        and self.ui.rolling and self.ui.rolling.onGotoXPointer then
        self.ui.rolling:onGotoXPointer(anchor.xpointer)
    elseif type(anchor.xpointer) == "string" and doc and doc.gotoXPointer then
        doc:gotoXPointer(anchor.xpointer)
    elseif anchor.page and self.ui.paging and self.ui.paging.onGotoPage then
        self.ui.paging:onGotoPage(anchor.page)
    end
    self:_setDirty("ui")
    self:_promptSidecarAnnotation(annotation, entry.index)
end

function MarginPop:_showAnnotationResults(query, emoji_filter, results, selected_keys)
    selected_keys = selected_keys or {}
    results = type(results) == "table" and results or {}
    local results_dialog
    local selected_count = 0
    for _, entry in ipairs(results) do
        if selected_keys[annotation_entry_key(entry)] then
            selected_count = selected_count + 1
        end
    end

    local rows = {}
    for _, entry in ipairs(results) do
        local item = entry.annotation or entry.marker
        local key = annotation_entry_key(entry)
        local prefix = selected_keys[key] and "[x] " or "[ ] "
        local note = type(item.text) == "string" and item.text or ""
        if type(item.title) == "string" and item.title ~= "" then
            note = item.title .. (note ~= "" and (" — " .. note) or "")
        end
        note = util.fixUtf8(note, "�")
        if note == "" then note = _("(empty annotation)") end
        note = truncate_utf8((note:gsub("[\r\n]+", " ")), 120)
        local result_item = item
        local result_key = key
        rows[#rows + 1] = {{
            text = prefix .. note,
            align = "left",
            callback = function()
                if selected_keys[result_key] then
                    selected_keys[result_key] = nil
                else
                    selected_keys[result_key] = true
                end
                UIManager:close(results_dialog)
                self:_showAnnotationResults(
                    query, emoji_filter, results, selected_keys)
            end,
            hold_callback = function()
                if not result_item.emoji then return end
                local filtered = self:_collectAnnotationSearchResults(
                    query, result_item.emoji)
                if #filtered == 0 then
                    self:_notice(_("No matching annotations."))
                    return
                end
                UIManager:close(results_dialog)
                self:_showAnnotationResults(
                    query, result_item.emoji, filtered, selected_keys)
            end,
        }}
    end

    rows[#rows + 1] = {
        { text = _("Edit selected"), callback = function()
            local selected
            for _, entry in ipairs(results) do
                if selected_keys[annotation_entry_key(entry)] then
                    if selected then
                        self:_notice(_("Select only one annotation to edit."))
                        return
                    end
                    selected = entry
                end
            end
            if selected then
                self:_openAnnotationSearchEntry(selected, results_dialog)
            else
                self:_notice(_("Select an annotation first."))
            end
        end },
        { text = _("Export selected"), callback = function()
            local selected = {}
            for _, entry in ipairs(results) do
                if selected_keys[annotation_entry_key(entry)] then
                    selected[#selected + 1] = entry
                end
            end
            if #selected == 0 then
                self:_notice(_("Select annotations to export first."))
                return
            end
            UIManager:close(results_dialog)
            self:_exportAnnotations(selected)
        end },
    }
    rows[#rows + 1] = {
        { text = selected_count == #results and _("Clear selection") or _("Select all"),
            callback = function()
                local select_all = selected_count ~= #results
                for _, entry in ipairs(results) do
                    selected_keys[annotation_entry_key(entry)] = select_all or nil
                end
                UIManager:close(results_dialog)
                self:_showAnnotationResults(query, emoji_filter, results, selected_keys)
            end },
        { text = _("Search / filter"), callback = function()
            UIManager:close(results_dialog)
            self:_showSidecarAnnotationSearch(query, emoji_filter, selected_keys)
        end },
        { text = _("Close"), id = "close", callback = function()
            UIManager:close(results_dialog)
        end },
    }
    results_dialog = ButtonDialog:new{
        title = string.format(_("Annotations (%d found, %d selected)"),
            #results, selected_count),
        title_align = "left",
        width_factor = 0.98,
        buttons = rows,
    }
    UIManager:show(results_dialog)
    return results_dialog
end

function MarginPop:_showSidecarAnnotationSearch(initial_query, emoji_filter, selected_keys)
    selected_keys = selected_keys or {}
    local dialog
    local function show_results(query)
        local ok, results, index_complete = pcall(
            self._collectAnnotationSearchResults, self, query, emoji_filter)
        if not ok then
            logger.err("MarginPop could not load annotations:", results)
            self:_notice(_("Could not load the annotation list. Check the KOReader log."))
            return
        end
        if not index_complete then
            self:_startPdfMarkerIndexBuild()
        end
        if #results == 0 then
            self:_notice(index_complete and _("No matching annotations.")
                or _("No match on visible pages. PDF indexing is running; retry when it finishes."))
            return
        end
        UIManager:close(dialog)
        self:_showAnnotationResults(query, emoji_filter, results, selected_keys)
    end
    dialog = InputDialog:new{
        title = _("Search annotations"),
        input = initial_query or "",
        buttons = {{
            { text_func = function()
                return emoji_filter and ("#" .. emoji_tag(emoji_filter))
                    or _("Emoji filter")
            end,
                callback = function()
                    self:_openEmojiGrid(dialog, emoji_filter, function(code)
                        emoji_filter = code
                        UIManager:setDirty(dialog, "ui")
                    end)
                end },
            { text = _("Search"), is_enter_default = true, callback = function()
                show_results(dialog:getInputText() or "")
            end },
            { text = _("Close"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_annotationMarginGeometry()
    local min_width = Screen:scaleBySize(40)
    local width = Screen:scaleBySize(tonumber(self.annotation_margin_width) or 0)
    width = clamp(math.max(width, min_width), min_width,
        math.floor(Screen:getWidth() * 0.4))
    local inset = Screen:scaleBySize(4)
    local left = self.annotation_margin_side == "left"
        and inset or Screen:getWidth() - inset - width
    return left, width
end

function MarginPop:_defaultEmojiCenter(anchor_x, anchor_y, annotation)
    if not (anchor_x and anchor_y) then return nil end
    local placement = self:_getAnnotationEmojiPosition()
    local size = Screen:scaleBySize(
        tonumber(annotation and annotation.emoji_size)
            or self.emoji_size or DEFAULT_ANNOTATION_EMOJI_SIZE)
    if placement == "near_item" then
        return anchor_x + size / 2 + Screen:scaleBySize(2), anchor_y
    end
    local inset = Screen:scaleBySize(4)
    if placement == "right" then
        return Screen:getWidth() - inset - size / 2, anchor_y
    end
    return inset + size / 2, anchor_y
end

function MarginPop:_paintAnnotationEmoji(bb, x, y, item, selected)
    local center = item.emoji_center
    if not center then return end
    local cx, cy = center.x, center.y
    local size = Screen:scaleBySize(
        tonumber(item.annotation.emoji_size) or self.emoji_size or DEFAULT_ANNOTATION_EMOJI_SIZE)
    local image = item.annotation.emoji
        and self:_getEmojiImage(item.annotation.emoji, size)
    if image then
        local left = math.floor(x + cx - size / 2)
        local top = math.floor(y + cy - size / 2)
        bb:paintRoundedRect(left, top, size, size,
            selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            math.floor(size / 2))
        bb:alphablitFrom(image, left, top, 0, 0, size, size)
        if selected then
            if bb.invertRect then
                pcall(bb.invertRect, bb, left, top, size, size)
            end
            bb:paintBorder(left - 2, top - 2, size + 4, size + 4,
                MARKER_BORDER, Blitbuffer.COLOR_BLACK, math.floor(size / 2) + 2)
        end
        return
    end

    local diameter = math.max(3, math.floor(MARKER_DIAMETER / 2))
    local radius = math.floor(diameter / 2)
    local left = math.floor(x + cx - radius)
    local top = math.floor(y + cy - radius)
    bb:paintRoundedRect(left, top, diameter, diameter,
        selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(left, top, diameter, diameter,
        MARKER_BORDER, selected and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, radius)
end

function MarginPop:_paintAnnotationTextMargins(bb, x, y, items)
    local groups = {}
    local tolerance = Screen:scaleBySize(8)
    local visible_items = {}
    for _, item in ipairs(items) do
        if item.anchor_x and item.anchor_y
            and item.anchor_y >= -Screen:getHeight()
            and item.anchor_y <= Screen:getHeight() * 2 then
            visible_items[#visible_items + 1] = item
        end
    end
    items = visible_items
    table.sort(items, function(a, b)
        if a.anchor_y == b.anchor_y then return a.order < b.order end
        return a.anchor_y < b.anchor_y
    end)
    for _, item in ipairs(items) do
        local group = groups[#groups]
        if group and math.abs(item.anchor_y - group.y) <= tolerance then
            group.items[#group.items + 1] = item
        else
            groups[#groups + 1] = { y = item.anchor_y, items = { item } }
        end
    end

    self.last_emoji_positions = { markers = {}, annotations = {} }
    local inset = Screen:scaleBySize(4)
    local gap = Screen:scaleBySize(2)
    for _, group in ipairs(groups) do
        local total_width = 0
        for _, item in ipairs(group.items) do
            local size = Screen:scaleBySize(
                tonumber(item.annotation.emoji_size) or self.emoji_size
                    or DEFAULT_ANNOTATION_EMOJI_SIZE)
            item.icon_size = size
            total_width = total_width + size
        end
        total_width = total_width + math.max(0, #group.items - 1) * gap
        local placement = self:_getAnnotationEmojiPosition()
        local cursor
        if placement == "near_item" then
            cursor = clamp(group.items[1].anchor_x + gap, inset,
                math.max(inset, Screen:getWidth() - inset - total_width))
        elseif placement == "right" then
            cursor = Screen:getWidth() - inset - total_width
        else
            cursor = inset
        end
        for _, item in ipairs(group.items) do
            local center_x = cursor + item.icon_size / 2
            item.emoji_center = { x = center_x, y = group.y }
            cursor = cursor + item.icon_size + gap
            if item.marker then
                self.last_emoji_positions.markers[item.marker.key] = item.emoji_center
            else
                self.last_emoji_positions.annotations[item.annotation] = item.emoji_center
            end
        end
    end

    for _, item in ipairs(items) do
        self:_paintAnnotationEmoji(bb, x, y, item, item.selected)
    end
    if not self:_shouldShowAnnotationText() then return end

    local left, width = self:_annotationMarginGeometry()
    local padding = Screen:scaleBySize(3)
    local text_x = math.floor(x + left + padding)
    local text_width = math.max(1, width - 2 * padding)
    local font_size = math.max(1,
        Screen:scaleBySize(self.annotation_font_size or DEFAULT_ANNOTATION_FONT_SIZE))
    local face = Font:getFace("infofont", font_size)
    local line_height = math.max(1, font_size + Screen:scaleBySize(2))
    local text_rail_left = x + left
    local text_rail_right = text_rail_left + width

    for group_index, group in ipairs(groups) do
        local group_notes = {}
        local has_emoji, icon_size = false, 0
        local emoji_overlaps_text = false
        for _, item in ipairs(group.items) do
            local annotation = item.annotation
            if annotation.emoji then
                has_emoji = true
                icon_size = math.max(icon_size, item.icon_size or 0)
                local center = item.emoji_center
                if center and center.x + item.icon_size / 2 > text_rail_left
                    and center.x - item.icon_size / 2 < text_rail_right then
                    emoji_overlaps_text = true
                end
            end
            local text = type(annotation.text) == "string" and annotation.text or ""
            local title = type(annotation.title) == "string" and annotation.title or ""
            if title ~= "" then
                text = title .. (text ~= "" and (": " .. text) or "")
            end
            text = util.fixUtf8(text, "�"):gsub("[%c]+", " "):gsub("%s+", " ")
            if text ~= "" then group_notes[#group_notes + 1] = text end
        end
        local text = table.concat(group_notes, "  ·  ")
        if text ~= "" then
            local next_group = groups[group_index + 1]
            local next_icon_size = 0
            if next_group then
                for _, item in ipairs(next_group.items) do
                    next_icon_size = math.max(next_icon_size, item.icon_size or 0)
                end
            end
            local bottom = next_group
                and next_group.y - math.ceil(next_icon_size / 2) - gap
                or Screen:getHeight() - padding
            local start_y = group.y + padding
            if has_emoji and emoji_overlaps_text then
                start_y = group.y + math.ceil(icon_size / 2) + gap
            end
            local available_height = bottom - start_y
            local max_lines = math.floor(available_height / line_height)
            if max_lines < 1 and group_index == 1 then
                local top_limit = padding
                local above_height = group.y - gap - top_limit
                max_lines = math.floor(above_height / line_height)
                if max_lines > 0 then
                    start_y = group.y - gap - max_lines * line_height
                end
            end
            if max_lines > 0 then
                local lines, line = {}, ""
                local exhausted = false
                for word in text:gmatch("%S+") do
                    local candidate = line == "" and word or (line .. " " .. word)
                    local measured = RenderText:sizeUtf8Text(
                        0, text_width, face, candidate).x
                    if measured <= text_width then
                        line = candidate
                    else
                        if line ~= "" then
                            lines[#lines + 1] = line
                            if #lines >= max_lines then
                                exhausted = true
                                break
                            end
                        end
                        line = ""
                        for character in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                            candidate = line .. character
                            measured = RenderText:sizeUtf8Text(
                                0, text_width, face, candidate).x
                            if measured <= text_width then
                                line = candidate
                            else
                                if line ~= "" then
                                    lines[#lines + 1] = line
                                    if #lines >= max_lines then
                                        exhausted = true
                                        line = ""
                                        break
                                    end
                                end
                                line = character
                            end
                        end
                        if exhausted then break end
                    end
                end
                if line ~= "" and #lines < max_lines then
                    lines[#lines + 1] = line
                end
                local baseline = math.floor(y + start_y + font_size)
                for _, line_text in ipairs(lines) do
                    RenderText:renderUtf8Text(bb, text_x, baseline, face, line_text,
                        false, false, Blitbuffer.COLOR_BLACK, text_width)
                    baseline = baseline + line_height
                end
            end
        end
    end
end

function MarginPop:_getAnnotationBaseMargins()
    local doc = self.ui and self.ui.document
    if not doc then return nil end
    local state = self.typeset_margin_state
    if state and state.document == doc and type(state.base) == "table" then
        return state.base
    end
    local typeset = self.ui.typeset
    local margins = typeset and typeset.unscaled_margins
    if type(margins) ~= "table" then
        local configurable = doc.configurable
        local horizontal = configurable and configurable.h_page_margins
        if type(horizontal) == "table" then
            margins = {
                horizontal[1],
                configurable.t_page_margin,
                horizontal[2],
                configurable.b_page_margin,
            }
        end
    end
    return margins
end

function MarginPop:_capturePdfPageMargin()
    local doc = self.ui and self.ui.document
    local configurable = doc and doc.configurable
    local margin = configurable and tonumber(configurable.page_margin)
    if not (doc and doc.is_pdf and margin) then return false end
    if self.pdf_margin_document ~= doc then
        self.pdf_margin_document = doc
        self.pdf_base_page_margin = margin
        self.pdf_applied_page_margin = nil
    end
    return true
end

function MarginPop:_getAdjustedPdfPageMargin()
    local doc = self.ui and self.ui.document
    if not (doc and doc.is_pdf and doc.configurable and not self:_isReflowedPdf()) then
        return nil
    end
    self:_capturePdfPageMargin()
    local current = tonumber(doc.configurable.page_margin)
    if not (current and self.pdf_base_page_margin) then return nil end
    if self.pdf_applied_page_margin
        and math.abs(current - self.pdf_applied_page_margin) > 0.000001 then
        self.pdf_base_page_margin = current
    end
    local extra = self:_shouldShowAnnotationText()
        and (tonumber(self.annotation_margin_width) or 0) or 0
    local adjusted = self.pdf_base_page_margin
    if extra > 0 then
        adjusted = math.min(1.5, adjusted + Screen:scaleBySize(extra) / Screen:getDPI())
    end
    self.pdf_applied_page_margin = adjusted
    return adjusted
end

function MarginPop:_applyPdfPageMargin()
    local doc = self.ui and self.ui.document
    local adjusted = self:_getAdjustedPdfPageMargin()
    if not (adjusted and doc and doc.configurable) then return false end
    doc.configurable.page_margin = adjusted
    return true
end

function MarginPop:_restorePdfPageMargin()
    local doc = self.pdf_margin_document
    if doc and doc.configurable and self.pdf_base_page_margin then
        local current = tonumber(doc.configurable.page_margin)
        if not current or not self.pdf_applied_page_margin
            or math.abs(current - self.pdf_applied_page_margin) <= 0.000001 then
            doc.configurable.page_margin = self.pdf_base_page_margin
        end
    end
    self.pdf_margin_document = nil
    self.pdf_base_page_margin = nil
    self.pdf_applied_page_margin = nil
end

function MarginPop:_applyAnnotationMargins()
    local doc = self.ui and self.ui.document
    if not doc then return false end
    local margins = self:_getAnnotationBaseMargins()
    if type(margins) == "table" then
        if not doc.is_pdf or self:_isReflowedPdf() then
            self.ui:handleEvent(Event:new("SetPageMargins", margins))
            return true
        end
    end
    if doc.is_pdf then
        self:_capturePdfPageMargin()
        self:_applyPdfPageMargin()
        self.ui:handleEvent(Event:new("MarginUpdate"))
        return true
    end
    return false
end

function MarginPop:_saveAnnotationMarginPreference()
    if self:_saveSidecarAnnotations() then
        if not self:_applyAnnotationMargins() then
            logger.warn("MarginPop could not apply the annotation margin in this view")
            self:_notice(_("The setting was saved, but this view cannot reserve an annotation margin."))
        end
        self:_setDirty("ui")
        return true
    end
    return false
end

function MarginPop:_setAnnotationMarginSide(side)
    if side ~= "left" and side ~= "right" then return false end
    local previous = self.annotation_margin_side
    self.annotation_margin_side = side
    if not self:_saveAnnotationMarginPreference() then
        self.annotation_margin_side = previous
        self:_notice(_("Could not save the annotation margin side."))
        return false
    end
    return true
end

function MarginPop:_toggleAnnotationMarginText()
    local mode = "show_annotation_text_epub"
    local doc = self.ui and self.ui.document
    if doc and doc.is_pdf then
        mode = self:_isReflowedPdf()
            and "show_annotation_text_pdf_reflow" or "show_annotation_text_pdf"
    elseif doc and type(doc.file) == "string"
        and (doc.file:lower():match("%.txt$") or doc.file:lower():match("%.text$")) then
        mode = "show_annotation_text_txt"
    end
    local previous = self[mode]
    self[mode] = not previous
    if not self:_saveAnnotationMarginPreference() then
        self[mode] = previous
        self:_notice(_("Could not save the annotation display preference."))
        return false
    end
    return true
end

function MarginPop:_setAnnotationFontSize(size)
    size = tonumber(size)
    if not size or size < 1 or size > 24 then return false end
    size = math.floor(size)
    local previous = self.annotation_font_size
    self.annotation_font_size = size
    if not self:_saveAnnotationMarginPreference() then
        self.annotation_font_size = previous
        self:_notice(_("Could not save the annotation text size."))
        return false
    end
    return true
end

function MarginPop:_editAnnotationFontSize()
    local dialog
    dialog = InputDialog:new{
        title = _("Annotation text size"),
        description = _("Enter a number from 1 to 24. Default: 2."),
        input = tostring(self.annotation_font_size),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Apply"), is_enter_default = true, callback = function()
                local size = tonumber(dialog:getInputText())
                if not size or size < 1 or size > 24 then
                    self:_notice(_("Enter a text size from 1 to 24."))
                    return
                end
                if self:_setAnnotationFontSize(size) then
                    UIManager:close(dialog)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_setAnnotationEmojiPosition(position)
    if position ~= "near_item" and position ~= "left" and position ~= "right" then
        return false
    end
    local previous = self.annotation_emoji_position
    self.annotation_emoji_position = position
    if not self:_saveAnnotationMarginPreference() then
        self.annotation_emoji_position = previous
        self:_notice(_("Could not save the annotation emoji position."))
        return false
    end
    return true
end

function MarginPop:_editEmojiSize()
    local dialog
    dialog = InputDialog:new{
        title = _("Annotation emoji size"),
        description = _("Enter a number from 2 to 64. Smaller sizes use less margin space."),
        input = tostring(self.emoji_size),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Apply"), is_enter_default = true, callback = function()
                local size = tonumber(dialog:getInputText())
                if not size or size < 2 or size > 64 then
                    self:_notice(_("Enter an emoji size from 2 to 64."))
                    return
                end
                if self:_setEmojiSize(math.floor(size)) then
                    UIManager:close(dialog)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_editAnnotationMarginWidth()
    local dialog
    dialog = InputDialog:new{
        title = _("Text margin width"),
        description = _("Extra page space reserved for annotation text. Set 0 to disable extra layout space."),
        input = tostring(self.annotation_margin_width),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local width = tonumber(dialog:getInputText())
                if not width or width < 0 or width > 200 then
                    self:_notice(_("Enter a margin width from 0 to 200."))
                    return
                end
                local previous = self.annotation_margin_width
                self.annotation_margin_width = math.floor(width)
                if not self:_saveAnnotationMarginPreference() then
                    self.annotation_margin_width = previous
                    self:_notice(_("Could not save the annotation margin width."))
                    return
                end
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function MarginPop:_showAnnotationDisplayControls()
    local values = {
        emoji_size = self.emoji_size,
        emoji_position = self.annotation_emoji_position,
        text_size = self.annotation_font_size,
        margin_width = self.annotation_margin_width,
        text_side = self.annotation_margin_side,
        show_text_epub = self.show_annotation_text_epub ~= false,
        show_text_txt = self.show_annotation_text_txt ~= false,
        show_text_pdf = self.show_annotation_text_pdf ~= false,
        pdf_reflow_emoji_position = self.annotation_pdf_reflow_emoji_position or "same",
        show_text_pdf_reflow = self.show_annotation_text_pdf_reflow == true,
    }

    local function open_controls()
        local dialog
        local rows = {}
        local function redraw()
            UIManager:close(dialog)
            UIManager:scheduleIn(0.05, open_controls)
        end
        local function add_number_row(label, key, minimum, maximum, step)
            local function change_by(delta)
                values[key] = clamp(values[key] + delta, minimum, maximum)
                redraw()
            end
            local function enter_value()
                local input_dialog
                input_dialog = InputDialog:new{
                    title = label,
                    input = tostring(values[key]),
                    buttons = {{
                        { text = _("Cancel"), id = "close", callback = function()
                            UIManager:close(input_dialog)
                        end },
                        { text = _("Apply"), is_enter_default = true, callback = function()
                            local value = tonumber(input_dialog:getInputText())
                            if not value or value % 1 ~= 0
                                or value < minimum or value > maximum then
                                self:_notice(string.format(
                                    _("Enter a whole number from %d to %d."),
                                    minimum, maximum))
                                return
                            end
                            values[key] = value
                            UIManager:close(input_dialog)
                            redraw()
                        end },
                    }},
                }
                UIManager:show(input_dialog)
                input_dialog:onShowKeyboard()
            end
            rows[#rows + 1] = {
                { text = "-", callback = function() change_by(-step) end },
                { text = string.format(_("%s: %d"), label, values[key]),
                    callback = enter_value },
                { text = "+", callback = function() change_by(step) end },
            }
        end
        local function add_choice_row(label, key, choices)
            rows[#rows + 1] = { { text = label, enabled = false } }
            local row = {}
            for _, choice in ipairs(choices) do
                local choice_value = choice.value
                row[#row + 1] = {
                    text = (values[key] == choice_value and "[x] " or "") .. choice.label,
                    callback = function()
                        values[key] = choice_value
                        redraw()
                    end,
                }
            end
            rows[#rows + 1] = row
        end
        add_number_row(_("Emoji size"), "emoji_size", 2, 64, 1)
        add_number_row(_("Text size"), "text_size", 1, 24, 1)
        add_number_row(_("Text margin width"), "margin_width", 0, 200, 4)
        add_choice_row(_("Emoji"), "emoji_position", {
            { value = "left", label = _("Left") },
            { value = "near_item", label = _("Near anchor") },
            { value = "right", label = _("Right") },
        })
        add_choice_row(_("PDF reflow emoji"), "pdf_reflow_emoji_position", {
            { value = "same", label = _("Same as above") },
            { value = "left", label = _("Left") },
            { value = "near_item", label = _("Anchor") },
            { value = "right", label = _("Right") },
        })
        add_choice_row(_("Text side"), "text_side", {
            { value = "left", label = _("Left") },
            { value = "right", label = _("Right") },
        })
        rows[#rows + 1] = { { text = _("Text on:"), enabled = false } }
        local text_mode_row = {}
        for _, option in ipairs({
            { key = "show_text_epub", label = _("EPUB") },
            { key = "show_text_txt", label = _("TXT") },
            { key = "show_text_pdf", label = _("PDF") },
            { key = "show_text_pdf_reflow", label = _("Reflow") },
        }) do
            local key = option.key
            local label = option.label
            text_mode_row[#text_mode_row + 1] = {
                text = (values[key] and "[x] " or "[ ] ") .. label,
                callback = function()
                    values[key] = not values[key]
                    redraw()
                end,
            }
        end
        rows[#rows + 1] = text_mode_row
        rows[#rows + 1] = {
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
            end },
            { text = _("Apply"), is_enter_default = true, callback = function()
                local previous = {
                    emoji_size = self.emoji_size,
                    emoji_position = self.annotation_emoji_position,
                    pdf_reflow_emoji_position = self.annotation_pdf_reflow_emoji_position,
                    text_size = self.annotation_font_size,
                    margin_width = self.annotation_margin_width,
                    text_side = self.annotation_margin_side,
                    show_text_epub = self.show_annotation_text_epub,
                    show_text_txt = self.show_annotation_text_txt,
                    show_text_pdf = self.show_annotation_text_pdf,
                    show_text_pdf_reflow = self.show_annotation_text_pdf_reflow,
                }
                self.emoji_size = values.emoji_size
                self.annotation_emoji_position = values.emoji_position
                self.annotation_pdf_reflow_emoji_position =
                    values.pdf_reflow_emoji_position
                self.annotation_font_size = values.text_size
                self.annotation_margin_width = values.margin_width
                self.annotation_margin_side = values.text_side
                self.show_annotation_text_epub = values.show_text_epub
                self.show_annotation_text_txt = values.show_text_txt
                self.show_annotation_text_pdf = values.show_text_pdf
                self.show_annotation_text_pdf_reflow = values.show_text_pdf_reflow
                if self:_saveAnnotationMarginPreference() then
                    UIManager:close(dialog)
                    return
                end
                self.emoji_size = previous.emoji_size
                self.annotation_emoji_position = previous.emoji_position
                self.annotation_pdf_reflow_emoji_position =
                    previous.pdf_reflow_emoji_position
                self.annotation_font_size = previous.text_size
                self.annotation_margin_width = previous.margin_width
                self.annotation_margin_side = previous.text_side
                self.show_annotation_text_epub = previous.show_text_epub
                self.show_annotation_text_txt = previous.show_text_txt
                self.show_annotation_text_pdf = previous.show_text_pdf
                self.show_annotation_text_pdf_reflow = previous.show_text_pdf_reflow
                self:_applyAnnotationMargins()
                self:_notice(_("Could not save the annotation display settings."))
            end },
        }
        dialog = ButtonDialog:new{
            title = _("Annotation Display Controls"),
            width_factor = 0.98,
            rows_per_page = 8,
            buttons = rows,
        }
        UIManager:show(dialog)
    end

    open_controls()
end

function MarginPop:_getEmojiImage(code, size)
    if type(code) ~= "string" or not code:match("^[%x%-]+$") then
        return nil
    end
    local key = code .. ":" .. size
    local cached = self.emoji_cache[key]
    if cached ~= nil then return cached or nil end
    local path = PLUGIN_DIR .. "/openmoji-black/" .. code .. ".svg"
    if lfs.attributes(path, "mode") ~= "file" then
        self.emoji_cache[key] = false
        return nil
    end
    local ok, image = pcall(RenderImage.renderSVGImageFile, RenderImage, path, size, size)
    self.emoji_cache[key] = ok and image or false
    return self.emoji_cache[key] or nil
end

-- ReaderView view-module hook. V2 markers are painted by KOReader, not the PDF.
function MarginPop:paintTo(bb, x, y)
    local doc = self.ui and self.ui.document
    if not doc then return end

    local overlays = {}
    local order = 0
    if doc.is_pdf then
        for _, page in ipairs(self:_getMarkerPagesForView()) do
            for _, marker in ipairs(self:_getPageMarkers(page)) do
                if marker.version == 2 then
                    local anchor_x, anchor_y = self:_markerScreenCenter(marker)
                    if anchor_x and anchor_y then
                        order = order + 1
                        overlays[#overlays + 1] = {
                            annotation = marker,
                            marker = marker,
                            anchor_x = anchor_x,
                            anchor_y = anchor_y,
                            order = order,
                            selected = self.move_once and self.move_selected
                                and self.move_selected.key == marker.key,
                        }
                    end
                end
            end
        end
    end

    local visible_pdf_pages
    if doc.is_pdf then
        visible_pdf_pages = {}
        for _, page in ipairs(self:_getVisiblePages()) do
            visible_pdf_pages[page] = true
        end
    end
    for _, annotation in ipairs(self.sidecar_annotations or {}) do
        local anchor = annotation.anchor or {}
        local anchor_page = anchor.page
            or (type(anchor.xpointer) == "table" and anchor.xpointer.page)
        if not visible_pdf_pages or not anchor_page or visible_pdf_pages[anchor_page] then
            local anchor_x, anchor_y = self:_annotationScreenCenter(annotation)
            if anchor_x and anchor_y then
                order = order + 1
                overlays[#overlays + 1] = {
                    annotation = annotation,
                    anchor_x = anchor_x,
                    anchor_y = anchor_y,
                    order = order,
                    selected = self.move_selected_annotation == annotation,
                }
            end
        end
    end
    self:_paintAnnotationTextMargins(bb, x, y, overlays)
end

function MarginPop:_toggleAddMode()
    self:_setAnnotationMode(not self.annotate_mode)
end

function MarginPop:_setAnnotationMode(enabled)
    local entering = enabled and not self.annotate_mode
    self.annotate_mode = enabled
    if enabled then
        self:_activate()
        self.add_mode = false
        self.move_selected = nil
        self.move_selected_annotation = nil
        self.move_once = false
    else
        self.add_mode = false
        self.move_selected = nil
        self.move_selected_annotation = nil
        self.move_once = false
    end
    self:_setDirty("ui")
    if entering then
        UIManager:show(Notification:new{
            text = _("Annotation mode: tap a location to add a note."),
            timeout = 2,
        })
    end
end

function MarginPop:_setAddMode(enabled)
    local entering = enabled and not self.add_mode
    self.add_mode = enabled
    self.annotate_mode = enabled
    if enabled then
        self:_activate()
        self.move_selected = nil
        self.move_selected_annotation = nil
        self.move_once = false
    else
        self.move_selected = nil
        self.move_selected_annotation = nil
        self.move_once = false
    end
    self:_setDirty("ui")
    if entering then
        UIManager:show(Notification:new{
            text = _("Annotation mode: tap anywhere to add a note."),
            timeout = 2,
        })
    end
end

function MarginPop:_setAnnotationEditorFullscreen(fullscreen)
    if self.annotation_editor_fullscreen == fullscreen then return true end
    if not self:_saveGlobalPreference(ANNOTATION_EDITOR_FULLSCREEN_SETTING, fullscreen) then
        self:_notice(_("Could not save the annotation editor preference."))
        return false
    end
    self.annotation_editor_fullscreen = fullscreen
    self:_setDirty("ui")
    return true
end

function MarginPop:_toggleAnnotationEditorFullscreen()
    return self:_setAnnotationEditorFullscreen(not self.annotation_editor_fullscreen)
end

function MarginPop:_toggleAnnotationSelectionDefault()
    local enabled = not self.annotate_selection_by_default
    if not self:_saveGlobalPreference(ANNOTATION_SELECTION_DEFAULT_SETTING, enabled) then
        self:_notice(_("Could not save the selected-text action preference."))
        return false
    end
    self.annotate_selection_by_default = enabled
    self:_notice(enabled
        and _("Selected text will open a new annotation directly.")
        or _("Selected text will show KOReader's action menu."))
    return true
end

function MarginPop:_togglePdfNoteEmbedding()
    local enabled = not self.embed_pdf_notes
    self.embed_pdf_notes = enabled
    if not self:_saveSidecarAnnotations() then
        self.embed_pdf_notes = not enabled
        self:_notice(_("Could not save the PDF embedding preference for this book."))
        return
    end
    self:_setDirty("ui")
    self:_notice(enabled
        and _("PDF notes will be embedded when this book closes.")
        or _("Automatic PDF note embedding is off for this book."))
end

function MarginPop:_setPdfReflowAnchorMode(mode)
    if mode ~= "nearest" and mode ~= "line_right" then return end
    local previous = self.pdf_reflow_anchor_mode
    self.pdf_reflow_anchor_mode = mode
    if not self:_saveSidecarAnnotations() then
        self.pdf_reflow_anchor_mode = previous
        self:_notice(_("Could not save the PDF anchor preference."))
        return
    end
    self:_setDirty("ui")
end

function MarginPop:_setEmojiSize(size)
    size = tonumber(size)
    if not size or size < 2 or size > 64 then return false end
    size = math.floor(size)
    local previous = self.emoji_size
    self.emoji_size = size
    if not self:_saveSidecarAnnotations() then
        self.emoji_size = previous
        self:_notice(_("Could not save the annotation emoji size."))
        return false
    end
    self:_setDirty("ui")
    return true
end

function MarginPop:_resetMarker(marker)
    if not marker or marker.version ~= 2 then return false end

    local has_pending = self.positions[marker.key] ~= nil
    local has_embedded = marker.embedded_x ~= nil and marker.embedded_y ~= nil
    local already_reset = self.dirty_positions[marker.key] == "reset"
    if not has_pending and not has_embedded and not already_reset then
        return false
    end

    self.positions[marker.key] = nil
    self.dirty_positions[marker.key] = "reset"
    return true
end

function MarginPop:_resetVisiblePositions()
    local changed = false
    for _, page in ipairs(self:_getVisiblePages()) do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            if self:_resetMarker(marker) then
                changed = true
            end
        end
    end

    self.move_selected = nil
    if changed then
        self:_savePositions()
        self:_setDirty("ui")
    end
end

function MarginPop:_resetAllPositions()
    local doc = self.ui and self.ui.document
    local page_count = doc and doc.info and doc.info.number_of_pages or 0
    local changed = false

    for page = 1, page_count do
        for _, marker in ipairs(self:_getPageMarkers(page)) do
            if self:_resetMarker(marker) then
                changed = true
            end
        end
    end

    self.move_selected = nil
    if changed then
        self:_savePositions()
        self:_setDirty("ui")
    end
end

function MarginPop:addToMainMenu(menu_items)
    local history_export_items = {
        {
            text = _("Split by book"),
            callback = function() self:_exportAllHistoryAnnotations("book") end,
        },
        {
            text = _("Split by book and chapter"),
            callback = function() self:_exportAllHistoryAnnotations("chapter") end,
        },
        {
            text = _("One file per annotation"),
            callback = function() self:_exportAllHistoryAnnotations("annotation") end,
        },
    }
    local pdf_options = {
        {
            text = _("PDF Reflow Anchor Placement"),
            sub_item_table = {
                {
                    text = _("Nearest Text Item"),
                    checked_func = function()
                        return self.pdf_reflow_anchor_mode == "nearest"
                    end,
                    callback = function() self:_setPdfReflowAnchorMode("nearest") end,
                },
                {
                    text = _("Right Margin of Nearest Text Item"),
                    checked_func = function()
                        return self.pdf_reflow_anchor_mode == "line_right"
                    end,
                    callback = function() self:_setPdfReflowAnchorMode("line_right") end,
                },
            },
        },
        {
            text = _("Reset visible-page legacy marker positions"),
            callback = function() self:_resetVisiblePositions() end,
        },
        {
            text = _("Reset all legacy marker positions"),
            callback = function() self:_resetAllPositions() end,
        },
    }
    if self.ui and self.ui.document and self.ui.document.is_pdf then
        table.insert(pdf_options, 1, {
            text = _("Embed Notes in PDF on Close"),
            checked_func = function() return self.embed_pdf_notes end,
            callback = function() self:_togglePdfNoteEmbedding() end,
        })
    end
    menu_items.marginpop = {
        text = _("MarginPop"),
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text = _("Annotation Mode"),
                checked_func = function()
                    return self.annotate_mode
                end,
                callback = function()
                    self:_toggleAddMode()
                end,
            },
            {
                text = _("Annotation List"),
                callback = function()
                    self:onMarginPopAnnotationList()
                end,
            },
            {
                text = _("Search Annotations"),
                callback = function()
                    self:_showSidecarAnnotationSearch("", nil, {})
                end,
            },
            {
                text = _("Annotate Selected Text by Default"),
                checked_func = function()
                    return self.annotate_selection_by_default
                end,
                callback = function()
                    self:_toggleAnnotationSelectionDefault()
                end,
            },
            {
                text = _("Fullscreen Annotation Editor"),
                checked_func = function()
                    return self.annotation_editor_fullscreen
                end,
                callback = function()
                    self:_toggleAnnotationEditorFullscreen()
                end,
            },
            {
                text = _("Annotation Display Controls"),
                callback = function()
                    self:_showAnnotationDisplayControls()
                end,
                separator = true,
            },
            {
                text = _("PDF Options"),
                sub_item_table = pdf_options,
            },
            {
                text = _("Export All History Annotations"),
                sub_item_table = history_export_items,
            },
            {
                text = _("Help"),
                keep_menu_open = true,
                callback = function()
                    self:_show(_(
                        "Tap an annotation for its quick action bar; long-press opens the editor directly.\n"
                        .. "Use Save & Move in the editor to relocate it.\n\n"
                        .. "• Bind Annotation Mode to a gesture to add notes in PDF, EPUB, and TXT books.\n"
                        .. "• Select text and use Add annotation to create a note with the quote included.\n"
                        .. "• Reflow PDF, EPUB, and TXT anchors are saved in the book sidecar.\n"
                        .. "• PDF sidecar notes can be embedded as standard comments on close; toggle this per book.\n"
                        .. "• Existing KOPOPZH1/KOPOPZH2 PDF markers remain supported.\n"
                        .. "• Display Controls has compact size/width adjustments, separate PDF reflow emoji placement, and per-mode text visibility.\n"
                        .. "• Search supports text and emoji filters; the editor can insert the book, chapter, and page.\n"
                        .. "• PDF reflow anchors can use the nearest text item or its right margin. If OCR has no text boxes, placement falls back to the page center.\n\n"
                        .. "If sidecar or PDF saving fails, pending changes are retained and an error is shown."
                    ))
                end,
            },
        },
    }
    if not (self.ui and self.ui.document and self.ui.document.is_pdf) then
        local submenu = menu_items.marginpop.sub_item_table
        for index, item in ipairs(submenu) do
            if item.text == _("PDF Options") then
                table.remove(submenu, index)
                break
            end
        end
    end
end

return MarginPop
