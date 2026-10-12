--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A dump's records as text: YAML as `jess save dump` wrote it (jess's `plugin/display.rs`), written
for reading, and JSON as serde_json wrote it. In the YAML, lists of scalars are inline
(`position: [1.5, 2.0, 3.25]`), text with line breaks is a literal block, strings are quoted only
when a YAML reader could take them for something else, and floats are spelled in the fewest
digits that read back as the same value.

A dump is the one document that is as big as the save it describes, and one cell's record can be
a quarter of the save, so a record's text is written straight from its tree (`@tes3-saves`'s
`tree`), piece by piece into a list the caller joins: nothing is built in between.
]]

local Values = require './values'
local data = require '@jess/data/value'

type Node = Values.Node
type Fields = Values.Fields

--- Words YAML readers may resolve to non-strings when left unquoted.
local ReservedList = {
  'true',
  'false',
  'null',
  'yes',
  'no',
  'on',
  'off',
  'y',
  'n',
  'nan',
  'inf',
  '~',
  '=',
  '<<',
}

local Reserved: { [string]: boolean } = {}
for _, word in ReservedList do
  Reserved[word] = true
end

--- Scalar lists longer than this are block lists instead of inline.
local MaxInlineWidth = 100

--- How many spellings are kept at once, and the longest text one is kept for.
local KeptSpellings, KeptLength = 4096, 64

--- `spell` with its answers kept. A dump spells the same keys, tags, types, and ids for every
--- record and subrecord it writes, and working one out costs far more than looking it up. What
--- is kept is bounded: short texts only, and when there are `KeptSpellings` of them they are let
--- go and kept afresh, since what a dump repeats changes as it moves through a save.
local function remembering(spell: (text: string) -> string): (text: string) -> string
  local kept: { [string]: string } = {}
  local count = 0
  return function(text: string): string
    local known = kept[text]
    if known then return known end

    local spelled = spell(text)
    if #text > KeptLength then return spelled end

    if count == KeptSpellings then
      table.clear(kept)
      count = 0
    end

    count += 1
    kept[text] = spelled
    return spelled
  end
end

--- A record field's name as jess's files spell it. `@tes3` names a typed record's fields
--- camelCase from jess-omwaddon's snake_case ones, which are lowercase words and digits between
--- underscores, so each capital is where an underscore was. That holds for field names and for
--- nothing else: a code is never read back this way.
local fieldName = remembering(function(name: string): string
  return (
    string.gsub(name, '%u', function(letter: string): string return '_' .. string.lower(letter) end)
  )
end)

--[[ Numbers ]]

local Scratch = buffer.create(4)

local function single(value: number): number
  buffer.writef32(Scratch, 0, value)
  return buffer.readf32(Scratch, 0)
end

--- The fewest decimal digits that read back as `magnitude` (as an f32 when `narrow`), without a
--- point, and the decimal exponent of the first one.
local function shortest(magnitude: number, narrow: boolean): (string, number)
  for precision = 1, 17 do
    local text = string.format(`%.{precision - 1}e`, magnitude)
    local back = tonumber(text) :: number
    if (if narrow then single(back) else back) ~= magnitude then continue end

    local mantissa, exponent = string.match(text, '^(%d[%.%d]*)e([%+%-]%d+)$')
    local digits = string.gsub(mantissa :: string, '%.', '')
    digits = string.gsub(digits, '0+$', '')
    return if digits == '' then '0' else digits, tonumber(exponent) :: number
  end

  return string.format('%.17g', magnitude), 0
end

