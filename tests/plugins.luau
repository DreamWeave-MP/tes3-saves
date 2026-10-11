--!strict
--!native
-- The plugin byte builders the save fixtures and cases use, copied from tes3cmd's suite
-- (`tests/fixtures.luau` there), which spells the synthetic plugins of jess's CLI tests
-- (`libs/cli/tests/common/mod.rs`, `libs/cli/tests/plugin.rs`) the same way.

local function u32(value: number): string return string.pack('<I4', value) end

local function f32(value: number): string return string.pack('<f', value) end

local function subrecord(tag: string, payload: string): string
  return tag .. u32(#payload) .. payload
end

local function record(tag: string, payload: string, flags: number?): string
  return tag .. u32(#payload) .. u32(0) .. u32(flags or 0) .. payload
end

local function fixed(text: string, length: number): string
  return text .. string.rep('\0', length - #text)
end

local function hedr(count: number, fileType: number?): string
  return subrecord(
    'HEDR',
    f32(1.3) .. u32(fileType or 0) .. fixed('test', 32) .. fixed('synthetic', 256) .. u32(count)
  )
end

local function masterEntry(name: string, size: number): string
  return subrecord('MAST', name .. '\0') .. subrecord('DATA', string.pack('<I8', size))
end

local function header(count: number, masters: { { name: string, size: number } }?): string
  local parts = { hedr(count) }
  for _, master in masters or {} do
    table.insert(parts, masterEntry(master.name, master.size))
  end

  return record('TES3', table.concat(parts))
end

local function plugin(records: { string }, masters: { { name: string, size: number } }?): string
  return header(#records, masters) .. table.concat(records)
end

return table.freeze {
  fixed = fixed,
  hedr = hedr,
  masterEntry = masterEntry,
  plugin = plugin,
  record = record,
  subrecord = subrecord,
  u32 = u32,
}
