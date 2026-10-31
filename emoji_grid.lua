-- A paged, image-only OpenMoji picker for the PDF popup text dialog.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")

local Screen = Device.screen
local COLS = 6

local function gridMetrics()
    local width = math.floor(Screen:getWidth() * 0.92)
    local cell = math.floor((width - 2 * Size.padding.default) / COLS)
    local rows = math.min(5, math.max(3,
        math.floor(Screen:getHeight() * 0.70 / cell)))
    return width, cell, rows
end

local function unique_codes(entries, available, excluded)
    local result = {}
    local seen = {}
    excluded = excluded or {}
    for _, code in ipairs(entries or {}) do
        if available[code] and not excluded[code] and not seen[code] then
            result[#result + 1] = code
            seen[code] = true
        end
    end
    return result, seen
end

local EmojiTile = InputContainer:extend{
    file = nil,
    size = nil,
    selected = false,
    callback = nil,
    hold_callback = nil,
}

function EmojiTile:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
    self:_build()
end

function EmojiTile:_build()
    local border = self.selected and math.max(4, Screen:scaleBySize(4)) or 1
    local icon_size = math.floor(self.size * 0.72)
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = self.selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_GRAY,
        bordersize = border,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.size - 2 * border, h = self.size - 2 * border },
            ImageWidget:new{
                file = self.file,
                width = icon_size,
                height = icon_size,
                alpha = true,
            },
        },
    }
end

function EmojiTile:setSelected(selected)
    if self.selected == selected then return end
    self.selected = selected
    self:_build()
    UIManager:setDirty(self, "ui")
end

function EmojiTile:onTap()
    if self.callback then self.callback() end
    return true
end

function EmojiTile:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

local EmojiGrid = InputContainer:extend{
    name = "marginpop_emoji_grid",
    faces = nil,
    assets_dir = nil,
    selected = nil,
    history = nil,
    favorites = nil,
    on_history_hold = nil,
    on_favorite_hold = nil,
    history_offset = 0,
    favorites_offset = 0,
    page = 1,
    on_select = nil,
    on_cancel = nil,
}

function EmojiGrid.pageForCode(faces, code)
    if not code then return 1 end
    local _, _, rows = gridMetrics()
    for index, face in ipairs(faces) do
        if face.code == code then
            return math.ceil(index / (COLS * rows))
        end
    end
    return 1
end

