--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A command's result as the text `jess save` printed for it: one YAML, JSON, or TOML document.

A result is Luau's: its tables have no order, its field names are camelCase, and its numbers
don't say whether they are floats. The document is serde's: jess-save's report structs field by
field in their order under their own snake_case names, counts sorted by name, a field that has
no value left out, and an f32 in an f32's digits. Each report's shape below is the struct it was
(`SaveInfo`, `SaveCheck`, `SaveStripReport`, the layouts), its fields declared under the names
jess-save gave them; the name a result has a field under is that name camelCased, never the
other way about. `@vfs/serialize` writes the three formats as serde did.

Codes (`will_not_load`, `dry-run`, a strip's reasons) are not this module's to spell: the
commands hand them over as jess-save's sources have them, and they are written as they come.

A dump is a list under `records`. Its YAML is jess's own (`./dumpyaml`), and a byte layout is
JSON unless a format is asked for. jess wrote a dump's records as it read them, and a dump in
pages is written the same way: each page's result is its part of the one document, the first
starting it and the last (the one without a `next`) ending it. TOML has no list that can be
carried on, so a dump in TOML is one result.
]]

local Commands = require './commands'
local DumpYaml = require './dumpyaml'
local Values = require './values'
local serialize = require '@vfs/serialize'
local tes3 = require '@tes3'

type Value = serialize.Value

export type Format = 'yaml' | 'json' | 'toml'

export type Options = {
  --- YAML without one, except for a dump's byte layout, which is JSON.
  format: Format?,
  --- For a page of a dump: whether an earlier page gave records, so that this one carries the
  --- document on instead of starting it.
  continued: boolean?,
}

--- What a field of a result becomes in the document.
type Shape = (value: unknown) -> Value

--[[ Shapes ]]

--- A string, number, or boolean as it is.
local function plain(value: unknown): Value
  if type(value) == 'string' or type(value) == 'number' or type(value) == 'boolean' then
    return value
  end

  return serialize.Null
end

--- A record field's name as jess's files spell it. `@tes3` names a typed record's fields
--- camelCase from jess-omwaddon's snake_case ones, which are lowercase words and digits between
--- underscores, so each capital is where an underscore was. That holds for field names and for
--- nothing else: a code is never read back this way.
local function fieldName(name: string): string
  return (
    string.gsub(name, '%u', function(letter: string): string return '_' .. string.lower(letter) end)
  )
end

--- The name of the typed string field a subrecord holds.
local function typedField(value: unknown): Value
  if type(value) ~= 'string' then return plain(value) end

  return fieldName(value)
end

--- A number serde wrote as an f64: with a point, whole or not.
local function float(value: unknown): Value
  if type(value) ~= 'number' then return plain(value) end

  return serialize.float(value)
end

local Scratch = buffer.create(4)

local function narrow(value: number): number
  buffer.writef32(Scratch, 0, value)
  return buffer.readf32(Scratch, 0)
end

--- A number serde wrote as an f32: in the fewest digits that read back as that f32, where the
--- same value as an f64 takes seventeen (`8.372071`, not `8.372071266174316`).
local function single(value: unknown): Value
  if type(value) ~= 'number' then return plain(value) end

  if value ~= value or math.abs(value) == math.huge or value == 0 then
    return serialize.float(value)
  end

  for precision = 1, 9 do
    local back = tonumber(string.format(`%.{precision - 1}e`, value)) :: number
    if narrow(back) == narrow(value) then return serialize.float(back) end
  end

  return serialize.float(value)
end

local function listOf(shape: Shape): Shape
  return function(value: unknown): Value
    local items: { Value } = {}
    if type(value) == 'table' then
      for position, item in value :: { unknown } do
        items[position] = shape(item)
      end
    end

    return serialize.array(items)
  end
end

local strings = listOf(plain)

--- A field of a report: its name in jess-save's struct, the name the result has it under, its
--- shape, and `keep` for one serde writes as null when it has no value, where every other is
--- left out.
type Field = { name: string, key: string, shape: Shape, keep: boolean? }

