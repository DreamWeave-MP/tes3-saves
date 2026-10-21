# tes3-saves benchmarks

`bench/bench.jsl` times save tooling the way a tool reaches it, through `@tes3-saves`,
`@tes3-saves/commands`, and `@tes3-saves/cli`: opening a save and reading what it says of itself,
checking it against a load order, stripping a content file from it, and dumping it as values, as
text, and as byte layouts. The save is synthetic and seeded: 949 KB, 602 records, 39,419
subrecords. It holds 48 cell states (46 of a hundred objects and two of eight hundred, with
owners, locks, inventories, AI packages, and Lua data), the player with sixty items and their
equipment, dynamic records, global scripts, spell, projectile, and stolen-item state, 61 Lua
payloads of their own, and 300 journal records. Its four content files hold 8,242 records, and are
read from memory. A dump is asked for a page at a time, as the command line asks, without the
collection the command line runs between pages.

Each workload is warmed up, sized to a batch of about a tenth of a second, and reported as the
median of seven batches with a full collection between them. What each call returns is checked
outside the time, before the batches and after them: a check by the CRC of its report, a strip by
the CRC of its report and of the stripped save's bytes, a dump by the CRC of its text. The bench
stops if one is wrong.

```sh
jess run --package jpk/tes3-saves --package-path jpk --capability filesystem.read \
  --capability filesystem.write jpk/tes3-saves/bench/bench.jsl <scratch folder> [filter]
```

## The move onto l3i 2.0, base against head

- Machine: Intel Core i7-10870H @ 2.20 GHz, 16 threads, shared with other work while this ran.
- Date: 2026-10-12.
- Binary: the verified release build of Jess 0.1.0 on l3i 2.0.1 (Luau 0.742), the same one for
  both sides.
- Base: `f4e3cd4`, the package before the move, with this bench. Head: `0825fea`.
- Protocol: the whole bench run against base, then head, three times over, back to back under
  one lock; each cell is the median of its three runs. A difference under 5 percent is called no
  change.

| Workload | Base, ms | Head, ms | Base / head |
|---|---:|---:|---:|
| open a save | 0.293 | 0.297 | no change |
| info | 0.006 | 0.006 | no change |
| validate | 7.557 | 5.164 | 1.46x |
| decode every Lua payload | 7.988 | 5.376 | 1.49x |
| check against the load order | 29.265 | 19.783 | 1.48x |
| check against a load order without Tribunal.esm | 28.665 | 19.278 | 1.49x |
| strip Tribunal.esm | 2442.648 | 76.596 | 31.89x |
| strip Tribunal.esm, which is not installed | 2420.988 | 75.154 | 32.21x |
| strip Mod.esp, the last content file | 290.504 | 56.927 | 5.10x |
| plan a strip of Bloodmoon.esm, which is blocked | 535.930 | 35.731 | 15.00x |
| tree of every record | 73.452 | 53.061 | 1.38x |
| values of every record | 84.266 | 63.198 | 1.33x |
| dump as YAML | 442.951 | 281.529 | 1.57x |
| dump as JSON | 186.557 | 149.428 | 1.25x |
| dump the byte layout as JSON | 222.717 | 117.758 | 1.89x |
| dump the byte layout as YAML | 454.888 | 199.331 | 2.28x |
| list every record | 3.269 | 1.737 | 1.88x |
| list the records whose id matches a pattern | 1.259 | 1.131 | 1.11x |
| extract the cell states | 1.017 | 1.076 | 0.95x |

What moved, and why:

- **A strip** (32x for a content file in the middle of the load order, 15x for a plan that is
  blocked, 5.1x for the last content file). Almost all of it was work done over and over, and
  grew with the square of the save. A plan asked of every field and reference whether an edit
  already deleted it by looking through every edit so far; it now keeps what its edits delete by
  record and subrecord. Applying a plan replaced one subrecord at a time, each replacement
  rebuilding its record and each step listing the record's subrecords again: a cell's record
  with a thousand references to renumber was rebuilt a thousand times. A record is now rebuilt
  once for all of its remaps, once for the inventories renumbered in it, and once for what is
  deleted from it, from its own bytes. A step reads the save's ids and references once where it
  read them two and three times, and a report's codes are spelled in camelCase once each
  instead of once for every edit.
- **Checks, validation, and Lua data** (1.5x), and part of everything else that walks a save. A
  record's subrecords were listed as a table apiece, six fields each. They're now two columns:
  the tags, and a buffer of offsets that `bytes.frame` fills in one native call per record. An
  id and a FormId are read from the record's bytes where they lie, without the payload being
  made a string first, and a record without Lua data is passed over without being listed.
- **Dumps** (YAML 1.6x, JSON 1.25x, byte layouts 1.9x and 2.3x, a listing 1.9x). The text of a
  dump was the cost. A key, a field name, a tag, or an id was spelled from scratch every time it
  was written (pattern matches to decide a YAML scalar is plain, a substitution to turn a field
  name to snake_case, a search for a character JSON escapes); the spellings of short strings are
  now kept, a bounded number of them. A whole number was written with `%.0f`, and is now written
  by Luau's own printing, which is the same digits under 2^53 and several times faster. A float's
  shortest spelling was searched for by writing it out at one digit, two, three, and reading
  each back; exact arithmetic now tells beforehand which counts of digits have no decimal near
  enough to read back, and only the others are written out (29 million f32s and doubles were
  checked to spell the same). A subrecord's value is made from the record's bytes with fewer
  tables.
