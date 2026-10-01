#
# cleanup.ps1 - reclaim disk space from what a Windows machine accumulates and
# does not need. REPORTS BY DEFAULT; deletes nothing without -Apply. The
# Windows twin of cleanup.sh.
#
# platforms: windows
#
#   .\cleanup.ps1                       # what each category would free
#   .\cleanup.ps1 -Apply                # clean, and report what was freed
#   .\cleanup.ps1 -Only temp,crash-dumps
#   .\cleanup.ps1 -Apply -OlderThan 14
#
# Categories (all run unless -Only or -Skip says otherwise):
#   temp                   your %TEMP% and C:\Windows\Temp: files not written
#                          or created for 7 days
#   update-downloads       C:\Windows\SoftwareDistribution\Download: update
#                          files already downloaded, not written for 7 days
#   delivery-optimization  the Delivery Optimization cache, through
#                          Delete-DeliveryOptimizationCache
#   crash-dumps            C:\Windows\Minidump, C:\Windows\MEMORY.DMP and your
#                          CrashDumps, older than 7 days
#   error-reports          Windows Error Reporting archives and queues, yours
#                          and the system's, older than 7 days
#   thumbnails             Explorer's thumbnail cache, rebuilt on demand
#
# Opt-in categories, run only when named with -Include (or -Only):
#   components             superseded components in the component store
#                          (WinSxS): DISM /StartComponentCleanup. DISM counts
#                          reclaimable packages but not bytes, so the size is
#                          shown as unknown until cleaned. Administrator
#   recycle-bin            the Recycle Bin, every drive: Clear-RecycleBin.
#                          User data, which is why it is opt-in
#   package-caches         Scoop's download cache and old app versions (never
#                          the version 'current' points to), Chocolatey's
#                          download cache
#
# Never touched: documents, downloads, the Recycle Bin, anything a user made.
# A file in use is skipped and counted, not treated as a failure.
#
# Without administrator rights, your own parts are sized and cleaned and the
# system's are left alone, which the report says.
#
# Options - every input is one; nothing else is read from the environment
# except where things live: TEMP, LOCALAPPDATA, SystemRoot, USERPROFILE,
# ProgramData, SCOOP and SCOOP_GLOBAL:
#   -Apply             clean; without it nothing is deleted
#   -Only <list>       only these categories
#   -Skip <list>       all but these
#   -Include <list>    add opt-in categories to the default ones
#   -OlderThan <days>  one age limit for every category that has one (default
#                      7). 0 means any age
#   -Format <f>        table (default), tsv or json
#   -Help              this text
#
# Windows PowerShell 5.1 and PowerShell 7. Plain ASCII on purpose: 5.1 reads a
# script without a byte-order mark as Windows-1252.
# PositionalBinding off: a stray argument is an error, not a value for some
# other parameter. Through `powershell -File`, `-Only a,b` arrives as two
# arguments, and the second used to land silently in the next parameter.
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch] $Apply,
  [string[]] $Only = @(),
  [string[]] $Skip = @(),
  [string[]] $Include = @(),
  [int] $OlderThan = -1,
  [string] $Format = 'table',
  [switch] $Help
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Note([string] $m) { [Console]::Error.WriteLine("cleanup: $m") }
function Stop-Cleanup([string] $m) { Write-Note $m; exit 1 }
function Show-Usage {
  $lines = Get-Content -LiteralPath $PSCommandPath
  $end = [Array]::FindIndex([string[]] $lines, [Predicate[string]] { param($l) $l -like '`[CmdletBinding*' })
  $lines[2..($end - 1)] | ForEach-Object { $_ -replace '^# ?', '' }
}
if ($Help) { Show-Usage; exit 0 }

$All = @('temp', 'update-downloads', 'delivery-optimization', 'crash-dumps', 'error-reports', 'thumbnails')
$OptIn = @('components', 'recycle-bin', 'package-caches')
function Split-List($l) { @($l | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() }) }
$Only = Split-List $Only; $Skip = Split-List $Skip; $Include = Split-List $Include
foreach ($c in $Only + $Skip + $Include) {
  if (($All + $OptIn) -notcontains $c) { Stop-Cleanup "unknown category '$c'. Categories: $($All -join ', '); opt-in: $($OptIn -join ', ')" }
}
if (@('table', 'tsv', 'json') -notcontains $Format) { Stop-Cleanup "-Format '$Format': table, tsv or json" }
if ($OlderThan -lt -1) { Stop-Cleanup "-OlderThan $OlderThan is not a number of days" }
$Age = 7; if ($OlderThan -ge 0) { $Age = $OlderThan }
$Cutoff = (Get-Date).AddDays(-$Age)

