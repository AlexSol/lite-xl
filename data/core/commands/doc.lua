local core = require "core"
local command = require "core.command"
local common = require "core.common"
local config = require "core.config"
local translate = require "core.doc.translate"
local DocView = require "core.docview"


local function dv()
  return core.active_view
end


local function doc()
  return core.active_view.doc
end


local function get_indent_string()
  if config.tab_type == "hard" then
    return "\t"
  end
  return string.rep(" ", config.indent_size)
end


local function doc_multiline_selection(sort)
  local line1, col1, line2, col2, swap = doc():get_selection(sort)
  if line2 > line1 and col2 == 1 then
    line2 = line2 - 1
    col2 = #doc().lines[line2]
  end
  return line1, col1, line2, col2, swap
end

local function append_line_if_last_line(line)
  if line >= #doc().lines then
    doc():insert(line, math.huge, "\n")
  end
end


local function save(filename)
  if filename then
    filename = core.normalize_to_working_dir(filename)
  end
  doc():save(filename)
  local saved_filename = doc().filename
  core.on_doc_save(saved_filename)
  core.log("Saved \"%s\"", saved_filename)
end

-- returns the size of the original indent, and the indent
-- in your config format, rounded either up or down
local function get_line_indent(line, rnd_up)
  local _, e = line:find("^[ \t]+")
  local soft_tab = string.rep(" ", config.indent_size)
  if config.tab_type == "hard" then
    local indent = e and line:sub(1, e):gsub(soft_tab, "\t") or ""
    return e, indent:gsub(" +", rnd_up and "\t" or "")
  else
    local indent = e and line:sub(1, e):gsub("\t", soft_tab) or ""
    local number = #indent / #soft_tab
    return e, indent:sub(1,
      (rnd_up and math.ceil(number) or math.floor(number))*#soft_tab)
  end
end

-- un/indents text; behaviour varies based on selection and un/indent.
-- * if there's a selection, it will stay static around the
--   text for both indenting and unindenting.
-- * if you are in the beginning whitespace of a line, and are indenting, the
--   cursor will insert the exactly appropriate amount of spaces, and jump the
--   cursor to the beginning of first non whitespace characters
-- * if you are not in the beginning whitespace of a line, and you indent, it
--   inserts the appropriate whitespace, as if you typed them normally.
-- * if you are unindenting, the cursor will jump to the start of the line,
--   and remove the appropriate amount of spaces (or a tab).
local function indent_text(unindent)
  local text = get_indent_string()
  local line1, col1, line2, col2, swap = doc_multiline_selection(true)
  local _, se = doc().lines[line1]:find("^[ \t]+")
  local in_beginning_whitespace = col1 == 1 or (se and col1 <= se + 1)
  if unindent or doc():has_selection() or in_beginning_whitespace then
    local l1d, l2d = #doc().lines[line1], #doc().lines[line2]
    for line = line1, line2 do
      local e, rnded = get_line_indent(doc().lines[line], unindent)
      doc():remove(line, 1, line, (e or 0) + 1)
      doc():insert(line, 1,
        unindent and rnded:sub(1, #rnded - #text) or rnded .. text)
    end
    l1d, l2d = #doc().lines[line1] - l1d, #doc().lines[line2] - l2d
    if (unindent or in_beginning_whitespace) and not doc():has_selection() then
      local start_cursor = (se and se + 1 or 1) + l1d or #(doc().lines[line1])
      doc():set_selection(line1, start_cursor, line2, start_cursor, swap)
    else
      doc():set_selection(line1, col1 + l1d, line2, col2 + l2d, swap)
    end
  else
    doc():text_input(text)
  end
end

local commands = {
  ["doc:undo"] = function()
    doc():undo()
  end,

  ["doc:redo"] = function()
    doc():redo()
  end,

  ["doc:cut"] = function()
    if doc():has_selection() then
      local text = doc():get_text(doc():get_selection())
      system.set_clipboard(text)
      doc():delete_to(0)
    end
  end,

  ["doc:copy"] = function()
    if doc():has_selection() then
      local text = doc():get_text(doc():get_selection())
      system.set_clipboard(text)
    end
  end,

  ["doc:paste"] = function()
    doc():text_input(system.get_clipboard():gsub("\r", ""))
  end,

  ["doc:newline"] = function()
    local line, col = doc():get_selection()
    local indent = doc().lines[line]:match("^[\t ]*")
    if col <= #indent then
      indent = indent:sub(#indent + 2 - col)
    end
    doc():text_input("\n" .. indent)
  end,

  ["doc:newline-below"] = function()
    local line = doc():get_selection()
    local indent = doc().lines[line]:match("^[\t ]*")
    doc():insert(line, math.huge, "\n" .. indent)
    doc():set_selection(line + 1, math.huge)
  end,

  ["doc:newline-above"] = function()
    local line = doc():get_selection()
    local indent = doc().lines[line]:match("^[\t ]*")
    doc():insert(line, 1, indent .. "\n")
    doc():set_selection(line, math.huge)
  end,

  ["doc:delete"] = function()
    local line, col = doc():get_selection()
    if not doc():has_selection() and doc().lines[line]:find("^%s*$", col) then
      doc():remove(line, col, line, math.huge)
    end
    doc():delete_to(translate.next_char)
  end,

  ["doc:backspace"] = function()
    local line, col = doc():get_selection()
    if not doc():has_selection() then
      local text = doc():get_text(line, 1, line, col)
      if #text >= config.indent_size and text:find("^ *$") then
        doc():delete_to(0, -config.indent_size)
        return
      end
    end
    doc():delete_to(translate.previous_char)
  end,

  ["doc:select-all"] = function()
    doc():set_selection(1, 1, math.huge, math.huge)
  end,

  ["doc:select-none"] = function()
    local line, col = doc():get_selection()
    doc():set_selection(line, col)
  end,

  ["doc:select-lines"] = function()
    local line1, _, line2, _, swap = doc():get_selection(true)
    append_line_if_last_line(line2)
    doc():set_selection(line1, 1, line2 + 1, 1, swap)
  end,

  ["doc:select-word"] = function()
    local line1, col1 = doc():get_selection(true)
    local line1, col1 = translate.start_of_word(doc(), line1, col1)
    local line2, col2 = translate.end_of_word(doc(), line1, col1)
    doc():set_selection(line2, col2, line1, col1)
  end,

  ["doc:join-lines"] = function()
    local line1, _, line2 = doc():get_selection(true)
    if line1 == line2 then line2 = line2 + 1 end
    local text = doc():get_text(line1, 1, line2, math.huge)
    text = text:gsub("(.-)\n[\t ]*", function(x)
      return x:find("^%s*$") and x or x .. " "
    end)
    doc():insert(line1, 1, text)
    doc():remove(line1, #text + 1, line2, math.huge)
    if doc():has_selection() then
      doc():set_selection(line1, math.huge)
    end
  end,

  ["doc:indent"] = function()
    indent_text()
  end,

  ["doc:unindent"] = function()
    indent_text(true)
  end,

  ["doc:duplicate-lines"] = function()
    local line1, col1, line2, col2, swap = doc_multiline_selection(true)
    append_line_if_last_line(line2)
    local text = doc():get_text(line1, 1, line2 + 1, 1)
    doc():insert(line2 + 1, 1, text)
    local n = line2 - line1 + 1
    doc():set_selection(line1 + n, col1, line2 + n, col2, swap)
  end,

  ["doc:delete-lines"] = function()
    local line1, col1, line2 = doc_multiline_selection(true)
    append_line_if_last_line(line2)
    doc():remove(line1, 1, line2 + 1, 1)
    doc():set_selection(line1, col1)
  end,

  ["doc:move-lines-up"] = function()
    local line1, col1, line2, col2, swap = doc_multiline_selection(true)
    append_line_if_last_line(line2)
    if line1 > 1 then
      local text = doc().lines[line1 - 1]
      doc():insert(line2 + 1, 1, text)
      doc():remove(line1 - 1, 1, line1, 1)
      doc():set_selection(line1 - 1, col1, line2 - 1, col2, swap)
    end
  end,

  ["doc:move-lines-down"] = function()
    local line1, col1, line2, col2, swap = doc_multiline_selection(true)
    append_line_if_last_line(line2 + 1)
    if line2 < #doc().lines then
      local text = doc().lines[line2 + 1]
      doc():remove(line2 + 1, 1, line2 + 2, 1)
      doc():insert(line1, 1, text)
      doc():set_selection(line1 + 1, col1, line2 + 1, col2, swap)
    end
  end,

  ["doc:toggle-line-comments"] = function()
    local comment = doc().syntax.comment
    if not comment then return end
    local indentation = get_indent_string()
    local comment_text = comment .. " "
    local line1, _, line2 = doc_multiline_selection(true)
    local uncomment = true
    local start_offset = math.huge
    for line = line1, line2 do
      local text = doc().lines[line]
      local s = text:find("%S")
      local cs, ce = text:find(comment_text, s, true)
      if s and cs ~= s then
        uncomment = false
        start_offset = math.min(start_offset, s)
      end
    end
    for line = line1, line2 do
      local text = doc().lines[line]
      local s = text:find("%S")
      if uncomment then
        local cs, ce = text:find(comment_text, s, true)
        if ce then
          doc():remove(line, cs, line, ce + 1)
        end
      elseif s then
        doc():insert(line, start_offset, comment_text)
      end
    end
  end,

  ["doc:upper-case"] = function()
    doc():replace(string.upper)
  end,

  ["doc:lower-case"] = function()
    doc():replace(string.lower)
  end,

  ["doc:go-to-line"] = function()
    local dv = dv()

    local items
    local function init_items()
      if items then return end
      items = {}
      local mt = { __tostring = function(x) return x.text end }
      for i, line in ipairs(dv.doc.lines) do
        local item = { text = line:sub(1, -2), line = i, info = "line: " .. i }
        table.insert(items, setmetatable(item, mt))
      end
    end

    core.command_view:enter("Go To Line", function(text, item)
      local line = item and item.line or tonumber(text)
      if not line then
        core.error("Invalid line number or unmatched string")
        return
      end
      dv.doc:set_selection(line, 1  )
      dv:scroll_to_line(line, true)

    end, function(text)
      if not text:find("^%d*$") then
        init_items()
        return common.fuzzy_match(items, text)
      end
    end)
  end,

  ["doc:toggle-line-ending"] = function()
    doc().crlf = not doc().crlf
  end,

  ["doc:save-as"] = function()
    local last_doc = core.last_active_view and core.last_active_view.doc
    if doc().filename then
      core.command_view:set_text(doc().filename)
    elseif last_doc and last_doc.filename then
      local dirname, filename = core.last_active_view.doc.abs_filename:match("(.*)[/\\](.+)$")
      core.command_view:set_text(core.normalize_to_project_dir(dirname) .. PATHSEP)
    end
    core.command_view:enter("Save As", function(filename)
      save(common.home_expand(filename))
    end, function (text)
      return common.home_encode_list(common.path_suggest(common.home_expand(text)))
    end)
  end,

  ["doc:save"] = function()
    if doc().filename then
      save()
    else
      command.perform("doc:save-as")
    end
  end,

  ["doc:rename"] = function()
    local old_filename = doc().filename
    if not old_filename then
      core.error("Cannot rename unsaved doc")
      return
    end
    core.command_view:set_text(old_filename)
    core.command_view:enter("Rename", function(filename)
      save(common.home_expand(filename))
      core.log("Renamed \"%s\" to \"%s\"", old_filename, filename)
      if filename ~= old_filename then
        os.remove(old_filename)
      end
    end, function (text)
      return common.home_encode_list(common.path_suggest(common.home_expand(text)))
    end)
  end,
}


local translations = {
  ["previous-char"] = translate.previous_char,
  ["next-char"] = translate.next_char,
  ["previous-word-start"] = translate.previous_word_start,
  ["next-word-end"] = translate.next_word_end,
  ["previous-block-start"] = translate.previous_block_start,
  ["next-block-end"] = translate.next_block_end,
  ["start-of-doc"] = translate.start_of_doc,
  ["end-of-doc"] = translate.end_of_doc,
  ["start-of-line"] = translate.start_of_line,
  ["end-of-line"] = translate.end_of_line,
  ["start-of-word"] = translate.start_of_word,
  ["end-of-word"] = translate.end_of_word,
  ["previous-line"] = DocView.translate.previous_line,
  ["next-line"] = DocView.translate.next_line,
  ["previous-page"] = DocView.translate.previous_page,
  ["next-page"] = DocView.translate.next_page,
}

for name, fn in pairs(translations) do
  commands["doc:move-to-" .. name] = function() doc():move_to(fn, dv()) end
  commands["doc:select-to-" .. name] = function() doc():select_to(fn, dv()) end
  commands["doc:delete-to-" .. name] = function() doc():delete_to(fn, dv()) end
end

commands["doc:move-to-previous-char"] = function()
  if doc():has_selection() then
    local line, col = doc():get_selection(true)
    doc():set_selection(line, col)
  else
    doc():move_to(translate.previous_char)
  end
end

commands["doc:move-to-next-char"] = function()
  if doc():has_selection() then
    local _, _, line, col = doc():get_selection(true)
    doc():set_selection(line, col)
  else
    doc():move_to(translate.next_char)
  end
end

command.add("core.docview", commands)