- **The comprehensions, reducers, slices, and record patterns** the loops became lower to the
  loops they replaced, and no row moved on their account.

What did not move: `open a save` and `info` are `@esm`'s framing and its SAVE record, and the
extraction is a file read and a copy. The extraction read 5 percent slower in the three rounds
above, 60 microseconds on a millisecond. Seven more rounds of that workload alone, base and head
in turn under one lock, put the medians at 1.117 ms and 1.119 ms: no change.

What is left, and isn't this package's to change: a YAML scalar that isn't plainly safe goes
through `@jess/data/value`'s encoder at about 8.8 microseconds a call, and each of this dump's
9,084 references (`123 (Morrowind.esm)`) is one, which is about 80 of the YAML dump's 282 ms. A
float of a JSON dump goes through that module's `shortest` at about 1.3 microseconds, and this
dump has 40,000, which is about 53 of the JSON dump's 149 ms.

## Which modules are native, and why

Jess compiles to machine code only what is marked (`--!native` on a module, `@native` on one
function), and every load pays for what is marked. A module carries `--!native` when a row below
spends its time there and the module is small (12 KB or less); a larger module carries `@native`
on the functions the row spends its time in, and nothing else.

Measured 2026-10-15 with `jess 0.1.0`, the verified release build of jess `07c38cb` on l3i
2.0.3, on the i7-10870H, the one-minute load 1.43 and 1.14 at the start of the two
sessions. In each session the bench ran alternately on this package and on a copy of it with
every module marked, three fresh runs of `bench/bench.jsl` each, every run's row the median of
its batches; a column is the median of the three, and a ratio is against the all-marked runs of
the same session. Which functions a row spends its time in comes from `jess run --profile` of
that row alone, unmarked. The load cost is a fresh `jess run --package <this package>
--package-path jpk` of a script that only requires `@tes3-saves`, the two sides alternating, the
median of five each after one warm-up.

| Requiring `@tes3-saves` | All marked | This state |
| --- | ---: | ---: |
| Unmarked | 0.169 s | 0.127 s |
| Final | 0.132 s | 0.119 s |

| Row | All marked (ms) | Unmarked / all marked | Final (ms) | Final / all marked |
| --- | ---: | ---: | ---: | ---: |
| open a save | 0.2713 | 1.017× | 0.2665 | 0.982× |
| info | 0.00804 | **1.056×** | 0.00785 | 0.976× |
| validate | 4.953 | **2.035×** | 4.969 | 1.003× |
| decode every Lua payload | 5.131 | **1.477×** | 4.908 | 0.956× |
| check against the load order | 18.65 | **1.936×** | 18.24 | 0.978× |
| check against a load order without Tribunal.esm | 18.27 | **1.952×** | 17.81 | 0.975× |
| strip Tribunal.esm | 72.47 | **1.775×** | 79.53 | **1.097×** |
| strip Tribunal.esm, which is not installed | 70.54 | **1.769×** | 75.11 | **1.065×** |
| strip Mod.esp, the last content file | 56.00 | **1.843×** | 57.29 | 1.023× |
| plan a strip of Bloodmoon.esm, which is blocked | 34.25 | **1.697×** | 36.54 | **1.067×** |
| tree of every record | 53.68 | **1.640×** | 52.08 | 0.970× |
| values of every record | 64.38 | **1.657×** | 60.89 | 0.946× |
| dump as YAML | 261.6 | **1.390×** | 253.8 | 0.970× |
| dump as JSON | 142.8 | **1.418×** | 137.7 | 0.964× |
| dump the byte layout as JSON | 109.0 | **1.568×** | 111.9 | 1.027× |
| dump the byte layout as YAML | 186.0 | **1.337×** | 186.9 | 1.005× |
| list every record | 1.723 | **1.340×** | 1.703 | 0.988× |
| list the records whose id matches a pattern | 1.112 | **1.139×** | 1.065 | 0.957× |
| extract the cell states | 0.9535 | **1.073×** | 0.9456 | 0.992× |

What carries the directive (every module and function here is one a row spends its time in,
unmarked):

- Whole: `check`, `commands`, `dumptext`, `layout`, `loadorder`, `read`, `records`, `scan`,
  `select`, `values`.
- `render`, by function: `fieldsOf`, `yamlLayout`, `jsonSubrecords`, `records`.
- Unmarked: `cli`, `init`, `main`, `strip`.

Marked by function first, the dumps, the record tree and values, and the strips stayed 1.07x to
1.21x slower than all marked, the time between the marked functions and the rest of each module
being most of what was left; so the modules those rows spend time in are marked whole, and this
state saves 0.013 s a load where by function saved 0.020 s. `cli` and `main` parse a command line
once a run and are never marked. The three rows still above 5% are the strips (1.065x to 1.097x),
whose profiles never put `strip` itself above 3% of their time: what they spend is in the modules
marked here, and what remains sits at the edge of this protocol's noise (two all-marked copies of
dream-archive, measured the same way, put 10 of 109 rows more than 5% apart, the 95th percentile
at 1.074x).