--- A float in its shortest spelling that reads back exactly, always with a decimal point, in
--- scientific notation outside 1e-4 to 1e16 (jess-omwaddon's `float_text`). A value that is
--- exactly an f32, as every float a save stores is, is spelled as that f32: `0.1`, not
--- `0.10000000149011612`.
local function floatText(value: number): string
  if value ~= value then return '.nan' end

  if value == math.huge then return '.inf' end

  if value == -math.huge then return '-.inf' end

  local sign = if value < 0 or (value == 0 and 1 / value < 0) then '-' else ''
  if value == 0 then return sign .. '0.0' end

  local magnitude = math.abs(value)
  local digits, exponent = shortest(magnitude, single(magnitude) == magnitude)
  if magnitude < 1e-4 or magnitude >= 1e16 then
    local rest = string.sub(digits, 2)
    return `{sign}{string.sub(digits, 1, 1)}.{if rest == '' then '0' else rest}e{exponent}`
  end

  if exponent < 0 then return `{sign}0.{string.rep('0', -exponent - 1)}{digits}` end

  if #digits <= exponent + 1 then
    return `{sign}{digits}{string.rep('0', exponent + 1 - #digits)}.0`
  end

  return `{sign}{string.sub(digits, 1, exponent + 1)}.{string.sub(digits, exponent + 2)}`
end

--[[ Scalars ]]

local function isPlainSafe(text: string): boolean
  return string.find(text, '^%a') ~= nil
    and string.sub(text, -1) ~= ' '
    and not string.find(text, '[^%w _%.%-/\\]')
    and not Reserved[string.lower(text)]
end

--- A string as a YAML scalar: plain when it can only be read as itself, quoted otherwise.
local quote = remembering(function(text: string): string
  if isPlainSafe(text) then return text end

  -- YAML 1.1 readers take these for booleans and null, so they are quoted though 1.2 wouldn't.
  if Reserved[string.lower(text)] then return `'{text}'` end

  local quoted = string.gsub(data.encode(text, 'yaml'), '%s+$', '')
  local first = string.sub(quoted, 1, 1)
  -- serde_yaml's plain scalars are for block context; in an inline list a flow indicator would
  -- end one early.
  if first ~= '\'' and first ~= '"' and string.find(text, '[,%[%]{}]') then
    return `'{string.gsub(text, '\'', '\'\'')}'`
  end

  return quoted
end)

--- Whether Rust reads `key` as a finite float: a mapping key that is a number (a Lua table's
--- index) reads better unquoted.
local function isNumber(key: string): boolean
  local digits = string.match(key, '^[%+%-]?(.*)$') :: string
  local mantissa = string.match(digits, '^(.-)[eE][%+%-]?%d+$') or digits
  if not (string.find(mantissa, '^%d+%.?%d*$') or string.find(mantissa, '^%.%d+$')) then
    return false
  end

  local value = tonumber((string.gsub(key, '^%+', '')))
  return value ~= nil and value == value and math.abs(value) ~= math.huge
end

local keyText = remembering(
  function(key: string): string return if isNumber(key) then key else quote(key) end
)

--- The name the fields `node` have their value at `position` under, as a dump spells it: the
--- save's own, or a field's name in snake_case.
local function keyAt(node: Fields, position: number): string
  local key = node.keys[position]
  return if node.verbatim then key else fieldName(key)
end

local function isWhole(value: number): boolean
  return value == math.floor(value) and math.abs(value) < 2 ^ 53
end

--- Whether a node is a list or fields, or else a scalar.
local function isCollection(node: Node): boolean
  return type(node) == 'table' and (node.kind == 'list' or node.kind == 'map')
end

local function isMultiline(node: Node): boolean
  return type(node) == 'string' and string.find(node, '\n', 1, true) ~= nil
end

--[[ YAML ]]

local inline: (node: Node) -> string

--- A value on one line.
inline = function(node: Node): string
  if type(node) == 'string' then return quote(node) end

  if type(node) == 'boolean' then return if node then 'true' else 'false' end

  if type(node) == 'number' then
    return if isWhole(node) then string.format('%.0f', node) else floatText(node)
  end

  if node.kind == 'null' then return 'null' end

  if node.kind == 'float' then return floatText(node.value) end

  if node.kind == 'list' then
    local items = {}
    for position, item in node.items do
      items[position] = inline(item)
    end

    return `[{table.concat(items, ', ')}]`
  end

  local entries = {}
  for position, value in node.values do
    entries[position] = `{keyText(keyAt(node, position))}: {inline(value)}`
  end

  return `\{{table.concat(entries, ', ')}}`
end

--- Whether a list goes on one line: scalars only, none with a line break, and short enough
--- unless they are all numbers.
local function isInlineSequence(items: { Node }): boolean
  local numbers = true
  for _, item in items do
    if isCollection(item) or isMultiline(item) then return false end

    if type(item) ~= 'number' and not (type(item) == 'table' and item.kind == 'float') then
      numbers = false
    end
  end

  if numbers then return true end

  local width = 0
  for _, item in items do
    width += #inline(item) + 2
  end

  return width <= MaxInlineWidth
end

--- Whether a character of `text` is a control character other than a line break or a tab.
local function hasControl(text: string): boolean
  for _, codepoint in utf8.codes(text) do
    if codepoint == 10 or codepoint == 9 then continue end

    if codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0) then return true end
  end

  return false
end

--- Text with line breaks as a literal block, its CRLF line endings made LF.
local function writeBlockScalar(out: { string }, text: string, indent: number)
  text = string.gsub(text, '\r\n', '\n')
  if not utf8.len(text) or hasControl(text) then
    table.insert(out, quote(text))
    table.insert(out, '\n')
    return
  end

  local body = string.gsub(text, '\n+$', '')
  local trailing = #text - #body
  local chomp = if trailing == 0 then '-' elseif trailing == 1 then '' else '+'
  local indicator = if string.sub(body, 1, 1) == ' ' then '2' else ''
  table.insert(out, `|{indicator}{chomp}\n`)

  local pad = string.rep(' ', indent)
  for _, line in string.split(body, '\n') do
    if line ~= '' then table.insert(out, pad .. line) end

    table.insert(out, '\n')
  end

  for _ = 2, trailing do
    table.insert(out, '\n')
  end
