# buzz-image: generate or edit images with GPT Image through BUZZ, from Claude Code.
# Windows PowerShell 5.1+ version of gen.sh (same options, same JSON output).
# Spec: docs/BUZZ_IMAGE_SKILL_DESIGN.md
#
#   gen.ps1 -Prompt "..." [-Out out.png] [-Model m] [-Size s] [-Quality q] [-Background b]
#           [-Format png|jpeg|webp] [-N 1-10] [-Ref a.png,b.png] [-Mask m.png] [-NoUpscale]
#   gen.ps1 -Models
#
# stdout: exactly one JSON line. Exit code 0 on success, 1 on failure.
param(
  [string]$Prompt = "",
  [string]$Out = "",
  [string]$Model = "",
  [string]$Size = "",
  [string]$Quality = "",
  [string]$Background = "",
  [string]$Format = "png",
  [int]$N = 1,
  [string[]]$Ref = @(),
  [string]$Mask = "",
  [switch]$Models,
  [switch]$NoUpscale
)

$BuzzImageVersion = "1.3.0"

$ErrorActionPreference = "Stop"
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Emit($obj) { Write-Output ($obj | ConvertTo-Json -Compress -Depth 5) }
function Fail([string]$code, [string]$message, $extra = $null) {
  $o = [ordered]@{ ok = $false; code = $code; message = $message }
  if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }
  Emit $o
  exit 1
}

# ------------------------------------------------------------------ arguments
if (-not $Models) {
  if (-not $Prompt) { Fail "bad_args" "missing -Prompt" }
  if ($N -lt 1 -or $N -gt 10) { Fail "bad_args" "-N must be 1-10" }
  if (@("png", "jpeg", "webp") -notcontains $Format) { Fail "bad_args" "-Format must be png, jpeg or webp" }
  if (@("", "auto", "low", "medium", "high", "xhigh", "max") -notcontains $Quality) { Fail "bad_args" "-Quality must be low|medium|high|xhigh|max|auto" }
  if (@("", "auto", "opaque", "transparent") -notcontains $Background) { Fail "bad_args" "-Background must be auto|opaque|transparent" }
  if ($Background -eq "transparent" -and $Format -eq "jpeg") { Fail "bad_args" "transparent background needs png or webp" }
  foreach ($r in $Ref) { if (-not (Test-Path -LiteralPath $r -PathType Leaf)) { Fail "bad_args" "reference image not found: $r" } }
  if ($Mask) {
    if (-not (Test-Path -LiteralPath $Mask -PathType Leaf)) { Fail "bad_args" "mask not found: $Mask" }
    if ($Ref.Count -eq 0) { Fail "bad_args" "-Mask needs at least one -Ref reference image" }
  }
}

# ------------------------------------------------------------------ sizes
function IsLegal([int]$w, [int]$h) {
  $mx = [Math]::Max($w, $h); $mn = [Math]::Min($w, $h)
  return ($w % 16 -eq 0) -and ($h % 16 -eq 0) -and ($mx -le 3840) -and ($mx / $mn -le 3) -and ($w * $h -ge 655360) -and ($w * $h -le 8294400)
}
$targetW = 0; $targetH = 0; $genSize = ""
$presets = @{ "square" = "1024x1024"; "1k" = "1024x1024"; "landscape" = "1536x1024"; "portrait" = "1024x1536";
  "wide" = "1792x1008"; "tall" = "1008x1792"; "2k" = "2048x2048"; "4k" = "3840x2160" }
