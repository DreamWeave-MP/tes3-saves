--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
@tes3-saves/commands: what each `tes3-saves` command does, as a function of one request to one
result.

  info(request)        the save's character, place, time, and the content files it needs
  check(request)       whether the save is sound, and what it needs that a load order lacks
  strip(request)       content files removed from the save, or the plan when they can't be
  screenshot(request)  the save's screenshot, written as an image file
  dump(request)        records as readable values, a listing, their byte layout, or extracted

A request is plain data: the save's path, what to do, and options. A result is plain data too,
tagged with its `command`: everything the command learned, the file it wrote, and the backup it
kept. Nothing here reads an argument list, the environment, or standard input, prints, or lays
text out for a terminal; a front end with no terminal gets all of it from the result.

A save is named by its path, read in `encoding` (win1252 without one), and taken as whichever
game wrote it unless `game` insists on one. What a command found is in its result: a check's
verdict and findings, a strip that is blocked and why. A request that can't be carried out at all
raises: a file that isn't there or isn't a save, a configuration that can't be loaded, a content
file the save doesn't list, a pattern that isn't a regex, an output that is the input.

`check` and `strip` take `config`: an openmw.cfg, or the folder holding one. It is the load order
the save is compared with and the removed content files are found through. Without one, a check
looks at the save alone and a strip can't tell which records came from the file it removes. There
is no default configuration.

Every command that writes takes `output` (where to write), `backup` (false to replace a file
without copying it to `.bak`, `.bak1`, ... first), and `dryRun` (do the work in memory and say
what would be written, writing nothing). Its result says what was `written`: nothing for a dry
run, or for a strip that was blocked.
]]

local Check = require './check'
local Layout = require './layout'
local LoadOrder = require './loadorder'
local Read = require './read'
local Select = require './select'
local Strip = require './strip'
local Values = require './values'
local fs = require '@dream/fs'
local openmw = require '@openmw'
local tes3 = require '@tes3'

export type Game = Read.Game
export type Encoding = 'win1250' | 'win1251' | 'win1252'
export type SelectorSpec = Select.Spec

--- A file a command wrote, and the copy it kept of the file that was there.
export type Written = { path: string, backup: string? }

--- What every request says of the save it is about.
type Input = { path: string, game: Game?, encoding: Encoding? }

local function open(request: Input): Read.Save
  return Read.open(request.path, { game = request.game, encoding = request.encoding })
end

--[[ The load order ]]

--- The openmw.cfg `config` names: the file itself, or the one in the folder, under any
--- capitalization.
local function configuration(config: string): string
  local info, problem = fs.stat(config)
  if not info then
    if problem then error(`failed to read the OpenMW configuration '{config}': {problem}`, 0) end

    error(`the OpenMW configuration '{config}' doesn't exist`, 0)
  end

  if info.isFile then return config end

  if not info.isDir then
    error(`the OpenMW configuration '{config}' isn't a file or a folder`, 0)
  end

  local names, listProblem = fs.list(config)
  if not names then
    error(`failed to list the OpenMW configuration folder '{config}': {listProblem}`, 0)
  end

  for _, name in names do
    if string.lower(name) == 'openmw.cfg' then return jess.fs.join(config, name) end
  end

  return error(`the folder '{config}' has no openmw.cfg`, 0)
end

--- The load order of the configuration `config` names, and the openmw.cfg it was read from; nil
--- without one.
local function loadOrder(config: string?): (LoadOrder.LoadOrder?, string?)
  if not config then return nil, nil end

  local path = configuration(config)
  -- openmw.new raises on a configuration chain it can't read or parse; the error names the
  -- configuration with why.
  local loaded, context = pcall(openmw.new, path)
  if not loaded then error(`failed to load the OpenMW configuration '{path}': {context}`, 0) end

  return LoadOrder.fromOpenMw(context :: openmw.Context), path
end

--[[ info ]]

export type InfoRequest = Input

export type InfoResult = { command: 'info', path: string, info: Read.Info }

local function info(request: InfoRequest): InfoResult
  return { command = 'info', path = request.path, info = Read.info(open(request)) }
end

--[[ check ]]

