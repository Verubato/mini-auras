[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("Setup", "Instrument", "Analyze", "Restore")]
    [string] $Action = "Instrument",

    [string] $WowPath = "D:\Games\World of Warcraft",
    [string] $Flavor = "_ptr_",

    # Perfy was last touched in Feb 2025 and assigns to for-loop variables, which
    # lua-language-server rejects from 3.14 on, so the version is pinned rather than latest.
    [string] $LuaLsVersion = "3.13.6",

    # Trace the login loading screen instead of waiting for /perfy start. Perfy ships this
    # switched off behind a comment; the tracer stops itself once the first frame is drawn.
    [switch] $LoginTrace,

    # Passed through to Perfy's analyzer, e.g. --split-frames or --frames 3-7.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $AnalyzerArgs = @()
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$srcDir = Join-Path $repoRoot "src"
$toolsDir = Join-Path $repoRoot "tools"
$perfyDir = Join-Path $toolsDir "Perfy"
$flameDir = Join-Path $toolsDir "FlameGraph"
$luaLsDir = Join-Path $toolsDir "lua-language-server"
$luaLsExe = Join-Path $luaLsDir "bin\lua-language-server.exe"
$outDir = Join-Path $toolsDir "perfy-out"

$addonsDir = Join-Path $WowPath "$Flavor\Interface\AddOns"
$targetDir = Join-Path $addonsDir "MiniAuras"
$backupDir = Join-Path $addonsDir "MiniAuras.perfy-backup"
$perfyAddonDir = Join-Path $addonsDir "!!!Perfy"
$noBom = New-Object System.Text.UTF8Encoding($false)

function Test-Instrumented([string] $dir) {
    foreach ($toc in @(Get-ChildItem -Path $dir -Filter "*.toc" -File -ErrorAction SilentlyContinue)) {
        if ([System.IO.File]::ReadAllText($toc.FullName) -match "(?m)^## X-Perfy-Instrumented:") { return $true }
    }
    return $false
}

# Whether two installs hold the same files with the same contents.
function Test-SameTree([string] $left, [string] $right) {
    $leftFiles = @(Get-ChildItem -Path $left -Recurse -File | Sort-Object FullName)
    $rightFiles = @(Get-ChildItem -Path $right -Recurse -File | Sort-Object FullName)

    if ($leftFiles.Count -ne $rightFiles.Count) { return $false }

    for ($index = 0; $index -lt $leftFiles.Count; $index++) {
        $leftRelative = $leftFiles[$index].FullName.Substring($left.Length)
        $rightRelative = $rightFiles[$index].FullName.Substring($right.Length)

        if ($leftRelative -ne $rightRelative) { return $false }
        if ((Get-FileHash $leftFiles[$index].FullName).Hash -ne (Get-FileHash $rightFiles[$index].FullName).Hash) {
            return $false
        }
    }

    return $true
}

# Perfy's toc reader counts a BOM as part of the first line, so "## Interface" stops looking
# like a comment and it tries to open it as a file. ReadAllText drops the BOM.
function Get-TocPaths([string] $dir) {
    $paths = @()
    foreach ($toc in @(Get-ChildItem -Path $dir -Filter "*.toc" -File)) {
        [System.IO.File]::WriteAllText($toc.FullName, [System.IO.File]::ReadAllText($toc.FullName), $noBom)
        $paths += $toc.FullName
    }
    return $paths
}

function Invoke-Instrumenter([string[]] $tocPaths) {
    # Forward slashes because Perfy shortens a traced file to its path below Interface/AddOns/
    # by matching on them, and falls back to the full absolute path when it can't.
    $arguments = @((Join-Path $perfyDir "Instrumentation\Main.lua"))
    $arguments += @($tocPaths | ForEach-Object { $_ -replace "\\", "/" })

    Push-Location $luaLsDir  # Perfy's instrumenter resolves lua-language-server modules relative to the cwd
    try {
        & $luaLsExe @arguments
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw "Instrumentation failed" }
}

function Sync-Repo([string] $url, [string] $dir) {
    if (Test-Path (Join-Path $dir ".git")) {
        Write-Host "Updating $dir"
        git -C $dir pull --ff-only --quiet
    }
    else {
        Write-Host "Cloning $url"
        git clone --depth 1 --quiet $url $dir
    }
    if ($LASTEXITCODE -ne 0) { throw "git failed for $url" }
}