if ($Size -and $Size -ne "auto") {
  if ($presets.ContainsKey($Size)) { $genSize = $presets[$Size] }
  elseif ($Size -match '^(\d+)x(\d+)$') {
    $tw = [int]$Matches[1]; $th = [int]$Matches[2]
    if ($tw -lt 1 -or $th -lt 1 -or $tw -gt 16384 -or $th -gt 16384) { Fail "bad_args" "size out of range: $Size" }
    if (IsLegal $tw $th) { $genSize = "${tw}x${th}" }
    else {
      $targetW = $tw; $targetH = $th
      $r = [Math]::Min(3.0, [Math]::Max(1.0 / 3.0, $tw / $th))
      $area = [Math]::Min(8294400.0, [Math]::Max(1048576.0, [double]$tw * $th))
      $gw = [Math]::Sqrt($area * $r); $gh = $gw / $r
      if ($gw -gt 3840) { $gh = $gh * 3840 / $gw; $gw = 3840 }
      if ($gh -gt 3840) { $gw = $gw * 3840 / $gh; $gh = 3840 }
      $gw = [int]([Math]::Floor($gw / 16 + 0.5)) * 16; $gh = [int]([Math]::Floor($gh / 16 + 0.5)) * 16
      while ($gw * $gh -gt 8294400 -or $gw -gt 3840 -or $gh -gt 3840) { if ($gw -ge $gh) { $gw -= 16 } else { $gh -= 16 } }
      while ($gw * $gh -lt 655360) { if ($gw -le $gh) { $gw += 16 } else { $gh += 16 } }
      $genSize = "${gw}x${gh}"
    }
  }
  else { Fail "bad_args" "-Size must be WxH or square|landscape|portrait|wide|tall|2k|4k|auto" }
}

# ------------------------------------------------------------------ Claude Code config
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME ".claude" }
# Reads a value from the env block of Claude Code's settings, or a top-level key with -Top.
function SettingsVal([string]$name, [switch]$Top) {
  foreach ($f in @((Join-Path $configDir "settings.local.json"), (Join-Path $configDir "settings.json"))) {
    if (Test-Path -LiteralPath $f) {
      try {
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Top) { if ($j.$name) { return [string]$j.$name } }
        elseif ($j.env -and $j.env.$name) { return [string]$j.env.$name }
      } catch { }
    }
  }
  return ""
}
# BUZZ_BASE_URL overrides Claude Code's address, for setups where Claude Code
# talks to BUZZ through a local relay or proxy.
$base = $env:BUZZ_BASE_URL
if (-not $base) { $base = $env:ANTHROPIC_BASE_URL }
if (-not $base) { $base = SettingsVal "BUZZ_BASE_URL" }
if (-not $base) { $base = SettingsVal "ANTHROPIC_BASE_URL" }
# BUZZ_IMAGE_API_KEY: an optional key just for images (e.g. a token in a group that
# has gpt-image models), so chat and images can use different keys at the same time.
$key = $env:BUZZ_IMAGE_API_KEY
if (-not $key) { $key = SettingsVal "BUZZ_IMAGE_API_KEY" }
if (-not $key) { $key = $env:ANTHROPIC_AUTH_TOKEN }
if (-not $key) { $key = $env:ANTHROPIC_API_KEY }
if (-not $key) { $key = SettingsVal "ANTHROPIC_AUTH_TOKEN" }
if (-not $key) { $key = SettingsVal "ANTHROPIC_API_KEY" }
if (-not $key) {
  # Claude Code's apiKeyHelper: a command that prints the key.
  $helper = SettingsVal "apiKeyHelper" -Top
  if ($helper) {
    try {
      # Claude Code on Windows runs shell commands with Git Bash; find it the same way.
      $sh = $env:CLAUDE_CODE_GIT_BASH_PATH
      if (-not $sh -or -not (Test-Path -LiteralPath $sh)) {
        $sh = $null
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($git) {
          $root = Split-Path (Split-Path $git.Source -Parent) -Parent
          foreach ($c in @((Join-Path $root 'bin\bash.exe'), (Join-Path $root 'usr\bin\bash.exe'))) { if (Test-Path -LiteralPath $c) { $sh = $c; break } }
        }
      }
      $outLines = if ($sh) { & $sh -c $helper 2>$null } else { & cmd.exe /d /c $helper 2>$null }
      $first = @($outLines | Where-Object { "$_".Trim() })[0]
      if ($first) { $key = "$first".Trim() }
    } catch { }
  }
}
if (-not $base) { Fail "not_buzz" "Claude Code is not connected to BUZZ (ANTHROPIC_BASE_URL is not set)." }
$base = $base.TrimEnd("/")
if ($base.EndsWith("/v1")) { $base = $base.Substring(0, $base.Length - 3).TrimEnd("/") }

