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
Filtering itself is done client side by finder.js.
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

local function build_filters(groups, doc_dir)
  local blocks = { raw('<form class="finder-filters" aria-label="Filters">') }
  for _, g in ipairs(groups) do
    local fieldset = string.format(
      '<fieldset class="finder-group" data-key="%s" data-type="%s"><legend>%s</legend>',
      html_escape(g.key), html_escape(g.type), html_escape(g.title))
    table.insert(blocks, raw(fieldset))

    if g.description then
      local file = resolve(g.description, doc_dir)
      local desc = read_markdown(file)
      if desc then
        table.insert(blocks, raw('<details class="finder-info"><summary>More information</summary>'))
        for _, b in ipairs(desc) do table.insert(blocks, b) end
        table.insert(blocks, raw('</details>'))
      else
        warn("description file not found: " .. file)
      end
    end

    local input_type = g.type == "multi" and "checkbox" or "radio"
    for _, opt in ipairs(g.options) do
      local id = "finder-" .. g.key .. "-" .. opt.key
      table.insert(blocks, raw(string.format(
        '<div class="finder-option"><input type="%s" name="%s" value="%s" id="%s">'
          .. '<label for="%s">%s</label></div>',
        input_type, html_escape(g.key), html_escape(opt.key), html_escape(id),
        html_escape(id), html_escape(opt.label))))
    end
    table.insert(blocks, raw('</fieldset>'))
  end
  table.insert(blocks, raw(
    '<button type="reset" class="btn btn-outline-secondary btn-sm">Reset filters</button></form>'))
  return blocks
end

local function build_tile(id, spec, groups_by_key, doc_dir)
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

  local body = {}
  if meta.title then
    table.insert(body, pandoc.Header(3, meta.title, { class = "card-title unnumbered unlisted" }))
  end
  -- Everything from the first `.description` div onwards is collapsed
  -- behind a "Description" link.
  local collapsed = nil
  for _, b in ipairs(content) do
    if not collapsed and b.t == "Div" and b.classes:includes("description") then
      collapsed = {}
      for _, inner in ipairs(b.content) do table.insert(collapsed, inner) end
    elseif collapsed then
      table.insert(collapsed, b)
    else
      table.insert(body, b)
    end
  end
  if collapsed then
    table.insert(body, raw('<details class="finder-description"><summary>Read more</summary>'))
    for _, b in ipairs(collapsed) do table.insert(body, b) end
    table.insert(body, raw('</details>'))
  end

  return pandoc.Div(
    pandoc.Div(body, { class = "card-body" }),
    pandoc.Attr("", { "finder-tile", "card", "g-col-12", "g-col-md-6" },
      { ["data-filter"] = pandoc.json.encode(match) }))
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
    table.insert(tiles, build_tile(kv.key, as_map(kv.value), groups_by_key, doc_dir))
  end

  local filters = pandoc.Div(build_filters(groups, doc_dir),
    { class = "finder-sidebar g-col-12 g-col-lg-3" })
  local results = pandoc.Div({
    raw('<p class="finder-count" aria-live="polite"></p>'),
    pandoc.Div(tiles, { class = "finder-tiles grid" }),
  }, { class = "finder-results g-col-12 g-col-lg-9" })

  -- Keep any content written inside the div above the finder.
  local out = {}
  for _, b in ipairs(div.content) do table.insert(out, b) end
  table.insert(out, pandoc.Div({ filters, results }, { class = "finder grid" }))
  return out
end
