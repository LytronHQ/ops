#
# inventory.ps1 - list the software installed on this Windows machine, and
# which package manager put each piece there. The Windows twin of inventory.sh:
# same columns, formats, filters and saved list.
#
# platforms: windows
#
#   .\inventory.ps1                          # name, version, package manager
#   .\inventory.ps1 -Wide                    # + arch, size, installed, explicit, source, update, summary
#   .\inventory.ps1 -Pm choco,scoop -Search git
#   .\inventory.ps1 -Explicit                # only what someone installed on purpose
#   .\inventory.ps1 -Format json > inventory.json
#   .\inventory.ps1 -Refresh                 # rescan instead of reading the saved list
#
# Every scan is saved IN FULL - every column, whatever format was asked for -
# and later runs read that saved list instead of scanning again. -Refresh
# rescans; -NoCache neither reads nor writes it.
#
# Package managers (PM column):
#   msi      registered by Windows Installer
#   exe      registered by any other installer
#   winget   known to winget (its sources are consulted, which may use the network)
#   choco    Chocolatey, read from its lib folder
#   scoop    Scoop, read from its apps folders
#   store    Microsoft Store and MSIX packages
# Hidden system components and Windows updates are not listed.
#
# Options - every input is one; nothing else is read from the environment
# except where things live: LOCALAPPDATA and USERPROFILE, and the install
# folders ChocolateyInstall, SCOOP and SCOOP_GLOBAL when set:
#   -Wide              the wide table (same as -Format wide)
#   -Format <f>        table (default), wide, tsv (every column, with a header)
#                      or json
#   -Pm <list>         only these package managers
#   -Search <text>     only names or summaries containing this (any case)
#   -Explicit          only what was installed on purpose, not as a dependency
#   -Updates           only what has a newer version known locally
#   -Refresh           scan now, and replace the saved list
#   -NoCache           scan now, and neither read nor write the saved list
#   -Cache <path>      where the saved list lives
#                      (default %LOCALAPPDATA%\ops\inventory.tsv)
#   -Help              this text
#
# Windows PowerShell 5.1 and PowerShell 7. Plain ASCII on purpose: 5.1 reads a
# script without a byte-order mark as Windows-1252.
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
function Show-Usage {
  $lines = Get-Content -LiteralPath $PSCommandPath
  $end = [Array]::FindIndex([string[]] $lines, [Predicate[string]] { param($l) $l -like '`[CmdletBinding*' })
  $lines[2..($end - 1)] | ForEach-Object { $_ -replace '^# ?', '' }
}
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
