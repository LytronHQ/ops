#
# ops-get_test.ps1 - run the real ops-get.ps1 against a local release served
# over HTTP, and check it fails closed. Runs under Windows PowerShell 5.1 and
# PowerShell 7, on Windows and Linux; ops-get.ps1 runs under the same engine as
# this test, so running the test with each engine tests each.
#
#   pwsh -File tests/ops-get_test.ps1
#   powershell -File tests\ops-get_test.ps1
#
# What it asserts: a good fetch lands; a tampered file, a missing script, an
# unlisted script, a release without SHA256SUMS and a missing version are
# refused with nothing written; -List marks what does not run here; a fetch of
# such a script says so; a tampered MANIFEST is refused; usage and -Help.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$opsGet = Join-Path (Split-Path -Parent $here) 'ops-get.ps1'
$engine = (Get-Process -Id $PID).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ("ops-get-test-" + [Guid]::NewGuid().ToString('N'))
$www = Join-Path $work 'www'
$server = $null

function Fail([string] $m) { [Console]::Error.WriteLine("FAIL: $m"); exit 1 }
function Write-Release([string] $dir, [hashtable] $files, [string[]] $listed) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  foreach ($k in $files.Keys) { [IO.File]::WriteAllText((Join-Path $dir $k), $files[$k]) }
  if ($listed) {
    $lines = foreach ($f in $listed) {
      '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dir $f)).Hash.ToLower(), $f
    }
    [IO.File]::WriteAllText((Join-Path $dir 'SHA256SUMS'), (($lines -join "`n") + "`n"))
  }
}
# Run ops-get.ps1 in its own process; return exit code and all output.
function Invoke-OpsGet {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & $engine -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $opsGet @args 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $old
  return @{ Code = $code; Out = ($out -join "`n") }
}