Add-Type -AssemblyName System.Net.Http
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

# Identify the gateway before any key leaves this machine.
$probe = New-Object System.Net.Http.HttpClient
$userAgent = "buzz-image/$BuzzImageVersion"
$probe.DefaultRequestHeaders.UserAgent.ParseAdd($userAgent)
$probe.Timeout = [TimeSpan]::FromSeconds(20)
$statusText = ""
try { $statusText = $probe.GetStringAsync("$base/api/status").GetAwaiter().GetResult() } catch { }
# A relay in front of BUZZ may refuse anonymous requests, so retry once with the
# key: it goes only to the address Claude Code already sends it to.
if ($statusText -notmatch '"gateway"\s*:\s*"buzz"' -and $key) {
  try {
    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "$base/api/status")
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $key)
    $statusText = $probe.SendAsync($req).GetAwaiter().GetResult().Content.ReadAsStringAsync().GetAwaiter().GetResult()
  } catch { }
}
if ($statusText -notmatch '"gateway"\s*:\s*"buzz"') {
  Fail "not_buzz" "$base did not identify itself as BUZZ, so buzz-image will not use it. If Claude Code reaches BUZZ through a local relay or proxy, set BUZZ_BASE_URL to your BUZZ API address (as an environment variable, or in the env block of Claude Code's settings.json)."
}
if (-not $key) { Fail "no_key" "No API key found in Claude Code's configuration." }

$client = New-Object System.Net.Http.HttpClient
$client.DefaultRequestHeaders.UserAgent.ParseAdd($userAgent)
$client.Timeout = [TimeSpan]::FromSeconds(540)
$client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", $key)

function ErrMessage([string]$text) {
  try { $j = $text | ConvertFrom-Json; if ($j.error -and $j.error.message) { return [string]$j.error.message }; if ($j.message) { return [string]$j.message } } catch { }
  return ""
}
function ErrCode([string]$text) {
  try { $j = $text | ConvertFrom-Json; if ($j.error -and $j.error.code) { return [string]$j.error.code } } catch { }
  return ""
}

# ------------------------------------------------------------------ models
$available = @()
try {
  $mr = $client.GetAsync("$base/v1/models").GetAwaiter().GetResult()
  $mt = $mr.Content.ReadAsStringAsync().GetAwaiter().GetResult()
} catch { Fail "http_error" "Could not list models: $($_.Exception.Message)" }
if (-not $mr.IsSuccessStatusCode) {
  $m = ErrMessage $mt
  Fail "http_error" ("Could not list models (HTTP {0}){1}" -f [int]$mr.StatusCode, $(if ($m) { ": $m" } else { "" }))
}
try { $available = @(($mt | ConvertFrom-Json).data | ForEach-Object { [string]$_.id } | Where-Object { $_ -like "gpt-image*" } | Sort-Object -Unique) } catch { }

if ($available.Count -eq 0) {
  Fail "no_image_model" "Your key's group has no GPT Image model. Change the key's group in the BUZZ console to one that includes gpt-image models, or set BUZZ_IMAGE_API_KEY to a separate key whose group has them." @{ available_models = @() }
}
if ($Models) { Emit ([ordered]@{ ok = $true; models = $available }); exit 0 }
if ($Model) {
  if ($available -notcontains $Model) { Fail "model_unavailable" "Model $Model is not available for this key." @{ available_models = $available } }
} else {
  foreach ($m in @("gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2")) { if ($available -contains $m) { $Model = $m; break } }
  if (-not $Model) { $Model = $available[0] }
}

