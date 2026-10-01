#
# server.ps1 - looking after a Windows machine: clean it up, take stock of what
# is installed on it. The Windows side of server.sh.
#
# platforms: windows
#
#   powershell -ExecutionPolicy Bypass -File .\server.ps1 cleanup          # a report
#   powershell -ExecutionPolicy Bypass -File .\server.ps1 cleanup -Apply
#   powershell -ExecutionPolicy Bypass -File .\server.ps1 inventory -Wide
#   .\server.ps1 <action> -Help                                            # its options
#
# Actions:
#   cleanup    reclaim disk space: temp files, update downloads, dumps, error
#              reports, thumbnails; reports first
#   inventory  what is installed, and which package manager put it there
#
# Windows PowerShell 5.1 and PowerShell 7. Plain ASCII on purpose: 5.1 reads a
# script without a byte-order mark as Windows-1252.

# The action is the first argument; the rest are its own, bound by its own
# param block, exactly as when it was a script of its own.
$ErrorActionPreference = 'Stop'
$SubjectAction = ''; if ($args.Count -gt 0) { $SubjectAction = [string] $args[0] }
$SubjectRest = @($args | Select-Object -Skip 1)

$SubjectHelp = @{
  'cleanup' = @'
server.ps1 cleanup - reclaim disk space from what a Windows machine accumulates and
does not need. REPORTS BY DEFAULT; deletes nothing without -Apply. The
Windows twin of server.sh cleanup.


  .\server.ps1 cleanup                       # what each category would free
  .\server.ps1 cleanup -Apply                # clean, and report what was freed
  .\server.ps1 cleanup -Only temp,crash-dumps
  .\server.ps1 cleanup -Apply -OlderThan 14

Categories (all run unless -Only or -Skip says otherwise):
  temp                   your %TEMP% and C:\Windows\Temp: files not written
                         or created for 7 days
  update-downloads       C:\Windows\SoftwareDistribution\Download: update
                         files already downloaded, not written for 7 days
  delivery-optimization  the Delivery Optimization cache, through
                         Delete-DeliveryOptimizationCache
  crash-dumps            C:\Windows\Minidump, C:\Windows\MEMORY.DMP and your
                         CrashDumps, older than 7 days
  error-reports          Windows Error Reporting archives and queues, yours
                         and the system's, older than 7 days
  thumbnails             Explorer's thumbnail cache, rebuilt on demand

Opt-in categories, run only when named with -Include (or -Only):
  components             superseded components in the component store
                         (WinSxS): DISM /StartComponentCleanup. DISM counts
                         reclaimable packages but not bytes, so the size is
                         shown as unknown until cleaned. Administrator
  recycle-bin            the Recycle Bin, every drive: Clear-RecycleBin.
                         User data, which is why it is opt-in
  package-caches         Scoop's download cache and old app versions (never
                         the version 'current' points to), Chocolatey's
                         download cache

Never touched: documents, downloads, the Recycle Bin, anything a user made.
A file in use is skipped and counted, not treated as a failure.

Without administrator rights, your own parts are sized and cleaned and the
system's are left alone, which the report says.

Options - every input is one; nothing else is read from the environment
except where things live: TEMP, LOCALAPPDATA, SystemRoot, USERPROFILE,
ProgramData, SCOOP and SCOOP_GLOBAL:
  -Apply             clean; without it nothing is deleted
  -Only <list>       only these categories
  -Skip <list>       all but these
  -Include <list>    add opt-in categories to the default ones
  -OlderThan <days>  one age limit for every category that has one (default
                     7). 0 means any age
  -Format <f>        table (default), tsv or json
  -Help              this text

Windows PowerShell 5.1 and PowerShell 7. Plain ASCII on purpose: 5.1 reads a
script without a byte-order mark as Windows-1252.
'@
  'inventory' = @'
server.ps1 inventory - list the software installed on this Windows machine, and
which package manager put each piece there. The Windows twin of server.sh inventory:
same columns, formats, filters and saved list.


  .\server.ps1 inventory                          # name, version, package manager
  .\server.ps1 inventory -Wide                    # + arch, size, installed, explicit, source, update, summary
  .\server.ps1 inventory -Pm choco,scoop -Search git
  .\server.ps1 inventory -Explicit                # only what someone installed on purpose
  .\server.ps1 inventory -Format json > inventory.json
  .\server.ps1 inventory -Refresh                 # rescan instead of reading the saved list

