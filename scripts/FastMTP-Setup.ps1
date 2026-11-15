<#
  FastMTP-Setup.ps1  -  one-shot setup + auto-tuner for HauhauCS FastMTP on Windows / AMD RDNA4 (gfx1201)

  What it does (nothing in LM Studio is modified, no existing GGUF is copied or re-downloaded):
    1. downloads the CI-built, patched llama.cpp (HIP) from the GitHub release and unpacks it
    2. downloads the 903 MB FastMTP-32K sidecar next to it (resumable)
    3. finds your IQ3_XS model in the LM Studio models folder (read-only)
    4. benchmarks configurations with identical prompts: tok/s, draft acceptance, VRAM
    5. writes the best config + a launcher (start-fastmtp.cmd)

  Run via Run-FastMTP-Setup.cmd (double-click). Works on Windows PowerShell 5.1 and PowerShell 7.
#>
[CmdletBinding()]
param(
  [string]$Root     = (Join-Path $env:USERPROFILE 'fastmtp'),
  [string]$Repo     = 'MafsITW/fastmtp-win-hip',
  [string]$Release  = 'latest',          # or e.g. build-2
  [string]$Model    = '',                # auto-detected in LM Studio's models folder when empty
  [int]$Port        = 8089,
  [switch]$Quick,                        # smaller sweep
  [switch]$SkipBench
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($m, $c = 'Cyan') { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m) -ForegroundColor $c }
function Die($m) { Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

$SidecarName = 'Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-FastMTP-32K.gguf'
$SidecarUrl  = "https://huggingface.co/HauhauCS/Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-MTP-GGUF/resolve/main/$SidecarName"
$ModelName   = 'Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-IQ3_XS.gguf'

New-Item -ItemType Directory -Force $Root, "$Root\bin", "$Root\models", "$Root\results", "$Root\logs" | Out-Null
Start-Transcript -Path "$Root\logs\setup-$(Get-Date -Format yyyyMMdd-HHmmss).log" | Out-Null

# ---------------------------------------------------------------- 0. environment checks
Say "Checking GPU / OS"
$gpus = @(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name)
$gpus | ForEach-Object { Say "  GPU: $_" 'Gray' }
if (-not ($gpus -match '9070')) { Say "No RX 9070 found in Win32_VideoController - continuing, llama-server will say if no ROCm device exists." 'Yellow' }
if ([Environment]::OSVersion.Version.Build -lt 19041) { Die "Windows 10 2004+ / 11 required" }
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { Die "curl.exe not found (ships with Windows 10/11)" }

# ---------------------------------------------------------------- 1. model files
if (-not $Model) {
  $lm = Join-Path $env:USERPROFILE '.lmstudio\models'
  $hit = Get-ChildItem $lm -Recurse -Filter $ModelName -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $hit) { Die "Could not find $ModelName under $lm - pass -Model <path>" }
  $Model = $hit.FullName
}
if (-not (Test-Path $Model)) { Die "Model not found: $Model" }
Say ("Model  : {0} ({1:N2} GB)" -f $Model, ((Get-Item $Model).Length / 1GB))

$Sidecar = Join-Path $Root "models\$SidecarName"
$existingSidecar = Get-ChildItem (Join-Path $env:USERPROFILE '.lmstudio\models'), "$env:USERPROFILE\Downloads" -Recurse -Filter $SidecarName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($existingSidecar -and -not (Test-Path $Sidecar)) { Say "Reusing sidecar found at $($existingSidecar.FullName)"; $Sidecar = $existingSidecar.FullName }
if (-not (Test-Path $Sidecar) -or ((Get-Item $Sidecar).Length -lt 800MB)) {
  Say "Downloading FastMTP sidecar (~903 MB, resumable)"
  & curl.exe -L -C - --fail --retry 5 --progress-bar -o $Sidecar $SidecarUrl
  if ($LASTEXITCODE -ne 0) { Die "Sidecar download failed (curl exit $LASTEXITCODE)" }
}
$len = (Get-Item $Sidecar).Length
if ($len -lt 850MB -or $len -gt 960MB) { Die "Sidecar size looks wrong: $len bytes (expected ~903 MB)" }
Say ("Sidecar: {0} ({1:N0} MB)" -f $Sidecar, ($len / 1MB))

