--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
YAML for a dump's records, as `jess save dump` wrote it (jess's `plugin/display.rs`): a list
under one key, written for reading. Lists of scalars are inline (`position: [1.5, 2.0, 3.25]`),
text with line breaks is a literal block, strings are quoted only when a YAML reader could take
them for something else, and floats are spelled in the fewest digits that read back as the same
value. Every other report is serde_yaml's layout, which `@vfs/serialize` writes; a dump's isn't.

Values are `@vfs/serialize`'s model: its ordered maps, arrays, and floats.
]]

local serialize = require '@vfs/serialize'

type Value = serialize.Value

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
local function quote(text: string): string
  if isPlainSafe(text) then return text end

  -- YAML 1.1 readers take these for booleans and null, so they are quoted though 1.2 wouldn't.
  if Reserved[string.lower(text)] then return `'{text}'` end

  local quoted = string.gsub(serialize.encode(text, 'yaml'), '%s+$', '')
  local first = string.sub(quoted, 1, 1)
  -- serde_yaml's plain scalars are for block context; in an inline list a flow indicator would
  -- end one early.
  if first ~= '\'' and first ~= '"' and string.find(text, '[,%[%]{}]') then
    return `'{string.gsub(text, '\'', '\'\'')}'`
  end

  return quoted
end

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

local function keyText(key: string): string return if isNumber(key) then key else quote(key) end

local function numberOf(value: Value): number
  if type(value) == 'number' then return value end

  return (value :: { value: number }).value
end

local inline: (value: Value) -> string

local function scalar(value: Value, kind: string): string
  if kind == 'null' or kind == 'none' then return 'null' end

  if kind == 'boolean' then return if value then 'true' else 'false' end

  if kind == 'int' then
    return if typeof(value) == 'integer' then tostring(value) else string.format('%.0f', value :: number)
  end

  if kind == 'float' then return floatText(numberOf(value)) end

  return quote(value :: string)
end

--- A value on one line.
inline = function(value: Value): string
  local kind = serialize.kindOf(value)
  if kind == 'array' then
    local items = {}
    for position, item in value :: { Value } do
      items[position] = inline(item)
    end

    return `[{table.concat(items, ', ')}]`
  end

  if kind == 'map' then
    local map = value :: serialize.Map
    local entries = {}
    for position, key in map.keys do
      entries[position] = `{keyText(key)}: {inline(map.values[key])}`
    end

    return `\{{table.concat(entries, ', ')}}`
  end

  return scalar(value, kind)
end

--- Whether a list goes on one line: scalars only, none with a line break, and short enough
--- unless they are all numbers.
local function isInlineSequence(items: { Value }): boolean
  local numbers = true
  for _, item in items do
    local kind = serialize.kindOf(item)
    if kind == 'array' or kind == 'map' or kind == 'variant' then return false end

    if kind == 'string' and string.find(item :: string, '\n', 1, true) then return false end

    if kind ~= 'int' and kind ~= 'float' then numbers = false end
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

local function isMultiline(value: Value, kind: string): boolean
  return kind == 'string' and string.find(value :: string, '\n', 1, true) ~= nil
end

local writeSequenceItem: (out: { string }, value: Value, indent: number) -> ()

--- A mapping's fields, one to a line, indented by `indent`; the first line starts with `lead`
--- in place of its indent (the `- ` of the list item the mapping is).
local function writeMapping(out: { string }, map: serialize.Map, indent: number, lead: string?)
  local pad = string.rep(' ', indent)
  for position, key in map.keys do
    local value = map.values[key]
    local kind = serialize.kindOf(value)
    table.insert(out, if position == 1 and lead then lead else pad)
    table.insert(out, keyText(key))
    table.insert(out, ':')
    if kind == 'map' and #(value :: serialize.Map).keys > 0 then
      table.insert(out, '\n')
      writeMapping(out, value :: serialize.Map, indent + 2)
    elseif kind == 'array' and not isInlineSequence(value :: { Value }) then
      table.insert(out, '\n')
      for _, item in value :: { Value } do
        writeSequenceItem(out, item, indent)
      end
    elseif isMultiline(value, kind) then
      table.insert(out, ' ')
      writeBlockScalar(out, value :: string, indent + 2)
    else
      table.insert(out, ' ')
      table.insert(out, inline(value))
      table.insert(out, '\n')
    end
  end
end

writeSequenceItem = function(out: { string }, value: Value, indent: number)
  local pad = string.rep(' ', indent)
  local kind = serialize.kindOf(value)
  if kind == 'map' and #(value :: serialize.Map).keys > 0 then
    writeMapping(out, value :: serialize.Map, indent + 2, pad .. '- ')
  elseif kind == 'array' and not isInlineSequence(value :: { Value }) then
    table.insert(out, pad .. '-\n')
    for _, item in value :: { Value } do
      writeSequenceItem(out, item, indent + 2)
    end
  elseif isMultiline(value, kind) then
    table.insert(out, pad .. '- ')
    writeBlockScalar(out, value :: string, indent + 2)
  else
    table.insert(out, `{pad}- {inline(value)}\n`)
  end
end

--- `items` as the items of a list at the top of a document, one after another.
local function items(items: { Value }): string
  local out: { string } = {}
  for _, item in items do
    writeSequenceItem(out, item, 0)
  end

  return table.concat(out)
end

--- A document with one list under `key`: `key:` and an item for each of `values`, or `key: []`.
local function list(key: string, values: { Value }): string
  if #values == 0 then return `{key}: []\n` end

  return `{key}:\n{items(values)}`
end

return table.freeze { floatText = floatText, items = items, list = list, quote = quote }
