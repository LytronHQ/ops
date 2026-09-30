#
# ops-get.ps1 - fetch one script from a pinned release of this repo and verify it.
#
# platforms: windows linux
#
#   .\ops-get.ps1 <script> <version> [destination]   fetch, verify, write (default .\<script>)
#   .\ops-get.ps1 -List <version>                    the scripts in that version, marking
#                                                    any that do not run on this machine
#
#   .\ops-get.ps1 inventory.ps1 v4.2.0
#
# Options - every input is one; nothing is read from the environment:
#   -List <version>     list the scripts in a version, from its SHA256SUMS;
#                       those whose MANIFEST excludes this platform are marked
#   -Repo <owner/name>  whose releases to use (default LytronHQ/ops): a fork
#   -BaseUrl <url>      the whole release URL, for a mirror, an air-gapped copy,
#                       or a test serving a deliberately corrupted file
#   -Help               this text
#
# The Windows twin of ops-get, with the same guarantees: a pinned version, a
# checksum, nothing to install first. It FAILS CLOSED - a missing release, a
# missing checksum or a mismatch aborts without leaving the file behind.
#
# Written for Windows PowerShell 5.1, the one every Windows has, and runs on
# PowerShell 7 too. Downloaded scripts are blocked by the default execution
# policy, so the first run is usually:
#   powershell -ExecutionPolicy Bypass -File .\ops-get.ps1 ...
[CmdletBinding()]
param(
  [Parameter(Position = 0)] [string] $Script,
  [Parameter(Position = 1)] [string] $Version,
  [Parameter(Position = 2)] [string] $Destination,
  [string] $List,
  [string] $Repo = 'LytronHQ/ops',
  [string] $BaseUrl,
  [switch] $Help
)
$ErrorActionPreference = 'Stop'
# Invoke-WebRequest draws a progress bar that slows Windows PowerShell's
# downloads by an order of magnitude.
$ProgressPreference = 'SilentlyContinue'

function Stop-OpsGet([string] $message) {
  [Console]::Error.WriteLine("ops-get: $message")
  exit 1
}
function Show-Usage {
  $lines = Get-Content -LiteralPath $PSCommandPath
  $end = [Array]::FindIndex([string[]] $lines, [Predicate[string]] { param($l) $l -like '`[CmdletBinding*' })
  $lines[2..($end - 1)] | ForEach-Object { $_ -replace '^# ?', '' }
}

if ($Help) { Show-Usage; exit 0 }
if ($List) { $Version = $List }
elseif (-not $Script) { Show-Usage | ForEach-Object { [Console]::Error.WriteLine($_) }; exit 1 }
elseif (-not $Version) { Stop-OpsGet "which version? ops-get.ps1 $Script <version>   (see: ops-get.ps1 -List <version>)" }
if ($Script -match '[\\/]') { Stop-OpsGet "'$Script': a script name, not a path - release assets are flat" }
if (-not $Destination) { $Destination = Join-Path '.' $Script }
if (-not $BaseUrl) { $BaseUrl = "https://github.com/$Repo/releases/download/$Version" }
$BaseUrl = $BaseUrl.TrimEnd('/')

# Windows PowerShell 5.1 does not offer TLS 1.2 by default, and GitHub requires it.
if ($PSVersionTable.PSEdition -ne 'Core') {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# The platform this runs on, in MANIFEST's words.
if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { $Platform = 'windows' }
elseif ($IsMacOS) { $Platform = 'macos' }
else { $Platform = 'linux' }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ops-get-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  function Get-Asset([string] $name) {
    try {
      Invoke-WebRequest -Uri "$BaseUrl/$name" -OutFile (Join-Path $tmp $name) -UseBasicParsing
      return $true
    } catch { return $false }
  }

  # SHA256SUMS first: it is both the proof and the table of contents. If it is
  # not there, nothing else in the release can be trusted - and "no such
  # script" would be the wrong thing to say when the whole version is missing.
  if (-not (Get-Asset 'SHA256SUMS')) {
    Stop-OpsGet "cannot get SHA256SUMS for $Version of $Repo. Either that version does not exist, it is still being published (a new release can take a few minutes to appear), or it has no checksums. Nothing was fetched."
  }
  $sums = @{}
  $order = New-Object System.Collections.Generic.List[string]
  foreach ($line in Get-Content -LiteralPath (Join-Path $tmp 'SHA256SUMS')) {
    if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$') {
      $sums[$Matches[2]] = $Matches[1].ToLower()
      $order.Add($Matches[2])
    }
  }
  $scripts = @($order | Where-Object { $_ -ne 'SHA256SUMS' -and $_ -ne 'MANIFEST' })

  function Get-Verified([string] $name) {
    if (-not (Get-Asset $name)) {
      Stop-OpsGet "$name is listed in ${Version}'s SHA256SUMS but could not be downloaded from $BaseUrl/$name"
    }
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tmp $name)).Hash.ToLower()
    if ($got -ne $sums[$name]) {
      [Console]::Error.WriteLine("ops-get: CHECKSUM MISMATCH for $name@$Version")
      [Console]::Error.WriteLine("  expected $($sums[$name])")
      [Console]::Error.WriteLine("  got      $got")
      exit 1
    }
  }

  # MANIFEST says where each script runs. Releases before it have none, and
  # then nothing is marked. When the release lists one, it is verified like any
  # asset: a list saying "runs here" is a claim, and an unverified claim is a
  # way in.
  $platforms = @{}
  if ($sums.ContainsKey('MANIFEST')) {
    Get-Verified 'MANIFEST'
    foreach ($line in Get-Content -LiteralPath (Join-Path $tmp 'MANIFEST')) {
      $parts = @($line -split '\s+' | Where-Object { $_ })
      if ($parts.Count -ge 2) { $platforms[$parts[0]] = @($parts[1..($parts.Count - 1)]) }
    }
  }
  function Test-RunsHere([string] $name) {
    if (-not $platforms.ContainsKey($name)) { return $true }
    return ($platforms[$name] -contains $Platform)
  }

  if ($List) {
    # Everything is listed; what does not run here says so, rather than being
    # hidden - hidden, a module looks like it does not exist.
    foreach ($s in $scripts) {
      if (Test-RunsHere $s) { $s }
      else { '{0,-16} unsupported on {1} (runs on: {2})' -f $s, $Platform, ($platforms[$s] -join ' ') }
    }
    exit 0
  }

  if (-not $sums.ContainsKey($Script)) {
    Stop-OpsGet "$Script is not in $Version. It has: $($scripts -join ' ')"
  }
  Get-Verified $Script
  if (-not (Test-RunsHere $Script)) {
    # Still fetched: it may be for another machine. But said, so nobody is surprised.
    [Console]::Error.WriteLine("ops-get: note: $Script does not run on $Platform (runs on: $($platforms[$Script] -join ' ')); fetched anyway")
  }

  $parent = Split-Path -Parent $Destination
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
  Copy-Item -LiteralPath (Join-Path $tmp $Script) -Destination $Destination -Force
  if ($Platform -ne 'windows') { chmod +x -- $Destination }
  $Destination
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