local function field(name: string, shape: Shape?, keep: boolean?): Field
  return { name = name, key = tes3.text.camelCase(name), shape = shape or plain, keep = keep }
end

--- A struct: its fields in their order, each under its own name.
local function struct(fields: { Field }): Shape
  return function(value: unknown): Value
    local source: { [string]: unknown } = if type(value) == 'table' then value :: {} else {}
    local pairs: { { unknown } } = {}
    for _, entry in fields do
      local item = source[entry.key]
      if item ~= nil then
        table.insert(pairs, { entry.name, entry.shape(item) })
      elseif entry.keep then
        table.insert(pairs, { entry.name, serialize.None })
      end
    end

    return serialize.struct(pairs)
  end
end

--- Counts by name, sorted by name as a BTreeMap is.
local function counts(value: unknown): Value
  local names: { string } = {}
  local byName: { [string]: unknown } = {}
  if type(value) == 'table' then
    for key, count in value :: { [unknown]: unknown } do
      local name = tostring(key)
      table.insert(names, name)
      byName[name] = count
    end
  end

  table.sort(names)
  local pairs: { { unknown } } = {}
  for _, name in names do
    table.insert(pairs, { name, plain(byName[name]) })
  end

  return serialize.struct(pairs)
end

--[[ Reports ]]

local Written = struct { field 'path', field 'backup' }

--- jess-save's `SaveInfo`.
local Info = struct {
  field 'format',
  field 'format_version',
  field 'description',
  field('player', struct { field 'name', field 'level', field 'class_id', field 'class_name' }),
  field 'cell',
  field(
    'in_game_time',
    struct { field('game_hour', single), field 'day', field 'month', field 'year' }
  ),
  field('time_played', float),
  field('dependencies', strings),
  field 'screenshot_bytes',
  field 'current_day',
  field('current_health', single),
  field('maximum_health', single),
}

--- jess-save's `SaveCheck`.
local Check = struct {
  field 'input',
  field 'verdict',
  field 'format_version',
  field 'strippable_format',
  field('structure_problems', strings),
  field 'load_order_checked',
  field('missing_content', listOf(struct { field 'name', field 'strippable' })),
  field('added_content', strings),
  field 'order_changed',
  field(
    'findings',
    listOf(struct {
      field 'severity',
      field 'problem',
      field 'id',
      field 'record_index',
      field 'record_type',
      field 'subrecord_index',
      field 'subrecord_type',
    })
  ),
  field('dropped_on_load', counts),
  field('warnings', strings),
}

local Concerns = listOf(struct { field 'kind', field 'count', field 'action' })