Every scan is saved IN FULL - every column, whatever format was asked for -
and later runs read that saved list instead of scanning again. -Refresh
rescans; -NoCache neither reads nor writes it.

Package managers (PM column):
  msi      registered by Windows Installer
  exe      registered by any other installer
  winget   known to winget (its sources are consulted, which may use the network)
  choco    Chocolatey, read from its lib folder
  scoop    Scoop, read from its apps folders
  store    Microsoft Store and MSIX packages
Hidden system components and Windows updates are not listed.

Options - every input is one; nothing else is read from the environment
except where things live: LOCALAPPDATA and USERPROFILE, and the install
folders ChocolateyInstall, SCOOP and SCOOP_GLOBAL when set:
  -Wide              the wide table (same as -Format wide)
  -Format <f>        table (default), wide, tsv (every column, with a header)
                     or json
  -Pm <list>         only these package managers
  -Search <text>     only names or summaries containing this (any case)
  -Explicit          only what was installed on purpose, not as a dependency
  -Updates           only what has a newer version known locally
  -Refresh           scan now, and replace the saved list
  -NoCache           scan now, and neither read nor write the saved list
  -Cache <path>      where the saved list lives
                     (default %LOCALAPPDATA%\ops\inventory.tsv)
  -Help              this text

Windows PowerShell 5.1 and PowerShell 7. Plain ASCII on purpose: 5.1 reads a
script without a byte-order mark as Windows-1252.
'@
}

$SubjectActions = @{
  'cleanup' = {
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
function Show-Usage { $SubjectHelp['cleanup'] }
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
}
  'inventory' = {
# PositionalBinding off: a stray argument is an error, not a value for some
# other parameter. Through `powershell -File`, `-Only a,b` arrives as two
# arguments, and the second used to land silently in the next parameter.
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch] $Wide,
  [string] $Format = 'table',
  [string[]] $Pm = @(),
  [string] $Search = '',
  [switch] $Explicit,
  [switch] $Updates,
  [switch] $Refresh,
  [switch] $NoCache,
  [string] $Cache,
  [switch] $Help
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Note([string] $m) { [Console]::Error.WriteLine("inventory: $m") }
function Stop-Inventory([string] $m) { Write-Note $m; exit 1 }
function Show-Usage { $SubjectHelp['inventory'] }
if ($Help) { Show-Usage; exit 0 }

if ($Wide) { $Format = 'wide' }
if (@('table', 'wide', 'tsv', 'json') -notcontains $Format) { Stop-Inventory "-Format '$Format': table, wide, tsv or json" }
$known = @('msi', 'exe', 'winget', 'choco', 'scoop', 'store')
$Pm = @($Pm | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLower() })
foreach ($p in $Pm) { if ($known -notcontains $p) { Stop-Inventory "-Pm '$p': one of $($known -join ', ')" } }
if (-not $Cache) { $Cache = Join-Path $env:LOCALAPPDATA 'ops\inventory.tsv' }

$Marker = '# ops-inventory v1'
$Columns = @('name', 'version', 'pm', 'arch', 'size_kb', 'installed', 'explicit', 'source', 'update', 'summary')

# Fields must not carry the separators: a tab or a newline in a summary would
# shift every column after it.
function New-Row($name, $version, $pm, $arch, $size, $installed, $explicit, $source, $update, $summary) {
  $vals = @($name, $version, $pm, $arch, $size, $installed, $explicit, $source, $update, $summary) | ForEach-Object {
    $v = [string] $_
    $v = ($v -replace '[\x00-\x1f]', ' ').Trim()
    if ($v -eq '') { '-' } else { $v }
  }
  return ,$vals
}
function Get-Date8([string] $d) {           # 20260930 -> 2026-09-30
  if ($d -match '^(\d{4})(\d{2})(\d{2})$') { return "$($Matches[1])-$($Matches[2])-$($Matches[3])" }
  return '-'
}

# --- collectors: each returns rows; a failure is named, not fatal -------------

