--!strict
--!native
-- SPDX-License-Identifier: MIT OR Apache-2.0

--[[
The load order a save is checked or stripped against: the active content files (and where each is
on disk), how a content file name resolves through the data folders, and the code page content is
read in. `fromOpenMw` makes one from an `@openmw` Context; scripts that hold the files
some other way build one themselves.
]]

local intern = require '@dream/intern'
local tes3 = require '@tes3'

export type Content = { name: string, path: string? }

export type LoadOrder = {
  --- The active content files, in load order.
  content: { Content },
  --- The file a content name resolves to through the data folders, or nil.
  resolve: (name: string) -> string?,
  --- A resolved file's bytes; `jess.fs.readBuffer` when missing.
  read: ((path: string) -> (string | buffer)?)?,
  --- The code page content is read in (the config's `encoding=`); the save's when nil.
  encoding: string?,
}

--- What `fromOpenMw` uses of an `@openmw` Context, named here so reading saves doesn't depend on
--- the VFS and archives behind one. `Self` is the whole Context: its methods take it as their
--- receiver, and the checker rejects a Context where they are declared to take anything narrower.
type Context<Self> = {
  read encoding: string?,
  read content: (self: Self) -> { Content },
  read resolve: (self: Self, path: string) -> string?,
}

--- The load order an `@openmw` Context describes. A content file is a loose file at the top of a
--- data folder, and the Context resolves its name to that file, so it is read as the file it is:
--- the Context's own read goes through its whole VFS, archives and all, which a load order has no
--- use for.
local function fromOpenMw<Self>(context: Self & Context<Self>): LoadOrder
  return {
    content = context:content(),
    resolve = function(name: string): string? return context:resolve(name) end,
    read = function(path: string): buffer? return jess.fs.readBuffer(path) end,
    encoding = context.encoding,
  }
end

--- Reads and opens the content file at `path` in `encoding`, or says why it couldn't, as
--- jess-save's `read_content_file` does; and with the plugin, the file's size. The plugin holds
--- the whole file; whoever opens one lets it go as soon as it has what it came for (`letGo`).
local function openContent(
  order: LoadOrder,
  path: string,
  encoding: string
): (tes3.Plugin?, string?, number)
  local reader = order.read
  local bytes = if reader then reader(path) else jess.fs.readBuffer(path)
  if not bytes then
    return nil, `failed to read '{path}': No such file or directory (os error 2)`, 0
  end

  local size = if type(bytes) == 'string' then #bytes else buffer.len(bytes)

  -- tes3.open throws on a file that doesn't frame; that's the reason.
  local ok, opened = pcall(
    function(): tes3.Plugin return tes3.open(bytes, { encoding = encoding }) end
  )
  if not ok then return nil, `failed to parse '{path}': {opened}`, size end

  return opened :: tes3.Plugin, nil, size
end

--- How many bytes of content files have been let go since the last collection, and how many it
--- takes to run one.
local released = 0
local CollectEvery = 8 * 1024 * 1024

--- Says a content file of `size` bytes has been read and let go. A load order's files are far
--- more than a check or a strip keeps of them, and the collector doesn't know a master's bytes
--- are garbage until it next runs, by which time several masters' are; so once enough has been
--- let go, a collection is run. Call it once nothing still refers to the plugin.
local function letGo(size: number)
  released += size
  if released < CollectEvery then return end

  released = 0
  jess.bench.collect()
end

export type Pool = dream_intern_Pool

--- A pool for one check or strip: ids compare as jess-save compares them, ASCII case ignored and
--- every other byte exact, in the content files' code page.
local function pool(): Pool return intern.new 'ascii-nocase' end

export type Ids = {
  --- Each record's id as a token of the pool, or false for one without (record `index` at
  --- `index + 1`).
  tokens: { number | false },
  --- Each record's type, as a number.
  codes: { number },
}

--- Every record's id (interned in `ids`, straight from the file's bytes: no string is made) and
--- type in a content file.
local function ids(plugin: tes3.Plugin, ids: Pool): Ids
  local count = plugin:count()
  local tokens: { number | false }, codes: { number } = {}, {}
  for index = 0, count - 1 do
    local source, at, length = tes3.records.idSpan(plugin, index)
    tokens[index + 1] = if source then ids:intern(source, at, length) else false
    codes[index + 1] = plugin:code(index)
  end

  return { tokens = tokens, codes = codes }
end

--- What a strip keeps of a content file once it has read it: every record's id and type, and
--- the masters the file names, or why its header doesn't give them.
export type Index = { ids: Ids, masters: { string }?, mastersProblem: string? }

--- Content files already indexed, by path and code page, and why the ones that didn't open didn't.
export type Cache = { [string]: { index: Index?, problem: string? } }

local function indexOf(
  order: LoadOrder,
  path: string,
  encoding: string,
  pool: Pool
): (Index?, string?, number)
  local plugin, problem, size = openContent(order, path, encoding)
  if not plugin then return nil, problem, size end

  local names: { string }? = nil
  -- masters throws on a header that doesn't read; whoever asks for the masters is told why.
  local ok, masters = pcall(plugin.masters, plugin)
  if ok then names = [for master in masters :: { tes3.Master } => master.name] end

  return {
    ids = ids(plugin, pool),
    masters = names,
    mastersProblem = if ok then nil else tostring(masters),
  },
    nil,
    size
end

--- The index of the content file at `path` read in `encoding`, its ids interned in `pool`, or
--- why the file couldn't be opened; each path and code page is read once for a cache. The file
--- itself is let go as soon as it is indexed: a load order is read one file at a time, and only
--- the indexes are kept.
local function index(
  order: LoadOrder,
  path: string,
  encoding: string,
  pool: Pool,
  cache: Cache
): (Index?, string?)
  local key = `{encoding}\0{path}`
  local found = cache[key]
  if found then return found.index, found.problem end

  local made, problem, size = indexOf(order, path, encoding, pool)
  cache[key] = { index = made, problem = problem }
  letGo(size)
  return made, problem
end

--- The token of an id a save holds (UTF-8) among content ids read in `encoding`, or nil when no
--- content id is spelled that way; `add` interns it. An id the code page can't spell is no content
--- file's, and a NUL before it keeps it apart from every id one can (no content id holds a NUL).
local function token(ids: Pool, id: string, encoding: string, add: boolean?): number?
  local encoded = tes3.text.encode(id, encoding)
  local key = encoded or '\0' .. id
  if add then return ids:intern(key) end

  return ids:find(key)
end

return table.freeze {
  fromOpenMw = fromOpenMw,
  ids = ids,
  index = index,
  letGo = letGo,
  openContent = openContent,
  pool = pool,
  token = token,
}