function EmojiGrid.makeQuickRows(options)
    local width, cell = gridMetrics()
    local available = {}
    for _, face in ipairs(options.faces or {}) do
        available[face.code] = face
    end
    local quick_rows = VerticalGroup:new{}
    local tiles = {}
    local tile_size = math.floor(math.min(cell * 0.56, Screen:scaleBySize(48)))
    local selected = options.selected

    local function selected_preview(code)
        local face = code and available[code]
        local preview = HorizontalGroup:new{}
        if face then
            table.insert(preview, ImageWidget:new{
                file = options.assets_dir .. "/" .. code .. ".svg",
                width = math.floor(tile_size * 0.72),
                height = math.floor(tile_size * 0.72),
                alpha = true,
            })
        end
        table.insert(preview, TextWidget:new{
            text = face and (_("Selected: ") .. face.name)
                or code and _("Selected emoji") or _("No emoji selected"),
            face = Font:getFace("infofont"),
            max_width = width - tile_size,
        })
        return CenterContainer:new{
            dimen = Geom:new{ w = width, h = tile_size },
            preview,
        }
    end

    local function set_selected(code)
        selected = code
        for _, quick_tile in ipairs(tiles) do
            quick_tile:setSelected(quick_tile.code == code)
        end
        quick_rows[1] = selected_preview(code)
        UIManager:setDirty(quick_rows, "ui")
    end

    quick_rows.setSelected = function(_, code)
        set_selected(code)
    end
    table.insert(quick_rows, selected_preview(selected))

    local favorites, favorite_set = unique_codes(options.favorites, available)
    local history = unique_codes(options.history, available, favorite_set)

    local function add_row(label_text, entries, hold_callback)
        if not entries or #entries == 0 then return end
        local label = TextWidget:new{
            text = label_text,
            face = Font:getFace("smallinfofont"),
        }
        table.insert(quick_rows, CenterContainer:new{
            dimen = Geom:new{ w = width, h = label:getSize().h },
            label,
        })
        local row = HorizontalGroup:new{}
        for index = 1, math.min(COLS, #entries) do
            local code = entries[index]
            if available[code] then
                local tile = EmojiTile:new{
                    file = options.assets_dir .. "/" .. code .. ".svg",
                    size = tile_size,
                    selected = selected == code,
                    callback = function()
                        set_selected(code)
                        if options.on_select then options.on_select(code) end
                    end,
                    hold_callback = function()
                        if hold_callback then hold_callback(code) end
                    end,
                }
                tile.code = code
                tiles[#tiles + 1] = tile
                table.insert(row, tile)
            end
        end
        if #row > 0 then
            table.insert(quick_rows, CenterContainer:new{
                dimen = Geom:new{ w = width, h = tile_size },
                row,
            })
        end
    end

    if #history > 0 then
        add_row(_("Recent"), history, options.on_history_hold)
    else
        local quick_picks = {}
        for _, face in ipairs(options.faces or {}) do
            if not favorite_set[face.code] and #quick_picks < COLS then
                quick_picks[#quick_picks + 1] = face.code
            end
        end
        add_row(_("Quick picks"), quick_picks)
    end
    add_row(_("Favorites"), favorites, options.on_favorite_hold)
    if #quick_rows == 0 then return nil end
    return quick_rows
end

function EmojiGrid:init()
    self.dimen = Screen:getSize()
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:_build()
    UIManager:setDirty(self, "ui")
end

function EmojiGrid:_build()
    local width, cell, rows = gridMetrics()
    local per_page = COLS * rows
    local pages = math.max(1, math.ceil(#self.faces / per_page))
    self.page = math.max(1, math.min(self.page, pages))

    local top = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {{
            { text = _("Plain Dot"), callback = function() self:_choose(nil) end },
            { text = _("Cancel"), callback = function() UIManager:close(self) end },
        }},
    }
    local title = TextWidget:new{
        text = _("Choose Emoji"),
        face = Font:getFace("smallinfofont"),
    }
    local title_row = CenterContainer:new{
        dimen = Geom:new{ w = width, h = title:getSize().h + Size.padding.default },
        title,
    }

    local available = {}
    for _, face in ipairs(self.faces) do available[face.code] = face end
    local favorites, favorite_set = unique_codes(self.favorites, available)
    local history = unique_codes(self.history, available, favorite_set)
    local quick_rows = VerticalGroup:new{}
    local function add_quick_row(title_text, entries, offset_name, hold_callback)
        if not entries or #entries == 0 then return end
        local label = TextWidget:new{
            text = title_text,
            face = Font:getFace("smallinfofont"),
        }
        table.insert(quick_rows, CenterContainer:new{
            dimen = Geom:new{ w = width, h = label:getSize().h },
            label,
        })
        local offset = self[offset_name] or 0
        local first_quick = math.min(offset + 1, #entries)
        local last_quick = math.min(#entries, first_quick + COLS - 1)
        local quick_row = HorizontalGroup:new{}
        if #entries > COLS then
            table.insert(quick_row, ButtonTable:new{
                width = math.floor(width / 9),
                show_parent = self,
                buttons = {{
                    { text = "◀", enabled = offset > 0, callback = function()
                        self[offset_name] = math.max(0, offset - 1)
                        self:_build()
                    end },
                }},
            })
        end
        for quick_index = first_quick, last_quick do
            local code = entries[quick_index]
            if available[code] then
                table.insert(quick_row, EmojiTile:new{
                    file = self.assets_dir .. "/" .. code .. ".svg",
                    size = math.floor(cell * 0.72),
                    selected = self.selected == code,
                    callback = function() self:_choose(code) end,
                    hold_callback = function()
                        if hold_callback then hold_callback(code) end
                        self:_build()
                        UIManager:setDirty(self, "ui")
                    end,
                })
            end
        end
        if #entries > COLS then
            table.insert(quick_row, ButtonTable:new{
                width = math.floor(width / 9),
                show_parent = self,
                buttons = {{
                    { text = "▶", enabled = last_quick < #entries, callback = function()
                        self[offset_name] = math.min(#entries - COLS, offset + 1)
                        self:_build()
                    end },
                }},
            })
        end
        table.insert(quick_rows, quick_row)
    end
    add_quick_row(_("Recent"), history, "history_offset",
        self.on_history_hold)
    add_quick_row(_("Favorites"), favorites, "favorites_offset",
        self.on_favorite_hold)

    local grid = VerticalGroup:new{}
    local first = (self.page - 1) * per_page + 1
    local last = math.min(#self.faces, first + per_page - 1)
    local row
    for index = first, last do
        if (index - first) % COLS == 0 then
            row = HorizontalGroup:new{}
            table.insert(grid, row)
        end
        local face = self.faces[index]
        table.insert(row, EmojiTile:new{
            file = self.assets_dir .. "/" .. face.code .. ".svg",
            size = cell,
            selected = self.selected == face.code,
            callback = function() self:_choose(face.code) end,
        })
    end

    local page_row = ButtonTable:new{
        width = width,
        show_parent = self,
        buttons = {{
            { text = "◀", enabled = self.page > 1,
                callback = function() self:_switchPage(self.page - 1) end },
            { text = self.page .. " / " .. pages, enabled = false },
            { text = "▶", enabled = self.page < pages,
                callback = function() self:_switchPage(self.page + 1) end },
        }},
    }
    self.frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        padding = 0,
        VerticalGroup:new{
            align = "center",
            top,
            title_row,
            quick_rows,
            grid,
            page_row,
        },
    }
    self.movable = MovableContainer:new{ self.frame }
    self[1] = CenterContainer:new{ dimen = self.dimen, self.movable }
end

function EmojiGrid:_choose(code)
    self.choice_made = true
    UIManager:close(self)
    if self.on_select then self.on_select(code) end
end

function EmojiGrid:_switchPage(page)
    self.replacing = true
    UIManager:close(self)
    UIManager:show(EmojiGrid:new{
        faces = self.faces,
        assets_dir = self.assets_dir,
        selected = self.selected,
        history = self.history,
        favorites = self.favorites,
        on_history_hold = self.on_history_hold,
        on_favorite_hold = self.on_favorite_hold,
        history_offset = self.history_offset,
        favorites_offset = self.favorites_offset,
        page = page,
        on_select = self.on_select,
        on_cancel = self.on_cancel,
    })
end

function EmojiGrid:onTapClose(_, ges)
    if self.frame.dimen and ges.pos:notIntersectWith(self.frame.dimen) then
        UIManager:close(self)
        return true
    end
    return false
end

function EmojiGrid:onClose()
    UIManager:close(self)
    return true
end

function EmojiGrid:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.frame.dimen)
    if not self.choice_made and not self.replacing and self.on_cancel then
        self.on_cancel()
    end
end

return EmojiGrid