export type CheckRequest = Input & {
  --- An openmw.cfg or its folder: the load order to check against. Without one only the save's
  --- own structure is checked.
  config: string?,
}

export type CheckResult = {
  command: 'check',
  path: string,
  --- The openmw.cfg the load order was read from.
  config: string?,
  --- The verdict, what is missing, and each finding; `check.loads` says whether OpenMW would load
  --- the save.
  check: Check.Check,
}

local function check(request: CheckRequest): CheckResult
  local save = open(request)
  Read.requireOpenMw(save, 'check')
  local order, config = loadOrder(request.config)
  return {
    command = 'check',
    path = request.path,
    config = config,
    check = Check.check(save, { loadOrder = order }),
  }
end

--[[ strip ]]

export type StripRequest = Input & {
  --- Content files to remove, by name as the save lists them, in any order.
  dependencies: { string },
  --- An openmw.cfg or its folder: where the content files are found, to tell which of the save's
  --- records came from the ones removed.
  config: string?,
  --- Write the stripped save here instead of over the save.
  output: string?,
  --- False replaces the save, or a file already at `output`, without backing it up.
  backup: boolean?,
  --- Plan and verify in memory, and write nothing.
  dryRun: boolean?,
  --- How many example records and references each part of the plan lists; 5 without one.
  sampleLimit: number?,
}

export type StripResult = {
  command: 'strip',
  path: string,
  config: string?,
  dryRun: boolean,
  --- Whether a removal was refused. Nothing is written then, and the last step's `blockers` and
  --- `mutationReadiness` say why.
  blocked: boolean,
  --- The stripped save, and the backup of the file it replaced; nil for a dry run or a blocked
  --- strip.
  written: Written?,
  --- The plan as `@tes3-saves`'s `strip` reports it: `input`, the `dependencies` in the order
  --- they were removed, and one of `steps` for each, with what refers to the content file, what
  --- blocks its removal, every edit, and the result of applying them in memory.
  report: { [string]: unknown },
}

--- What a strip's report says it wrote.
local function writtenOf(value: unknown): Written?
  if type(value) ~= 'table' then return nil end

  local fields = value :: { [string]: unknown }
  local path, backup = fields.path, fields.backup
  if type(path) ~= 'string' then return nil end

  return { path = path, backup = if type(backup) == 'string' then backup else nil }
end

local function strip(request: StripRequest): StripResult
  local save = open(request)
  Read.requireOpenMw(save, 'strip')
  local order, config = loadOrder(request.config)
  local dryRun = request.dryRun == true
  local mode: Strip.Mode = if dryRun
    then 'dryRun'
    elseif request.output then 'output'
    else 'inPlace'
  local report = Strip.strip(save, request.dependencies, {
    loadOrder = order,
    mode = mode,
    output = request.output,
    sampleLimit = request.sampleLimit,
    backup = request.backup,
  })

  return {
    command = 'strip',
    path = request.path,
    config = config,
    dryRun = dryRun,
    blocked = report.blocked == true,
    written = writtenOf(report.written),
    report = report,
  }
end

--[[ screenshot ]]

export type ScreenshotRequest = Input & {
  --- Where to write the image. Without it, beside the save, under the save's name with `.jpg` or
  --- `.tga` for its extension.
  output: string?,
  --- False replaces a file already there without backing it up.
  backup: boolean?,
  --- Say what would be written and write nothing.
  dryRun: boolean?,
}

export type ScreenshotResult = {
  command: 'screenshot',
  path: string,
  --- A JPEG as OpenMW stored it, or a TGA made of a Morrowind save's pixels.
  format: 'jpeg' | 'tga',
  --- The image file's size.
  bytes: number,
  --- Where the image goes.
  output: string,
  dryRun: boolean,
  written: Written?,
}

--- `path` with its file name's extension replaced by `extension`, or given one.
local function withExtension(path: string, extension: string): string
  local name = jess.fs.fileName(path) or path
  local stem = string.match(name, '^(.+)%.[^.]*$') or name
  return `{string.sub(path, 1, #path - #name)}{stem}.{extension}`
end

