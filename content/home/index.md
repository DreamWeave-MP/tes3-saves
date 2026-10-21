+++
title = "tes3-saves"
description = "Reads, strips and repairs Morrowind and OpenMW saves, verified in memory before anything is written, as a Jess package and command in Luau."
date = 2026-10-21

[taxonomies]
tags = ["Jess", "Luau", "OpenMW"]

[extra]
sections = ["overview", "releases", "credits"]
+++

Reads, strips and repairs Morrowind and OpenMW saves, verified in memory before anything is written, as a Jess package and command in Luau.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.tes3-saves`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.tes3-saves" = "0.1"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.