--- jess-save's `SaveStripPlan`.
local Step = struct {
  field 'dependency',
  field 'mode',
  field 'dependency_index',
  field 'dependencies_before',
  field 'dependencies_after',
  field 'requires_content_file_index_remapping',
  field(
    'save_format',
    struct {
      field 'format_version',
      field 'engine_min_supported',
      field 'engine_current',
      field 'mutation_status',
      field 'reason',
    }
  ),
  field('target_resolution', struct { field 'status', field 'path' }),
  field(
    'target_records',
    struct {
      field 'total',
      field('by_type', counts),
      field('samples', listOf(struct { field 'type', field 'id' })),
    }
  ),
  field('dependents', strings),
  field(
    'save_references',
    struct {
      field 'confidence',
      field 'total',
      field('by_provenance_role', counts),
      field('by_meaning', counts),
      field('by_record_type', counts),
      field(
        'samples',
        listOf(struct {
          field 'record_index',
          field 'record_type',
          field 'subrecord_index',
          field 'subrecord_type',
          field 'ref_id',
          field 'meaning',
          field 'provenance_role',
          field 'first_defined_by',
          field 'last_defined_by',
          field('target_types', strings),
        })
      ),
    }
  ),
  field(
    'content_file_references',
    struct {
      field 'confidence',
      field 'total',
      field('by_meaning', counts),
      field('by_record_type', counts),
      field(
        'samples',
        listOf(struct {
          field 'record_index',
          field 'record_type',
          field 'subrecord_index',
          field 'subrecord_type',
          field 'meaning',
          field 'content_file_index',
          field 'local_index',
          field 'dependency',
        })
      ),
    }
  ),
  field(
    'reference_coverage',
    struct {
      field 'status',
      field('known_scans', strings),
      field('unclassified_risky_records', counts),
    }
  ),
  field(
    'blockers',
    struct {
      field 'status',
      field('hard', Concerns),
      field('informational', Concerns),
      field('protected', Concerns),
    }
  ),
  field(
    'planned_operations',
    listOf(struct {
      field 'name',
      field 'status',
      field 'count',
      field 'reason',
    })
  ),
  field(
    'planned_edits',
    listOf(struct {
      field 'operation',
      field 'status',
      field 'record_index',
      field 'record_type',
      field 'subrecord_index',
      field 'subrecord_end_index',
      field 'subrecord_type',
      field 'meaning',
      field 'local_index',
      field 'old_content_file_index',
      field 'new_content_file_index',
      field 'reason',
    })
  ),
  field(
    'mutation_readiness',
    struct {
      field 'status',
      field 'can_attempt_dry_run',
      field 'reason',
      field 'reference_coverage',
    }
  ),
  field(
    'dry_run',
    struct {
      field 'requested',
      field 'status',
      field 'reason',
      field 'output',
      field 'applied_edits',
      field 'bytes_before',
      field 'bytes_after',
      field 'verification',
      field(
        'post_mutation_verification',
        struct {
          field 'status',
          field 'reason',
          field 'known_remaining_target_refids',
          field 'invalid_content_file_refnums',
        }
      ),
    }
  ),
  field 'mutation',
  field('warnings', strings),
}

--- jess-save's `SaveStripReport`.
local Strip = struct {
  field 'input',
  field('dependencies', strings),
  field('steps', listOf(Step)),
  field('written', Written, true),
}

--- What `screenshot` reported, and what `dump` did of the records it wrote to a file.
local Screenshot = struct { field 'input', field 'format', field 'bytes', field('written', Written) }
local Extracted = struct { field 'input', field 'path', field 'bytes', field('written', Written) }

--[[ Dumps ]]

local Listed = struct { field 'record', field 'type', field 'id' }

local Range = struct { field 'start', field 'end' }

local Subrecords = listOf(struct {
  field 'index',
  field 'type',
  field 'size',
  field('range', Range),
  field('field', typedField),
  field 'value',
})

--- jess-omwaddon's `RecordLayout`, and after it the `ReferenceLayout`s of a CELL.
local Layout = struct {
  field 'index',
  field 'type',
  field 'id',
  field 'flags',
  field 'size',
  field('range', Range),
  field('subrecords', Subrecords),
  field('references', listOf(struct { field 'index', field('subrecords', Subrecords) })),
}