try {
  if ($PSVersionTable.PSEdition -ne 'Core' -or $IsWindows) { $here_ = 'windows'; $other = 'macos' }
  elseif ($IsMacOS) { $here_ = 'macos'; $other = 'windows' }
  else { $here_ = 'linux'; $other = 'windows' }

  $hello = "echo hello`n"
  Write-Release (Join-Path $www 'v1') @{ 'hello.ps1' = $hello; 'unlisted.ps1' = "x`n" } @('hello.ps1')
  Write-Release (Join-Path $www 'tampered') @{ 'hello.ps1' = $hello } @('hello.ps1')
  Add-Content -LiteralPath (Join-Path $www 'tampered/hello.ps1') -Value 'Invoke-Evil'
  Write-Release (Join-Path $www 'nosums') @{ 'hello.ps1' = $hello } $null
  Write-Release (Join-Path $www 'manifest') @{
    'hello.ps1' = $hello; 'elsewhere.sh' = "echo x`n"
    'MANIFEST' = "hello.ps1 $here_`nelsewhere.sh $other`n"
  } @('hello.ps1', 'elsewhere.sh', 'MANIFEST')
  Copy-Item -Recurse (Join-Path $www 'manifest') (Join-Path $www 'badmanifest')
  [IO.File]::WriteAllText((Join-Path $www 'badmanifest/MANIFEST'), "hello.ps1 $here_`nelsewhere.sh $other $here_`n")

  $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
  $python = (Get-Command python3, python -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if (-not $python) { Fail 'needs python to serve the test release' }
  $serve = @{ FilePath = $python; ArgumentList = @('-m', 'http.server', "$port", '--bind', '127.0.0.1', '--directory', "`"$www`""); PassThru = $true
              RedirectStandardError = (Join-Path $work 'server.log'); RedirectStandardOutput = (Join-Path $work 'server.out') }
  if ($here_ -eq 'windows') { $serve.WindowStyle = 'Hidden' }      # not a parameter elsewhere
  $server = Start-Process @serve
  $base = "http://127.0.0.1:$port"
  $up = $false
  foreach ($i in 1..50) {
    try { Invoke-WebRequest -Uri "$base/v1/SHA256SUMS" -UseBasicParsing | Out-Null; $up = $true; break } catch { Start-Sleep -Milliseconds 200 }
  }
  if (-not $up) { Fail 'the test server did not start' }

  $out = Join-Path $work 'out'
  function Refused([string] $what, [string] $release, [string] $script, [string] $want) {
    $dest = Join-Path $out $script
    $r = Invoke-OpsGet $script v1 $dest -BaseUrl "$base/$release"
    if ($r.Code -eq 0) { Fail "${what}: ops-get.ps1 succeeded" }
    if (Test-Path -LiteralPath $dest) { Fail "${what}: left $dest behind" }
    if ($r.Out -notlike "*$want*") { Fail "${what}: expected '$want', got: $($r.Out)" }
  }

  'a good fetch verifies and lands'
  $dest = Join-Path $out 'sub/hello.ps1'
  $r = Invoke-OpsGet hello.ps1 v1 $dest -BaseUrl "$base/v1"
  if ($r.Code -ne 0) { Fail "good fetch failed: $($r.Out)" }
  if ([IO.File]::ReadAllText($dest) -ne $hello) { Fail 'fetched file has the wrong content' }

  'refusals leave nothing behind'
  Refused 'tampered' 'tampered' 'hello.ps1' 'CHECKSUM MISMATCH'
  Refused 'missing script' 'v1' 'nope.ps1' 'nope.ps1 is not in v1. It has: hello.ps1'
  Refused 'unlisted' 'v1' 'unlisted.ps1' 'unlisted.ps1 is not in v1'
  Refused 'no sums' 'nosums' 'hello.ps1' 'cannot get SHA256SUMS'
  Refused 'missing version' 'v9' 'hello.ps1' 'still being published'

  '-List marks what does not run here'
  $r = Invoke-OpsGet -List v1 -BaseUrl "$base/manifest"
  if ($r.Code -ne 0) { Fail "-List failed: $($r.Out)" }
  $lines = @($r.Out -split "`n" | Where-Object { $_ })
  if ($lines.Count -ne 2) { Fail "-List should show 2 scripts: $($r.Out)" }
  if ($lines[0] -ne 'hello.ps1') { Fail "hello.ps1 should be plain: $($r.Out)" }
  if ($lines[1] -notmatch "^elsewhere\.sh +unsupported on $here_ \(runs on: $other\)$") { Fail "elsewhere.sh not marked: $($r.Out)" }

  'fetching an unsupported script works, and says so'
  $r = Invoke-OpsGet elsewhere.sh v1 (Join-Path $out 'e.sh') -BaseUrl "$base/manifest"
  if ($r.Code -ne 0) { Fail "unsupported fetch failed: $($r.Out)" }
  if ($r.Out -notlike "*does not run on $here_*") { Fail "no note: $($r.Out)" }

  'a tampered MANIFEST is refused'
  Refused 'bad manifest' 'badmanifest' 'hello.ps1' 'CHECKSUM MISMATCH for MANIFEST'

  'usage and help'
  $r = Invoke-OpsGet
  if ($r.Code -eq 0 -or $r.Out -notlike '*ops-get.ps1 <script> <version>*') { Fail "no arguments: $($r.Out)" }
  $r = Invoke-OpsGet -Help
  if ($r.Code -ne 0 -or $r.Out -notlike '*-List <version>*') { Fail "-Help: $($r.Out)" }
  $r = Invoke-OpsGet hello.ps1
  if ($r.Code -eq 0 -or $r.Out -notlike '*which version*') { Fail "missing version: $($r.Out)" }

  'PASS'
  # Explicitly: otherwise the exit code is whatever the last deliberate failure
  # above left in $LASTEXITCODE, and a caller passing it through sees a fail.
  $passed = $true
}
finally {
  if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($passed) { exit 0 }
exit 1