end

--- Whether a node is written under its key or its dash rather than beside it: fields that
--- aren't empty, or a list that doesn't go on one line.
local function isBlock(node: Node): boolean
  if type(node) ~= 'table' then return false end

  if node.kind == 'map' then return #node.keys > 0 end

  return node.kind == 'list' and not isInlineSequence(node.items)
end

local yamlItem: (out: { string }, node: Node, indent: number) -> ()

--- Fields one to a line, indented by `indent`; the first line starts with `lead` in place of
--- its indent (the `- ` of the list item the fields are).
local function yamlFields(out: { string }, node: Fields, indent: number, lead: string?)
  local pad = string.rep(' ', indent)
  for position, value in node.values do
    table.insert(out, if position == 1 and lead then lead else pad)
    table.insert(out, keyText(keyAt(node, position)))
    if not isBlock(value) then
      if isMultiline(value) then
        table.insert(out, ': ')
        writeBlockScalar(out, value :: string, indent + 2)
      else
        table.insert(out, `: {inline(value)}\n`)
      end
    elseif (value :: Fields).kind == 'map' then
      table.insert(out, ':\n')
      yamlFields(out, value :: Fields, indent + 2)
    else
      table.insert(out, ':\n')
      for _, item in (value :: Values.List).items do
        yamlItem(out, item, indent)
      end
    end
  end
end

--- One item of a list, its dash indented by `indent`.
yamlItem = function(out: { string }, node: Node, indent: number)
  local pad = string.rep(' ', indent)
  if not isBlock(node) then
    if isMultiline(node) then
      table.insert(out, pad .. '- ')
      writeBlockScalar(out, node :: string, indent + 2)
    else
      table.insert(out, `{pad}- {inline(node)}\n`)
    end
  elseif (node :: Fields).kind == 'map' then
    yamlFields(out, node :: Fields, indent + 2, pad .. '- ')
  else
    table.insert(out, pad .. '-\n')
    for _, item in (node :: Values.List).items do
      yamlItem(out, item, indent + 2)
    end
  end
end

--[[ JSON ]]

local JsonEscapes: { [string]: string } = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

--- A string as serde_json writes one: `"`, `\`, and control characters escaped, DEL as it is.
local jsonString = remembering(function(text: string): string
  if not string.find(text, '[%c"\\]') then return `"{text}"` end

  return '"'
    .. string.gsub(text, '[%c"\\]', function(character: string): string
      local byte = string.byte(character)
      if byte == 127 then return character end

      return JsonEscapes[character] or string.format('\\u%04x', byte)
    end)
    .. '"'
end)

local jsonValue: (out: { string }, node: Node) -> ()

--- Fields as the members of a JSON object, without its braces, so that a caller can put more
--- after them.
local function jsonFields(out: { string }, node: Fields)
  for position, value in node.values do
    table.insert(out, if position == 1 then '' else ',')
    table.insert(out, jsonString(keyAt(node, position)))
    table.insert(out, ':')
    jsonValue(out, value)
  end
end

--- A value as compact JSON.
jsonValue = function(out: { string }, node: Node)
  if type(node) == 'string' then
    table.insert(out, jsonString(node))
  elseif type(node) == 'boolean' then
    table.insert(out, if node then 'true' else 'false')
  elseif type(node) == 'number' then
    local finite = node == node and math.abs(node) ~= math.huge
    table.insert(
      out,
      if not finite
        then 'null'
        elseif isWhole(node) then string.format('%.0f', node)
        else data.shortest(node, true)
    )
  elseif node.kind == 'null' then
    table.insert(out, 'null')
  elseif node.kind == 'float' then
    table.insert(out, data.shortest(node.value, true))
  elseif node.kind == 'list' then
    table.insert(out, '[')
    for position, item in node.items do
      if position > 1 then table.insert(out, ',') end

      jsonValue(out, item)
    end

    table.insert(out, ']')
  else
    table.insert(out, '{')
    jsonFields(out, node)
    table.insert(out, '}')
  end
end

return table.freeze {
  fieldName = fieldName,
  floatText = floatText,
  jsonFields = jsonFields,
  jsonValue = jsonValue,
  quote = quote,
  yamlFields = yamlFields,
  yamlItem = yamlItem,
}