--- A readable value's tree in the document's terms: fields under snake_case names unless they
--- are the save's own, floats as floats, and a missing value as null.
local function tree(node: Values.Node): Value
  if type(node) ~= 'table' then return node end

  if node.kind == 'null' then return serialize.Null end

  if node.kind == 'float' then return serialize.float(node.value) end

  if node.kind == 'list' then
    local items: { Value } = table.create(#node.items)
    for position, item in node.items do
      items[position] = tree(item)
    end

    return serialize.array(items)
  end

  local map = serialize.map()
  for position, key in node.keys do
    serialize.set(map, if node.verbatim then key else fieldName(key), tree(node.values[position]))
  end

  return map
end

--[[ Documents ]]

--- The byte after the string that starts at `position` of a TOML document: a basic or literal
--- one, on one line or several.
local function afterString(text: string, position: number): number
  local quote = string.sub(text, position, position)
  local long = string.sub(text, position, position + 2) == string.rep(quote, 3)
  local close = if long then string.rep(quote, 3) else quote
  local at = position + #close
  while at <= #text do
    if quote == '"' and string.sub(text, at, at) == '\\' then
      at += 2
    elseif string.sub(text, at, at + #close - 1) == close then
      return at + #close
    else
      at += 1
    end
  end

  return at
end

--- A TOML document with each array on one line. `@vfs/serialize` writes the toml crate's pretty
--- layout, an array of two or more items one to a line; jess wrote its plain one, `[a, b]`, and
--- that is the only way the two differ.
local function inlineArrays(text: string): string
  local out: { string } = {}
  local position, pending = 1, 1
  local function flush(upTo: number, with: string, skip: number)
    table.insert(out, string.sub(text, pending, upTo))
    table.insert(out, with)
    position = upTo + 1 + skip
    pending = position
  end

  while position <= #text do
    local character = string.sub(text, position, position)
    if character == '"' or character == '\'' then
      position = afterString(text, position)
    elseif character == '[' and string.sub(text, position + 1, position + 5) == '\n    ' then
      flush(position, '', 5)
    elseif character == ',' and string.sub(text, position + 1, position + 5) == '\n    ' then
      flush(position, ' ', 5)
    elseif character == ',' and string.sub(text, position + 1, position + 2) == '\n]' then
      flush(position - 1, '', 2)
    else
      position += 1
    end
  end

  table.insert(out, string.sub(text, pending))
  return table.concat(out)
end

--- One document. serde_json's has no line break of its own, so jess ended it with one.
local function document(value: Value, format: Format): string
  if format == 'json' then return serialize.encode(value, 'json') .. '\n' end

  if format == 'toml' then return inlineArrays(serialize.encode(value, 'toml')) end

  return serialize.encode(value, format)
end

--- A document that is one list under `records`, or the part of it one page of a dump is:
--- `continued` when an earlier page started the list, `last` when no page follows.
local function records(items: { Value }, format: Format, continued: boolean, last: boolean): string
  if format == 'toml' then
    if continued or not last then error('a dump in TOML can\'t be written in pages', 0) end

    return document(serialize.struct { { 'records', serialize.array(items) } }, format)
  end

  if #items == 0 and not continued then
    if not last then return '' end

    return if format == 'yaml' then 'records: []\n' else '{"records":[]}\n'
  end

  if format == 'yaml' then
    return if continued then DumpYaml.items(items) else DumpYaml.list('records', items)
  end

  local parts: { string } = {}
  for position, item in items do
    table.insert(parts, if position == 1 and not continued then '{"records":[' else ',')
    table.insert(parts, serialize.encode(item, 'json'))
  end

  if last then table.insert(parts, ']}\n') end

  return table.concat(parts)
end

local function each<Item>(list: { Item }?, shape: (Item) -> Value): { Value }
  local items: { Value } = {}
  for position, item in list or {} do
    items[position] = shape(item)
  end

  return items
end

--- `result` as the document `jess save` printed for it, in `options.format`.
local function render(result: Commands.Result, options: Options?): string
  local format = options and options.format
  if result.command == 'info' then return document(Info(result.info), format or 'yaml') end

  if result.command == 'check' then return document(Check(result.check), format or 'yaml') end

  if result.command == 'strip' then return document(Strip(result.report), format or 'yaml') end

  if result.command == 'screenshot' then
    local shown = {
      input = result.path,
      format = result.format,
      bytes = result.bytes,
      written = result.written,
    }

    return document(Screenshot(shown), format or 'yaml')
  end

  if result.mode == 'extract' then
    local shown = {
      input = result.path,
      path = result.path,
      bytes = result.bytes,
      written = result.written,
    }

    return document(Extracted(shown), format or 'yaml')
  end

  local continued = options ~= nil and options.continued == true
  local last = result.next == nil
  if result.mode == 'layout' then
    return records(each(result.layouts, Layout), format or 'json', continued, last)
  end

  if result.mode == 'list' then
    return records(each(result.listed, Listed), format or 'yaml', continued, last)
  end

  return records(each(result.records, tree), format or 'yaml', continued, last)
end

return table.freeze { render = render }
