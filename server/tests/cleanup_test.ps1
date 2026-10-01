#
# cleanup_test.ps1 - run server.ps1 cleanup on a real Windows and check that it
# removes exactly the junk, and nothing else. Windows only: elsewhere it exits
# 77 and is reported as skipped.
#
#   powershell -File cleanup\tests\cleanup_test.ps1
#
# The user's parts are test folders: TEMP and LOCALAPPDATA point at them, as
# they point at the real ones. The system's parts are the real C:\Windows ones,
# with a test file placed in C:\Windows\Temp; the CI runner is administrator
# and thrown away afterwards.
#
# What it asserts:
#   1. a report deletes nothing
#   2. -Apply removes old junk in each user category and in C:\Windows\Temp,
#      and the empty folders it leaves
#   3. fresh files, files outside a category's pattern, and other folders stay
#   4. a file in use is left, counted, and not a failure
#   5. -OlderThan 0, formats, -Only, -Skip, bad input
#   6. opt-in: never run unless named; package-caches keeps the version
#      'current' points to; recycle-bin empties a file really sent to it;
#      components reports DISM's count with the size unknown
$ErrorActionPreference = 'Stop'
if (-not ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows)) { 'Windows only'; exit 77 }

$script = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'server.ps1'
$engine = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("cleanup-test-" + [Guid]::NewGuid().ToString('N'))
$sysFile = Join-Path $env:SystemRoot ("Temp\ops-cleanup-test-" + [Guid]::NewGuid().ToString('N') + '.tmp')
$lock = $null

function Fail([string] $m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }
function Invoke-Cleanup {
  $err = Join-Path $work 'stderr.txt'
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script cleanup @args 2> $err
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  return @{ Code = $code; Out = @($out); Err = ((Get-Content -LiteralPath $err -ErrorAction SilentlyContinue) -join "`n") }
}
function New-File([string] $path, [int] $size, [int] $daysOld) {
  New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
  [IO.File]::WriteAllBytes($path, (New-Object byte[] $size))
  if ($daysOld -gt 0) {
    $when = (Get-Date).AddDays(-$daysOld)
    $f = Get-Item -LiteralPath $path -Force
    $f.CreationTime = $when; $f.LastWriteTime = $when; $f.LastAccessTime = $when
  }
}
function Get-Row($r, [string] $c) {
  foreach ($line in $r.Out | Select-Object -Skip 1) { $f = $line -split "`t"; if ($f[0] -eq $c) { return $f } }
}

