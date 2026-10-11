--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
A command's result as the text `jess save` printed for it: one YAML, JSON, or TOML document.

A result is Luau's: its tables have no order, its field names and codes are camelCase, and its
numbers don't say whether they are floats. The document is serde's: jess-save's report structs
field by field in their order, names and codes in snake_case (`will_not_load`), a strip's `mode`
in kebab-case (`dry-run`), counts sorted by name, a field that has no value left out, and an f32
in an f32's digits. Each report's shape below is the struct it was (`SaveInfo`, `SaveCheck`,
`SaveStripReport`, the layouts); `@vfs/serialize` writes the three formats as serde did.

A dump is a list under `records`. Its YAML is jess's own (`./dumpyaml`), and a byte layout is
JSON unless a format is asked for. jess wrote a dump's records as it read them, and a dump in
pages is written the same way: each page's result is its part of the one document, the first
starting it and the last (the one without a `next`) ending it. TOML has no list that can be
carried on, so a dump in TOML is one result.
]]

local Codes = require './codes'
local Commands = require './commands'
local DumpYaml = require './dumpyaml'
local Values = require './values'
local serialize = require '@vfs/serialize'

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

--- A code: camelCase in the result, snake_case in the document.
local function code(value: unknown): Value
  if type(value) ~= 'string' then return plain(value) end

  return Codes.snakeCase(value)
end

--- A strip's mode: `dryRun` in the result, `dry-run` in the document.
local function kebab(value: unknown): Value
  if type(value) ~= 'string' then return plain(value) end

  return (string.gsub(Codes.snakeCase(value), '_', '-'))
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

--- A field of a report: its name in the result, its shape, and `keep` for one serde writes as
--- null when it has no value, where every other is left out.
type Field = { name: string, shape: Shape, keep: boolean? }

local function field(name: string, shape: Shape?, keep: boolean?): Field
  return { name = name, shape = shape or plain, keep = keep }
end

--- A struct: its fields in their order, each under its snake_case name.
local function struct(fields: { Field }): Shape
  local names: { string } = {}
  for position, entry in fields do
    names[position] = Codes.snakeCase(entry.name)
  end

  return function(value: unknown): Value
    local source: { [string]: unknown } = if type(value) == 'table' then value :: {} else {}
    local pairs: { { unknown } } = {}
    for position, entry in fields do
      local item = source[entry.name]
      if item ~= nil then
        table.insert(pairs, { names[position], entry.shape(item) })
      elseif entry.keep then
        table.insert(pairs, { names[position], serialize.None })
      end
    end

    return serialize.struct(pairs)
  end
end

--- Counts by name, sorted by name as a BTreeMap is; `codes` when the names are codes.
local function counts(codes: boolean): Shape
  return function(value: unknown): Value
    local names: { string } = {}
    local byName: { [string]: unknown } = {}
    if type(value) == 'table' then
      for key, count in value :: { [unknown]: unknown } do
        local name = if codes then Codes.snakeCase(tostring(key)) else tostring(key)
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
end

--[[ Reports ]]

local Written = struct { field 'path', field 'backup' }

--- jess-save's `SaveInfo`.
local Info = struct {
  field('format', code),
  field 'formatVersion',
  field 'description',
  field('player', struct { field 'name', field 'level', field 'classId', field 'className' }),
  field 'cell',
  field(
    'inGameTime',
    struct { field('gameHour', single), field 'day', field 'month', field 'year' }
  ),
  field('timePlayed', float),
  field('dependencies', strings),
  field 'screenshotBytes',
  field 'currentDay',
  field('currentHealth', single),
  field('maximumHealth', single),
}

--- jess-save's `SaveCheck`.
local Check = struct {
  field 'input',
  field('verdict', code),
  field 'formatVersion',
  field 'strippableFormat',
  field('structureProblems', strings),
  field 'loadOrderChecked',
  field('missingContent', listOf(struct { field 'name', field 'strippable' })),
  field('addedContent', strings),
  field 'orderChanged',
  field(
    'findings',
    listOf(struct {
      field('severity', code),
      field('problem', code),
      field 'id',
      field 'recordIndex',
      field 'recordType',
      field 'subrecordIndex',
      field 'subrecordType',
    })
  ),
  field('droppedOnLoad', counts(true)),
  field('warnings', strings),
}