function Install-LuaLs {
    $marker = Join-Path $luaLsDir ".version"
    if ((Test-Path $marker) -and ((Get-Content $marker -Raw).Trim() -eq $LuaLsVersion)) { return }

    $url = "https://github.com/LuaLS/lua-language-server/releases/download/$LuaLsVersion/lua-language-server-$LuaLsVersion-win32-x64.zip"
    $zip = Join-Path $env:TEMP "lua-language-server-$LuaLsVersion.zip"
    Write-Host "Downloading lua-language-server $LuaLsVersion"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Remove-Item -Recurse -Force $luaLsDir -ErrorAction SilentlyContinue
    Expand-Archive -Path $zip -DestinationPath $luaLsDir -Force
    Remove-Item $zip -Force
    Set-Content -Path $marker -Value $LuaLsVersion
}

function Invoke-Setup {
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    Sync-Repo "https://github.com/emmericp/Perfy.git" $perfyDir
    Sync-Repo "https://github.com/brendangregg/FlameGraph.git" $flameDir
    Install-LuaLs
}

function Invoke-Instrument {
    Invoke-Setup

    if (-not (Test-Path $addonsDir)) { throw "No AddOns folder at $addonsDir" }

    if (Test-Path $targetDir) {
        if (Test-Instrumented $targetDir) {
            Remove-Item -Recurse -Force $targetDir
        }
        else {
            # A redeploy over the instrumented copy lands here: the install is clean again, and
            # the backup is the same clean tree it was taken from. Nothing to sort out then, so
            # the leftover goes and the fresh install is backed up in its place. Anything else is
            # a real conflict and stays for a human.
            if (Test-Path $backupDir) {
                if (Test-SameTree $targetDir $backupDir) {
                    Write-Host "$backupDir is the same tree as the install; dropping the leftover"
                    Remove-Item -Recurse -Force $backupDir
                }
                else {
                    throw "$targetDir is a clean install but $backupDir also exists and differs; sort those out by hand first"
                }
            }

            Write-Host "Backing up the installed copy to $backupDir"
            Move-Item $targetDir $backupDir
        }
    }

    Write-Host "Deploying src to $targetDir"
    New-Item -ItemType Directory -Path $targetDir | Out-Null
    Copy-Item (Join-Path $srcDir "*") $targetDir -Recurse -Force

    Write-Host "Instrumenting"
    Invoke-Instrumenter (Get-TocPaths $targetDir)
    if (-not (Test-Instrumented $targetDir)) { throw "Instrumentation left no marker in the toc" }

    Write-Host "Installing $perfyAddonDir"
    Remove-Item -Recurse -Force $perfyAddonDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $perfyAddonDir | Out-Null
    Copy-Item (Join-Path $perfyDir "AddOn\*") $perfyAddonDir -Recurse -Force

    # Perfy ships a 2024 Interface number. Instrumentation makes it a hard dependency of
    # MiniAuras, so an out of date Perfy takes MiniAuras down with it.
    $interfaceLine = [regex]::Match([System.IO.File]::ReadAllText((Join-Path $srcDir "MiniAuras.toc")), "(?m)^## Interface:.*$").Value
    $perfyToc = Join-Path $perfyAddonDir "!!!Perfy.toc"
    $text = [regex]::Replace([System.IO.File]::ReadAllText($perfyToc), "(?m)^## Interface:.*$", $interfaceLine)
    [System.IO.File]::WriteAllText($perfyToc, $text, $noBom)

    if ($LoginTrace) {
        # The one loading screen no slash command can reach: tracing has to be running before the
        # addon files are, so Perfy starts itself from its own file and stops on the second
        # OnUpdate, which is as close to "the first frame is drawn" as it can get.
        $tracer = Join-Path $perfyAddonDir "TraceLoadingScreen.lua"
        $text = [System.IO.File]::ReadAllText($tracer) -replace "(?m)^--Perfy_Start\(\)", "Perfy_Start()"
        [System.IO.File]::WriteAllText($tracer, $text, $noBom)
    }

    # A trace carries the ids of the build that wrote it, and Perfy reuses the name map it finds
    # while restarting its id counter, so a trace kept across a rebuild ends up with two functions
    # under one id and the analyzer rejects it. Deleting the file only helps while the client is
    # closed: a running one holds that table in memory and writes it back on exit, which is what
    # "/perfy clear" is for.
    foreach ($saved in @(Get-ChildItem -Path (Join-Path $WowPath "$Flavor\WTF\Account") -Recurse -Filter "!!!Perfy.lua*" -ErrorAction SilentlyContinue)) {
        Write-Host "Clearing the trace left by the previous build: $($saved.FullName)"
        Remove-Item $saved.FullName -Force
    }

    Write-Host ""
    Write-Host "Done. Restart the client (toc changes are read at startup), then:" -ForegroundColor Green
    Write-Host "  /perfy clear       first, if the client was running just now" -ForegroundColor Yellow

    if ($LoginTrace) {
        Write-Host "  the login loading screen traces itself, and stops on the first drawn frame"
        Write-Host "  /reload            trace that reload too, then write it out"
    }
    else {
        Write-Host "  /perfy start 30    trace for 30 seconds"
        Write-Host "  /reload            write the trace to saved variables"
    }

    Write-Host "  Perfy.ps1 Analyze  build the flame graphs"
}

