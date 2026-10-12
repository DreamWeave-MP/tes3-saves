--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
Removing content files from an OpenMW save (jess-save's `strip`, `plan`, `plan_operations`,
`plan_readiness`, `mutate`, and `verify`): plan each removal, apply it in memory, verify the
result, and only then write. Every field the engine can't drop on its own is fixed or refused;
`docs/save-strip.md` has the rules and their engine sources. Reports are shaped as `jess save
strip` prints them in Luau: keys and codes camelCase, or the codes as jess-save spells them when
asked (`originalCodes`).
]]

local Check = require './check'
local LoadOrder = require './loadorder'
local Read = require './read'
local Records = require './records'
local Scan = require './scan'
local intern = require '@dream/intern'
local tes3 = require '@tes3'

type Plugin = tes3.Plugin
type Record = Records.Record
type Save = Read.Save

--- A count map: how many a scan found of each role, meaning, or record type, by its name.
type Counts = { [string]: number }

--- How a report spells a code. jess-save's codes are the data, as its sources spell them
--- (`dry_run_only`, `in-place`, `OpenMW maps save FormIds through TES3_MAST_not_SAVE_DEPE`);
--- a report has them camelCase for Luau unless it is asked for them as they are, and nothing
--- has to work its way back from one spelling to the other.
type Spell = (code: string) -> string

local function asWritten(code: string): string return code end

--- Each key of a count map, spelled.
local function spellKeys(counts: Counts, spell: Spell): Counts
  local out: Counts = {}
  for key, count in counts do
    out[spell(key)] = count
  end

  return out
end

--[[ Edits ]]

export type Edit = {
  operation: string,
  status: string,
  recordIndex: number?,
  recordType: string?,
  subrecordIndex: number?,
  subrecordEndIndex: number?,
  subrecordType: string?,
  meaning: string?,
  localIndex: number?,
  oldContentFileIndex: number?,
  newContentFileIndex: number?,
  reason: string,
}

local GroupDeletions: { [string]: boolean } = {
  delete_csta_reference_group = true,
  delete_moved_reference_group = true,
  delete_inventory_item_group = true,
  delete_stolen_item_group = true,
  clear_cell_ref_field = true,
  delete_ai_package = true,
  delete_stale_state_field = true,
}

--- The edits a removal needs, in the order they were planned, and what they already delete. A
--- plan asks that of every field and reference it comes to, and a save's edits are too many to
--- look through each time.
type Plan = {
  edits: { Edit },
  --- The records an edit deletes whole.
  records: { [number]: boolean },
  --- The subrecords a group deletion covers, by record.
  covered: { [number]: { [number]: boolean } },
  --- The subrecords edits start at, by operation and record.
  starts: { [string]: { [number]: { [number]: boolean } } },
}

--- Adds `edit` to the plan.
local function push(plan: Plan, edit: Edit)
  table.insert(plan.edits, edit)
  local operation, record, start = edit.operation, edit.recordIndex, edit.subrecordIndex
  if not record then return end

  if operation == 'delete_target_save_record' then plan.records[record] = true end

  if not start then return end

  local byRecord = plan.starts[operation]
  if not byRecord then
    byRecord = {}
    plan.starts[operation] = byRecord
  end

  local starts = byRecord[record]
  if not starts then
    starts = {}
    byRecord[record] = starts
  end

  starts[start] = true
  local finish = edit.subrecordEndIndex
  if not finish or not GroupDeletions[operation] then return end

  local covered = plan.covered[record]
  if not covered then
    covered = {}
    plan.covered[record] = covered
  end

  for position = start, finish - 1 do
    covered[position] = true
  end
end

local function recordPlannedForDeletion(plan: Plan, record: number): boolean
  return plan.records[record] == true
end

local function subrecordPlannedForDeletion(plan: Plan, record: number, sub: number): boolean
  local covered = plan.covered[record]
  return covered ~= nil and covered[sub] == true
end

local function alreadyPlanned(plan: Plan, operation: string, record: number, start: number): boolean
  local byRecord = plan.starts[operation]
  local starts = byRecord and byRecord[record]
  return starts ~= nil and starts[start] == true
end

--- A group deletion, unless one already covers the group.
local function pushGroup(
  plan: Plan,
  operation: string,
  record: Record,
  range: Scan.Range,
  position: number,
  meaning: string,
  reason: string
)
  if alreadyPlanned(plan, operation, record.index, range.start) then return end

  push(plan, {
    operation = operation,
    status = 'planned',
    recordIndex = record.index,
    recordType = record.tag,
    subrecordIndex = range.start,
    subrecordEndIndex = range.finish,
    subrecordType = Records.tagAt(record, position),
    meaning = meaning,
    reason = reason,
  })
end