# ------------------------------------------------------------------ output paths
$ext = if ($Format -eq "jpeg") { "jpg" } else { $Format }
if (-not $Out) { $Out = "generated\image-$(Get-Date -Format 'yyyyMMdd-HHmmss').$ext" }
if (-not [IO.Path]::HasExtension($Out)) { $Out = "$Out.$ext" }
$cwd = (Get-Location).ProviderPath
$outFull = if ([IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $cwd $Out }
$outFull = [IO.Path]::GetFullPath($outFull)
$dir = [IO.Path]::GetDirectoryName($outFull)
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$stem = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($outFull))
$oext = [IO.Path]::GetExtension($outFull)
function UniquePath() { $p = "$stem$oext"; $i = 2; while (Test-Path -LiteralPath $p) { $p = "$stem-$i$oext"; $i++ }; return $p }
function RelPath([string]$p) {
  $prefix = $cwd.TrimEnd("\") + "\"
  if ($p.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($prefix.Length) }
  return $p
}

# ------------------------------------------------------------------ requests
function NewRequest() {
  if ($Ref.Count -gt 0) {
    $form = New-Object System.Net.Http.MultipartFormDataContent
    $fields = [ordered]@{ model = $Model; prompt = $Prompt; n = "1"; output_format = $Format }
    if ($genSize) { $fields["size"] = $genSize }
    if ($Quality) { $fields["quality"] = $Quality }
    if ($Background) { $fields["background"] = $Background }
    foreach ($k in $fields.Keys) { $form.Add((New-Object System.Net.Http.StringContent([string]$fields[$k], [Text.Encoding]::UTF8)), $k) }
    foreach ($r in $Ref) {
      $c = New-Object System.Net.Http.ByteArrayContent(, [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $r).ProviderPath))
      $form.Add($c, "image[]", [IO.Path]::GetFileName($r))
    }
    if ($Mask) {
      $mc = New-Object System.Net.Http.ByteArrayContent(, [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Mask).ProviderPath))
      $form.Add($mc, "mask", [IO.Path]::GetFileName($Mask))
    }
    return $client.PostAsync("$base/v1/images/edits", $form)
  }
  $body = [ordered]@{ model = $Model; prompt = $Prompt; n = 1; output_format = $Format }
  if ($genSize) { $body["size"] = $genSize }
  if ($Quality) { $body["quality"] = $Quality }
  if ($Background) { $body["background"] = $Background }
  $content = New-Object System.Net.Http.StringContent(($body | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, "application/json")
  return $client.PostAsync("$base/v1/images/generations", $content)
}

# Chinese gateway messages, kept as \u escapes so this file stays pure ASCII
# (Windows PowerShell 5.1 misreads non-ASCII in BOM-less scripts).
$zhBalance = [regex]::Unescape('\u4f59\u989d\u4e0d\u8db3|\u989d\u5ea6\u4e0d\u8db3')
$zhPolicy = [regex]::Unescape('\u5ba1\u6838|\u8fdd\u89c4')
$zhUnavailable = [regex]::Unescape('\u6682\u65f6\u4e0d\u53ef\u7528|\u65e0\u53ef\u7528\u6e20\u9053')
function Classify([int]$http, [string]$text) {
  $msg = ErrMessage $text; $ec = ErrCode $text
  $lower = ("$ec $msg").ToLowerInvariant()
  if ($lower -match 'insufficient.*quota|quota.*insufficient|insufficient_user_quota|balance' -or $msg -match $zhBalance) { return @("insufficient_balance", $(if ($msg) { $msg } else { "Insufficient balance" })) }
  if ($lower -match 'moderation|content_policy|safety|policy|violat' -or $msg -match $zhPolicy) { return @("content_policy", $(if ($msg) { $msg } else { "Rejected by content policy" })) }
  if ($lower -match 'model_not_found|not.*available|no.*available.*channel' -or $msg -match $zhUnavailable) { return @("model_unavailable", $(if ($msg) { $msg } else { "Model unavailable" })) }
  return @("http_error", ("HTTP {0}{1}" -f $http, $(if ($msg) { ": $msg" } else { "" })))
}