function Invoke-Analyze {
    if (-not (Test-Path $luaLsExe)) { throw "Run Perfy.ps1 Setup first" }

    $savedVarsGlob = Join-Path $WowPath "$Flavor\WTF\Account\*\SavedVariables\!!!Perfy.lua"
    $saved = @(Get-ChildItem -Path $savedVarsGlob -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($saved.Count -eq 0) { throw "No trace found; expected $savedVarsGlob" }

    Write-Host "Reading $($saved[0].FullName) ($([math]::Round($saved[0].Length / 1MB, 1)) MiB, written $($saved[0].LastWriteTime))"

    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Get-ChildItem $outDir -Filter "*.txt" | Remove-Item -Force
    Get-ChildItem $outDir -Filter "*.svg" | Remove-Item -Force

    Push-Location $luaLsDir
    try {
        & $luaLsExe (Join-Path $PSScriptRoot "RunAnalyzer.lua") (Join-Path $perfyDir "Analyzer") $outDir $saved[0].FullName @AnalyzerArgs
    }
    finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) { throw "Analysis failed" }

    $perl = (Get-Command perl -ErrorAction SilentlyContinue).Source
    if (-not $perl) { $perl = "C:\Program Files\Git\usr\bin\perl.exe" }
    if (-not (Test-Path $perl)) { throw "perl not found; it ships with Git for Windows" }

    foreach ($stacks in @(Get-ChildItem $outDir -Filter "*stacks-*.txt")) {
        $isCpu = $stacks.Name -like "*cpu*"
        $countName = if ($isCpu) { "Microseconds" } else { "Bytes" }
        $title = if ($isCpu) { "CPU time" } else { "Memory allocations" }
        $svg = Join-Path $outDir (($stacks.BaseName -replace "stacks", "perfy") + ".svg")
        $lines = & $perl (Join-Path $flameDir "flamegraph.pl") $stacks.FullName --countname $countName --title $title --width 1600
        if ($LASTEXITCODE -ne 0) { throw "flamegraph.pl failed on $($stacks.Name)" }
        [System.IO.File]::WriteAllLines($svg, $lines)
        Write-Host "Wrote $svg"
    }
}

function Invoke-Restore {
    if (Test-Path $perfyAddonDir) {
        Remove-Item -Recurse -Force $perfyAddonDir
        Write-Host "Removed $perfyAddonDir"
    }

    if (Test-Path $targetDir) {
        if (Test-Instrumented $targetDir) {
            Remove-Item -Recurse -Force $targetDir
        }
        else {
            Write-Host "$targetDir is not instrumented, leaving it alone"
        }
    }

    if (Test-Path $backupDir) {
        if (Test-Path $targetDir) {
            Write-Host "Backup kept at $backupDir because $targetDir is still there"
        }
        else {
            Move-Item $backupDir $targetDir
            Write-Host "Restored $targetDir from the backup"
        }
    }
    elseif (-not (Test-Path $targetDir)) {
        Write-Host "No backup to restore; deploy a clean copy of src yourself"
    }
}

switch ($Action) {
    "Setup" { Invoke-Setup }
    "Instrument" { Invoke-Instrument }
    "Analyze" { Invoke-Analyze }
    "Restore" { Invoke-Restore }
}
