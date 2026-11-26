--[[
finder.lua – build an interactive "finder" from a YAML data model.

Usage in a .qmd page:

    ---
    filters:
      - finder
    ---

    ::: {.finder data="data.yml"}
    :::

The data file defines `filter` (the filter groups shown on the left) and
`blocks` (the tiles shown on the right). Paths starting with "/" are resolved
against the project root, other paths against the directory of the page.
The HTML layout comes from the pandoc templates in templates/ (see
https://pandoc.org/MANUAL.html#template-syntax). Filtering itself is done
client side by finder.js.
]]

local path = pandoc.path
local stringify = pandoc.utils.stringify

local function warn(msg)
  quarto.log.warning("[finder] " .. msg)
end

local function html_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function raw(s) return pandoc.RawBlock("html", s) end

-- The data model uses lists of single-key maps to keep order:
--   - vol: [...]
--   - class: [...]
-- Return them as an ordered list of {key=..., value=...}.
local function ordered(list)
  local out = {}
  for _, item in ipairs(list or {}) do
    for k, v in pairs(item) do
      table.insert(out, { key = k, value = v })
    end
  end
  return out
end

-- Turn a list of single-key maps into a plain lookup table.
local function as_map(list)
  local out = {}
  for _, kv in ipairs(ordered(list)) do out[kv.key] = kv.value end
  return out
end

local function resolve(p, doc_dir)
  if p:sub(1, 1) == "/" then
    return path.join({ quarto.project.directory or doc_dir, p:sub(2) })
  end
  return path.join({ doc_dir, p })
end

local function read_file(file)
  local fh = io.open(file, "r")
  if not fh then return nil end
  local text = fh:read("*a")
  fh:close()
  return text
end

-- Read a markdown/qmd file; returns its blocks and metadata.
local function read_markdown(file)
  local text = read_file(file)
  if not text then return nil end
  local doc = pandoc.read(text, "markdown", PANDOC_READER_OPTIONS)
  return doc.blocks, doc.meta
end

-- Content blocks (tile bodies, filter descriptions) stay pandoc AST so that
-- Quarto still processes them. The templates get a marker for each, which is
-- swapped for the real blocks after rendering.
local slots = {}
local function slot(blocks)
  table.insert(slots, blocks)
  return string.format("<!--finder-slot-%d-->", #slots)
end

local function render_template(dir, name, context)
  local file = path.join({ dir, name })
  local text = read_file(file)
  if not text then
    error("[finder] template not found: " .. file)
  end
  local tpl = pandoc.template.compile(text, file)
  local html = pandoc.layout.render(pandoc.template.apply(tpl, context))

  -- Split the rendered HTML at the slot markers.
  local out, pos = {}, 1
  local function add_raw(s)
    if s:match("%S") then table.insert(out, raw(s)) end
  end
  while true do
    local s, e, n = html:find("<!%-%-finder%-slot%-(%d+)%-%->", pos)
    if not s then break end
    add_raw(html:sub(pos, s - 1))
    for _, b in ipairs(slots[tonumber(n)]) do table.insert(out, b) end
    pos = e + 1
  end
  add_raw(html:sub(pos))
  return out
end

local function group_context(g, doc_dir)
  local ctx = {
    key = html_escape(g.key),
    type = html_escape(g.type),
    title = html_escape(g.title),
    options = {},
  }
  if g.description then
    local file = resolve(g.description, doc_dir)
    local desc = read_markdown(file)
    if desc then
      ctx.description = slot(desc)
    else
      warn("description file not found: " .. file)
    end
  end
  local input_type = g.type == "multi" and "checkbox" or "radio"
  for _, opt in ipairs(g.options) do
    table.insert(ctx.options, {
      input_type = input_type,
      name = html_escape(g.key),
      value = html_escape(opt.key),
      id = html_escape("finder-" .. g.key .. "-" .. opt.key),
      label = html_escape(opt.label),
    })
  end
  return ctx
end

local function tile_context(id, spec, groups_by_key, doc_dir)
  -- Collect and validate the filter values of this tile.
  local match = {}
  for _, kv in ipairs(ordered(spec.filter)) do
    local group = groups_by_key[kv.key]
    local values = {}
    for _, v in ipairs(kv.value) do
      local s = stringify(v)
      if group and not group.option_keys[s] then
        warn(string.format("block %s: unknown option '%s' for filter '%s'", id, s, kv.key))
      end
      table.insert(values, s)
    end
    if not group then
      warn(string.format("block %s: unknown filter '%s'", id, kv.key))
    end
    match[kv.key] = values
  end

  local content, meta = {}, {}
  if spec.contents then
    local file = resolve(stringify(spec.contents), doc_dir)
    local b, m = read_markdown(file)
    if b then
      content, meta = b, m
    else
      warn("contents file not found: " .. file)
    end
  end

  -- Everything from the first `.description` div onwards goes in `details`,
  -- which the template shows behind a "Read more" link.
  local intro, details = {}, nil
  for _, b in ipairs(content) do
    if not details and b.t == "Div" and b.classes:includes("description") then
      details = {}
      for _, inner in ipairs(b.content) do table.insert(details, inner) end
    elseif details then
      table.insert(details, b)
    else
      table.insert(intro, b)
    end
  end

  return {
    id = html_escape(id),
    title = meta.title and html_escape(stringify(meta.title)) or nil,
    filter = html_escape(pandoc.json.encode(match)),
    intro = slot(intro),
    details = details and slot(details) or nil,
  }
end

function Div(div)
  if not div.classes:includes("finder") then return nil end

  local doc_dir = path.directory(quarto.doc.input_file)
  local data_file = resolve(div.attributes["data"] or "data.yml", doc_dir)
  local yaml = read_file(data_file)
  if not yaml then
    warn("data file not found: " .. data_file)
    return nil
  end
  -- Pandoc parses YAML string values as markdown. Escape a leading block
  -- marker in double-quoted values so labels like ">500GB" survive.
  yaml = yaml:gsub('(:%s*)"([>#%-%+%*|])', '%1"\\\\%2')
  local data = pandoc.read("---\n" .. yaml .. "\n---\n", "markdown").meta

  quarto.doc.add_html_dependency({
    name = "finder",
    version = "0.1.0",
    scripts = { "finder.js" },
    stylesheets = { "finder.css" },
  })

  -- Normalise filter groups.
  local groups, groups_by_key = {}, {}
  for _, kv in ipairs(ordered(data.filter)) do
    local props = as_map(kv.value)
    local g = {
      key = kv.key,
      title = props.title and stringify(props.title) or kv.key,
      type = props.type and stringify(props.type) or "single",
      description = props.description and stringify(props.description) or nil,
      options = {},
      option_keys = {},
    }
    for _, o in ipairs(ordered(props.options)) do
      table.insert(g.options, { key = o.key, label = stringify(o.value) })
      g.option_keys[o.key] = true
    end
    table.insert(groups, g)
    groups_by_key[g.key] = g
  end

  local tiles = {}
  for _, kv in ipairs(ordered(data.blocks)) do
    table.insert(tiles, tile_context(kv.key, as_map(kv.value), groups_by_key, doc_dir))
  end
  local group_ctx = {}
  for _, g in ipairs(groups) do table.insert(group_ctx, group_context(g, doc_dir)) end

  -- Templates live next to this filter, unless the page points elsewhere
  -- with `templates="dir"` (which must contain finder.html, group.html and
  -- tile.html).
  local template_dir = div.attributes["templates"]
    and resolve(div.attributes["templates"], doc_dir)
    or path.join({ path.directory(PANDOC_SCRIPT_FILE), "templates" })

  -- Keep any content written inside the div above the finder.
  local out = {}
  for _, b in ipairs(div.content) do table.insert(out, b) end
  for _, b in ipairs(render_template(template_dir, "finder.html",
      { groups = group_ctx, tiles = tiles })) do
    table.insert(out, b)
  end
  return out
end