# ---------------------------------------------------------------- 2. patched llama.cpp build
function Get-Build($variant) {
  $dir = Join-Path $Root "bin\$variant"
  if (Test-Path "$dir\llama-server.exe") { return $dir }
  $zip = Join-Path $Root "bin\$variant.zip"
  $url = if ($Release -eq 'latest') { "https://github.com/$Repo/releases/latest/download/llama-fastmtp-win-hip-$variant.zip" }
         else { "https://github.com/$Repo/releases/download/$Release/llama-fastmtp-win-hip-$variant.zip" }
  Say "Downloading build '$variant'"
  & curl.exe -L --fail --retry 3 --progress-bar -o $zip $url
  if ($LASTEXITCODE -ne 0) { Say "No '$variant' build available" 'Yellow'; return $null }
  Expand-Archive -Path $zip -DestinationPath $dir -Force
  Remove-Item $zip -Force
  return $dir
}
$BinPlain = Get-Build 'plain'
if (-not $BinPlain) { Die "Could not download the patched build from github.com/$Repo" }
Get-Content "$BinPlain\build-info.txt" | ForEach-Object { Say "  $_" 'Gray' }

# GPU visible to the binary?
$dev = & "$BinPlain\llama-server.exe" --list-devices 2>&1 | Out-String
Say ("llama-server devices:`n" + $dev.Trim()) 'Gray'
if ($dev -notmatch 'gfx1201|9070') { Die "llama-server does not see the RX 9070 XT (gfx1201). Update the AMD Adrenalin driver and retry. Output above." }

$help = & "$BinPlain\llama-server.exe" --help 2>&1 | Out-String
function Has($flag) { return $help.Contains($flag) }
foreach ($need in '--spec-type','--spec-draft-n-max','--spec-draft-model') {
  if (-not (Has $need)) { Die "Build lacks $need - the FastMTP patch/build is not what we expect." }
}