# Pixel size of a saved image as @(w, h); $null when it cannot be read.
function ImageDims([string]$path) {
  try {
    $fs = [IO.File]::OpenRead($path)
    try { $hd = New-Object byte[] 24; $read = $fs.Read($hd, 0, 24) } finally { $fs.Dispose() }
    if ($read -eq 24 -and $hd[0] -eq 0x89 -and $hd[1] -eq 0x50 -and $hd[2] -eq 0x4E -and $hd[3] -eq 0x47) {
      $w = (([int]$hd[16] -shl 24) -bor ([int]$hd[17] -shl 16) -bor ([int]$hd[18] -shl 8) -bor [int]$hd[19])
      $h = (([int]$hd[20] -shl 24) -bor ([int]$hd[21] -shl 16) -bor ([int]$hd[22] -shl 8) -bor [int]$hd[23])
      return @($w, $h)
    }
    Add-Type -AssemblyName System.Drawing
    $ms = New-Object IO.MemoryStream(, [IO.File]::ReadAllBytes($path))
    $img = [System.Drawing.Image]::FromStream($ms)
    try { return @($img.Width, $img.Height) } finally { $img.Dispose(); $ms.Dispose() }
  } catch { return $null }
}

# The size the saved files must end up at: an exact -Size WxH, or the size sent to
# the model. Models may return fewer pixels than asked (same aspect ratio), so
# every file is measured and scaled to this size when it differs.
$wantW = $targetW; $wantH = $targetH
if ($wantW -eq 0 -and $genSize) { $wantW = [int]($genSize.Split("x")[0]); $wantH = [int]($genSize.Split("x")[1]) }

