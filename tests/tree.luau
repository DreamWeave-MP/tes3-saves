--!strict
--!native
-- What the package gives anything that writes a report or a dump outside Luau: `snakeCase`, the
-- spelling jess-save's JSON, YAML, and TOML have, and `tree`, a record's readable value with the
-- order of its fields, its floats, and its missing values.
local fixtures = require './fixtures'
local plugins = require './plugins'
local saves = require '@tes3-saves'
local tes3 = require '@tes3'
local test = require '@jess/test'
local expect = test.expect
local suite = test.new()

local record, subrecord = plugins.record, plugins.subrecord

--- The package's folder, from this file's chunk name.
local function root(): string
  local source = debug.info(1, 's')
  local first = string.sub(source, 1, 1)
  local path = if first == '@' or first == '=' then string.sub(source, 2) else source

  return string.match(path, '^(.*)/tests/[^/]*$') or '.'
end

--- A tree as the plain tables `values` gives.
local function plain(node: saves.Node): unknown
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

local function fieldsOf(node: saves.Node?): saves.Fields
  assert(type(node) == 'table' and node.kind == 'map', 'expected fields')
  return node
end

local function listOf(node: saves.Node?): saves.List
  assert(type(node) == 'table' and node.kind == 'list', 'expected a list')
  return node
end

--- The value `fields` holds under `key`.
local function at(node: saves.Node?, key: string): saves.Node?
  local fields = fieldsOf(node)
  local position = table.find(fields.keys, key)
  return if position then fields.values[position] else nil
end

local function luaString(text: string): tes3.LuaValue return { kind = 'string', value = text } end

local function luaNumber(value: number): tes3.LuaValue return { kind = 'number', value = value } end

--- The save `save_dump_decodes_save_records_readably` dumps (`libs/cli/tests/save.rs`): two Lua
--- scripts, and a player with a placement, a script's data, and an item from the second content
--- file.
local function readable(): string
  local state: tes3.LuaValue = {
    kind = 'table',
    entries = {
      { key = luaString 'stage', value = luaNumber(20) },
      {
        key = luaString 'giver',
        value = { kind = 'object', ref = { index = 7, contentFile = 1 } },
      },
    },
  }

  local placement = string.pack('<ffffff', 1.5, 2, 3.25, 0, 0, 1.5)
  return fixtures.save({ 'Morrowind.esm', 'Tribunal.esm' }, nil, true)
    .. record(
      'LUAM',
      subrecord('LUAP', 'scripts/first.lua') .. subrecord('LUAP', 'scripts/quests.lua')
    )
    .. record(
      'PLAY',
      table.concat {
        subrecord('FRMR', fixtures.formId(1, -1)),
        subrecord('NAME', fixtures.refId 'player'),
        subrecord('DATA', placement),
        subrecord('LUAS', string.pack('<i4', 1)),
        subrecord('LUAD', tes3.save.encodeLuaData(state)),
        subrecord('ICNT', plugins.u32(1)),
        subrecord('FRMR', fixtures.formId(42, 1)),
        subrecord('NAME', fixtures.refId 'tribunal_sword'),
      }
    )
end

suite.describe('snakeCase', function()
  suite.it('spells codes and field names as jess-save writes them', function()
    expect(saves.snakeCase 'willNotLoad').toBe 'will_not_load'
    expect(saves.snakeCase 'dependencyIndex').toBe 'dependency_index'
    expect(saves.snakeCase 'knownRemainingTargetRefids').toBe 'known_remaining_target_refids'
    expect(saves.snakeCase 'verified').toBe 'verified'
    expect(saves.snakeCase 'bonus_0').toBe 'bonus_0'
    expect(saves.snakeCase 'requestedDependencyEntryWouldBeRemovedFrom_SAVE_DEPE').toBe 'requested_dependency_entry_would_be_removed_from_SAVE_DEPE'
    expect(saves.snakeCase 'laterDependencyIndicesShiftWhenA_SAVE_DEPEEntryIsRemoved').toBe 'later_dependency_indices_shift_when_a_SAVE_DEPE_entry_is_removed'
    expect(saves.snakeCase 'known_FormIdFieldsPointAtTheDependencyIndexBeingRemoved').toBe 'known_FormId_fields_point_at_the_dependency_index_being_removed'
    expect(saves.snakeCase 'serialized_LuaRefnumPointsAtRemovedDependency').toBe 'serialized_Lua_refnum_points_at_removed_dependency'
  end)

  suite.it('undoes camelCase for every code the package\'s sources spell', function()
    local codes: { [string]: boolean } = {}
    local count = 0
    for _, name in { 'check', 'scan', 'strip' } do
      local source = assert(jess.fs.read(`{root()}/src/{name}.luau`))
      for code in string.gmatch(source, '\'(%l[%w_]*_[%w_]*)\'') do
        if codes[code] then continue end

        codes[code] = true
        count += 1
      end
    end

    -- The scans, the edits, the blockers, and the reasons: a few hundred codes between them.
    expect(count > 150).toBe(true)
    local undone: { string } = {}
    for code in codes do
      local back = saves.snakeCase(tes3.text.camelCase(code))
      if back ~= code then table.insert(undone, `{code} -> {back}`) end
    end

    expect(table.concat(undone, '\n')).toBe ''
  end)
end)