try {
  $temp = Join-Path $work 'temp'; $la = Join-Path $work 'localappdata'
  New-File "$temp\old.tmp" 3000 400
  New-File "$temp\sub\deeper\old2.tmp" 50 400
  New-File "$temp\fresh.tmp" 10 0
  New-File "$temp\locked.tmp" 500 400
  New-File "$la\CrashDumps\app.exe.1234.dmp" 9000 400
  New-File "$la\Microsoft\Windows\WER\ReportArchive\AppCrash_x\Report.wer" 700 400
  New-File "$la\Microsoft\Windows\WER\Temp\keep.txt" 10 400
  New-File "$la\Microsoft\Windows\Explorer\thumbcache_256.db" 400 0
  New-File "$la\Microsoft\Windows\Explorer\iconcache_256.db" 10 0
  New-File "$la\Documents-like\keep.docx" 10 400
  New-File $sysFile 1234 400
  $env:TEMP = $temp; $env:TMP = $temp; $env:LOCALAPPDATA = $la

  $keep = @("$temp\fresh.tmp", "$la\Microsoft\Windows\WER\Temp\keep.txt", "$la\Microsoft\Windows\Explorer\iconcache_256.db", "$la\Documents-like\keep.docx")
  $junk = @("$temp\old.tmp", "$temp\sub\deeper\old2.tmp", "$la\CrashDumps\app.exe.1234.dmp",
            "$la\Microsoft\Windows\WER\ReportArchive\AppCrash_x\Report.wer", "$la\Microsoft\Windows\Explorer\thumbcache_256.db", $sysFile)

  'a report deletes nothing'
  $r = Invoke-Cleanup -Format tsv
  if ($r.Code -ne 0) { Fail "report failed: $($r.Err)" }
  foreach ($f in $keep + $junk) { if (-not (Test-Path -LiteralPath $f)) { Fail "a report deleted $f" } }
  if ($r.Err -match 'not running as administrator') { Fail 'the CI runner is expected to be administrator' }
  if ([long] (Get-Row $r 'crash-dumps')[1] -lt 9000) { Fail "crash-dumps not sized: $($r.Out -join ' | ')" }
  if ([int] (Get-Row $r 'thumbnails')[2] -ne 1) { Fail "thumbnails should count only thumbcache_*: $(Get-Row $r 'thumbnails')" }

  'a file in use is left, counted, and not a failure'
  $lock = [IO.File]::Open("$temp\locked.tmp", 'Open', 'ReadWrite', 'None')
  # One string: through -File a PowerShell array arrives as separate arguments.
  $r = Invoke-Cleanup -Apply -Only 'temp,crash-dumps,error-reports,thumbnails' -Format tsv
  if ($r.Code -ne 0) { Fail "apply failed ($($r.Code)): $($r.Err)" }
  if (-not (Test-Path -LiteralPath "$temp\locked.tmp")) { Fail 'a locked file was removed?' }
  if ((Get-Row $r 'temp')[3] -notlike '*1 in use, left*') { Fail "the locked file was not reported: $(Get-Row $r 'temp')" }
  $lock.Close(); $lock = $null

  '-Apply removed the junk, and only the junk'
  foreach ($f in $junk) { if (Test-Path -LiteralPath $f) { Fail "$f is still there" } }
  foreach ($f in $keep) { if (-not (Test-Path -LiteralPath $f)) { Fail "$f was deleted" } }
  if (Test-Path -LiteralPath "$temp\sub") { Fail 'emptied folders were left in TEMP' }
  if (-not (Test-Path -LiteralPath $temp)) { Fail 'TEMP itself was removed' }
  if ([long] (Get-Row $r 'crash-dumps')[1] -lt 9000) { Fail "crash-dumps freed: $(Get-Row $r 'crash-dumps')" }

  '-OlderThan 0 takes fresh files too'
  $r = Invoke-Cleanup -Apply -Only temp -OlderThan 0
  if (Test-Path -LiteralPath "$temp\fresh.tmp") { Fail '-OlderThan 0 kept a fresh file' }

  'formats and choices'
  $r = Invoke-Cleanup -Format json -Only 'thumbnails,temp'
  $j = ($r.Out -join "`n") | ConvertFrom-Json
  if ($j.applied -ne $false -or @($j.categories).Count -ne 2) { Fail "json: $($r.Out -join ' ')" }
  $r = Invoke-Cleanup -Format tsv -Skip temp
  if (Get-Row $r 'temp') { Fail '-Skip temp still ran temp' }
  $r = Invoke-Cleanup
  if ($r.Out[0] -notmatch '^CATEGORY\s+RECLAIMABLE\s+ITEMS\s+HOW$') { Fail "table header: $($r.Out[0])" }
  if ($r.Err -notlike '*nothing was deleted*') { Fail 'the report did not say it deleted nothing' }

  'opt-in categories never run unless named'
  $r = Invoke-Cleanup -Format tsv
  foreach ($c in 'components', 'recycle-bin', 'package-caches') { if (Get-Row $r $c) { Fail "$c ran without being named" } }

  'package-caches: old Scoop versions and caches go, current stays'
  $scoop = Join-Path $work 'scoop'
  New-File "$scoop\apps\tool\1.0\tool.exe" 5000 0
  New-File "$scoop\apps\tool\2.0\tool.exe" 6000 0
  New-Item -ItemType Junction -Path "$scoop\apps\tool\current" -Target "$scoop\apps\tool\2.0" | Out-Null
  New-File "$scoop\cache\tool#1.0#x.zip" 7000 0
  New-File "$temp\chocolatey\pkg.nupkg" 800 0
  $env:SCOOP = $scoop; $env:SCOOP_GLOBAL = (Join-Path $work 'noglobal')
  $r = Invoke-Cleanup -Only package-caches -Format tsv
  if ([long] (Get-Row $r 'package-caches')[1] -ne 12800) { Fail "package-caches size: $(Get-Row $r 'package-caches')" }
  $r = Invoke-Cleanup -Apply -Include package-caches -Only package-caches -Format tsv
  if ($r.Code -ne 0) { Fail "package-caches apply: $($r.Err)" }
  if (Test-Path "$scoop\apps\tool\1.0") { Fail 'the old Scoop version is still there' }
  if (-not (Test-Path "$scoop\apps\tool\2.0\tool.exe")) { Fail 'the current Scoop version was removed' }
  if (-not (Test-Path "$scoop\apps\tool\current")) { Fail "Scoop's current link was removed" }
  if ((Test-Path "$scoop\cache\tool#1.0#x.zip") -or (Test-Path "$temp\chocolatey\pkg.nupkg")) { Fail 'a download cache is still there' }

  'recycle-bin: a file really sent there is emptied'
  Add-Type -AssemblyName Microsoft.VisualBasic
  $binned = Join-Path $work 'to-the-bin.txt'; New-File $binned 4321 0
  [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($binned, 'OnlyErrorDialogs', 'SendToRecycleBin')
  $r = Invoke-Cleanup -Only recycle-bin -Format tsv
  if ([long] (Get-Row $r 'recycle-bin')[1] -lt 4321) { Fail "recycle-bin size: $(Get-Row $r 'recycle-bin')" }
  $r = Invoke-Cleanup -Apply -Include recycle-bin -Only recycle-bin -Format tsv
  if ($r.Code -ne 0) { Fail "recycle-bin apply: $($r.Err)" }
  $r = Invoke-Cleanup -Only recycle-bin -Format tsv
  if ([long] (Get-Row $r 'recycle-bin')[1] -ne 0) { Fail "the Recycle Bin was not emptied: $(Get-Row $r 'recycle-bin')" }

  'components: DISM counts packages, the size is unknown until cleaned'
  $r = Invoke-Cleanup -Only components -Format tsv
  if ($r.Code -ne 0) { Fail "components: $($r.Err)" }
  $row = Get-Row $r 'components'
  if ($row[1] -ne '-1' -or $row[2] -notmatch '^\d+$') { Fail "components should be unknown size and a package count: $($row -join ' | ')" }
  $r = Invoke-Cleanup -Only components
  if ($r.Out[1] -notmatch '^components\s+\?\s') { Fail "the table should show the size as ?: $($r.Out[1])" }

  'bad input'
  $r = Invoke-Cleanup -Only temp crash-dumps
  if ($r.Code -eq 0) { Fail 'a stray argument was bound to some other parameter instead of failing' }
  $r = Invoke-Cleanup -Only tmp
  if ($r.Code -eq 0 -or $r.Err -notlike "*unknown category 'tmp'*") { Fail "-Only tmp: $($r.Err)" }
  $r = Invoke-Cleanup -Format html
  if ($r.Code -eq 0 -or $r.Err -notlike "*-Format 'html'*") { Fail "-Format html: $($r.Err)" }

  'PASS'
  $passed = $true
}
finally {
  if ($lock) { $lock.Close() }
  Remove-Item -LiteralPath $sysFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($passed) { exit 0 }
exit 1
