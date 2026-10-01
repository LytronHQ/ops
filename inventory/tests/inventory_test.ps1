#
# inventory_test.ps1 - run inventory.ps1 on a real Windows and check what it
# reports. Windows only: elsewhere it exits 77 and is reported as skipped.
#
#   powershell -File inventory\tests\inventory_test.ps1
#   pwsh -File inventory\tests\inventory_test.ps1
#
# The registry is the real one, with test entries added under HKCU (no admin
# needed) and removed afterwards. Chocolatey and Scoop are fake folders, found
# through ChocolateyInstall and SCOOP as the real ones are.
#
# What it asserts:
#   1. installer entries: msi vs exe, version, publisher, date, size
#   2. hidden system components and updates are not listed
#   3. Chocolatey: a package another depends on is not explicit; Scoop: bucket
#   4. table, wide, tsv and json, and the filters
#   5. the saved list: in full, read back, stale warning, -Refresh, -NoCache,
#      never overwriting a file that is not an inventory, a partial scan not saved
#   6. bad input fails
$ErrorActionPreference = 'Stop'
if (-not ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows)) { 'Windows only'; exit 77 }

$inv = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'inventory.ps1'
$engine = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("inventory-test-" + [Guid]::NewGuid().ToString('N'))
$uninstall = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$keys = @('ops-test-exe', 'ops-test-msi', 'ops-test-hidden', 'ops-test-update')

function Fail([string] $m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }
function Invoke-Inventory {
  $err = Join-Path $work 'stderr.txt'
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $inv @args 2> $err
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  return @{ Code = $code; Out = @($out); Err = ((Get-Content -LiteralPath $err -ErrorAction SilentlyContinue) -join "`n") }
}
function Get-Tsv { # rows as hashtables, from -Format tsv
  $r = Invoke-Inventory -Format tsv @args
  if ($r.Code -ne 0) { Fail "tsv run failed ($($r.Code)): $($r.Err)" }
  $head = $r.Out[0] -split "`t"
  foreach ($line in ($r.Out | Select-Object -Skip 1)) {
    $f = $line -split "`t"; $h = @{}
    for ($i = 0; $i -lt $head.Count; $i++) { $h[$head[$i]] = $f[$i] }
    $h
  }
}
function Find([object[]] $rows, [string] $name) { $rows | Where-Object { $_.name -eq $name } | Select-Object -First 1 }