local Concerns = listOf(struct { field('kind', code), field 'count', field('action', code) })

--- jess-save's `SaveStripPlan`.
local Step = struct {
  field 'dependency',
  field('mode', kebab),
  field 'dependencyIndex',
  field 'dependenciesBefore',
  field 'dependenciesAfter',
  field 'requiresContentFileIndexRemapping',
  field(
    'saveFormat',
    struct {
      field 'formatVersion',
      field 'engineMinSupported',
      field 'engineCurrent',
      field('mutationStatus', code),
      field('reason', code),
    }
  ),
  field('targetResolution', struct { field 'status', field 'path' }),
  field(
    'targetRecords',
    struct {
      field 'total',
      field('byType', counts(false)),
      field('samples', listOf(struct { field 'type', field 'id' })),
    }
  ),
  field('dependents', strings),
  field(
    'saveReferences',
    struct {
      field('confidence', code),
      field 'total',
      field('byProvenanceRole', counts(true)),
      field('byMeaning', counts(true)),
      field('byRecordType', counts(false)),
      field(
        'samples',
        listOf(struct {
          field 'recordIndex',
          field 'recordType',
          field 'subrecordIndex',
          field 'subrecordType',
          field 'refId',
          field('meaning', code),
          field('provenanceRole', code),
          field 'firstDefinedBy',
          field 'lastDefinedBy',
          field('targetTypes', strings),
        })
      ),
    }
  ),
  field(
    'contentFileReferences',
    struct {
      field('confidence', code),
      field 'total',
      field('byMeaning', counts(true)),
      field('byRecordType', counts(false)),
      field(
        'samples',
        listOf(struct {
          field 'recordIndex',
          field 'recordType',
          field 'subrecordIndex',
          field 'subrecordType',
          field('meaning', code),
          field 'contentFileIndex',
          field 'localIndex',
          field 'dependency',
        })
      ),
    }
  ),
  field(
    'referenceCoverage',
    struct {
      field('status', code),
      field('knownScans', listOf(code)),
      field('unclassifiedRiskyRecords', counts(false)),
    }
  ),
  field(
    'blockers',
    struct {
      field('status', code),
      field('hard', Concerns),
      field('informational', Concerns),
      field('protected', Concerns),
    }
  ),
  field(
    'plannedOperations',
    listOf(struct {
      field('name', code),
      field('status', code),
      field 'count',
      field('reason', code),
    })
  ),
  field(
    'plannedEdits',
    listOf(struct {
      field('operation', code),
      field('status', code),
      field 'recordIndex',
      field 'recordType',
      field 'subrecordIndex',
      field 'subrecordEndIndex',
      field 'subrecordType',
      field('meaning', code),
      field 'localIndex',
      field 'oldContentFileIndex',
      field 'newContentFileIndex',
      field('reason', code),
    })
  ),
  field(
    'mutationReadiness',
    struct {
      field('status', code),
      field 'canAttemptDryRun',
      field('reason', code),
      field('referenceCoverage', code),
    }
  ),
  field(
    'dryRun',
    struct {
      field 'requested',
      field('status', code),
      field('reason', code),
      field('output', code),
      field 'appliedEdits',
      field 'bytesBefore',
      field 'bytesAfter',
      field('verification', code),
      field(
        'postMutationVerification',
        struct {
          field('status', code),
          field('reason', code),
          field 'knownRemainingTargetRefids',
          field 'invalidContentFileRefnums',
        }
      ),
    }
  ),
  field('mutation', code),
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
  field('field', code),
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
    serialize.set(map, if node.verbatim then key else Codes.snakeCase(key), tree(node.values[position]))
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
