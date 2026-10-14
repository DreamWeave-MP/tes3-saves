--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Readable values for a save's records (jess-save's `SaveValues`, what `jess save dump` prints).
The SAVE header and dynamic records (player-made spells, the player's NPC_, ...) decode to typed
values. Save-only records (PLAY, CSTA, JOUR, ...) have no typed model, so each subrecord gets its
best-known decoding: ids and object references the classifiers understand, LUAD Lua data (its
keys as they are), strings, and numbers, with hex or a byte count for the rest.

A value is built as a tree (`tree`) and handed out as plain tables (`values`). The tree keeps
what a plain table can't: the order fields come in (a record's subrecords, a Lua table's keys as
the save has them), which numbers the save holds as floats, an empty table apart from an empty
list, and the place of a value that is missing.
]]

local Read = require './read'
local Records = require './records'
local Scan = require './scan'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin
type Record = Records.Record
type Save = Read.Save
type LuaValue = tes3.LuaValue

--- A missing value where one has a place: a float that isn't finite, which no format spells.
export type Null = { kind: 'null' }

--- A number the save holds as a float, whole or not.
export type Float = { kind: 'float', value: number }

export type List = { kind: 'list', items: { Node } }

--- Named values in order: `keys[n]` names `values[n]`. `verbatim` keys are the save's own
--- (subrecord tags, a Lua table's keys); the rest are field names, camelCase.
export type Fields = { kind: 'map', keys: { string }, values: { Node }, verbatim: boolean? }

--- A readable value. A plain number is a whole number, or one of a typed record's, which
--- `@tes3` gives without saying whether the record holds it as a float.
export type Node = string | number | boolean | Null | Float | List | Fields

local Null: Null = table.freeze { kind = 'null' :: 'null' }

--- Record types OpenMW writes as dynamic records with the regular content-record layout.
local DynamicTagList = {
  'ALCH',
  'ARMO',
  'BOOK',
  'CLAS',
  'CLOT',
  'ENCH',
  'NPC_',
  'MISC',
  'ACTI',
  'SPEL',
  'WEAP',
  'LEVC',
  'LEVI',
  'CREA',
  'CONT',
  'LIGH',
  'STAT',
  'DOOR',
  'PROB',
  'INGR',
}

local DynamicTags: { [string]: boolean } = {}
for _, tag in DynamicTagList do
  DynamicTags[tag] = true
end

--[[ Trees ]]

local function list(items: { Node }): List return { kind = 'list' :: 'list', items = items } end

--- Fields from `{ key, value }` pairs in order; a pair without a value is left out.
local function fields(pairs: { { unknown } }, verbatim: boolean?): Fields
  local keys: { string }, values: { Node } = {}, {}
  for _, pair in pairs do
    local value = pair[2] :: Node?
    if value == nil then continue end

    table.insert(keys, pair[1] :: string)
    table.insert(values, value)
  end

  return { kind = 'map' :: 'map', keys = keys, values = values, verbatim = verbatim }
end

--- A float of the save; one that isn't finite has no spelling, and is missing.
local function float(value: number): Node
  if value ~= value or value == math.huge or value == -math.huge then return Null end

  return { kind = 'float' :: 'float', value = value }
end

local function floats(numbers: { number }, first: number, last: number): List
  return list([for value in numbers[first:last] => float(value)])
end

--- The fields a typed value starts with, in order; the rest follow by name.
local Leading = { 'record', 'type', 'id', 'name' }

--- A plain value of `@tes3`'s as a tree. Its tables don't say what order their fields come in, so
--- a record's number, type, id, and name go first and the rest by name.
local function fromPlain(value: unknown): Node
  if type(value) ~= 'table' then
    if type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean' then
      return value
    end

    return Null
  end

  local members = value :: { [unknown]: unknown }
  if members[1] ~= nil or next(members) == nil then
    local items: { Node } = {}
    for position, item in members :: { unknown } do
      items[position] = fromPlain(item)
    end

    return list(items)
  end

  local names: { string } = {}
  local byName: { [string]: unknown } = {}
  for key, item in members do
    local name = tostring(key)
    byName[name] = item
    if not table.find(Leading, name) then table.insert(names, name) end
  end

  table.sort(names)
  local keys: { string }, nodes: { Node } = {}, {}
  for _, name in Leading do
    if byName[name] == nil then continue end

    table.insert(keys, name)
    table.insert(nodes, fromPlain(byName[name]))
  end

  for _, name in names do
    table.insert(keys, name)
    table.insert(nodes, fromPlain(byName[name]))
  end

  return { kind = 'map' :: 'map', keys = keys, values = nodes }
end

--- A tree as plain tables: fields by key, lists as arrays, floats as numbers, and a missing value
--- as nil.
local function plain(node: Node): unknown
  if type(node) ~= 'table' then return node end

  if node.kind == 'null' then return nil end

  if node.kind == 'float' then return node.value end

  if node.kind == 'list' then
    local out: { unknown } = {}
    for position, item in node.items do
      out[position] = plain(item)
    end

    return out
  end

  local out: { [string]: unknown } = {}
  for position, key in node.keys do
    out[key] = plain(node.values[position])
  end

  return out
end

--[[ Lua data ]]

--- A number as a key, the way `@tes3`'s display spells one (serde_json's): an exact integer
--- without a fraction, else its shortest digits.
local function numberKey(value: number): string
  if value % 1 == 0 and math.abs(value) <= 2 ^ 53 then return string.format('%d', value) end

  for precision = 1, 17 do
    local text = string.format(`%.{precision}g`, value)
    if tonumber(text) == value then return text end
  end

  return tostring(value)
