# Perfy profiling

Temporary wiring for [Perfy](https://github.com/emmericp/Perfy), an instrumentation profiler
for WoW addons. It rewrites a *copy* of `src` with tracing calls and deploys that to the game;
the repo sources are never touched.

## Use

```powershell
.\scripts\Perfy\Perfy.ps1 Setup        # clone Perfy + FlameGraph, fetch lua-language-server into tools/
.\scripts\Perfy\Perfy.ps1 Instrument   # deploy an instrumented MiniAuras plus !!!Perfy to the PTR client
.\scripts\Perfy\Perfy.ps1 Analyze      # turn the last trace into flame graphs in tools/perfy-out
.\scripts\Perfy\Perfy.ps1 Restore      # put the clean install back and remove !!!Perfy
```

`Instrument` runs `Setup` for you. Every action takes `-Flavor _retail_` for a different client.

Only MiniAuras is instrumented, so only MiniAuras appears in a trace. Time it spends inside
another addon, or inside the client, is charged to whichever of our functions called out.

Restart the client after `Instrument` (toc changes are only read at startup), then in game:

```
/perfy start 30   trace for 30 seconds
/perfy stop       or stop it early
/reload           writes the trace to saved variables
```

Traces cost roughly 240 bytes per entry and garbage collection is off while running, so keep
runs to a minute or two. `/perfy clear` throws away what has been collected.

`Analyze` writes `stacks-cpu.txt`, `stacks-memory.txt`, and the matching SVG flame graphs to
`tools/perfy-out`. It prints the ten slowest frames first; to dig into one of those, pass the
analyzer's own flags through, e.g. `Perfy.ps1 Analyze --split-frames` for one graph per top
frame, or `Perfy.ps1 Analyze --frames 3-7`.

## Bursts

`Bursts.lua` answers the question the flame graph cannot: what does one call cost, and how much
work lands in a single frame. It reports the most expensive top-level calls, the entry points by
total time, and every function by its worst single call.

```powershell
cd tools\lua-language-server
.\bin\lua-language-server.exe ..\..\scripts\Perfy\Bursts.lua ..\Perfy\Analyzer `
  "D:\Games\World of Warcraft\_retail_\WTF\Account\<account>\SavedVariables\!!!Perfy.lua" 20
```

Perfy's own per-frame breakdown reports zero frames here, because its frame detector needs
several instrumented addons to bracket each frame and with one traced addon nearly every frame
holds only its marker. A burst is the stand-in: everything between an entering call on an empty
stack and its return, which the client cannot split across frames.

## Notes

* lua-language-server is pinned to 3.13.6. Perfy assigns to for-loop variables, which 3.14 and
  later reject.
* The deployed copy's toc gets `## Dependencies: !!!Perfy`, so MiniAuras will not load without
  Perfy enabled. `Restore` undoes that by putting the backup back.
* Reloading with a trace in saved variables throws a constant table size error. Expected, the
  data is only ever read by the analyzer.
* Everything the toc lists is instrumented, `Libs` included. The analyzer bills library time to
  the addon that called in, so MiniFramework and LibStub show up under MiniAuras.

The scripts stay in the repo. `tools/` does not: it is gitignored, and everything in it is
rebuilt by `Setup`, so delete it whenever the disk matters more than the next run's clone.
`tools/perfy-out` is the exception worth a look first, since it holds the last trace's flame
graphs.