try {
  New-Item -ItemType Directory -Path $work | Out-Null
  # --- registry entries --------------------------------------------------------
  foreach ($k in $keys) { New-Item -Path "$uninstall\$k" -Force | Out-Null }
  $e = "$uninstall\ops-test-exe"
  Set-ItemProperty $e DisplayName 'Ops Test Exe App'; Set-ItemProperty $e DisplayVersion '1.2.3'
  Set-ItemProperty $e Publisher 'Example Corp'; Set-ItemProperty $e InstallDate '20260102'
  New-ItemProperty $e EstimatedSize -Value 2048 -PropertyType DWord | Out-Null
  $m = "$uninstall\ops-test-msi"
  Set-ItemProperty $m DisplayName 'Ops Test Msi App'; Set-ItemProperty $m DisplayVersion '4.5'
  New-ItemProperty $m WindowsInstaller -Value 1 -PropertyType DWord | Out-Null
  $h = "$uninstall\ops-test-hidden"
  Set-ItemProperty $h DisplayName 'Ops Test Hidden Component'
  New-ItemProperty $h SystemComponent -Value 1 -PropertyType DWord | Out-Null
  $u = "$uninstall\ops-test-update"
  Set-ItemProperty $u DisplayName 'Ops Test Update KB1'; Set-ItemProperty $u ParentKeyName 'ops-test-msi'

  # --- Chocolatey and Scoop, faked ----------------------------------------------
  $choco = Join-Path $work 'choco'; $scoop = Join-Path $work 'scoop'
  New-Item -ItemType Directory -Path "$choco\lib\git", "$choco\lib\git.install", "$scoop\apps\ripgrep\current" | Out-Null
  Set-Content "$choco\lib\git\git.nuspec" '<?xml version="1.0"?><package><metadata><id>git</id><version>2.51.0</version><summary>Distributed version control</summary><dependencies><dependency id="git.install" /></dependencies></metadata></package>'
  Set-Content "$choco\lib\git.install\git.install.nuspec" '<?xml version="1.0"?><package><metadata><id>git.install</id><version>2.51.0</version><title>Git (Install)</title></metadata></package>'
  Set-Content "$scoop\apps\ripgrep\current\manifest.json" '{"version":"14.1.1","description":"Recursively searches directories"}'
  Set-Content "$scoop\apps\ripgrep\current\install.json" '{"bucket":"main","architecture":"64bit"}'
  $env:ChocolateyInstall = $choco; $env:SCOOP = $scoop; $env:SCOOP_GLOBAL = (Join-Path $work 'noglobal')

  'installer entries'
  $rows = @(Get-Tsv -NoCache)
  $x = Find $rows 'Ops Test Exe App'
  if (-not $x) { Fail 'the exe entry is missing' }
  if ($x.pm -ne 'exe' -or $x.version -ne '1.2.3' -or $x.source -ne 'Example Corp') { Fail "exe entry: $($x | Out-String)" }
  if ($x.installed -ne '2026-01-02' -or $x.size_kb -ne '2048') { Fail "exe date/size: $($x.installed) $($x.size_kb)" }
  if ((Find $rows 'Ops Test Msi App').pm -ne 'msi') { Fail 'the msi entry is not msi' }
  if (Find $rows 'Ops Test Hidden Component') { Fail 'a SystemComponent was listed' }
  if (Find $rows 'Ops Test Update KB1') { Fail 'an update (ParentKeyName) was listed' }
  if (@($rows | Where-Object { $_.pm -in 'msi', 'exe' -and $_.name -notlike 'Ops Test*' }).Count -eq 0) { Fail 'no real installer entries on this machine' }

  'Chocolatey and Scoop'
  if ((Find $rows 'git').explicit -ne 'yes') { Fail 'git was installed on purpose' }
  if ((Find $rows 'git.install').explicit -ne 'no') { Fail 'git.install is a dependency of git' }
  if ((Find $rows 'ripgrep').source -ne 'bucket main' -or (Find $rows 'ripgrep').pm -ne 'scoop') { Fail 'ripgrep from scoop' }

  'formats and filters'
  $r = Invoke-Inventory -NoCache
  if (($r.Out[0] -replace '\s+', ' ').Trim() -ne 'NAME VERSION PM') { Fail "table header: $($r.Out[0])" }
  $r = Invoke-Inventory -NoCache -Wide
  if ($r.Out[0] -notmatch 'EXPLICIT\s+SOURCE\s+UPDATE\s+SUMMARY') { Fail "wide header: $($r.Out[0])" }
  $r = Invoke-Inventory -NoCache -Format json -Pm choco
  # Piped on: Windows PowerShell 5.1's ConvertFrom-Json returns a JSON array as
  # ONE object, where PowerShell 7 enumerates it.
  $j = @(($r.Out -join "`n") | ConvertFrom-Json | ForEach-Object { $_ })
  if ($j.Count -ne 2 -or @($j[0].PSObject.Properties).Count -ne 10) { Fail "json: $($r.Out -join ' ')" }
  # One string: through -File a PowerShell array arrives as separate arguments,
  # and this check once passed vacuously with the second landing in -Search.
  $picked = @(Get-Tsv -NoCache -Pm 'choco,scoop')
  if ($picked.Count -ne 3) { Fail "-Pm choco,scoop should give git, git.install and ripgrep: $($picked.Count) rows" }
  if (@($picked | Where-Object { $_.pm -notin 'choco', 'scoop' }).Count) { Fail '-Pm let others through' }
  if ((@(Get-Tsv -NoCache -Search 'VERSION CONTROL') | ForEach-Object { $_.name }) -join ',' -ne 'git') { Fail '-Search should match summaries, any case' }
  if (Find @(Get-Tsv -NoCache -Explicit) 'git.install') { Fail '-Explicit let a dependency through' }

  'the saved list'
  $c = Join-Path $work 'saved.tsv'
  $r = Invoke-Inventory -Cache $c
  if ((Get-Content $c -TotalCount 1) -notlike '# ops-inventory v1 *') { Fail 'no marker line' }
  if (((Get-Content $c)[1] -split "`t").Count -ne 10) { Fail 'the saved list is not in full' }
  $r = Invoke-Inventory -Cache $c
  if ($r.Err -notlike '*from the list saved*') { Fail "second run did not read the saved list: $($r.Err)" }
  if ($r.Err -like '*may be out of date*') { Fail 'stale warning with nothing changed' }
  Start-Sleep -Seconds 2; (Get-Item "$choco\lib").LastWriteTime = Get-Date
  $r = Invoke-Inventory -Cache $c
  if ($r.Err -notlike '*may be out of date*') { Fail 'no warning after a package was added' }
  $before = Get-Content $c -Raw
  Start-Sleep -Seconds 1
  $r = Invoke-Inventory -Cache $c -Refresh
  if ($r.Err -like '*from the list saved*') { Fail '-Refresh read the saved list' }
  if ((Get-Content $c -Raw) -eq $before) { Fail '-Refresh did not replace the saved list' }
  $none = Join-Path $work 'none.tsv'
  $r = Invoke-Inventory -Cache $none -NoCache
  if (Test-Path $none) { Fail '-NoCache wrote a file' }
  $notes = Join-Path $work 'notes.txt'; Set-Content $notes 'precious'
  $r = Invoke-Inventory -Cache $notes
  if ($r.Code -eq 0) { Fail 'read a file that is not an inventory' }
  $r = Invoke-Inventory -Cache $notes -Refresh
  if ((Get-Content $notes) -ne 'precious') { Fail 'overwrote a file that is not an inventory' }

  'a package manager that cannot be read'
  Set-Content "$choco\lib\git\git.nuspec" '<package><metadata>this is not closed'
  $partial = Join-Path $work 'partial.tsv'
  $r = Invoke-Inventory -Cache $partial -Format tsv
  if ($r.Code -eq 0) { Fail 'a failed package manager did not fail the run' }
  if ($r.Err -notlike '*could not read choco*') { Fail "the failure was not named: $($r.Err)" }
  if (-not ($r.Out | Where-Object { $_ -like 'Ops Test Exe App*' })) { Fail 'the rest of the list was lost' }
  if (Test-Path $partial) { Fail 'an incomplete list was saved' }

  'bad input'
  $r = Invoke-Inventory -NoCache -Pm choco scoop
  if ($r.Code -eq 0) { Fail 'a stray argument was bound to some other parameter instead of failing' }
  $r = Invoke-Inventory -NoCache -Format html
  if ($r.Code -eq 0 -or $r.Err -notlike "*-Format 'html'*") { Fail "-Format html: $($r.Err)" }
  $r = Invoke-Inventory -NoCache -Pm apt
  if ($r.Code -eq 0 -or $r.Err -notlike "*-Pm 'apt'*") { Fail "-Pm apt: $($r.Err)" }

  'PASS'
  $passed = $true
}
finally {
  foreach ($k in $keys) { Remove-Item -Path "$uninstall\$k" -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($passed) { exit 0 }
exit 1
