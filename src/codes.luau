--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
How a report's codes and field names are spelled outside Luau. A check's and a strip's reports
spell them camelCase (`willNotLoad`, `dependencyIndex`), as `@tes3`'s `text.camelCase` makes them
from the snake_case jess-save writes in JSON, YAML, and TOML (`will_not_load`,
`dependency_index`). `snakeCase` is the way back, for anything that writes those formats.

camelCase alone doesn't say where the words were: a code keeps the capitals of the names it
mentions (`known_FormId_fields_...`, `..._removed_from_SAVE_DEPE`), and a capital inside one of
those isn't a word of its own. The names are listed here, where the codes are.
]]

--- The names a code spells with their own capitals, each after the `_` camelCase leaves before it.
local Names = { 'FormId', 'Lua', 'SAVE', 'DEPE', 'TES3', 'MAST' }

--- The name of `Names` that starts at byte `at` of `code`, or nil.
local function nameAt(code: string, at: number): string?
  for _, name in Names do
    if string.sub(code, at, at + #name - 1) == name then return name end
  end

  return nil
end

--- A camelCase code or field name of this package's reports as jess-save spells it: `willNotLoad`
--- is `will_not_load`, and `requestedDependencyEntryWouldBeRemovedFrom_SAVE_DEPE` is
--- `requested_dependency_entry_would_be_removed_from_SAVE_DEPE`.
local function snakeCase(code: string): string
  if not string.find(code, '%u') then return code end

  local out = {}
  local position = 1
  while position <= #code do
    local character = string.sub(code, position, position)
    local name = if character == '_' then nameAt(code, position + 1) else nil
    if name then
      table.insert(out, '_' .. name)
      position += 1 + #name
    elseif #out > 0 and string.find(character, '^%u') then
      table.insert(out, '_' .. string.lower(character))
      position += 1
    else
      table.insert(out, character)
      position += 1
    end
  end

  return table.concat(out)
end

return table.freeze { snakeCase = snakeCase }