# Cover-scale then centre-crop to exactly wantW x wantH, keeping alpha.
function ResizeToTarget([string]$path) {
  $targetW = $wantW; $targetH = $wantH
  if ($Format -eq "webp") { return "Windows built-in imaging cannot write webp" }
  try {
    Add-Type -AssemblyName System.Drawing
    $bytes = [IO.File]::ReadAllBytes($path)
    $ms = New-Object IO.MemoryStream(, $bytes)
    $src = [System.Drawing.Image]::FromStream($ms)
    try {
      $s = [Math]::Max($targetW / $src.Width, $targetH / $src.Height)
      $dw = [int][Math]::Ceiling($src.Width * $s); $dh = [int][Math]::Ceiling($src.Height * $s)
      $bmp = New-Object System.Drawing.Bitmap($targetW, $targetH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
      $g.DrawImage($src, [int](($targetW - $dw) / 2), [int](($targetH - $dh) / 2), $dw, $dh)
      $g.Dispose()
    } finally { $src.Dispose(); $ms.Dispose() }
    $fmt = if ($Format -eq "jpeg") { [System.Drawing.Imaging.ImageFormat]::Jpeg } else { [System.Drawing.Imaging.ImageFormat]::Png }
    $bmp.Save($path, $fmt); $bmp.Dispose()
    return ""
  } catch { return "Windows built-in imaging failed: $($_.Exception.Message)" }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$tasks = @(); for ($i = 0; $i -lt $N; $i++) { $tasks += NewRequest }
$files = New-Object System.Collections.ArrayList
$errors = New-Object System.Collections.ArrayList
$firstCode = ""; $firstMsg = ""; $resized = $null; $resizeNote = ""; $gotSize = ""; $finalSize = ""

foreach ($t in $tasks) {
  try {
    $resp = $t.GetAwaiter().GetResult()
    $text = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
  } catch {
    $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
    if ($e -is [System.Threading.Tasks.TaskCanceledException] -or $e -is [TimeoutException]) {
      $c = @("timeout", "Request timed out after 540s. Not retried automatically: the image may still have been generated and billed.")
    } else { $c = @("http_error", "Network error: $($e.Message)") }
    [void]$errors.Add($c[1]); if (-not $firstCode) { $firstCode = $c[0]; $firstMsg = $c[1] }
    continue
  }
  $item = $null
  if ($resp.IsSuccessStatusCode) { try { $item = @(($text | ConvertFrom-Json).data)[0] } catch { } }
  if (-not $item -or (-not $item.b64_json -and -not $item.url)) {
    $c = if ($resp.IsSuccessStatusCode) { @("http_error", "No image in the response") } else { Classify ([int]$resp.StatusCode) $text }
    [void]$errors.Add($c[1]); if (-not $firstCode) { $firstCode = $c[0]; $firstMsg = $c[1] }
    continue
  }
  $target = UniquePath
  try {
    if ($item.b64_json) { [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String([string]$item.b64_json)) }
    else {
      $dl = New-Object System.Net.Http.HttpClient; $dl.Timeout = [TimeSpan]::FromSeconds(120); $dl.DefaultRequestHeaders.UserAgent.ParseAdd($userAgent)
      [IO.File]::WriteAllBytes($target, $dl.GetByteArrayAsync([string]$item.url).GetAwaiter().GetResult())
    }
  } catch { }
  if (-not (Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -eq 0) {
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target }
    [void]$errors.Add("could not save the image"); if (-not $firstCode) { $firstCode = "http_error"; $firstMsg = "could not save the image" }
    continue
  }
  $dims = ImageDims $target
  if (-not $gotSize -and $dims) { $gotSize = "$($dims[0])x$($dims[1])" }
  # Scale when the measured size differs. If it can't be measured, scale only
  # sizes the model can't produce at all (it never returns those as asked).
  $need = $false
  if ($wantW -gt 0) {
    if ($dims) { $need = ($dims[0] -ne $wantW -or $dims[1] -ne $wantH) }
    elseif ($targetW -gt 0) { $need = $true }
  }
  # -NoUpscale: a smaller image at the requested aspect ratio (within 1%) is kept as is.
  if ($need -and $NoUpscale -and $dims -and $dims[0] -le $wantW -and $dims[1] -le $wantH) {
    $ratio = ($dims[0] / $dims[1]) / ($wantW / $wantH)
    if ($ratio -gt 0.99 -and $ratio -lt 1.01) { $need = $false; $resizeNote = "kept the model's smaller image as is (-NoUpscale)" }
  }
  if ($need) {
    $why = ResizeToTarget $target
    if ($why) { $resized = $false; $resizeNote = $why }
    else { $resized = $true; $dims = ImageDims $target; if (-not $dims) { $dims = @($wantW, $wantH) } }
  }
  if (-not $finalSize -and $dims) { $finalSize = "$($dims[0])x$($dims[1])" }
  [void]$files.Add((RelPath $target))
}

$elapsed = [int]$sw.Elapsed.TotalSeconds
if ($files.Count -eq 0) {
  Emit ([ordered]@{ ok = $false; code = $(if ($firstCode) { $firstCode } else { "http_error" }); message = $firstMsg; model = $Model; seconds = $elapsed; errors = @($errors) })
  exit 1
}
# size: measured pixels of the saved file(s); generated_size: what the model returned.
if (-not $finalSize) { $finalSize = "unknown" }
if (-not $gotSize) { $gotSize = "unknown" }
$result = [ordered]@{ ok = $true; model = $Model; files = @($files); size = $finalSize; generated_size = $gotSize }
if ($wantW -gt 0) { $result["requested_size"] = "${wantW}x${wantH}"; $result["resized"] = ($resized -eq $true) }
if ($resizeNote) { $result["resize_note"] = $resizeNote }
$result["seconds"] = $elapsed
$result["errors"] = @($errors)
Emit $result