suite.describe('tree', function()
  suite.it('keeps a save-only record\'s fields, its subrecords, and its Lua keys in order', function()
    local save = saves.parse(readable())
    local play = saves.tree(save, { 3 })[1]
    expect(fieldsOf(play).keys).toEqual { 'record', 'type', 'subrecords' }
    expect(at(play, 'record')).toBe(3)
    expect(at(play, 'type')).toBe 'PLAY'

    local subrecords = listOf(at(play, 'subrecords')).items
    local tags = {}
    for position, entry in subrecords do
      local fields = fieldsOf(entry)
      expect(fields.verbatim).toBe(true)
      tags[position] = fields.keys[1]
    end

    expect(tags).toEqual { 'FRMR', 'NAME', 'DATA', 'LUAS', 'LUAD', 'ICNT', 'FRMR', 'NAME' }
    expect(at(subrecords[1], 'FRMR')).toBe '1 (generated)'
    expect(at(subrecords[4], 'LUAS')).toBe '1 (scripts/quests.lua)'
    expect(at(subrecords[7], 'FRMR')).toBe '42 (Tribunal.esm)'
    expect(at(subrecords[8], 'NAME')).toBe 'tribunal_sword'

    -- The save's own order, which sorting would turn around: giver, then stage.
    local data = fieldsOf(at(subrecords[5], 'LUAD'))
    expect(data.keys).toEqual { 'stage', 'giver' }
    expect(data.verbatim).toBe(true)
    expect(data.values[1]).toBe(20)
    expect(fieldsOf(at(data.values[2], 'object')).keys).toEqual { 'index', 'content_file' }
  end)

  suite.it('says which numbers the save holds as floats', function()
    local save = saves.parse(readable())
    local play = saves.tree(save, { 3 })[1]
    local placement = at(listOf(at(play, 'subrecords')).items[3], 'DATA')
    expect(fieldsOf(placement).keys).toEqual { 'position', 'rotation' }
    expect(listOf(at(placement, 'position')).items).toEqual {
      { kind = 'float', value = 1.5 },
      { kind = 'float', value = 2 },
      { kind = 'float', value = 3.25 },
    }

    local header = saves.tree(save, { 1 })[1]
    expect(at(at(header, 'inGameTime'), 'gameHour')).toEqual { kind = 'float', value = 8.5 }
    expect(at(at(header, 'inGameTime'), 'day')).toBe(18)
    expect(at(header, 'timePlayed')).toEqual { kind = 'float', value = 12.5 }
    expect(at(header, 'currentHealth')).toEqual { kind = 'float', value = 42 }
    expect(at(header, 'currentDay')).toBe(3)
  end)

  suite.it('lays the header out as jess-save\'s SaveInfo, after its number and type', function()
    local header = saves.tree(saves.parse(fixtures.save()), { 1 })[1]
    expect(fieldsOf(header).keys).toEqual {
      'record',
      'type',
      'format',
      'formatVersion',
      'description',
      'player',
      'cell',
      'inGameTime',
      'timePlayed',
      'dependencies',
      'screenshotBytes',
      'currentDay',
      'currentHealth',
      'maximumHealth',
    }
    expect(fieldsOf(at(header, 'player')).keys).toEqual { 'name', 'level', 'classId', 'className' }
    expect(fieldsOf(at(header, 'inGameTime')).keys).toEqual { 'gameHour', 'day', 'month', 'year' }

    -- A Morrowind save's header has no format version, class name, play time, or day.
    local morrowind = saves.tree(saves.parse(fixtures.morrowindSave()), { 0 })[1]
    expect(fieldsOf(morrowind).keys).toEqual {
      'record',
      'type',
      'format',
      'description',
      'player',
      'cell',
      'inGameTime',
      'dependencies',
      'screenshotBytes',
      'currentHealth',
      'maximumHealth',
    }
  end)

  suite.it('puts a typed record\'s number, type, id, and name first, and the rest by name', function()
    local npc = saves.tree(saves.parse(fixtures.morrowindSave()), { 4 })[1]
    local keys = fieldsOf(npc).keys
    expect({ keys[1], keys[2], keys[3], keys[4] }).toEqual { 'record', 'type', 'id', 'name' }
    expect(at(npc, 'type')).toBe 'Npc'
    expect(at(npc, 'id')).toBe 'player'
    local rest = table.move(keys, 5, #keys, 1, {})
    local sorted = table.clone(rest)
    table.sort(sorted)
    expect(rest).toEqual(sorted)
    expect(fieldsOf(npc).verbatim).toBeNil()
  end)

  suite.it('tells an empty Lua table from an empty list, and keeps a number with no spelling its place', function()
    local state: tes3.LuaValue = {
      kind = 'table',
      entries = {
        { key = luaString 'empty', value = { kind = 'table', entries = {} } },
        { key = luaString 'gone', value = luaNumber(math.huge) },
        { key = luaNumber(5), value = { kind = 'boolean', value = true } },
        { key = luaString 'half', value = luaNumber(0.5) },
        { key = luaString 'at', value = { kind = 'vec2', values = { 1, 2.5 } } },
      },
    }

    local bytes = fixtures.save()
      .. record('LUAM', subrecord('LUAD', tes3.save.encodeLuaData(state)))
      .. record('LUAM', subrecord('LUAD', '\1'))
    local save = saves.parse(bytes)
    local trees = saves.tree(save)
    local data = fieldsOf(at(listOf(at(trees[3], 'subrecords')).items[1], 'LUAD'))
    expect(data.keys).toEqual { 'empty', 'gone', '5', 'half', 'at' }
    expect(data.values[1]).toEqual { kind = 'map', keys = {}, values = {}, verbatim = true }
    expect(data.values[2]).toEqual { kind = 'null' }
    expect(data.values[3]).toBe(true)
    expect(data.values[4]).toEqual { kind = 'float', value = 0.5 }
    expect(listOf(at(data.values[5], 'vec2')).items).toEqual {
      { kind = 'float', value = 1 },
      { kind = 'float', value = 2.5 },
    }
    expect(at(listOf(at(trees[4], 'subrecords')).items[1], 'LUAD')).toContain '1 bytes, undecodable: unsupported Lua serialization format version 1'
  end)

  suite.it('is what values gives, as plain tables, and shows Lua data as @tes3 does', function()
    local bytes = {
      readable(),
      fixtures.morrowindSave(),
      fixtures.save()
        .. record('LUAM', subrecord('LUAD', fixtures.luaObjectList { { 3, 0 }, { 4, 1 } }))
        .. record('LUAM', subrecord('LUAD', fixtures.luaCustom('thing', 'abc'))),
    }

    for _, scenario in fixtures.scenarios() do
      table.insert(bytes, scenario.save)
    end

    for _, source in bytes do
      local save = saves.parse(source)
      local values = saves.values(save)
      local trees = saves.tree(save)
      expect(#trees).toBe(#values)
      for position, node in trees do
        expect(plain(node)).toEqual(values[position])
      end

      for index = 0, save.plugin:count() - 1 do
        local span = save.plugin:span(index)
        for position, sub in save.plugin:subrecords(index) do
          if sub.tag ~= 'LUAD' then continue end

          local shown = (values[index + 1] :: { subrecords: { { [string]: unknown } }? }).subrecords
          if not shown then continue end

          expect(shown[position].LUAD).toEqual(
            tes3.display.luaPayload(span, sub.payload, sub.size, true)
          )
        end
      end
    end
  end)
end)

return suite