$IsAdmin = $false
try {
  $IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
$Win = $env:SystemRoot; if (-not $Win) { $Win = 'C:\Windows' }

# --- what each category covers --------------------------------------------------

# Each category is a list of places: a folder (files under it, recursively), or
# a single file, with whether the age limit applies and whether it needs admin.
function Get-Places([string] $category) {
  switch ($category) {
    'temp' {
      @{ Path = $env:TEMP; Aged = $true; Admin = $false }
      @{ Path = Join-Path $Win 'Temp'; Aged = $true; Admin = $true }
    }
    'update-downloads' { @{ Path = Join-Path $Win 'SoftwareDistribution\Download'; Aged = $true; Admin = $true } }
    'delivery-optimization' {
      @{ Path = Join-Path $Win 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'; Aged = $false; Admin = $true }
      @{ Path = Join-Path $Win 'SoftwareDistribution\DeliveryOptimization'; Aged = $false; Admin = $true }
    }
    'crash-dumps' {
      @{ Path = Join-Path $Win 'Minidump'; Aged = $true; Admin = $true }
      @{ Path = Join-Path $Win 'MEMORY.DMP'; Aged = $true; Admin = $true; File = $true }
      @{ Path = Join-Path $env:LOCALAPPDATA 'CrashDumps'; Aged = $true; Admin = $false }
    }
    'error-reports' {
      foreach ($sub in 'ReportArchive', 'ReportQueue') {
        @{ Path = Join-Path $env:ProgramData "Microsoft\Windows\WER\$sub"; Aged = $true; Admin = $true }
        @{ Path = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\$sub"; Aged = $true; Admin = $false }
      }
    }
    'thumbnails' { @{ Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'; Aged = $false; Admin = $false; Filter = 'thumbcache_*.db' } }
    'recycle-bin' {
      # This user's bin on every fixed drive: $Recycle.Bin\<SID>.
      $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      foreach ($d in [IO.DriveInfo]::GetDrives()) {
        # desktop.ini is the bin's own metadata, kept by Clear-RecycleBin; counted,
        # it made an emptied bin look 258 bytes full.
        if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { @{ Path = Join-Path $d.RootDirectory.FullName "`$Recycle.Bin\$sid"; Aged = $false; Admin = $false; Keep = 'desktop.ini' } }
      }
    }
    'package-caches' {
      @{ Path = Join-Path $env:TEMP 'chocolatey'; Aged = $false; Admin = $false }
      foreach ($root in Get-ScoopRoots) {
        @{ Path = Join-Path $root 'cache'; Aged = $false; Admin = $false }
        foreach ($dir in Get-ScoopOldVersions $root) { @{ Path = $dir; Aged = $false; Admin = $false; Whole = $true } }
      }
    }
  }
}
function Get-ScoopRoots {
  $r = $env:SCOOP; if (-not $r) { $r = Join-Path $env:USERPROFILE 'scoop' }; $r
  $g = $env:SCOOP_GLOBAL; if (-not $g) { $g = Join-Path $env:ProgramData 'scoop' }; $g
}
# Version folders of each app other than the one 'current' points to - what
# `scoop cleanup` removes. Without a resolvable 'current', nothing is old.
function Get-ScoopOldVersions([string] $root) {
  $apps = Join-Path $root 'apps'
  if (-not (Test-Path -LiteralPath $apps)) { return }
  foreach ($app in Get-ChildItem -LiteralPath $apps -Directory -Force) {
    $cur = Get-Item -LiteralPath (Join-Path $app.FullName 'current') -Force -ErrorAction SilentlyContinue
    if (-not $cur -or -not $cur.Target) { continue }
    $target = Split-Path -Leaf ([string] @($cur.Target)[0])
    foreach ($v in Get-ChildItem -LiteralPath $app.FullName -Directory -Force) {
      if ($v.Name -ne 'current' -and $v.Name -ne $target) { $v.FullName }
    }
  }
}
$How = @{
  'temp' = "not written or created for $Age+ days"
  'update-downloads' = "not written for $Age+ days"
  'delivery-optimization' = 'Delete-DeliveryOptimizationCache'
  'crash-dumps' = "older than $Age days"
  'error-reports' = "older than $Age days"
  'thumbnails' = 'rebuilt on demand'
  'components' = 'DISM /StartComponentCleanup'
  'recycle-bin' = 'Clear-RecycleBin'
  'package-caches' = 'Scoop and Chocolatey caches, old Scoop versions'
}
if ($Age -eq 0) { foreach ($k in 'temp', 'update-downloads', 'crash-dumps', 'error-reports') { $How[$k] = 'any age' } }

$script:Partial = $false
function Get-Files([string] $category) {
  foreach ($p in Get-Places $category) {
    if (-not $p.Path) { continue }
    if ($p.Admin -and -not $IsAdmin) { $script:Partial = $true; continue }
    if (-not (Test-Path -LiteralPath $p.Path)) { continue }
    if ($p.File) { $items = @(Get-Item -LiteralPath $p.Path -Force) }
    else {
      $filter = '*'; if ($p.Filter) { $filter = $p.Filter }
      $items = @(Get-ChildItem -LiteralPath $p.Path -Recurse -File -Force -Filter $filter -ErrorAction SilentlyContinue)
    }
    foreach ($f in $items) {
      if ($p.Keep -and $f.Name -eq $p.Keep) { continue }
      # Young by any measure Windows keeps reliably: written, or created (a
      # copied-in file keeps an old write time but gets a new creation time).
      if ($p.Aged -and $Age -gt 0 -and ($f.LastWriteTime -gt $Cutoff -or $f.CreationTime -gt $Cutoff)) { continue }
      $f
    }
  }
}
function Measure-Files($files) {
  $b = 0L; $n = 0
  foreach ($f in $files) { $b += $f.Length; $n++ }
  return @{ Bytes = $b; Items = $n }
}

# Folders under a place that the deletion left empty, deepest first; never the
# place itself.
function Remove-EmptyFolders([string] $category) {
  foreach ($p in Get-Places $category) {
    if ($p.File -or $p.Filter -or -not $p.Path -or ($p.Admin -and -not $IsAdmin)) { continue }
    if (-not (Test-Path -LiteralPath $p.Path)) { continue }
    Get-ChildItem -LiteralPath $p.Path -Recurse -Directory -Force -ErrorAction SilentlyContinue |
      Sort-Object { $_.FullName.Length } -Descending |
      ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } }
  }
}

# Returns how many files were in use and left.
function Invoke-Clean([string] $category) {
  if ($category -eq 'delivery-optimization' -and (Get-Command Delete-DeliveryOptimizationCache -ErrorAction SilentlyContinue)) {
    # The owning tool: the service knows which cached content is still serving.
    Delete-DeliveryOptimizationCache -Force | Out-Null
    return 0
  }
  if ($category -eq 'recycle-bin' -and (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue)) {
    Clear-RecycleBin -Force -ErrorAction Stop
    return 0
  }
  if ($category -eq 'components') { & dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DISM /StartComponentCleanup exited $LASTEXITCODE" }
    return 0 }
  if ($category -eq 'package-caches' -and (Get-Command scoop -ErrorAction SilentlyContinue)) {
    # Scoop's own commands where Scoop is installed; the files below catch
    # Chocolatey's cache and anything they left.
    & scoop cache rm '*' 2>&1 | Out-Null
    & scoop cleanup '*' 2>&1 | Out-Null
  }
  $inUse = 0
  foreach ($p in Get-Places $category) {
    if ($p.Whole -and (Test-Path -LiteralPath $p.Path)) {
      try { Remove-Item -LiteralPath $p.Path -Recurse -Force -ErrorAction Stop } catch { $inUse++ }
    }
  }
  foreach ($f in @(Get-Files $category)) {
    try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
    catch [System.IO.IOException] { $inUse++ }
    catch [System.UnauthorizedAccessException] { $inUse++ }
  }
  Remove-EmptyFolders $category
  return $inUse
}

# The component store as DISM reports it: actual size and reclaimable package
# count. Parsed from English output; on another display language both stay
# unknown and cleaning still works.
function Get-ComponentStore {
  $out = & dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "DISM /AnalyzeComponentStore exited $LASTEXITCODE" }
  $size = -1L; $count = '-'
  if ($out -match 'Actual Size of Component Store\s*:\s*([\d.,]+)\s*(KB|MB|GB|TB)') {
    $n = [double] ($Matches[1] -replace ',', '')
    $size = [long] ($n * @{ KB = 1KB; MB = 1MB; GB = 1GB; TB = 1TB }[$Matches[2]])
  }
  if ($out -match 'Number of Reclaimable Packages\s*:\s*(\d+)') { $count = $Matches[1] }
  return @{ Actual = $size; Reclaimable = $count }
}

# --- run -----------------------------------------------------------------------

if (-not $IsAdmin) { Write-Note 'not running as administrator: only your own files are sized and cleaned; the system''s are left alone' }
$results = New-Object System.Collections.Generic.List[object]
$failed = @()
foreach ($c in $All + $OptIn) {
  # Default categories run unless left out; opt-in ones only when named.
  if ($Only.Count -gt 0) { if ($Only -notcontains $c) { continue } }
  elseif ($OptIn -contains $c -and $Include -notcontains $c) { continue }
  if ($Skip -contains $c) { continue }
  try {
    if ($c -eq 'components') {
      if (-not $IsAdmin) { $script:Partial = $true; continue }
      $store = Get-ComponentStore
      $bytes = -1L; $note = ''
      if ($Apply -and $store.Reclaimable -ne '0') {
        Invoke-Clean $c | Out-Null
        $after = Get-ComponentStore
        if ($store.Actual -ge 0 -and $after.Actual -ge 0) { $bytes = $store.Actual - $after.Actual }
      }
      $results.Add([pscustomobject] @{ Category = $c; Bytes = $bytes; Items = $store.Reclaimable; How = "$($How[$c]) ($($store.Reclaimable) reclaimable packages)" })
      continue
    }
    $before = Measure-Files @(Get-Files $c)
    $bytes = $before.Bytes; $note = ''
    if ($Apply -and ($bytes -gt 0 -or $before.Items -gt 0)) {
      $inUse = Invoke-Clean $c
      $after = Measure-Files @(Get-Files $c)
      $bytes = $before.Bytes - $after.Bytes
      if ($inUse -gt 0) { $note = "; $inUse in use, left" }
    }
    $results.Add([pscustomobject] @{ Category = $c; Bytes = $bytes; Items = $before.Items; How = $How[$c] + $note })
  } catch {
    Write-Note "could not $(if ($Apply) { 'clean' } else { 'size' }) ${c}: $($_.Exception.Message)"
    $failed += $c
  }
}

function Format-Size([long] $b) {
  if ($b -lt 0) { return '?' }                  # not known until cleaned
  if ($b -ge 1GB) { return ('{0:0.0}G' -f ($b / 1GB)) }
  if ($b -ge 1MB) { return ('{0:0.0}M' -f ($b / 1MB)) }
  if ($b -ge 1KB) { return ('{0:0.0}K' -f ($b / 1KB)) }
  return "${b}B"
}
$total = 0L; foreach ($r in $results) { if ($r.Bytes -gt 0) { $total += $r.Bytes } }
$col = 'RECLAIMABLE'; if ($Apply) { $col = 'FREED' }
switch ($Format) {
  'tsv' {
    "category`t$($col.ToLower())_bytes`titems`thow"
    foreach ($r in $results) { "$($r.Category)`t$($r.Bytes)`t$($r.Items)`t$($r.How)" }
  }
  'json' {
    $cats = @($results | ForEach-Object { [ordered] @{ category = $_.Category; bytes = $_.Bytes; items = $_.Items; how = $_.How } })
    ConvertTo-Json -Depth 3 -InputObject ([ordered] @{ applied = [bool] $Apply; total_bytes = $total; categories = $cats })
  }
  default {
    $w = 21
    ('{0,-' + $w + '}  {1,11}  {2,6}  {3}') -f 'CATEGORY', $col, 'ITEMS', 'HOW'
    foreach ($r in $results) { ('{0,-' + $w + '}  {1,11}  {2,6}  {3}') -f $r.Category, (Format-Size $r.Bytes), $r.Items, $r.How }
    ('{0,-' + $w + '}  {1,11}') -f 'total', (Format-Size $total)
    if (-not $Apply) { [Console]::Error.WriteLine('(a report: nothing was deleted. -Apply to clean.)') }
  }
}
if ($failed.Count -gt 0) { exit 1 }
exit 0