end

--- Lua has one number type: a whole one reads as a whole number, any other as a float.
local function luaNumber(value: number): Node
  if value % 1 == 0 and math.abs(value) <= 2 ^ 53 then return value end

  return float(value)
end

--- A Lua integer as a whole number where a number holds it exactly, and past that as its digits:
--- a plain number in a tree is a whole number, and nothing else in one can hold 64 bits.
local function luaInteger(value: integer): Node
  local number = integer.tonumber(value)
  if math.abs(number) <= 2 ^ 53 then return number end

  return tostring(value)
end

--- The place in a list a table key names: a number or an integer that is a whole number.
local function listIndex(key: LuaValue): number?
  if key.kind == 'number' then return key.value :: number end

  if key.kind == 'integer' then return integer.tonumber(key.value :: integer) end

  return nil
end

local function refnum(ref: tes3.LuaRef): Fields
  return fields({ { 'index', ref.index }, { 'content_file', ref.contentFile } }, true)
end

local Vectors: { [string]: string } = {
  vec2 = 'vec2',
  vec3 = 'vec3',
  vec4 = 'vec4',
  transformM = 'matrix',
  transformQ = 'quat',
  color = 'color',
}

--- A decoded Lua value as `@tes3`'s display shows one with its keys kept (`display.luaValue`),
--- with what that loses: a table's keys in the order the save has them. Tables keyed 1 to n are
--- lists, other tables fields under text keys, and userdata one field naming its type.
local function luaNode(value: LuaValue): Node
  local kind = value.kind
  if kind == 'nil' then return Null end

  if kind == 'number' then return luaNumber(value.value :: number) end

  if kind == 'integer' then return luaInteger(value.value :: integer) end

  if kind == 'boolean' then return value.value :: boolean end

  if kind == 'string' then return tes3.lossyUtf8(value.value :: string) end

  if kind == 'table' then
    local entries = value.entries or {}
    local isList = #entries > 0
      and all[for position, entry in enumerate(entries) => listIndex(entry.key) == position]
    if isList then return list([for entry in entries => luaNode(entry.value)]) end

    local keys: { string }, nodes: { Node } = {}, {}
    local places: { [string]: number } = {}
    for _, entry in entries do
      local key = entry.key
      local text = if key.kind == 'string'
        then tes3.lossyUtf8(key.value :: string)
        elseif key.kind == 'number' then numberKey(key.value :: number)
        elseif key.kind == 'integer' then tostring(key.value)
        elseif key.kind == 'boolean' then tostring(key.value)
        else key.kind
      -- Two keys that spell alike share the first one's place; the later value is the one kept.
      local place = places[text]
      if not place then
        place = #keys + 1
        places[text] = place
        keys[place] = text
      end

      nodes[place] = luaNode(entry.value)
    end

    return { kind = 'map' :: 'map', keys = keys, values = nodes, verbatim = true }
  end

  if kind == 'object' then
    return fields({ { 'object', refnum(value.ref :: tes3.LuaRef) } }, true)
  end

  if kind == 'objectList' then
    local items: { Node } = [for ref in value.refs or {} => refnum(ref) :: Node]
    return fields({ { 'objlist', list(items) } }, true)
  end

  if kind == 'userdata' then
    return fields({ { value.typeName :: string, `{#(value.data or '')} bytes` } }, true)
  end

  local components = value.values or {}
  return fields({ { Vectors[kind], floats(components, 1, #components) } }, true)
end

--- A LUAD payload decoded, or its size and why it doesn't decode.
local function luaPayload(source: buffer, offset: number, length: number): Node
  -- decodeLuaData throws on a payload that doesn't decode; that's what's shown instead.
  local ok, value = pcall(tes3.save.decodeLuaData, source, offset, length)
  if ok then return luaNode(value :: LuaValue) end

  return `{length} bytes, undecodable: {value}`
end

--[[ Subrecords ]]

--- Whether every byte is printable text (or a tab or line break); a trailing NUL is left out.
local function printable(data: string): string?
  if string.sub(data, -1) == '\0' then data = string.sub(data, 1, -2) end

  if data == '' then return nil end

  for index = 1, #data do
    local byte = string.byte(data, index)
    if
      not ((byte >= 0x20 and byte < 0x7f) or byte >= 0xa0 or byte == 9 or byte == 10 or byte == 13)
    then
      return nil
    end
  end

  return tes3.lossyUtf8(data)
end

--- The `length` bytes of `source` at `offset` as a typed RefId spelled as OpenMW spells it (`#-2
--- -9` for an exterior cell); string ids must be printable, since this also guesses whether an
--- unknown subrecord holds one.
local function typedRefIdTextAt(source: buffer, offset: number, length: number): string?
  local id = tes3.save.decodeRefId(source, offset, length)
  if not id or id.kind == 'empty' then return nil end

  if id.kind == 'string' then return printable(id.value) end

  return tes3.save.refIdText(id)
end

local function typedRefIdText(data: string): string?
  return typedRefIdTextAt(buffer.fromstring(data), 0, #data)
end

--- Four bytes are usually an i32 count or flag, or an f32; a float's bit pattern reads as a huge int.
local function fourByteNumber(data: string): Node
  local int = Records.i32At(data)
  if math.abs(int) < 1000000 then return int end

  local value = Records.f32At(data)
  if value == value and math.abs(value) >= 1e-4 and math.abs(value) < 1e8 then
    return float(value)
  end

  return int
end

--- Best-effort decoding of a subrecord no classifier knows: `data`, which is the `length` bytes
--- of `source` at `offset`.
local function genericValue(data: string, source: buffer, offset: number, length: number): Node
  local text = typedRefIdTextAt(source, offset, length) or printable(data)
  if text then return text end

  if #data == 4 then return fourByteNumber(data) end

  if #data <= 16 then
    local hex = [for index in range(1, #data) => string.format('%02x', string.byte(data, index))]
    return `hex {table.concat(hex, ' ')}`
  end

  return `{#data} bytes`
end

--- A placement (CellRef DATA, object POS_, door DODT): three position then three rotation f32s,
--- in the `length` bytes of `source` at `offset`.
local function placement(source: buffer, offset: number, length: number): Node?
  if length ~= 24 then return nil end

  local numbers = [for index in range(0, 5) => buffer.readf32(source, offset + index * 4)]
  return fields { { 'position', floats(numbers, 1, 3) }, { 'rotation', floats(numbers, 4, 6) } }
end

--- EQIP: a u32 count, then (u32 inventory item index, u32 equipment slot) pairs.
local function equipment(data: string): Node?
  if #data < 4 then return nil end

  local count = Records.u32At(data)
  if #data - 4 ~= count * 8 then return nil end

  local items: { Node } = [
    for index in range(0, count - 1)
    => `item {Records.u32At(data, 5 + index * 8)} in slot {Records.u32At(data, 9 + index * 8)}` :: Node
  ]

  return list(items)
end

--- NPCO: an i32 count followed by the item id.
local function inventoryEntry(data: string): string?
  if #data < 4 then return nil end

  local count = Records.i32At(data)
  local id = string.sub(data, 5)
  local text = typedRefIdText(id)
  if not text then
    local nul = string.find(id, '\0', 1, true)
    text = printable(if nul then string.sub(id, 1, nul - 1) else id)
  end

  if not text then return nil end

  return `{count} x {text}`
end

local function referenceValue(
  localIndex: number,
  contentFile: number,
  contentFiles: { string }
): string
  local source = contentFiles[contentFile + 1]
  if not source then
    source = if contentFile < 0 then 'generated' else `content file {contentFile}`
  end

  return `{localIndex} ({source})`
end

--[[ Typed records ]]

--- Save records store ids as typed RefIds; typed record decoders read them as plain strings.
local function cleanRefIds(value: unknown): unknown
  if type(value) == 'string' then
    local first = string.byte(value, 1)
    if first == 2 then return string.sub(value, 2) end

    if first == 4 then return '<generated id>' end

    return value
  end

  if type(value) == 'table' then
    local out = {}
    for key, item in value :: { [unknown]: unknown } do
      out[key] = cleanRefIds(item)
    end

    return out
  end

  return value
end

--- The text of a string RefId (type 1 or 2); nil for anything else.
local function plainRefId(data: string): string?
  local kind = string.byte(data, 1)
  if kind ~= 1 and kind ~= 2 then return nil end

  return typedRefIdText(data)
end

local function fixedName(name: string): string?
  if #name > 32 then return nil end

  return name .. string.rep('\0', 32 - #name)
end

--- A save record rewritten into the plugin layout the typed decoders read: typed RefIds become
--- plain strings, and NPCO items and NPCS spells become fixed 32-byte names.
local function pluginLayout(plugin: Plugin, index: number, record: Record): string?
  local parts = {}
  for position = 0, record.count - 1 do
    local tag = Records.tagAt(record, position) :: string
    local data = Records.payload(record, position)
    if tag == 'NPCO' then
      if #data < 4 then return nil end

      local id = plainRefId(string.sub(data, 5))
      local name = id and fixedName(id)
      if not name then return nil end

      data = string.sub(data, 1, 4) .. name
    elseif tag == 'NPCS' then
      local id = plainRefId(data)
      local name = id and fixedName(id)
      if not name then return nil end

      data = name
    else
      data = plainRefId(data) or data
    end

    table.insert(parts, tag .. string.pack('<I4', #data) .. data)
  end

  local payload = table.concat(parts)
  local source, start = plugin:span(index)
  local header = buffer.readstring(source, start, 16)
  return string.sub(header, 1, 4)
    .. string.pack('<I4', #payload)
    .. string.sub(header, 9, 16)
    .. payload
end

local function typedContentValue(plugin: Plugin, index: number, record: Record): Node?
  local bytes = pluginLayout(plugin, index, record)
  if not bytes then return nil end

  -- tes3.open throws on bytes that don't frame, and decode on a record that doesn't decode; either
  -- way the record is shown subrecord by subrecord instead.
  local ok, value = pcall(function(): unknown
    local single = tes3.open(bytes :: string, { encoding = plugin.encoding })
    local decoded = single:decode(0)
    if not decoded then return nil end

    local shown = tes3.display.recordValue(single, 0, decoded)
    shown.record = index
    return cleanRefIds(shown)
  end)

  if not ok or value == nil then return nil end

  return fromPlain(value)
end

--[[ Records ]]

local function isObjectState(record: Record): boolean
  return record.tag == 'CSTA' or record.tag == 'PLAY'
end

type Indexes = { contentFiles: { string }, luaScripts: { string } }

--- A save-only record's value: its number, its type, and each subrecord's best-known decoding.
--- With `limit`, only the subrecords from position `from` (0 without one) up to that many, and
--- the position the next part starts at when there are more: a cell's record can hold tens of
--- thousands, and what one means depends on the ones before it, which are still read.
local function subrecordsValue(
  record: Record,
  indexes: Indexes,
  from: number?,
  limit: number?
): (Node, number?)
  local subrecords: { Node } = {}
  local inventoryItemsRemaining = 0
  local first = from or 0
  local last = record.count - 1
  if limit then last = math.min(last, first + limit - 1) end

  for position = 0, last do
    local tag = Records.tagAt(record, position) :: string
    if tag == 'ICNT' then
      inventoryItemsRemaining = Records.inventoryCount(Records.payload(record, position))
    end

    local meaning = Scan.refIdField(record, position, inventoryItemsRemaining)
    if meaning == 'inventory_item_base_object' then
      inventoryItemsRemaining = math.max(inventoryItemsRemaining - 1, 0)
    end

    if position < first then continue end

    local source = record.source
    local at, size = Records.span(record, position)
    local data = buffer.readstring(source, at, size)
    local value: Node? = nil
    if tag == 'LUAD' then
      value = luaPayload(source, at, size)
    elseif tag == 'LUAS' and #data == 4 then
      local id = Records.i32At(data)
      local path = if id >= 0 then indexes.luaScripts[id + 1] else nil
      value = if path then `{id} ({path})` else tostring(id)
    end

    if
      value == nil
      and isObjectState(record)
      and (tag == 'DATA' or tag == 'POS_' or tag == 'DODT')
    then
      value = placement(source, at, size)
    end

    if value == nil and tag == 'EQIP' then value = equipment(data) end

    -- Dynamic records store inventory as a count plus a typed RefId.
    if value == nil and tag == 'NPCO' then value = inventoryEntry(data) end

    if value == nil and Scan.formIdField(record, position) then
      local localIndex, contentFile = Records.wideFormId(data)
      if localIndex then value = referenceValue(localIndex, contentFile, indexes.contentFiles) end
    end

    if value == nil and meaning then value = Records.refId(data) end

    if value == nil then value = genericValue(data, source, at, size) end

    table.insert(
      subrecords,
      { kind = 'map' :: 'map', keys = { tag }, values = { value :: Node }, verbatim = true }
    )
  end

  local value = fields {
    { 'record', record.index },
    { 'type', record.tag },
    { 'subrecords', list(subrecords) },
  }

  return value, if last < record.count - 1 then last + 1 else nil
end

local function strings(items: { string }): List
  local nodes: { Node } = table.create(#items)
  for position, item in items do
    nodes[position] = item
  end

  return list(nodes)
end

--- The save's metadata as the header record's value: jess-save's `SaveInfo`, field for field in
--- its order, under the record's number and `SaveHeader`.
local function headerValue(index: number, info: Read.Info): Node
  local player = info.player
  local time = info.inGameTime

  return fields {
    { 'record', index },
    { 'type', 'SaveHeader' },
    { 'format', info.format },
    { 'formatVersion', info.formatVersion },
    { 'description', info.description },
    {
      'player',
      fields {
        { 'name', player.name },
        { 'level', player.level },
        { 'classId', player.classId },
        { 'className', player.className },
      },
    },
    { 'cell', info.cell },
    {
      'inGameTime',
      fields {
        { 'gameHour', float(time.gameHour) },
        { 'day', time.day },
        { 'month', time.month },
        { 'year', time.year },
      },
    },
    { 'timePlayed', info.timePlayed and float(info.timePlayed) },
    { 'dependencies', strings(info.dependencies) },
    { 'screenshotBytes', info.screenshotBytes },
    { 'currentDay', info.currentDay },
    { 'currentHealth', info.currentHealth and float(info.currentHealth) },
    { 'maximumHealth', info.maximumHealth and float(info.maximumHealth) },
  }
end

--- What gives record `index`'s readable value for `save`: OpenMW saves give typed values for the
--- SAVE header and dynamic records and a subrecord list otherwise; Morrowind saves give the
--- header's metadata, then typed values for the record types jess models. A subrecord list can
--- be had in parts: with `limit`, at most that many subrecords from position `from`, and the
--- position the next part starts at when the record has more. A typed value comes whole.
local function reader(save: Save): (index: number, from: number?, limit: number?) -> (Node, number?)
  local plugin = save.plugin
  local headerCode = tes3.tags.code(if save.game == 'openmw' then 'SAVE' else 'TES3')
  local unnamed: Save = { plugin = plugin, game = save.game, name = '' }
  -- info throws on metadata that doesn't read; the header record is then shown like any other.
  local ok, header = pcall(Read.info, unnamed)
  local indexes: Indexes = { contentFiles = {}, luaScripts = {} }
  if save.game == 'openmw' then
    -- masters throws on a header that doesn't read; then no content file has a name.
    local read, masters = pcall(plugin.masters, plugin)
    if read then indexes.contentFiles = [for master in masters :: { tes3.Master } => master.name] end

    local luamCode = tes3.tags.code 'LUAM'
    for index = 0, plugin:count() - 1 do
      if plugin:code(index) ~= luamCode then continue end

      local record = Records.record(plugin, index)
      for position = 0, record.count - 1 do
        if Records.tagAt(record, position) ~= 'LUAP' then continue end

        local data = Records.payload(record, position)
        if string.sub(data, -1) == '\0' then data = string.sub(data, 1, -2) end

        table.insert(indexes.luaScripts, tes3.lossyUtf8(data))
      end
    end
  end

  return function(index: number, from: number?, limit: number?): (Node, number?)
    if plugin:code(index) == headerCode and ok then
      return headerValue(index, header :: Read.Info), nil
    end

    if save.game == 'morrowind' then
      return fromPlain(tes3.display.display(plugin, index)), nil
    end

    local record = Records.record(plugin, index)
    if DynamicTags[record.tag] or record.tag == 'GLOB' then
      local typed = typedContentValue(plugin, index, record)
      if typed then return typed, nil end
    end

    return subrecordsValue(record, indexes, from, limit)
  end
end

--- The readable values of records `indices` (0-based; every record without them) as trees, in
--- that order: what `values` gives, with the order of each value's fields, the floats, and the
--- missing values a plain table doesn't keep.
local function tree(save: Save, indices: { number }?): { Node }
  local read = reader(save)
  local out: { Node } = {}
  if indices then
    for position, index in indices do
      out[position] = (read(index))
    end

    return out
  end

  return [for index in range(0, save.plugin:count() - 1) => (read(index))]
end

--- Every record's readable value, as `jess save dump` shows it.
local function values(save: Save): { unknown }
  local read = reader(save)
  local out = table.create(save.plugin:count())
  for index = 0, save.plugin:count() - 1 do
    out[index + 1] = plain((read(index)))
  end

  return out
end

return table.freeze { plain = plain, reader = reader, tree = tree, values = values }
