# Deploys one commit's src to the retail AddOns folder, for bisecting a performance change by hand.
# Temporary, alongside the /miniauras fa build accounting.
param(
    [Parameter(Mandatory = $true)][string] $Commit,
    [string] $WowPath = "D:\Games\World of Warcraft",
    [string] $Flavor = "_retail_"
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("MiniAuras-" + $Commit)
$target = Join-Path $WowPath "$Flavor\Interface\AddOns\MiniAuras"

if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Path $staging | Out-Null

# Written to a file rather than piped: PowerShell pipes are text, and they corrupt a tar stream.
$archive = Join-Path $staging "src.tar"

git -C $repoRoot archive --format=tar -o $archive $Commit src

if ($LASTEXITCODE -ne 0) {
    throw "git archive failed for $Commit"
}

tar --force-local -x -f $archive -C $staging

if ($LASTEXITCODE -ne 0) {
    throw "tar failed for $Commit"
}

robocopy (Join-Path $staging "src") $target /MIR /NFL /NDL /NJH /NJS /NP | Out-Null

if ($LASTEXITCODE -ge 8) {
    throw "robocopy failed with $LASTEXITCODE"
}

$subject = (git -C $repoRoot log --format=%s -1 $Commit)
Write-Host "Deployed $Commit - $subject"