local function screenshot(request: ScreenshotRequest): ScreenshotResult
  local image, format = Read.screenshot(open(request))
  local output = request.output
    or withExtension(request.path, if format == 'jpeg' then 'jpg' else format)
  local dryRun = request.dryRun == true
  local written: Written? = nil
  if not dryRun then
    written = jess.fs.write(output, image, { backup = request.backup ~= false })
  end

  return {
    command = 'screenshot',
    path = request.path,
    format = format,
    bytes = buffer.len(image),
    output = output,
    dryRun = dryRun,
    written = written,
  }
end

--[[ dump ]]

export type DumpRequest = Input & {
  --- Which records; all of them without any.
  selectors: SelectorSpec?,
  --- Only each record's number, type, and id; with `raw`, each record's layout without its
  --- subrecords.
  list: boolean?,
  --- Each record's byte layout instead of its values.
  raw: boolean?,
  --- Write the selected records, byte for byte, to this file instead of describing them.
  rawOutput: string?,
  --- With `rawOutput`, start the file with the save's TES3 header, its record count updated.
  header: boolean?,
  --- With `rawOutput`, false replaces a file already there without backing it up.
  backup: boolean?,
  --- With `rawOutput`, say what would be written and write nothing.
  dryRun: boolean?,
}

export type Listed = { record: number, type: string, id: string? }

--- A record's byte layout, with its CELL references when instance filters select them.
export type RecordLayout = Layout.RecordLayout & { references: { Layout.ReferenceLayout }? }

export type DumpResult = {
  command: 'dump',
  path: string,
  --- What was asked for, and so which of the fields below is set: `records` (readable values),
  --- `list` (`listed`), `layout` (`layouts`), or `extract` (`bytes`, `output`, `written`).
  mode: 'records' | 'list' | 'layout' | 'extract',
  --- Each selected record's readable value as a tree: `@tes3-saves`'s `tree`.
  records: { Values.Node }?,
  listed: { Listed }?,
  layouts: { RecordLayout }?,
  --- The size of the extracted file.
  bytes: number?,
  output: string?,
  dryRun: boolean?,
  written: Written?,
}

local CellTag = tes3.tags.code 'CELL'

local function dump(request: DumpRequest): DumpResult
  local path = request.path
  local save = open(request)
  local plugin = save.plugin
  local selector = Select.new(request.selectors)
  local output = request.rawOutput
  if output then
    local bytes = Layout.extractMatching(plugin, selector, request.header == true)
    local written: Written? = nil
    if not request.dryRun then
      written = jess.fs.write(output, bytes, { backup = request.backup ~= false })
    end

    return {
      command = 'dump',
      path = path,
      mode = 'extract',
      bytes = buffer.len(bytes),
      output = output,
      dryRun = request.dryRun == true,
      written = written,
    }
  end

  if request.raw then
    local instances = not request.list and Select.hasInstanceFilters(selector)
    local layouts: { RecordLayout } = {}
    for index = 0, plugin:count() - 1 do
      if not Select.matchesRecord(selector, plugin, index) then continue end

      local layout: RecordLayout =
        Layout.layout(plugin, index, selector, { subrecords = not request.list, fields = true })
      if instances and plugin:code(index) == CellTag then
        layout.references = Layout.references(plugin, index, selector, true)
      end

      table.insert(layouts, layout)
    end

    return { command = 'dump', path = path, mode = 'layout', layouts = layouts }
  end

  -- A save's readable dump picks whole records: subrecord and instance filters narrow a layout
  -- or an extraction, and say nothing here, as jess-save's dump had it.
  local indices: { number } = {}
  for index = 0, plugin:count() - 1 do
    if Select.matchesRecord(selector, plugin, index) then table.insert(indices, index) end
  end

  if request.list then
    local listed: { Listed } = {}
    for _, index in indices do
      local id = tes3.records.id(plugin, index)
      table.insert(listed, {
        record = index,
        type = plugin:tag(index),
        id = if id and id ~= '' then id else nil,
      })
    end

    return { command = 'dump', path = path, mode = 'list', listed = listed }
  end

  return { command = 'dump', path = path, mode = 'records', records = Values.tree(save, indices) }
end

export type Result = InfoResult | CheckResult | StripResult | ScreenshotResult | DumpResult

return table.freeze {
  check = check,
  dump = dump,
  info = info,
  screenshot = screenshot,
  strip = strip,
}