function Get-RegistryRows {
  $hives = @(
    @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'; Arch = 'x64' },
    @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'; Arch = 'x86' },
    @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'; Arch = '-' }
  )
  foreach ($h in $hives) {
    foreach ($k in @(Get-ItemProperty -Path $h.Path -ErrorAction SilentlyContinue)) {
      if (-not $k.DisplayName) { continue }
      # Not software a person installed: parts of Windows or of another
      # product, and the updates to them.
      if ($k.SystemComponent -eq 1) { continue }
      if ($k.ParentKeyName) { continue }
      if ($k.ReleaseType -in @('Update', 'Hotfix', 'Security Update', 'Update Rollup')) { continue }
      $pmName = 'exe'; if ($k.WindowsInstaller -eq 1) { $pmName = 'msi' }
      New-Row $k.DisplayName $k.DisplayVersion $pmName $h.Arch $k.EstimatedSize (Get-Date8 ([string] $k.InstallDate)) '-' $k.Publisher '-' $k.Comments
    }
  }
}

function Get-ChocoRows {
  $root = $env:ChocolateyInstall
  if (-not $root) { $root = Join-Path $env:ProgramData 'chocolatey' }
  $lib = Join-Path $root 'lib'
  if (-not (Test-Path -LiteralPath $lib)) { return }
  # The .nuspec of each installed package, not a choco process: offline, and
  # the same answer whether or not choco is on PATH.
  $specs = @()
  foreach ($dir in Get-ChildItem -LiteralPath $lib -Directory) {
    $file = Get-ChildItem -LiteralPath $dir.FullName -Filter *.nuspec -File | Select-Object -First 1
    if (-not $file) { continue }
    [xml] $x = Get-Content -LiteralPath $file.FullName -Raw
    $specs += ,@{ Meta = $x.package.metadata; Dir = $dir }
  }
  # Chocolatey does not record why a package was installed, but a package that
  # another installed package depends on was pulled in for it.
  $deps = @{}
  foreach ($s in $specs) {
    foreach ($d in @($s.Meta.dependencies.dependency)) { if ($d.id) { $deps[$d.id.ToLower()] = $true } }
    foreach ($g in @($s.Meta.dependencies.group)) { foreach ($d in @($g.dependency)) { if ($d.id) { $deps[$d.id.ToLower()] = $true } } }
  }
  foreach ($s in $specs) {
    $m = $s.Meta
    $expl = 'yes'; if ($deps.ContainsKey(([string] $m.id).ToLower())) { $expl = 'no' }
    $summary = $m.summary; if (-not $summary) { $summary = $m.title }
    New-Row $m.id $m.version 'choco' '-' '-' $s.Dir.CreationTime.ToString('yyyy-MM-dd') $expl 'chocolatey' '-' $summary
  }
}

function Get-ScoopRows {
  $roots = @()
  if ($env:SCOOP) { $roots += $env:SCOOP } else { $roots += (Join-Path $env:USERPROFILE 'scoop') }
  if ($env:SCOOP_GLOBAL) { $roots += $env:SCOOP_GLOBAL } else { $roots += (Join-Path $env:ProgramData 'scoop') }
  foreach ($r in $roots) {
    $apps = Join-Path $r 'apps'
    if (-not (Test-Path -LiteralPath $apps)) { continue }
    foreach ($app in Get-ChildItem -LiteralPath $apps -Directory) {
      if ($app.Name -eq 'scoop') { continue }          # scoop itself
      $cur = Join-Path $app.FullName 'current'
      $manifest = Join-Path $cur 'manifest.json'
      if (-not (Test-Path -LiteralPath $manifest)) { continue }
      $m = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
      $inst = $null; $installJson = Join-Path $cur 'install.json'
      if (Test-Path -LiteralPath $installJson) { $inst = Get-Content -LiteralPath $installJson -Raw | ConvertFrom-Json }
      $bucket = '-'; $arch = '-'
      if ($inst) { if ($inst.bucket) { $bucket = "bucket $($inst.bucket)" }; if ($inst.architecture) { $arch = $inst.architecture } }
      New-Row $app.Name $m.version 'scoop' $arch '-' (Get-Item -LiteralPath $cur).LastWriteTime.ToString('yyyy-MM-dd') 'yes' $bucket '-' $m.description
    }
  }
}

function Get-StoreRows {
  if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) { return }
  $pkgs = $null
  try { $pkgs = @(Get-AppxPackage) }
  catch {
    # PowerShell 7 can only reach the Appx module through Windows PowerShell.
    if ($PSVersionTable.PSEdition -eq 'Core') {
      Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue
      $pkgs = @(Get-AppxPackage)
    } else { throw }
  }
  foreach ($p in $pkgs) {
    # Part of Windows itself, not installed by anyone.
    if ([string] $p.SignatureKind -eq 'System') { continue }
    $expl = 'yes'; if ($p.IsFramework -or $p.IsResourcePackage) { $expl = 'no' }
    $pub = ([string] $p.Publisher) -replace '^CN=([^,]+).*$', '$1'
    $date = '-'
    if ($p.InstallLocation -and (Test-Path -LiteralPath $p.InstallLocation)) {
      $date = (Get-Item -LiteralPath $p.InstallLocation).CreationTime.ToString('yyyy-MM-dd')
    }
    New-Row $p.Name $p.Version 'store' ([string] $p.Architecture).ToLower() '-' $date $expl $pub '-' '-'
  }
}