--- Which save references point at records the target defines: each id the target defines
--- (lowercase) with its role, and where it was first and last defined (a dependency's position and
--- the record type; no type for a target that isn't installed). Kept as flat maps by id: a load
--- order's worth of ids makes a table per id add up.
export type Provenance = {
  targetIndex: number,
  targetMissing: boolean,
  --- The pool ids are interned in, and the code page content ids are spelled in.
  ids: LoadOrder.Pool,
  encoding: string,
  roles: { [number]: string },
  firstAt: { [number]: number },
  firstTag: { [number]: string },
  lastAt: { [number]: number },
  lastTag: { [number]: string },
  --- The types the target defines each id as.
  types: { [number]: { [string]: boolean } },
  names: { string },
  unreadable: { { string } },
  dependents: { string },
}

--- The token a save's id has in `provenance`'s pool, or nil when no content id is spelled so.
local function tokenOf(provenance: Provenance, id: string): number?
  return LoadOrder.token(provenance.ids, id, provenance.encoding)
end

--- The role of a save's id in `provenance`, or nil when the target doesn't define it.
local function roleOf(provenance: Provenance, id: string): string?
  local token = tokenOf(provenance, id)
  return if token then provenance.roles[token] else nil
end

--- Fixes for the save state that refers to records only the removed content file defined.
local function pushTargetIntroducedEdits(records: { Record }, provenance: Provenance, plan: Plan)
  for _, field in Scan.refIdFields(records) do
    local record, position, meaning = field.record, field.subrecord, field.meaning
    if subrecordPlannedForDeletion(plan, record.index, position) then continue end

    if roleOf(provenance, field.id) ~= 'introduced_by_target' then continue end

    if meaning == 'cell_ref_base_object' then
      local group = Scan.cstaReferenceGroup(record, position)
      if not group then error('target-introduced CSTA RefId is not inside a reference group', 0) end

      pushGroup(
        plan,
        'delete_csta_reference_group',
        record,
        group,
        position,
        meaning,
        'CSTA_reference_group_base_object_is_introduced_by_removed_dependency'
      )
      continue
    end

    if meaning == 'inventory_item_base_object' then
      local group = Scan.inventoryItemGroup(record, position)
      if not group then
        error('target-introduced inventory item RefId is not inside an inventory item group', 0)
      end

      if not Scan.inventoryCountFor(record, group.start) then
        error('target-introduced inventory item has no preceding ICNT', 0)
      end

      pushGroup(
        plan,
        'delete_inventory_item_group',
        record,
        group,
        position,
        meaning,
        'inventory_item_base_object_is_introduced_by_removed_dependency'
      )
      continue
    end

    local fix = Scan.fieldEdit(record, position, meaning)
    if fix then
      -- Object groups owned by the removed dependency are deleted whole by the RefNum pass.
      if Scan.inTargetCstaGroup(record, position, provenance.targetIndex) then continue end

      pushGroup(plan, fix.operation, record, fix.range, position, meaning, fix.reason)
      continue
    end

    if meaning == 'stolen_item_ref_id' then
      local group = Scan.stolenItemGroup(record, position)
      if not group then
        error('target-introduced stolen item RefId is not inside a stolen item group', 0)
      end

      pushGroup(
        plan,
        'delete_stolen_item_group',
        record,
        group,
        position,
        meaning,
        'stolen_item_is_introduced_by_removed_dependency'
      )
      continue
    end

    local reason = Scan.deletePolicy(record.tag, meaning)
    if not reason or recordPlannedForDeletion(plan, record.index) then continue end

    push(plan, {
      operation = 'delete_target_save_record',
      status = 'planned',
      recordIndex = record.index,
      recordType = record.tag,
      subrecordIndex = position,
      subrecordType = Records.tagAt(record, position),
      meaning = meaning,
      reason = reason,
    })
  end
end

local function contentFileEdit(
  hit: Scan.Hit,
  operation: string,
  status: string,
  new: number?,
  reason: string
): Edit
  return {
    operation = operation,
    status = status,
    recordIndex = hit.record.index,
    recordType = hit.record.tag,
    subrecordIndex = hit.subrecord,
    subrecordType = Records.tagAt(hit.record, hit.subrecord),
    meaning = hit.meaning,
    localIndex = hit.localIndex,
    oldContentFileIndex = hit.contentFile,
    newContentFileIndex = new,
    reason = reason,
  }
end

--- What happens to a reference that points at the content file being removed.
local function pushRemovedDependencyReference(plan: Plan, hit: Scan.Hit)
  local record, position = hit.record, hit.subrecord
  local tag = Records.tagAt(record, position)
  local function blocked(reason: string)
    push(
      plan,
      contentFileEdit(hit, 'rewrite_or_drop_removed_dependency_reference', 'blocked', nil, reason)
    )
  end

  if record.tag == 'CSTA' and tag == 'FRMR' then
    local group, frmr = Scan.cstaReferenceGroup(record, position)
    if not group then error('CSTA reference is not inside a reference group', 0) end

    local index, contentFile = Records.wideFormId(Records.payload(record, frmr))
    if not (index and contentFile == hit.contentFile) then
      blocked 'known_reference_points_at_the_dependency_being_removed'
      return
    end

    if alreadyPlanned(plan, 'delete_csta_reference_group', record.index, group.start) then
      return
    end

    local edit = contentFileEdit(
      hit,
      'delete_csta_reference_group',
      'planned',
      nil,
      'CSTA_reference_group_points_at_the_dependency_being_removed'
    )
    edit.subrecordIndex, edit.subrecordEndIndex = group.start, group.finish
    push(plan, edit)
    return
  end

  if record.tag == 'CSTA' and tag == 'MVRF' then
    local group = Scan.cstaMovedReferenceGroup(record, position)
    if not group then
      blocked 'moved_reference_marker_has_no_current_format_cell_id'
      return
    end

    if alreadyPlanned(plan, 'delete_moved_reference_group', record.index, group.start) then
      return
    end

    local edit = contentFileEdit(
      hit,
      'delete_moved_reference_group',
      'planned',
      nil,
      'moved_reference_marker_points_at_the_dependency_being_removed'
    )
    edit.subrecordIndex, edit.subrecordEndIndex = group.start, group.finish
    push(plan, edit)
    return
  end

  if tag == 'LUAD' then
    push(
      plan,
      contentFileEdit(
        hit,
        'rewrite_or_drop_removed_lua_reference',
        'blocked',
        nil,
        'serialized_Lua_refnum_points_at_removed_dependency'
      )
    )
    return
  end

  blocked 'known_reference_points_at_the_dependency_being_removed'
end

--- Every edit removing dependency `index` (0-based) from the save needs.
local function plannedEdits(
  plugin: Plugin,
  records: { Record },
  index: number,
  dependency: string,
  provenance: Provenance?
): { Edit }
  local plan: Plan = { edits = {}, records = {}, covered = {}, starts = {} }
  if dependency ~= '' then
    for _, master in plugin:masters() do
      if string.lower(master.name) ~= string.lower(dependency) then continue end

      push(plan, {
        operation = 'remove_tes3_master_dependency',
        status = 'planned',
        recordIndex = 0,
        recordType = 'TES3',
        subrecordIndex = master.mast,
        subrecordEndIndex = master.data + 1,
        subrecordType = 'MAST',
        oldContentFileIndex = index,
        reason = 'requested_dependency_entry_would_be_removed_from_TES3_MAST',
      })
      break
    end
  end

  for _, record in records do
    if record.tag ~= 'SAVE' then continue end

    local seen = 0
    for position = 0, #record.subs - 1 do
      if Records.tagAt(record, position) ~= 'DEPE' then continue end

      if seen == index then
        push(plan, {
          operation = 'remove_save_dependency',
          status = 'planned',
          recordIndex = record.index,
          recordType = 'SAVE',
          subrecordIndex = position,
          subrecordType = 'DEPE',
          oldContentFileIndex = index,
          reason = 'requested_dependency_entry_would_be_removed_from_SAVE_DEPE',
        })
        break
      end

      seen += 1
    end

    break
  end

  if provenance then pushTargetIntroducedEdits(records, provenance, plan) end

  for _, hit in Scan.contentFileHits(records) do
    if recordPlannedForDeletion(plan, hit.record.index) then continue end

    if subrecordPlannedForDeletion(plan, hit.record.index, hit.subrecord) then continue end

    if hit.contentFile == index then
      pushRemovedDependencyReference(plan, hit)
    elseif hit.contentFile > index then
      push(
        plan,
        contentFileEdit(
          hit,
          'remap_content_file_index',
          'planned',
          hit.contentFile - 1,
          'content_file_index_shifts_after_SAVE_DEPE_removal'
        )
      )
    end
  end

  return plan.edits
end

--[[ Provenance ]]

export type Resolution = { status: string, path: string? }

local function formatOccurrence(provenance: Provenance, at: number, tag: string?): string
  local name = provenance.names[at + 1]
  return if tag then `{name}:{tag}` else name
end

local function dependsOn(index: LoadOrder.Index, dependency: string, target: string): boolean
  local masters = index.masters
  if not masters then
    error(`failed to read masters of '{dependency}': {index.mastersProblem}`, 0)
  end

  for _, master in masters do
    if string.lower(master) == string.lower(target) then return true end
  end

  return false
end

--- Provenance for a target that isn't installed: every id the save refers to that neither a
--- remaining dependency nor the save's own dynamic records define is taken as the target's. That's
--- only certain when every remaining dependency can be read; otherwise such ids are
--- `target_only_unknown`, which blocks the strip.
local function missingTargetProvenance(
  records: { Record },
  order: LoadOrder.LoadOrder?,
  dependencies: { string },
  resolutions: { Resolution },
  target: number,
  alsoRemoved: { [string]: boolean },
  encoding: string,
  cache: LoadOrder.Cache,
  ids: LoadOrder.Pool
): Provenance
  local name = dependencies[target + 1]
  local known = Check.dynamicIds(records, ids, encoding)
  -- The player's own record, which the engine always has.
  known[LoadOrder.token(ids, 'player', encoding, true) :: number] = true
  local incomplete = false
  local unreadable, dependents = {}, {}
  for ordinal, dependency in dependencies do
    if ordinal - 1 == target or not Records.isRecordContentFile(dependency) then continue end

    local path = resolutions[ordinal].path
    if not path then
      -- A missing dependency being removed too defines nothing that stays.
      incomplete = incomplete or not alsoRemoved[string.lower(dependency)]
      continue
    end

    -- A resolved path came from the load order.
    local indexed, problem =
      LoadOrder.index(order :: LoadOrder.LoadOrder, path, encoding, ids, cache)
    if not indexed then
      incomplete = true
      table.insert(unreadable, { dependency, problem :: string })
      continue
    end

    if dependsOn(indexed, dependency, name) then table.insert(dependents, dependency) end

    for _, token in indexed.ids.tokens do
      if token then known[token] = true end
    end
  end

  local role = if incomplete then 'target_only_unknown' else 'introduced_by_target'
  local roles: { [number]: string }, at: { [number]: number } = {}, {}
  for _, field in Scan.refIdFields(records) do
    if field.id == '' then continue end

    local token = LoadOrder.token(ids, field.id, encoding, true) :: number
    if known[token] or roles[token] then continue end

    roles[token], at[token] = role, target
  end

  return {
    targetIndex = target,
    targetMissing = true,
    ids = ids,
    encoding = encoding,
    roles = roles,
    firstAt = at,
    firstTag = {},
    lastAt = at,
    lastTag = {},
    types = {},
    names = dependencies,
    unreadable = unreadable,
    dependents = dependents,
  }
end

--- Which records the save refers to come from dependency `target` (0-based), and which other
--- dependencies need it as a master.
local function provenanceOf(
  records: { Record },
  order: LoadOrder.LoadOrder?,
  dependencies: { string },
  resolutions: { Resolution },
  target: number,
  alsoRemoved: { [string]: boolean },
  encoding: string,
  cache: LoadOrder.Cache,
  ids: LoadOrder.Pool
): Provenance?
  if not resolutions[target + 1].path then
    return missingTargetProvenance(
      records,
      order,
      dependencies,
      resolutions,
      target,
      alsoRemoved,
      encoding,
      cache,
      ids
    )
  end

  local reader = order :: LoadOrder.LoadOrder
  local unresolvedBeforeTarget = false
  for ordinal = 1, target do
    if not resolutions[ordinal].path and Records.isRecordContentFile(dependencies[ordinal]) then
      unresolvedBeforeTarget = true
      break
    end
  end

  local types: { [number]: { [string]: boolean } } = {}
  local firstAt: { [number]: number }, firstTag: { [number]: string } = {}, {}
  local lastAt: { [number]: number }, lastTag: { [number]: string } = {}, {}
  local unreadable, dependents = {}, {}
  local name = dependencies[target + 1]
  local targetPath = resolutions[target + 1].path :: string
  -- Only ids the target defines get an entry, so the target is read first and the other content
  -- files are only searched for those.
  if Records.isRecordContentFile(targetPath) then
    local indexed, problem = LoadOrder.index(reader, targetPath, encoding, ids, cache)
    if not indexed then error(`failed to read dependency '{name}' ({targetPath}): {problem}`, 0) end

    local found = indexed.ids
    for slot, token in found.tokens do
      if not token then continue end

      local set = types[token]
      if not set then
        set = {}
        types[token] = set
      end

      set[tes3.tags.display(found.codes[slot])] = true
    end
  end

  local tags: { [number]: string } = {}
  for ordinal, dependency in dependencies do
    local path = resolutions[ordinal].path
    if not path or not Records.isRecordContentFile(path) then continue end

    local index = ordinal - 1
    local indexed, problem = LoadOrder.index(reader, path, encoding, ids, cache)
    if not indexed then
      -- An unreadable earlier dependency may define records the target also defines, so treat it
      -- like an unresolved one; later dependencies can't change provenance.
      unresolvedBeforeTarget = unresolvedBeforeTarget or index < target
      table.insert(unreadable, { dependency, problem :: string })
      continue
    end

    if index ~= target and dependsOn(indexed, dependency, name) then
      table.insert(dependents, dependency)
    end

    -- jess-omwaddon's `object_keys` gives each type and id once, sorted by type then id, so of the
    -- keys an id has here (differing in case or type), the smallest is its first occurrence and
    -- the largest its last.
    -- A token's ids are only read as text when it has more than one key here.
    local lowTag: { [number]: string }, lowAt: { [number]: number } = {}, {}
    local highTag: { [number]: string }, highAt: { [number]: number } = {}, {}
    local found = indexed.ids
    -- An index holds no id's text, so the file is opened again for the few that are compared
    -- as text: a file that was indexed opens.
    local reopened: Plugin? = nil
    local function idAt(slot: number): string
      if not reopened then
        local plugin, why = LoadOrder.openContent(reader, path, encoding)
        if not plugin then error(`failed to read dependency '{dependency}' ({path}): {why}`, 0) end

        reopened = plugin
      end

      return tes3.records.id(reopened :: Plugin, slot - 1) :: string
    end

    for slot, token in found.tokens do
      if not token or not types[token] then continue end

      local code = found.codes[slot]
      local tag = tags[code]
      if not tag then
        tag = tes3.tags.display(code)
        tags[code] = tag
      end

      local low = lowTag[token]
      if not low then
        lowTag[token], lowAt[token], highTag[token], highAt[token] = tag, slot, tag, slot
        continue
      end

      if tag < low or (tag == low and idAt(slot) < idAt(lowAt[token])) then
        lowTag[token], lowAt[token] = tag, slot
      end

      local high = highTag[token]
      if tag > high or (tag == high and idAt(slot) > idAt(highAt[token])) then
        highTag[token], highAt[token] = tag, slot
      end
    end

    for token, tag in lowTag do
      if not firstAt[token] then
        firstAt[token], firstTag[token] = index, tag
      end

      lastAt[token], lastTag[token] = index, highTag[token]
    end
  end

  local roles: { [number]: string } = {}
  for token in types do
    roles[token] = if firstAt[token] < target
      then 'overridden_by_target'
      elseif unresolvedBeforeTarget then 'target_only_unknown'
      else 'introduced_by_target'
  end

  return {
    targetIndex = target,
    targetMissing = false,
    ids = ids,
    encoding = encoding,
    roles = roles,
    firstAt = firstAt,
    firstTag = firstTag,
    lastAt = lastAt,
    lastTag = lastTag,
    types = types,
    names = dependencies,
    unreadable = unreadable,
    dependents = dependents,
  }
end

--[[ Scans ]]

local function sortedKeys(set: { [string]: boolean }): { string }
  local out = {}
  for key in set do
    table.insert(out, key)
  end

  table.sort(out)
  return out
end

--- The records the content file at `path` defines (how many, by type, and the first few), and
--- the file's size. The file is open only in here.
local function scanTarget(
  order: LoadOrder.LoadOrder,
  path: string,
  limit: number,
  encoding: string
): ({ [string]: unknown }, number)
  local plugin, problem, size = LoadOrder.openContent(order, path, encoding)
  if not plugin then error(`failed to read dependency '{path}': {problem}`, 0) end

  -- Every type and id once, ids compared exactly (interned straight from the file); the samples
  -- are the first few in type-then-id order, kept smallest first as the keys go by, and an id is
  -- only read as text when its key could be one.
  local exact: LoadOrder.Pool = intern.new 'exact'
  local seen: { [number]: { [number]: boolean } } = {}
  local tags: { [number]: string } = {}
  local byType: { [string]: number } = {}
  local samples: { { type: string, id: string } } = {}
  local total = 0
  for index = 0, plugin:count() - 1 do
    local source, at, length = tes3.records.idSpan(plugin, index)
    if not source then continue end

    local code = plugin:code(index)
    local ofType = seen[code]
    if not ofType then
      ofType = {}
      seen[code] = ofType
      tags[code] = tes3.tags.display(code)
    end

    local token = exact:intern(source, at, length)
    if ofType[token] then continue end

    ofType[token] = true
    local tag = tags[code]
    byType[tag] = (byType[tag] or 0) + 1
    total += 1
    if limit == 0 then continue end

    local last = samples[#samples]
    if #samples == limit and tag > last.type then continue end

    local id = tes3.records.id(plugin, index) :: string
    if #samples == limit and tag == last.type and id > last.id then continue end

    local place = #samples + 1
    while place > 1 do
      local before = samples[place - 1]
      if before.type < tag or (before.type == tag and before.id < id) then break end

      place -= 1
    end

    table.insert(samples, place, { type = tag, id = id })
    if #samples > limit then table.remove(samples) end
  end

  return { total = total, byType = byType, samples = samples }, size
end

--- The records the content file at `path` defines: how many, by type, and the first few.
local function targetRecords(
  order: LoadOrder.LoadOrder,
  path: string,
  limit: number,
  encoding: string
): { [string]: unknown }
  if not Records.isRecordContentFile(path) then return { total = 0, byType = {}, samples = {} } end

  local scan, size = scanTarget(order, path, limit, encoding)
  LoadOrder.letGo(size)
  return scan
end

export type ReferenceScan = {
  total: number,
  byRole: { [string]: number },
  report: { [string]: unknown },
}

--- The save's references to records the target defines that the plan doesn't already fix.
local function saveReferences(
  records: { Record },
  provenance: Provenance,
  limit: number,
  spell: Spell
): ReferenceScan
  local total = 0
  local byRole: Counts, byMeaning: Counts, byRecordType: Counts = {}, {}, {}
  local samples = {}
  for _, field in Scan.refIdFields(records) do
    local record, position, meaning = field.record, field.subrecord, field.meaning
    if Scan.inTargetCstaGroup(record, position, provenance.targetIndex) then continue end

    local token = tokenOf(provenance, field.id)
    local role = if token then provenance.roles[token] else nil
    if not token or not role then continue end

    if role == 'introduced_by_target' and Scan.canPlanDelete(record, position, meaning) then
      continue
    end

    total += 1
    byRole[role] = (byRole[role] or 0) + 1
    byMeaning[meaning] = (byMeaning[meaning] or 0) + 1
    byRecordType[record.tag] = (byRecordType[record.tag] or 0) + 1
    if #samples < limit then
      table.insert(samples, {
        recordIndex = record.index,
        recordType = record.tag,
        subrecordIndex = position,
        subrecordType = Records.tagAt(record, position),
        refId = field.id,
        meaning = spell(meaning),
        provenanceRole = spell(role),
        firstDefinedBy = formatOccurrence(
          provenance,
          provenance.firstAt[token],
          provenance.firstTag[token]
        ),
        lastDefinedBy = formatOccurrence(
          provenance,
          provenance.lastAt[token],
          provenance.lastTag[token]
        ),
        targetTypes = sortedKeys(provenance.types[token] or {}),
      })
    end
  end

  return {
    total = total,
    byRole = byRole,
    report = {
      confidence = spell 'known_openmw_refid_fields',
      total = total,
      byProvenanceRole = spellKeys(byRole, spell),
      byMeaning = spellKeys(byMeaning, spell),
      byRecordType = byRecordType,
      samples = samples,
    },
  }
end

--- The FormIds and Lua RefNums that point at content file `index`.
local function contentFileReferences(
  hits: { Scan.Hit },
  index: number,
  dependency: string,
  limit: number,
  spell: Spell
): { [string]: unknown }
  local total = 0
  local byMeaning: Counts, byRecordType: Counts = {}, {}
  local samples = {}
  for _, hit in hits do
    if hit.contentFile ~= index then continue end

    total += 1
    byMeaning[hit.meaning] = (byMeaning[hit.meaning] or 0) + 1
    byRecordType[hit.record.tag] = (byRecordType[hit.record.tag] or 0) + 1
    if #samples < limit then
      table.insert(samples, {
        recordIndex = hit.record.index,
        recordType = hit.record.tag,
        subrecordIndex = hit.subrecord,
        subrecordType = Records.tagAt(hit.record, hit.subrecord),
        meaning = spell(hit.meaning),
        contentFileIndex = hit.contentFile,
        localIndex = hit.localIndex,
        dependency = dependency,
      })
    end
  end

  return {
    confidence = spell 'known_openmw_formid_and_lua_refnum_fields',
    total = total,
    byMeaning = spellKeys(byMeaning, spell),
    byRecordType = byRecordType,
    samples = samples,
  }
end

--[[ Readiness ]]

type Concern = { kind: string, count: number, action: string }
type Blockers = {
  status: string,
  hard: { Concern },
  informational: { Concern },
  protected: { Concern },
}

type Readiness = {
  status: string,
  canAttemptDryRun: boolean,
  reason: string,
  referenceCoverage: string,
}

type Format = {
  formatVersion: number,
  engineMinSupported: number,
  engineCurrent: number,
  mutationStatus: string,
  reason: string,
}

local function formatSupport(version: number): Format
  local status, reason
  local current = tes3.save.CurrentFormatVersion
  if version == current then
    status, reason = 'supported', 'current_openmw_save_format'
  elseif version > current then
    status, reason = 'unsupported', 'newer_save_format_not_understood'
  elseif version >= tes3.save.MinMutationFormatVersion then
    status, reason = 'supported', 'older_openmw_save_format_with_checked_layout'
  else
    status, reason = 'unsupported', 'older_save_format_requires_resave_before_mutation'
  end

  return {
    formatVersion = version,
    engineMinSupported = tes3.save.MinEngineSupportedFormatVersion,
    engineCurrent = current,
    mutationStatus = status,
    reason = reason,
  }
end

local function countEdits(edits: { Edit }, keep: (Edit) -> boolean): number
  local count = 0
  for _, edit in edits do
    if keep(edit) then
      count += 1
    end
  end

  return count
end

local function isBlocked(edit: Edit): boolean return edit.status == 'blocked' end

local function isBlockedLua(edit: Edit): boolean
  return edit.status == 'blocked' and edit.operation == 'rewrite_or_drop_removed_lua_reference'
end

local function isBlockedContentFile(edit: Edit): boolean
  return edit.status == 'blocked'
    and edit.oldContentFileIndex ~= nil
    and edit.operation ~= 'rewrite_or_drop_removed_lua_reference'
end

local function sum(counts: { [string]: number }): number
  local total = 0
  for _, count in counts do
    total += count
  end

  return total
end

local function blockersOf(
  format: Format,
  provenance: Provenance?,
  coverage: Scan.Coverage,
  references: ReferenceScan?,
  edits: { Edit }
): Blockers
  local hard: { Concern } = {}
  if format.mutationStatus ~= 'supported' then
    table.insert(hard, {
      kind = 'save_format_unsupported',
      count = 1,
      action = 'load_and_save_the_game_in_a_current_openmw_first',
    })
  end

  if not provenance then
    table.insert(hard, {
      kind = 'dependency_provenance_unavailable',
      count = 1,
      action = 'make_the_remaining_content_files_readable_through_the_openmw_config',
    })
  end

  local unclassified = sum(coverage.unclassifiedRiskyRecords)
  if unclassified > 0 then
    table.insert(hard, {
      kind = 'unclassified_lua_data',
      count = unclassified,
      action = 'remove_the_lua_state_jess_cannot_read_before_removing_dependency',
    })
  end

  local dependents = if provenance then #provenance.dependents else 0
  if dependents > 0 then
    table.insert(hard, {
      kind = 'dependents_require_removed_master',
      count = dependents,
      action = 'remove_the_dependent_content_too_or_keep_this_dependency',
    })
  end

  local lua = countEdits(edits, isBlockedLua)
  if lua > 0 then
    table.insert(hard, {
      kind = 'target_lua_refnums',
      count = lua,
      action = 'delete_or_rewrite_lua_state_before_removing_dependency',
    })
  end

  local contentFile = countEdits(edits, isBlockedContentFile)
  if contentFile > 0 then
    table.insert(hard, {
      kind = 'target_content_file_refnums',
      count = contentFile,
      action = 'delete_or_rewrite_referencing_save_state_before_removing_dependency',
    })
  end

  local informational: { Concern } = {}
  if references then
    local introduced = references.byRole.introduced_by_target or 0
    if introduced > 0 then
      table.insert(hard, {
        kind = 'target_introduced_ref_ids',
        count = introduced,
        action = 'delete_or_rewrite_save_state_that_depends_on_target_only_records',
      })
    end

    local unknown = references.byRole.target_only_unknown or 0
    if unknown > 0 then
      table.insert(hard, {
        kind = 'target_ref_ids_with_incomplete_prior_provenance',
        count = unknown,
        action = 'make_the_other_content_files_readable_through_the_openmw_config_or_remove_them_too',
      })
    end

    local overridden = references.byRole.overridden_by_target or 0
    if overridden > 0 then
      table.insert(informational, {
        kind = 'target_overridden_refid_fallbacks',
        count = overridden,
        action = 'allow_refids_to_resolve_to_previous_load_order_definitions',
      })
    end
  end

  return {
    status = if #hard == 0 then 'no_known_blockers' else 'blocked',
    hard = hard,
    informational = informational,
    protected = {
      {
        kind = 'player_record',
        count = 1,
        action = 'never_remove_or_reclassify_as_dependency_content',
      },
    },
  }
end

local function readinessOf(
  format: Format,
  provenance: Provenance?,
  blockers: Blockers,
  coverage: Scan.Coverage,
  edits: { Edit }
): Readiness
  local function answer(status: string, can: boolean, reason: string): Readiness
    return {
      status = status,
      canAttemptDryRun = can,
      reason = reason,
      referenceCoverage = coverage.status,
    }
  end

  if format.mutationStatus ~= 'supported' then
    return answer('unknown', false, 'save_format_unsupported_for_mutation')
  end

  if not provenance then return answer('unknown', false, 'dependency_provenance_unavailable') end

  if next(coverage.unclassifiedRiskyRecords) then
    return answer('unknown', false, 'unclassified_risky_records_present')
  end

  if countEdits(edits, isBlocked) > 0 then
    return answer('blocked', false, 'blocked_planned_edits_present')
  end

  if #blockers.hard > 0 then return answer('blocked', false, 'hard_blockers_present') end

  if #edits == 0 then return answer('unknown', false, 'no_planned_edits_available') end

  return answer('eligible_for_dry_run', true, 'planned_edits_available')
end

type Operation = { name: string, status: string, count: number, reason: string }

local function operationsOf(
  remapping: boolean,
  references: ReferenceScan?,
  edits: { Edit },
  blockers: Blockers
): { Operation }
  local status = if #blockers.hard == 0 then 'planned' else 'blocked'
  local operations: { Operation } = {
    {
      name = 'preserve_protected_player_record',
      status = 'protected',
      count = 1,
      reason = 'player_save_state_is_not_dependency_content',
    },

    {
      name = 'remove_dependency_from_save_depe',
      status = status,
      count = 1,
      reason = 'requested_dependency_entry_would_be_removed_from_SAVE_DEPE',
    },
  }

  local function push(
    name: string,
    operationStatus: string,
    reason: string,
    keep: (Edit) -> boolean
  )
    local count = countEdits(edits, keep)
    if count > 0 then
      table.insert(
        operations,
        { name = name, status = operationStatus, count = count, reason = reason }
      )
    end
  end

  local function pushOperation(operation: string, name: string, reason: string)
    push(name, status, reason, function(edit) return edit.operation == operation end)
  end

  pushOperation(
    'remove_tes3_master_dependency',
    'remove_dependency_from_tes3_mast',
    'OpenMW maps save FormIds through TES3_MAST_not_SAVE_DEPE'
  )
  if remapping then
    table.insert(operations, {
      name = 'remap_content_file_indices_after_removed_dependency',
      status = status,
      count = 1,
      reason = 'later_dependency_indices_shift_when_a_SAVE_DEPE_entry_is_removed',
    })
  end

  push(
    'remap_lua_serialized_refnums_after_removed_dependency',
    status,
    'serialized_Lua_refnums_shift_after_dependency_removal',
    function(edit)
      return edit.operation == 'remap_content_file_index' and edit.subrecordType == 'LUAD'
    end
  )
  push(
    'rewrite_or_drop_lua_references_to_removed_dependency',
    'blocked',
    'serialized_Lua_refnums_point_at_removed_dependency',
    isBlockedLua
  )
  push(
    'rewrite_or_drop_content_file_refnum_references',
    'blocked',
    'known_FormId_fields_point_at_the_dependency_index_being_removed',
    isBlockedContentFile
  )
  push(
    'delete_stale_cell_state_for_removed_dependency',
    status,
    'saved_cell_state_references_a_removed_dependency_cell',
    function(edit)
      return edit.operation == 'delete_target_save_record' and edit.meaning == 'saved_cell_state'
    end
  )
  pushOperation(
    'delete_csta_reference_group',
    'delete_csta_reference_groups_for_removed_dependency',
    'saved_cell_references_point_at_the_dependency_index_being_removed'
  )
  pushOperation(
    'delete_moved_reference_group',
    'delete_moved_references_for_removed_dependency',
    'moved_reference_markers_point_at_the_dependency_index_being_removed'
  )
  pushOperation(
    'delete_inventory_item_group',
    'delete_inventory_items_for_removed_dependency',
    'inventory_items_reference_target_only_refids'
  )
  pushOperation(
    'delete_stolen_item_group',
    'delete_stolen_items_for_removed_dependency',
    'stolen_item_state_references_target_only_refids'
  )
  pushOperation(
    'clear_cell_ref_field',
    'clear_object_fields_for_removed_dependency',
    'object_owner_key_trap_or_global_references_target_only_refids'
  )
  pushOperation(
    'delete_ai_package',
    'delete_ai_packages_for_removed_dependency',
    'ai_packages_target_target_only_refids'
  )
  pushOperation(
    'delete_stale_state_field',
    'delete_stale_spell_and_script_state_for_removed_dependency',
    'spell_or_script_state_references_target_only_refids'
  )
  push(
    'delete_target_introduced_save_records',
    status,
    'save_records_reference_target_only_refids',
    function(edit)
      return edit.operation == 'delete_target_save_record' and edit.meaning ~= 'saved_cell_state'
    end
  )

  if references then
    local roles = {
      {
        'introduced_by_target',
        'delete_or_rewrite_target_introduced_refid_state',
        'blocked',
        'save_fields_reference_records_introduced_by_the_dependency',
      },

      {
        'target_only_unknown',
        'resolve_unknown_target_refid_provenance',
        'blocked',
        'earlier_dependencies_are_unresolved_so_target_ownership_is_not_proven',
      },

      {
        'overridden_by_target',
        'allow_overridden_refids_to_fallback',
        'expected',
        'save_fields_will_resolve_to_previous_load_order_definitions_after_dependency_removal',
      },
    }

    for _, entry in roles do
      local count = references.byRole[entry[1]] or 0
      if count > 0 then
        table.insert(
          operations,
          { name = entry[2], status = entry[3], count = count, reason = entry[4] }
        )
      end
    end
  end

  return operations
end

--[[ Applying and verifying ]]

local function need<T>(value: T?, message: string): T
  if value == nil then error(message, 0) end

  return value
end

--- Rewrites every Lua RefNum pointing at `old` to `new`; how many it rewrote.
local function remapLua(value: tes3.LuaValue, old: number, new: number): number
  local count = 0
  for _, entry in value.entries or {} do
    count += remapLua(entry.key, old, new) + remapLua(entry.value, old, new)
  end

  local ref = value.ref
  if ref and ref.contentFile == old then
    ref.contentFile = new
    count += 1
  end

  for _, reference in value.refs or {} do
    if reference.contentFile == old then
      reference.contentFile = new
      count += 1
    end
  end

  return count
end

--- A record's header (its tag, size, and flags), and a subrecord's (its tag and size).
local RecordHeader, SubrecordHeader = 16, 8

--- A record some of whose payloads are remapped: where its bytes are, its subrecords as they
--- were, and the payloads that take the place of the ones at these positions (0-based).
type Rewrite = {
  source: buffer,
  start: number,
  subs: { tes3.Subrecord },
  payloads: { [number]: buffer },
}

--- A record's bytes with a rewrite's payloads in place of the ones it had.
local function rewritten({source, start, subs, payloads}: Rewrite): buffer
  local length = sum[
    for ordinal, sub in enumerate(subs)
    => if payloads[ordinal - 1]
      then SubrecordHeader + buffer.len(payloads[ordinal - 1])
      else sub.finish - sub.start
  ]

  local out = buffer.create(RecordHeader + length)
  buffer.copy(out, 0, source, start, RecordHeader)
  local at = RecordHeader
  for ordinal, sub in subs do
    local payload = payloads[ordinal - 1]
    if not payload then
      buffer.copy(out, at, source, sub.start, sub.finish - sub.start)
      at += sub.finish - sub.start
      continue
    end

    buffer.copy(out, at, source, sub.start, 4)
    buffer.writeu32(out, at + 4, buffer.len(payload))
    buffer.copy(out, at + SubrecordHeader, payload)
    at += SubrecordHeader + buffer.len(payload)
  end

  return out
end

local function replacePayloads(plugin: Plugin, edits: { Edit })
  -- A LUAD payload gets one planned edit per RefNum in it, but one remap rewrites all of them.
  local remappedLua: { [string]: boolean } = {}
  -- A cell's record holds thousands of references to remap, and replacing a subrecord rebuilds
  -- its record: each record is rebuilt once, after the last of its remaps.
  local rewrites: { [number]: Rewrite } = {}
  local order: { number } = {}
  for _, edit in edits do
    if edit.status ~= 'planned' or edit.operation ~= 'remap_content_file_index' then continue end

    local record = need(edit.recordIndex, 'remap_content_file_index edit has no record index')
    local position =
      need(edit.subrecordIndex, 'remap_content_file_index edit has no subrecord index')
    local new = need(edit.newContentFileIndex, 'remap_content_file_index edit has no target index')
    if record >= plugin:count() then
      error('remap_content_file_index record index is out of bounds', 0)
    end

    local rewrite = rewrites[record]
    if not rewrite then
      local source, start = plugin:span(record)
      rewrite = { source = source, start = start, subs = plugin:subrecords(record), payloads = {} }
      rewrites[record] = rewrite
      table.insert(order, record)
    end

    local sub = rewrite.subs[position + 1]
    if not sub then error('remap_content_file_index subrecord index is out of bounds', 0) end

    -- The payload as it is now: a remap of this subrecord before this one has replaced it.
    local source, at, size = rewrite.source, sub.payload, sub.size
    local replaced = rewrite.payloads[position]
    if replaced then
      source, at, size = replaced, 0, buffer.len(replaced)
    end

    if sub.tag == 'LUAD' then
      local old =
        need(edit.oldContentFileIndex, 'remap_content_file_index LUAD edit has no source index')
      local key = `{record}:{position}:{old}`
      if remappedLua[key] then continue end

      remappedLua[key] = true
      -- decodeLuaData throws on a payload that isn't serialized Lua.
      local ok, value = pcall(tes3.save.decodeLuaData, source, at, size)
      if not ok then error(`failed to decode LUAD for remapping: {value}`, 0) end

      if remapLua(value :: tes3.LuaValue, old, new) == 0 then
        error('remap_content_file_index LUAD edit did not find the planned source index', 0)
      end

      rewrite.payloads[position] =
        buffer.fromstring(tes3.save.encodeLuaData(value :: tes3.LuaValue))
      continue
    end

    if size ~= 8 then
      error(`{plugin:tag(record)} {sub.tag} payload is not an 8-byte OpenMW FormId`, 0)
    end

    local payload = buffer.create(8)
    buffer.copy(payload, 0, source, at, 4)
    buffer.writei32(payload, 4, new)
    rewrite.payloads[position] = payload
  end

  for _, record in order do
    plugin:replaceBytes(record, rewritten(rewrites[record]))
  end
end

local function verifyRemapped(plugin: Plugin, edits: { Edit })
  -- Nothing here changes the save: a record's subrecords are listed once, and a LUAD payload's
  -- references read once, for however many remaps there are to look for in them.
  local listed: { [number]: { tes3.Subrecord } } = {}
  local references: { [tes3.Subrecord]: { tes3.LuaRef } } = {}
  for _, edit in edits do
    if edit.status ~= 'planned' or edit.operation ~= 'remap_content_file_index' then continue end

    local record = need(edit.recordIndex, 'remap_content_file_index edit has no record index')
    local position =
      need(edit.subrecordIndex, 'remap_content_file_index edit has no subrecord index')
    local localIndex = need(edit.localIndex, 'remap_content_file_index edit has no local index')
    local new = need(edit.newContentFileIndex, 'remap_content_file_index edit has no target index')
    if record >= plugin:count() then
      error('remap_content_file_index verification record index is out of bounds', 0)
    end

    local subs = listed[record]
    if not subs then
      subs = plugin:subrecords(record)
      listed[record] = subs
    end

    local sub = subs[position + 1]
    if not sub then
      error('remap_content_file_index verification subrecord index is out of bounds', 0)
    end

    local source = plugin:span(record)
    if sub.tag == 'LUAD' then
      local refs = references[sub]
      if not refs then
        -- decodeLuaData throws on a payload that isn't serialized Lua.
        local ok, value = pcall(tes3.save.decodeLuaData, source, sub.payload, sub.size)
        if not ok then error(`failed to decode remapped LUAD: {value}`, 0) end

        refs = tes3.save.luaRefs(value :: tes3.LuaValue)
        references[sub] = refs
      end

      local found = any[for ref in refs => ref.index == localIndex and ref.contentFile == new]
      if not found then error('dry-run remapped LUAD does not contain the planned RefNum', 0) end

      continue
    end

    local index, contentFile = Records.wideFormId(buffer.readstring(source, sub.payload, sub.size))
    if not index then error('dry-run remapped field is no longer an OpenMW FormId', 0) end

    if index ~= localIndex or contentFile ~= new then
      error('dry-run remapped field does not contain the planned FormId', 0)
    end
  end
end

--- EQIP and SELE point at inventory items by position (openmw inventorystate.cpp:149-163), so
--- removing items drops equipment on them and shifts later positions down.
local function renumberEquipment(
  plugin: Plugin,
  record: number,
  countAt: number,
  removed: { number }
)
  local gone: { [number]: boolean } = {}
  for _, position in removed do
    gone[position] = true
  end

  local function shifted(position: number): number
    local below = 0
    for _, other in removed do
      if other < position then
        below += 1
      end
    end

    return position - below
  end

  local snapshot = Records.record(plugin, record)
  -- This inventory's trailing subrecords run until the next object group or inventory.
  local finish = #snapshot.subs
  for subrecordIndex = countAt + 1, #snapshot.subs - 1 do
    local tag = Records.tagAt(snapshot, subrecordIndex)
    if tag == 'ICNT' or tag == 'OBJE' then
      finish = subrecordIndex
      break
    end
  end

  local replacements: { { number | string } } = {}
  for subrecordIndex = countAt + 1, finish - 1 do
    local tag = Records.tagAt(snapshot, subrecordIndex)
    local data = Records.payload(snapshot, subrecordIndex)
    if tag == 'EQIP' then
      if #data < 4 then error('EQIP payload is too short', 0) end

      local kept = {}
      local at = 5
      while at + 7 <= #data do
        local item = Records.u32At(data, at)
        if not gone[item] then table.insert(kept, { item, string.sub(data, at + 4, at + 7) }) end

        at += 8
      end

      local parts = { string.pack('<I4', #kept) }
      for _, pair in kept do
        table.insert(parts, string.pack('<I4', shifted(pair[1] :: number)) .. (pair[2] :: string))
      end

      table.insert(replacements, { subrecordIndex, table.concat(parts) })
    elseif tag == 'SELE' then
      if #data ~= 4 then error('SELE payload is not 4 bytes', 0) end

      local selected = Records.i32At(data)
      local rewritten = selected
      if selected >= 0 then rewritten = if gone[selected] then -1 else shifted(selected) end

      table.insert(replacements, { subrecordIndex, string.pack('<i4', rewritten) })
    end
  end

  for _, replacement in replacements do
    plugin:replaceSubrecord(record, replacement[1] :: number, replacement[2] :: string)
  end
end

local function updateInventoryCounts(plugin: Plugin, edits: { Edit })
  -- Deleted item positions (0-based, in save order) per inventory, by record and ICNT.
  type Removal = { record: number, countAt: number, removed: { number } }
  local removals: { [string]: Removal } = {}
  local order: { Removal } = {}
  -- The save isn't changed until every deletion has its inventory, so a record is read once.
  local snapshots: { [number]: Record } = {}
  for _, edit in edits do
    if edit.status ~= 'planned' or edit.operation ~= 'delete_inventory_item_group' then continue end

    local record = need(edit.recordIndex, 'delete_inventory_item_group edit has no record index')
    local start = need(edit.subrecordIndex, 'delete_inventory_item_group edit has no start index')
    if record >= plugin:count() then
      error('delete_inventory_item_group record index is out of bounds', 0)
    end

    local snapshot = snapshots[record]
    if not snapshot then
      snapshot = Records.record(plugin, record)
      snapshots[record] = snapshot
    end
    local countAt = need(
      Scan.inventoryCountFor(snapshot, start),
      'delete_inventory_item_group has no preceding ICNT'
    )
    -- Every inventory item group starts with FRMR, so its position is the FRMRs before it.
    local position = 0
    for subrecordIndex = countAt + 1, start - 1 do
      if Records.tagAt(snapshot, subrecordIndex) == 'FRMR' then
        position += 1
      end
    end

    local key = `{record}:{countAt}`
    local entry = removals[key]
    if not entry then
      entry = { record = record, countAt = countAt, removed = {} }
      removals[key] = entry
      table.insert(order, entry)
    end

    table.insert(entry.removed, position)
  end

  table.sort(order, function(left: Removal, right: Removal)
    if left.record ~= right.record then return left.record < right.record end

    return left.countAt < right.countAt
  end)

  for _, entry in order do
    renumberEquipment(plugin, entry.record, entry.countAt, entry.removed)
    local snapshot = Records.record(plugin, entry.record)
    local data = Records.payload(snapshot, entry.countAt)
    if #data ~= 4 then error('ICNT payload is not 4 bytes', 0) end

    local count = Records.u32At(data) - #entry.removed
    if count < 0 then error('inventory item deletion count exceeds ICNT', 0) end

    plugin:replaceSubrecord(entry.record, entry.countAt, string.pack('<I4', count))
  end
end

local SubrecordDeletions: { [string]: boolean } = {
  remove_tes3_master_dependency = true,
  remove_save_dependency = true,
  delete_csta_reference_group = true,
  delete_moved_reference_group = true,
  delete_inventory_item_group = true,
  delete_stolen_item_group = true,
  clear_cell_ref_field = true,
  delete_ai_package = true,
  delete_stale_state_field = true,
}

local function deleteSubrecords(plugin: Plugin, edits: { Edit })
  type Deletion = { record: number, start: number, finish: number, operation: string }
  local deletions: { Deletion } = {}
  for _, edit in edits do
    if edit.status ~= 'planned' then continue end

    local operation = edit.operation
    if operation == 'remap_content_file_index' or operation == 'delete_target_save_record' then
      continue
    end

    if not SubrecordDeletions[operation] then
      error(`planned edit operation '{operation}' has no dry-run executor`, 0)
    end

    local record = need(edit.recordIndex, `{operation} edit has no record index`)
    if operation == 'remove_save_dependency' then
      local position = need(edit.subrecordIndex, `{operation} edit has no subrecord index`)
      table.insert(
        deletions,
        { record = record, start = position, finish = position + 1, operation = operation }
      )
    else
      local start = need(edit.subrecordIndex, `{operation} edit has no start index`)
      local finish = need(edit.subrecordEndIndex, `{operation} edit has no end index`)
      table.insert(
        deletions,
        { record = record, start = start, finish = finish, operation = operation }
      )
    end
  end

  table.sort(deletions, function(left: Deletion, right: Deletion)
    if left.record ~= right.record then return left.record < right.record end

    if left.start ~= right.start then return left.start < right.start end

    return left.finish < right.finish
  end)

  local previousRecord, previousFinish = -1, 0
  -- How many subrecords each record has; nothing is deleted until every range is checked.
  local counts: { [number]: number } = {}
  for _, deletion in deletions do
    if deletion.start >= deletion.finish then
      error(`{deletion.operation} planned an empty subrecord deletion range`, 0)
    end

    if deletion.record >= plugin:count() then
      error(`{deletion.operation} record index is out of bounds`, 0)
    end

    local count = counts[deletion.record]
    if not count then
      count = #plugin:subrecords(deletion.record)
      counts[deletion.record] = count
    end

    if deletion.finish > count then
      error(`{deletion.operation} subrecord range is out of bounds`, 0)
    end

    if previousRecord == deletion.record and deletion.start < previousFinish then
      error('planned subrecord deletion ranges overlap', 0)
    end

    previousRecord, previousFinish = deletion.record, deletion.finish
  end

  local byRecord: { [number]: { number } } = {}
  local records = {}
  for _, deletion in deletions do
    local list = byRecord[deletion.record]
    if not list then
      list = {}
      byRecord[deletion.record] = list
      table.insert(records, deletion.record)
    end

    for position = deletion.start, deletion.finish - 1 do
      table.insert(list, position)
    end
  end

  for _, record in records do
    plugin:deleteSubrecords(record, byRecord[record])
  end
end

local function deleteRecords(plugin: Plugin, edits: { Edit })
  local set: { [number]: boolean } = {}
  for _, edit in edits do
    if edit.status == 'planned' and edit.operation == 'delete_target_save_record' then
      set[need(edit.recordIndex, 'delete_target_save_record edit has no record index')] = true
    end
  end

  local indices = {}
  for index in set do
    table.insert(indices, index)
  end

  table.sort(indices)
  for _, index in indices do
    if index >= plugin:count() then
      error('delete_target_save_record record index is out of bounds', 0)
    end

    local tag = plugin:tag(index)
    if tag == 'TES3' or tag == 'SAVE' then
      error('delete_target_save_record cannot delete TES3 or SAVE', 0)
    end
  end

  for slot = #indices, 1, -1 do
    plugin:delete(indices[slot])
  end

  -- OpenMW writes the exact count of records after TES3 (statemanagerimp.cpp:289-298); this also
  -- repairs saves an earlier strip left miscounted. updateRecordCount throws on a HEDR that doesn't
  -- read; that's the error to report.
  local ok, problem = pcall(plugin.updateRecordCount, plugin)
  if not ok then error(`failed to update the save's record count: {problem}`, 0) end
end

local function verifyResult(plugin: Plugin, before: { string }, index: number, dependency: string)
  local problems = Check.cstaMessages(plugin)
  if #problems > 0 then
    error(`OpenMW save CSTA semantic validation failed: {table.concat(problems, '; ')}`, 0)
  end

  -- profile throws on metadata that doesn't read.
  local ok, profile = pcall(tes3.save.profile, plugin)
  if not ok then error(`failed to read dry-run save metadata: {profile}`, 0) end

  local expected = {}
  for ordinal, name in before do
    if ordinal - 1 ~= index then table.insert(expected, name) end
  end

  local dependencies = (profile :: tes3.SaveProfile).dependencies
  local same = #dependencies == #expected
  for ordinal, name in expected do
    same = same and dependencies[ordinal] == name
  end

  if not same then
    error('dry-run dependency list does not match the planned SAVE.DEPE removal', 0)
  end

  -- masters throws on a header that doesn't read.
  local read, masters = pcall(plugin.masters, plugin)
  if not read then error(`failed to read dry-run TES3 masters: {masters}`, 0) end

  local list = masters :: { tes3.Master }
  if #list > 0 then
    local matches = #list == #expected
    for ordinal, master in list do
      matches = matches and master.name == expected[ordinal]
    end

    if not matches then
      error('dry-run TES3.MAST list does not match the planned dependency removal', 0)
    end
  end

  for _, name in dependencies do
    if string.lower(name) == string.lower(dependency) then
      error('dry-run dependency list still contains the removed dependency', 0)
    end
  end
end

type PostMutation = {
  status: string,
  reason: string,
  knownRemainingTargetRefids: number,
  invalidContentFileRefnums: number,
}

local function verifyPostMutation(
  plugin: Plugin,
  dependenciesAfter: number,
  provenance: Provenance?
): PostMutation
  local records = Records.all(plugin)
  local invalid = 0
  for _, hit in Scan.contentFileHits(records) do
    if hit.contentFile >= dependenciesAfter then
      invalid += 1
    end
  end

  local remaining = 0
  if provenance then
    for _, field in Scan.refIdFields(records) do
      if roleOf(provenance, field.id) == 'introduced_by_target' then
        remaining += 1
      end
    end
  end

  if invalid > 0 or remaining > 0 then
    error(
      `post-mutation verification failed: {remaining} target RefIds and {invalid} invalid content-file refs remain`,
      0
    )
  end

  return {
    status = 'verified',
    reason = 'no_known_removed_dependency_references_remain',
    knownRemainingTargetRefids = 0,
    invalidContentFileRefnums = 0,
  }
end

type Execution = {
  appliedEdits: number,
  bytesBefore: number,
  bytesAfter: number,
  bytes: buffer,
  post: PostMutation,
}

local function execute(
  plugin: Plugin,
  edits: { Edit },
  dependencies: { string },
  index: number,
  dependency: string,
  provenance: Provenance?
): Execution
  local before = plugin:save()
  local options: tes3.OpenOptions = { encoding = plugin.encoding, profile = plugin.profile }
  local mutated = tes3.open(before, options)
  replacePayloads(mutated, edits)
  mutated = tes3.open(mutated:save(), options)
  verifyRemapped(mutated, edits)
  updateInventoryCounts(mutated, edits)
  deleteSubrecords(mutated, edits)
  deleteRecords(mutated, edits)
  local bytes = mutated:save()
  -- tes3.open throws on bytes that don't frame.
  local ok, reparsed = pcall(function(): Plugin return tes3.open(bytes, options) end)
  if not ok then error(`dry-run produced an unparsable save: {reparsed}`, 0) end

  verifyResult(reparsed :: Plugin, dependencies, index, dependency)
  local post = verifyPostMutation(reparsed :: Plugin, #dependencies - 1, provenance)
  return {
    appliedEdits = #edits,
    bytesBefore = buffer.len(before),
    bytesAfter = buffer.len(bytes),
    bytes = bytes,
    post = post,
  }
end

--[[ Reports ]]

local function concernReport(concerns: { Concern }, spell: Spell): { { [string]: unknown } }
  local out: { { [string]: unknown } } = {}
  for _, concern in concerns do
    out[#out + 1] =
      { kind = spell(concern.kind), count = concern.count, action = spell(concern.action) }
  end

  return out
end

local function editReport(edit: Edit, spell: Spell): { [string]: unknown }
  return {
    operation = spell(edit.operation),
    status = spell(edit.status),
    recordIndex = edit.recordIndex,
    recordType = edit.recordType,
    subrecordIndex = edit.subrecordIndex,
    subrecordEndIndex = edit.subrecordEndIndex,
    subrecordType = edit.subrecordType,
    meaning = if edit.meaning then spell(edit.meaning) else nil,
    localIndex = edit.localIndex,
    oldContentFileIndex = edit.oldContentFileIndex,
    newContentFileIndex = edit.newContentFileIndex,
    reason = spell(edit.reason),
  }
end

--[[ Strip ]]

export type Mode = 'dryRun' | 'inMemory' | 'inPlace' | 'output'

export type StripOptions = {
  --- The load order the content files being removed are found through; without one, provenance
  --- is unavailable and every step is blocked.
  loadOrder: LoadOrder.LoadOrder?,
  --- Why the load order couldn't be had: each resolution's status says so.
  loadOrderError: string?,
  --- `dryRun` plans and verifies only; `inMemory` returns the stripped save; `inPlace` (the
  --- default with a path) writes over the save; `output` writes to `output`.
  mode: Mode?,
  output: string?,
  --- How many example records and references each scan keeps; 5 by default.
  sampleLimit: number?,
  --- Back up a file the strip writes over (the default).
  backup: boolean?,
  --- Spell the report's codes as jess-save's own reports do (`dry_run_only`, `in-place`) instead
  --- of camelCase: what anything that writes its files needs. Field names stay camelCase.
  originalCodes: boolean?,
}

--- Each mode as jess-save's reports name it.
local ModeNames: { [Mode]: string } =
  { dryRun = 'dry-run', inMemory = 'in-memory', inPlace = 'in-place', output = 'output' }

--- Removes `dependencies` from `save`, latest in the load order first. Every removal is applied and
--- verified in memory before anything is written; if any is blocked, nothing is written. Returns the
--- report and, when every removal was applied (not a dry run, nothing blocked), the stripped save.
local function strip(
  save: Save,
  dependencies: { string },
  options: StripOptions?
): ({ [string]: unknown }, Plugin?)
  Read.requireOpenMw(save, 'strip')
  local given: StripOptions = options or {}
  local mode: Mode = given.mode
    or (if given.output then 'output' elseif save.path then 'inPlace' else 'inMemory')
  local limit = given.sampleLimit or 5
  local spell: Spell = if given.originalCodes then asWritten else tes3.text.camelCase
  local order = given.loadOrder
  local encoding = save.plugin.encoding
  local openOptions: tes3.OpenOptions = { encoding = encoding, profile = save.plugin.profile }
  -- Plans index the save's current records, so start from its current bytes, edits included.
  -- tes3.open throws on bytes that don't frame; that's the error to report.
  local ok, opened = pcall(function(): Plugin return tes3.open(save.plugin:save(), openOptions) end)
  if not ok then error(`failed to parse '{save.name}': {opened}`, 0) end

  local plugin = opened :: Plugin
  -- profile throws on metadata that doesn't read; the error to report names the save.
  local read, profile = pcall(tes3.save.profile, plugin)
  if not read then error(`failed to read the save metadata of '{save.name}': {profile}`, 0) end

  local all = (profile :: tes3.SaveProfile).dependencies
  local requested: { [number]: boolean } = {}
  for _, name in dependencies do
    local found: number? = nil
    for ordinal, dependency in all do
      if string.lower(dependency) == string.lower(name) then
        found = ordinal
        break
      end
    end

    if not found then error(`save dependency '{name}' was not found`, 0) end

    requested[found] = true
  end

  local removal = {}
  for ordinal = #all, 1, -1 do
    if requested[ordinal] then table.insert(removal, all[ordinal]) end
  end

  local contentEncoding = order and order.encoding or encoding
  local resolutions: { [string]: Resolution } = {}
  for _, dependency in all do
    local resolution: Resolution
    if order then
      local path = order.resolve(dependency)
      resolution = if path
        then { status = 'resolved', path = path } :: Resolution
        else { status = 'missing' } :: Resolution
    elseif given.loadOrderError then
      resolution = { status = `unavailable: {given.loadOrderError}` } :: Resolution
    else
      resolution = { status = 'disabled' } :: Resolution
    end

    resolutions[string.lower(dependency)] = resolution
  end

  local target: string? = nil
  if mode == 'output' then
    target = need(given.output, 'output mode needs an output path')
    if save.path and target == save.path then
      error('save strip --output must differ from the input', 0)
    end
  elseif mode == 'inPlace' then
    target = need(save.path, 'this save has no path to strip in place')
  end

  local alsoRemoved: { [string]: boolean } = {}
  for _, name in dependencies do
    alsoRemoved[string.lower(name)] = true
  end

  -- Every content file is indexed once per strip, however many steps ask what it defines.
  local cache: LoadOrder.Cache = {}
  local ids = LoadOrder.pool()
  local steps = {}
  local applied = true
  -- Whether the last step couldn't be attempted, as its `mutationReadiness` reports: a strip stops
  -- at the first such step.
  local blocked = false
  for _, dependency in removal do
    local metadata = tes3.save.profile(plugin)
    local deps = metadata.dependencies
    local index = 0
    for ordinal, candidate in deps do
      if string.lower(candidate) == string.lower(dependency) then
        index = ordinal - 1
        break
      end
    end

    local stepResolutions: { Resolution } = {}
    for ordinal, name in deps do
      stepResolutions[ordinal] = resolutions[string.lower(name)]
        or { status = 'missing' } :: Resolution
    end

    local targetResolution = stepResolutions[index + 1]
    local others = table.clone(alsoRemoved)
    others[string.lower(dependency)] = nil
    local records = Records.all(plugin)
    local targetScan = if targetResolution.path and order
      then targetRecords(order, targetResolution.path, limit, contentEncoding)
      else nil
    local provenance = provenanceOf(
      records,
      order,
      deps,
      stepResolutions,
      index,
      others,
      contentEncoding,
      cache,
      ids
    )
    local format = formatSupport(metadata.formatVersion)
    local edits = plannedEdits(plugin, records, index, dependency, provenance)
    local references = if provenance then saveReferences(records, provenance, limit, spell) else nil
    local hits = Scan.contentFileHits(records)
    local fileReferences = contentFileReferences(hits, index, dependency, limit, spell)
    local coverage = Scan.coverage(records)
    local blockers = blockersOf(format, provenance, coverage, references, edits)
    local remapping = index + 1 < #deps
    local operations = operationsOf(remapping, references, edits, blockers)
    local readiness = readinessOf(format, provenance, blockers, coverage, edits)
    if not readiness.canAttemptDryRun and #blockers.hard == 0 then
      table.insert(
        blockers.hard,
        { kind = readiness.reason, count = 1, action = 'see_mutation_readiness' }
      )
      blockers.status = 'blocked'
    end

    local execution = if readiness.canAttemptDryRun
      then execute(plugin, edits, deps, index, dependency, provenance)
      else nil
    local dryRunRequested = mode == 'dryRun'
    local written = target ~= nil
    local dryRun: { [string]: unknown }
    if execution then
      dryRun = {
        requested = dryRunRequested,
        status = 'verified',
        reason = spell 'in_memory_mutation_reparsed_successfully',
        output = spell(if written then 'written_to_output' else 'in_memory_only'),
        appliedEdits = execution.appliedEdits,
        bytesBefore = execution.bytesBefore,
        bytesAfter = execution.bytesAfter,
        verification = 'reparsed',
        postMutationVerification = {
          status = spell(execution.post.status),
          reason = spell(execution.post.reason),
          knownRemainingTargetRefids = execution.post.knownRemainingTargetRefids,
          invalidContentFileRefnums = execution.post.invalidContentFileRefnums,
        },
      }
    elseif not dryRunRequested and not written then
      dryRun = {
        requested = false,
        status = spell 'not_requested',
        reason = spell 'dry_run_flag_not_set',
        output = 'none',
      }
    else
      dryRun = {
        requested = dryRunRequested,
        status = 'blocked',
        reason = spell(readiness.reason),
        output = 'none',
      }
    end

    local warnings = {}
    if provenance and provenance.targetMissing then
      table.insert(
        warnings,
        `'{dependency}' isn't installed, so its records are taken to be the ones the save refers to that no remaining content file defines`
      )
    end

    if next(coverage.unclassifiedRiskyRecords) then
      table.insert(
        warnings,
        'some LUAD payloads could not be decoded or contain unknown userdata; mutation is disabled until those references are classified'
      )
    end

    for _, entry in if provenance then provenance.unreadable else {} do
      table.insert(
        warnings,
        `could not read dependency '{entry[1]}' ({entry[2]}); records it defines are treated as unknown`
      )
    end

    local edited = {}
    for _, edit in edits do
      table.insert(edited, editReport(edit, spell))
    end

    local planned = {}
    for _, operation in operations do
      table.insert(planned, {
        name = spell(operation.name),
        status = spell(operation.status),
        count = operation.count,
        reason = spell(operation.reason),
      })
    end

    table.insert(steps, {
      dependency = dependency,
      mode = spell(ModeNames[mode]),
      dependencyIndex = index,
      dependenciesBefore = #deps,
      dependenciesAfter = #deps - 1,
      requiresContentFileIndexRemapping = remapping,
      saveFormat = {
        formatVersion = format.formatVersion,
        engineMinSupported = format.engineMinSupported,
        engineCurrent = format.engineCurrent,
        mutationStatus = spell(format.mutationStatus),
        reason = spell(format.reason),
      },
      targetResolution = targetResolution,
      targetRecords = targetScan,
      dependents = if provenance then provenance.dependents else {},
      saveReferences = references and references.report,
      contentFileReferences = fileReferences,
      referenceCoverage = {
        status = spell(coverage.status),
        knownScans = (function()
          local scans = {}
          for _, scan in coverage.knownScans do
            table.insert(scans, spell(scan))
          end

          return scans
        end)(),
        unclassifiedRiskyRecords = coverage.unclassifiedRiskyRecords,
      },

      blockers = {
        status = spell(blockers.status),
        hard = concernReport(blockers.hard, spell),
        informational = concernReport(blockers.informational, spell),
        protected = concernReport(blockers.protected, spell),
      },
      plannedOperations = planned,
      plannedEdits = edited,
      mutationReadiness = {
        status = spell(readiness.status),
        canAttemptDryRun = readiness.canAttemptDryRun,
        reason = spell(readiness.reason),
        referenceCoverage = spell(readiness.referenceCoverage),
      },
      dryRun = dryRun,
      mutation = if written and execution
        then 'written'
        elseif dryRunRequested then spell 'dry_run_only'
        else spell 'not_requested',
      warnings = warnings,
    })

    blocked = not readiness.canAttemptDryRun
    if not execution then
      applied = false
      break
    end

    -- tes3.open throws on bytes that don't frame.
    local reparsed, next = pcall(
      function(): Plugin return tes3.open(execution.bytes, openOptions) end
    )
    if not reparsed then
      error(`stripped save is unparsable after removing '{dependency}': {next}`, 0)
    end

    plugin = next :: Plugin
  end

  local written = nil
  if target and applied then
    -- Whatever is at the target, the input or an existing output, is backed up first.
    written = jess.fs.write(target, plugin:save(), { backup = given.backup ~= false })
  end

  local report = {
    input = if save.path then save.path else '<memory>',
    dependencies = removal,
    steps = steps,
    written = written,
    blocked = blocked,
  }
  return report, if mode ~= 'dryRun' and applied then plugin else nil
end

return table.freeze { strip = strip }