# ---------------------------------------------------------------- helpers: server + measurement
function Get-VramUsedGB {
  # WMI class has non-localized property names (works on any Windows language)
  try {
    $m = (Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUAdapterMemory -ErrorAction Stop |
          Measure-Object DedicatedUsage -Maximum).Maximum
    if ($m) { return [math]::Round($m / 1GB, 2) }
  } catch {}
  try {
    $s = (Get-Counter '\GPU Adapter Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples
    return [math]::Round(($s | Measure-Object CookedValue -Maximum).Maximum / 1GB, 2)
  } catch { return $null }
}

function Build-Args($c) {
  $a = @('--model', $Model, '--host', '127.0.0.1', '--port', $Port,
         '--ctx-size', $c.ctx, '--parallel', 1, '--batch-size', 2048, '--ubatch-size', 512,
         '--n-gpu-layers', 'all', '--split-mode', 'none', '--flash-attn', 'on', '--no-mmap',
         '--cache-type-k', $c.kv, '--cache-type-v', $c.kv, '--jinja')
  if ($help -match '--fit\s+\[') { $a += @('--fit', 'off') }           # never silently spill layers to the CPU
  if ($c.depth -gt 0) {
    $a += @('--spec-type', 'draft-mtp', '--spec-draft-model', $Sidecar,
            '--spec-draft-n-max', $c.depth, '--spec-draft-p-min', $c.pmin)
    if (Has '--spec-draft-ngl') { $a += @('--spec-draft-ngl', 'all') }
    if (Has '--spec-draft-type-k') { $a += @('--spec-draft-type-k', $c.dkv, '--spec-draft-type-v', $c.dkv) }
  }
  return $a
}

$Prompts = @(
  @{ name='code';   text='Write a Python function that parses an ISO-8601 date string without using any libraries, with input validation and three unit tests. Output only code.' },
  @{ name='prose';  text='Explain in about 200 words how a refrigerator works, for a curious teenager.' },
  @{ name='reason'; text='A train leaves at 09:10 and travels 180 km at 72 km/h, then waits 15 minutes and travels another 90 km at 60 km/h. At what time does it arrive? Show the steps briefly.' }
)

function Invoke-Config($c) {
  $label = "{0}|d{1}|p{2}|kv-{3}|dkv-{4}|ctx{5}" -f $c.variant, $c.depth, $c.pmin, $c.kv, $c.dkv, $c.ctx
  $bin = Get-Build $c.variant
  $res = [ordered]@{ label=$label; variant=$c.variant; depth=$c.depth; pmin=$c.pmin; kv=$c.kv; dkv=$c.dkv; ctx=$c.ctx
                     ok=$false; tps=$null; accept=$null; vram=$null; note='' }
  if (-not $bin) { $res.note = 'build missing'; return $res }
  $log = Join-Path $Root "logs\srv-$([guid]::NewGuid().ToString('N').Substring(0,6)).log"
  $argList = (Build-Args $c) | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }
  Say "RUN  $label"
  $p = Start-Process -FilePath "$bin\llama-server.exe" -ArgumentList $argList -PassThru -WindowStyle Hidden `
         -RedirectStandardError $log -RedirectStandardOutput "$log.out"
  try {
    $ready = $false
    for ($i = 0; $i -lt 180; $i++) {                      # up to ~6 min to load
      if ($p.HasExited) { break }
      try { $r = Invoke-WebRequest "http://127.0.0.1:$Port/health" -UseBasicParsing -TimeoutSec 3; if ($r.StatusCode -eq 200) { $ready = $true; break } } catch {}
      Start-Sleep -Seconds 2
    }
    if (-not $ready) {
      $tail = (Get-Content $log -Tail 400 -ErrorAction SilentlyContinue | Select-String -Pattern 'error|failed|out of memory|ggml_|abort' | Select-Object -Last 3 | ForEach-Object { $_.Line }) -join ' / '
      $res.note = "no start: $tail"; return $res
    }
    # warm-up (also compiles kernels) then 3 prompts x 2 runs, greedy + fixed seed => identical work in every config
    $body0 = @{ messages=@(@{role='user';content='Say hi.'}); max_tokens=16; temperature=0; chat_template_kwargs=@{enable_thinking=$false} } | ConvertTo-Json -Depth 6
    Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $body0 -ContentType 'application/json' -TimeoutSec 300 | Out-Null
    $tpsList = @(); $dn = 0; $da = 0
    foreach ($pr in $Prompts) {
      for ($k = 0; $k -lt 2; $k++) {
        $b = @{ messages=@(@{role='user';content=$pr.text}); max_tokens=320; temperature=0; seed=7; cache_prompt=$false
                chat_template_kwargs=@{enable_thinking=$false} } | ConvertTo-Json -Depth 6
        $o = Invoke-RestMethod "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 300
        $t = $o.timings
        if ($t -and $t.predicted_per_second) { $tpsList += [double]$t.predicted_per_second }
        if ($t -and $null -ne $t.draft_n) { $dn += [int]$t.draft_n; $da += [int]$t.draft_n_accepted }
      }
    }
    if ($tpsList.Count -eq 0) { $res.note = 'no timings in response'; return $res }
    $res.tps    = [math]::Round(($tpsList | Measure-Object -Average).Average, 1)
    $res.accept = if ($dn -gt 0) { [math]::Round(100.0 * $da / $dn, 1) } else { $null }
    $res.vram   = Get-VramUsedGB
    $res.ok     = $true
    if ($c.depth -gt 0 -and $dn -eq 0) { $res.note = 'MTP requested but no drafts reported (check log)' }
    return $res
  } catch {
    $res.note = "exception: $($_.Exception.Message)"; return $res
  } finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 4
  }
}

$all = New-Object System.Collections.ArrayList
function Run($c) {
  $r = Invoke-Config $c
  [void]$all.Add([pscustomobject]$r)
  $a = if ($null -ne $r.accept) { "$($r.accept)%" } else { '-' }
  $col = if ($r.ok) { 'Green' } else { 'Red' }
  Say ("     -> ok={0} tok/s={1} accept={2} vram={3}GB {4}" -f $r.ok, $r.tps, $a, $r.vram, $r.note) $col
  $all | Export-Csv -NoTypeInformation -Path "$Root\results\benchmark.csv"
  return [pscustomobject]$r
}
function Best($rows) { return ($rows | Where-Object { $_.ok -and $_.tps } | Sort-Object tps -Descending | Select-Object -First 1) }

# ---------------------------------------------------------------- 3. tuning stages
$best = $null
if (-not $SkipBench) {
  $ctx0 = 32768
  Say "=== Stage 0: baseline without MTP (this build) ===" 'Yellow'
  $base = Run @{ variant='plain'; depth=0; pmin=0; kv='q8_0'; dkv='f16'; ctx=$ctx0 }
  if (-not $base.ok) { Die "Baseline server failed: $($base.note). See logs in $Root\logs" }

  Say "=== Stage 1: draft depth / min-probability ===" 'Yellow'
  $grid = if ($Quick) { @(@(2,0),@(3,0),@(4,0)) } else { @(@(1,0),@(2,0),@(3,0),@(4,0),@(6,0),@(6,0.5),@(8,0.7)) }
  $s1 = @(); foreach ($g in $grid) { $s1 += Run @{ variant='plain'; depth=$g[0]; pmin=$g[1]; kv='q8_0'; dkv='f16'; ctx=$ctx0 } }
  $b1 = Best $s1
  if (-not $b1) { Die "No MTP configuration worked. See $Root\results\benchmark.csv and logs." }

  Say "=== Stage 2: KV cache precision (target + draft) ===" 'Yellow'
  $s2 = @($b1)
  foreach ($kvset in @(@('f16','f16'), @('q8_0','q8_0'), @('q4_0','q8_0'))) {
    if ($kvset[0] -eq $b1.kv -and $kvset[1] -eq $b1.dkv) { continue }
    $s2 += Run @{ variant='plain'; depth=$b1.depth; pmin=$b1.pmin; kv=$kvset[0]; dkv=$kvset[1]; ctx=$ctx0 }
  }
  # KV quality guard: q4_0 only wins if it is >5% faster than q8_0, otherwise stay on q8_0/f16
  $b2 = Best ($s2 | Where-Object { $_.kv -ne 'q4_0' })
  $q4 = $s2 | Where-Object { $_.kv -eq 'q4_0' -and $_.ok } | Select-Object -First 1
  if ($q4 -and $q4.tps -gt 1.05 * $b2.tps) { $b2 = $q4 }

  Say "=== Stage 3: rocWMMA flash-attention build ===" 'Yellow'
  $s3 = @($b2)
  $s3 += Run @{ variant='rocwmma'; depth=$b2.depth; pmin=$b2.pmin; kv=$b2.kv; dkv=$b2.dkv; ctx=$ctx0 }
  $b3 = Best $s3

  Say "=== Stage 4: maximum context that stays inside VRAM ===" 'Yellow'
  $okctx = $ctx0; $bestFinal = $b3
  foreach ($cx in @(49152, 65536, 98304, 131072, 196608)) {
    $r = Run @{ variant=$b3.variant; depth=$b3.depth; pmin=$b3.pmin; kv=$b3.kv; dkv=$b3.dkv; ctx=$cx }
    # pass = server started, VRAM below 15.3 GB (leaves headroom for Windows) and speed within 8% of the 32K figure
    if ($r.ok -and (($null -eq $r.vram) -or $r.vram -le 15.3) -and $r.tps -ge 0.92 * $b3.tps) { $okctx = $cx; $bestFinal = $r } else { break }
  }
  $best = $bestFinal
  $best | ConvertTo-Json | Set-Content "$Root\results\best-config.json"
  Say ("BEST: {0}  ->  {1} tok/s, accept {2}%, VRAM {3} GB (baseline no-MTP: {4} tok/s)" -f $best.label, $best.tps, $best.accept, $best.vram, $base.tps) 'Green'
}

# ---------------------------------------------------------------- 4. launcher
if (-not $best -and (Test-Path "$Root\results\best-config.json")) { $best = Get-Content "$Root\results\best-config.json" -Raw | ConvertFrom-Json }
if ($best) {
  $c = @{ variant=$best.variant; depth=[int]$best.depth; pmin=$best.pmin; kv=$best.kv; dkv=$best.dkv; ctx=[int]$best.ctx }
  $Port = 8080
  $bin = Get-Build $c.variant
  $a = Build-Args $c
  # card-recommended chat/sampling flags, only when this build supports them
  $a += @('--temp','1.0','--top-k','20','--top-p','0.95','--min-p','0','--presence-penalty','0','--repeat-penalty','1.0')
  if (Has '--reasoning-format') { $a += @('--reasoning-format','deepseek') }
  $line = ($a | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { "$_" } }) -join ' '
  $cmd = @(
    '@echo off',
    'title HauhauCS FastMTP server (127.0.0.1:8080)',
    "cd /d ""$bin""",
    'echo OpenAI-compatible endpoint: http://127.0.0.1:8080/v1   (stop with Ctrl+C)',
    "llama-server.exe $line",
    'pause'
  )
  Set-Content -Path "$Root\start-fastmtp.cmd" -Value $cmd -Encoding ASCII
  $desk = [Environment]::GetFolderPath('Desktop')
  Copy-Item "$Root\start-fastmtp.cmd" (Join-Path $desk 'Start FastMTP.cmd') -Force
  Say "Launcher: $Root\start-fastmtp.cmd  (copy on Desktop: 'Start FastMTP.cmd')" 'Green'
}
Say "Results: $Root\results\benchmark.csv" 'Green'
Stop-Transcript | Out-Null