function Get-WingetRows {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return }
  $out = Join-Path ([IO.Path]::GetTempPath()) ("winget-" + [Guid]::NewGuid().ToString('N') + '.json')
  try {
    & winget export --output $out --include-versions --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath $out)) { throw "winget export wrote nothing (exit $LASTEXITCODE)" }
    $j = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    foreach ($src in @($j.Sources)) {
      foreach ($p in @($src.Packages)) {
        New-Row $p.PackageIdentifier $p.Version 'winget' '-' '-' '-' 'yes' $src.SourceDetails.Name '-' '-'
      }
    }
  } finally { Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue }
}

# One package manager that cannot be read must not cost the whole list, nor
# pass for a complete one: it is named, the rest is shown, the run exits 1, and
# the partial list is not saved.
$Incomplete = @()
function Invoke-Scan {
  $rows = New-Object System.Collections.Generic.List[object]
  $collectors = [ordered] @{ registry = 'Get-RegistryRows'; winget = 'Get-WingetRows'; choco = 'Get-ChocoRows'; scoop = 'Get-ScoopRows'; store = 'Get-StoreRows' }
  foreach ($name in $collectors.Keys) {
    try { foreach ($r in @(& $collectors[$name])) { if ($r) { $rows.Add($r) } } }
    catch {
      Write-Note "could not read ${name}: $($_.Exception.Message); the list below is missing it"
      $script:Incomplete += $name
    }
  }
  return ,@($rows | Sort-Object { $_[0].ToLower() }, { $_[2] })
}

# --- the saved list ------------------------------------------------------------

$Utf8 = New-Object System.Text.UTF8Encoding($false)
function Test-Inventory([string] $path) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
  $first = Get-Content -LiteralPath $path -TotalCount 1 -Encoding UTF8
  return ($first -eq $Marker -or ([string] $first).StartsWith("$Marker "))
}
function Save-Inventory($rows) {
  if ((Test-Path -LiteralPath $Cache) -and -not (Test-Inventory $Cache)) {
    Write-Note "not saving: $Cache exists and is not an inventory file (choose another -Cache)"
    return
  }
  $dir = Split-Path -Parent $Cache
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("$Marker host=$([Environment]::MachineName) scanned=$((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))")
  $lines.Add($Columns -join "`t")
  foreach ($r in $rows) { $lines.Add($r -join "`t") }
  $tmp = "$Cache.tmp-$PID"
  [IO.File]::WriteAllLines($tmp, $lines, $Utf8)
  Move-Item -LiteralPath $tmp -Destination $Cache -Force
}
# Anywhere software lands, newer than the saved list, means it may be out of
# date. Said, not acted on: reading the saved list was asked for.
function Test-Stale {
  $choco = $env:ChocolateyInstall; if (-not $choco) { $choco = Join-Path $env:ProgramData 'chocolatey' }
  $scoop = $env:SCOOP; if (-not $scoop) { $scoop = Join-Path $env:USERPROFILE 'scoop' }
  $when = (Get-Item -LiteralPath $Cache).LastWriteTime
  foreach ($p in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs'),
                   (Join-Path $choco 'lib'), (Join-Path $scoop 'apps'))) {
    if ($p -and (Test-Path -LiteralPath $p) -and (Get-Item -LiteralPath $p).LastWriteTime -gt $when) { return $true }
  }
  return $false
}

if (-not $Refresh -and -not $NoCache -and (Test-Inventory $Cache)) {
  $all = @(Get-Content -LiteralPath $Cache -Encoding UTF8)
  $rows = @($all | Select-Object -Skip 2 | Where-Object { $_ } | ForEach-Object { ,@($_ -split "`t") })
  $scanned = ''; if ($all[0] -match 'scanned=(\S+)') { $scanned = $Matches[1] }
  Write-Note "from the list saved $scanned in $Cache (-Refresh to scan again)"
  if (Test-Stale) { Write-Note "software has been installed or changed since then; this list may be out of date" }
} else {
  if (-not $Refresh -and -not $NoCache -and (Test-Path -LiteralPath $Cache)) {
    Stop-Inventory "$Cache is not an inventory file; choose another -Cache"
  }
  $rows = Invoke-Scan
  if ($Incomplete.Count -gt 0) {
    if (-not $NoCache) { Write-Note 'not saving an incomplete list' }
  } elseif (-not $NoCache) { Save-Inventory $rows }
}

