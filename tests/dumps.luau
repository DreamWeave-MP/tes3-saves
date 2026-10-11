--!strict
--!native
-- The saves jess's CLI tests dumped (`libs/cli/tests/save.rs`), built the same way: one with a
-- player's placement, script data, and inventory, and one with dynamic records in save layout.
-- And the way into a readable value's tree by name.
local fixtures = require './fixtures'
local plugins = require './plugins'
local saves = require '@tes3-saves'
local tes3 = require '@tes3'

local record, subrecord = plugins.record, plugins.subrecord

local function luaString(text: string): tes3.LuaValue return { kind = 'string', value = text } end

local function luaNumber(value: number): tes3.LuaValue return { kind = 'number', value = value } end

--- `save_dump_decodes_save_records_readably`'s save: two content files, two Lua scripts, and a
--- player (record 3) with a placement, a script's data, and an item from the second content file.
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

--- A sized RefId (type 1), as a save's inventory entries hold their items.
local function sized(id: string): string return '\1' .. plugins.u32(#id) .. id end

--- `save_dump_decodes_dynamic_records_with_save_format_ids`'s save: the player's NPC_ (record 2)
--- and a global (record 3), their ids typed RefIds.
local function dynamic(): string
  return fixtures.save()
    .. record(
      'NPC_',
      table.concat {
        subrecord('NAME', fixtures.refId 'player'),
        subrecord('FNAM', 'Ashur'),
        subrecord('RNAM', fixtures.refId 'Dark Elf'),
        subrecord('CNAM', fixtures.refId 'Archer'),
        subrecord('NPDT', '\1\0\50' .. string.rep('\0', 9)),
        subrecord('NPCO', string.pack('<i4', 3) .. sized 'iron dagger'),
        subrecord('NPCS', fixtures.refId 'fireball'),
      }
    )
    .. record(
      'GLOB',
      table.concat {
        subrecord('NAME', fixtures.refId 'TimesDied'),
        subrecord('FNAM', 's'),
        subrecord('FLTV', string.pack('<f', 4)),
      }
    )
end

local function fieldsOf(node: saves.Node?): saves.Fields
  assert(type(node) == 'table' and node.kind == 'map', 'expected fields')
  return node
end

local function listOf(node: saves.Node?): saves.List
  assert(type(node) == 'table' and node.kind == 'list', 'expected a list')
  return node
end

--- The value the fields `node` hold under `key`.
local function at(node: saves.Node?, key: string): saves.Node?
  local fields = fieldsOf(node)
  local position = table.find(fields.keys, key)
  return if position then fields.values[position] else nil
end

return table.freeze {
  at = at,
  dynamic = dynamic,
  fieldsOf = fieldsOf,
  listOf = listOf,
  luaNumber = luaNumber,
  luaString = luaString,
  readable = readable,
}