# --- filter and render ----------------------------------------------------------

$shown = @($rows | Where-Object {
  $r = $_
  ($Pm.Count -eq 0 -or $Pm -contains $r[2]) -and
  (-not $Search -or ("$($r[0]) $($r[9])").ToLower().Contains($Search.ToLower())) -and
  (-not $Explicit -or $r[6] -eq 'yes') -and
  (-not $Updates -or ($r[8] -ne '-' -and $r[8] -ne ''))
})

function Format-Size([string] $kb) {
  $n = 0L
  if (-not [long]::TryParse($kb, [ref] $n)) { return '-' }
  if ($n -ge 1048576) { return ('{0:0.0}G' -f ($n / 1048576)) }
  if ($n -ge 1024) { return ('{0:0.0}M' -f ($n / 1024)) }
  return "${n}K"
}
function Get-Cut([string] $s, [int] $n) { if ($s.Length -gt $n) { return $s.Substring(0, $n - 1) + '~' } return $s }

switch ($Format) {
  'tsv' {
    $Columns -join "`t"
    foreach ($r in $shown) { $r -join "`t" }
  }
  'json' {
    $objs = foreach ($r in $shown) {
      $o = [ordered] @{}
      for ($i = 0; $i -lt $Columns.Count; $i++) { $o[$Columns[$i]] = $r[$i] }
      New-Object PSObject -Property $o
    }
    if ($objs) { ConvertTo-Json -InputObject @($objs) -Depth 2 } else { '[]' }
  }
  default {
    if ($Format -eq 'table') { $cols = @(0, 1, 2); $head = @('NAME', 'VERSION', 'PM') }
    else { $cols = 0..9; $head = @('NAME', 'VERSION', 'PM', 'ARCH', 'SIZE', 'INSTALLED', 'EXPLICIT', 'SOURCE', 'UPDATE', 'SUMMARY') }
    $cells = foreach ($r in $shown) {
      $c = [string[]] $r.Clone()          # a copy: display formatting only
      $c[4] = Format-Size $c[4]; $c[0] = Get-Cut $c[0] 60; $c[1] = Get-Cut $c[1] 36; $c[7] = Get-Cut $c[7] 40
      ,$c
    }
    $w = @{}
    for ($j = 0; $j -lt $cols.Count; $j++) {
      $w[$j] = $head[$j].Length
      foreach ($c in $cells) { if ($c[$cols[$j]].Length -gt $w[$j]) { $w[$j] = $c[$cols[$j]].Length } }
    }
    $line = { param($vals) (0..($cols.Count - 1) | ForEach-Object { if ($_ -lt $cols.Count - 1) { $vals[$_].PadRight($w[$_]) } else { $vals[$_] } }) -join '  ' }
    & $line $head
    foreach ($c in $cells) { & $line @($cols | ForEach-Object { $c[$_] }) }
    $count = ($shown | Group-Object { $_[2] } | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', '
    $summary = "$($shown.Count) packages"; if ($count) { $summary += " - $count" }
    [Console]::Error.WriteLine($summary)
  }
}

if ($Incomplete.Count -gt 0) { exit 1 }
exit 0
}
}

if ($SubjectActions.ContainsKey($SubjectAction)) { & $SubjectActions[$SubjectAction] @SubjectRest; exit $LASTEXITCODE }
# The file's leading comment, as usage. A foreach, not ForEach-Object: break
# inside ForEach-Object can end the whole script.
$usage = @(); foreach ($l in @(Get-Content -LiteralPath $PSCommandPath | Select-Object -Skip 1)) {
  if ($l -notmatch '^#') { break }; $usage += ($l -replace '^# ?', '') }
if (@('-h', '-Help', '--help', 'help') -contains $SubjectAction) { $usage; exit 0 }
if ($SubjectAction) { [Console]::Error.WriteLine("server.ps1: unknown action '$SubjectAction'. Actions: cleanup, inventory") }
else { $usage | ForEach-Object { [Console]::Error.WriteLine($_) } }
exit 1
