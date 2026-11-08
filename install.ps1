# BUZZ AI - buzz-image skill installer (Windows PowerShell 5.1+)
#
# Install / update: irm https://buzzai.cc/sh/buzz-image.ps1 | iex
# Uninstall:        powershell -NoProfile -ExecutionPolicy Bypass -File buzz-image.ps1 -Uninstall
#                   (with irm | iex, set $env:BUZZ_IMAGE_UNINSTALL = '1' first)
# Help:             -Help
#
# Writes only to $CLAUDE_CONFIG_DIR\skills\buzz-image (default $HOME\.claude).
# Never modifies other files, never reads or prints the API key.
# This file is ASCII-only: Chinese strings are \u escapes passed through T().

param(
    [switch]$Uninstall,
    [switch]$Help
)

# Route A, route B. Not tried in a fixed order: each is latency-tested and the
# fastest reachable one is used (see Get-SiteOrder); BUZZ_SITE overrides.
$BuzzSites = @('https://buzzai.cc', 'https://buzzgw.com')
$SkillRel = 'sh/skills/buzz-image'
$DocsPath = 'docs/guides/claude-code-image.html'
$DocsUrl = 'https://buzzai.cc/' + $DocsPath

# Bilingual message helper. Language follows the system UI culture (en* -> English, else Chinese).
function T([string]$zh, [string]$en) {
    if ([System.Globalization.CultureInfo]::CurrentUICulture.Name -like 'en*') {
        return $en
    }
    return [regex]::Unescape($zh)
}

function Write-Status([string]$Type, [string]$Message) {
    switch ($Type) {
        'ok'    { Write-Host '  [OK] ' -NoNewline -ForegroundColor Green;  Write-Host $Message }
        'info'  { Write-Host '  [*] ' -NoNewline -ForegroundColor Cyan;    Write-Host $Message }
        'warn'  { Write-Host '  [!] ' -NoNewline -ForegroundColor Yellow;  Write-Host $Message }
        'error' { Write-Host '  [x] ' -NoNewline -ForegroundColor Red;     Write-Host $Message }
        default { Write-Host "  $Message" }
    }
}

function Show-Help {
    Write-Host ''
    Write-Host (T 'buzz-image \u6280\u80fd\u5b89\u88c5\u5668' 'BUZZ AI - buzz-image skill installer')
    Write-Host ''
    Write-Host (T '  \u7528\u6cd5:' '  Usage:')
    Write-Host '    irm https://buzzai.cc/sh/buzz-image.ps1 | iex              '
    Write-Host ('      ' + (T '\u5b89\u88c5 / \u66f4\u65b0' 'install / update'))
    Write-Host '    powershell -ExecutionPolicy Bypass -File buzz-image.ps1 -Uninstall'
    Write-Host ('      ' + (T '\u5378\u8f7d' 'uninstall'))
    Write-Host ''
    Write-Host (T '  \u73af\u5883\u53d8\u91cf:' '  Environment:')
    Write-Host (T '    BUZZ_SITE=URL             \u6307\u5b9a\u4e0b\u8f7d\u7ad9\u70b9(\u9ed8\u8ba4\u5bf9 buzzai.cc\u3001buzzgw.com \u6d4b\u901f\u540e\u9009\u6700\u5feb\u7684)' '    BUZZ_SITE=URL             download site (default: the fastest of buzzai.cc / buzzgw.com)')
    Write-Host (T '    CLAUDE_CONFIG_DIR=DIR     Claude Code \u914d\u7f6e\u76ee\u5f55(\u9ed8\u8ba4\u4e3a\u7528\u6237\u76ee\u5f55\u4e0b\u7684 .claude)' '    CLAUDE_CONFIG_DIR=DIR     Claude Code config dir (default: $HOME\.claude)')
    Write-Host (T '    BUZZ_IMAGE_UNINSTALL=1    \u7b49\u540c\u4e8e -Uninstall' '    BUZZ_IMAGE_UNINSTALL=1    same as -Uninstall')
    Write-Host ''
}

function Get-ConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) {
        return $env:CLAUDE_CONFIG_DIR
    }
    return (Join-Path $HOME '.claude')
}

function Get-InstallDir {
    return (Join-Path (Join-Path (Get-ConfigDir) 'skills') 'buzz-image')
}

# Returns $true when the file downloaded and is non-empty / well-formed; otherwise $false.
function Get-SkillFile([string]$Url, [string]$Dest, [int]$TimeoutSec = 60) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec $TimeoutSec | Out-Null
        return $true
    } catch {
        if (Test-Path -LiteralPath $Dest) {
            Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# Non-empty check; SKILL.md first line must be '---'; no file may look like an HTML error page.
function Test-SkillFile([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    if ((Get-Item -LiteralPath $Path).Length -le 0) {
        Write-Status 'error' ((T '\u6587\u4ef6\u4e3a\u7a7a' 'empty file') + ': ' + $Name)
        return $false
    }
    $first = [string](Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8)
    $first = $first.TrimStart([char]0xFEFF).Trim()
    if ($Name -eq 'SKILL.md' -and $first -ne '---') {
        Write-Status 'error' (T 'SKILL.md \u683c\u5f0f\u4e0d\u6b63\u786e(\u9996\u884c\u5e94\u4e3a ---)' 'SKILL.md is malformed (first line should be ---)')
        return $false
    }
    if ($first.StartsWith('<')) {
        Write-Status 'error' ((T '\u4e0b\u8f7d\u5230\u7684\u4e0d\u662f skill \u6587\u4ef6(\u7591\u4f3c HTML \u9875\u9762)' 'downloaded content is not a skill file (looks like HTML)') + ': ' + $Name)
        return $false
    }
    return $true
}

# Tries each site in order; the first whose SKILL.md downloads and validates wins. Returns the site URL.
# Sites fastest first (GET /ping); unreachable ones go last but are still tried.
function Get-SiteOrder {
    $ok = @(); $bad = @()
    foreach ($s in $BuzzSites) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $r = Invoke-WebRequest -Uri ($s + '/ping') -UseBasicParsing -TimeoutSec 4
            if ([int]$r.StatusCode -eq 200) {
                $ok += [pscustomobject]@{ Site = $s; Ms = $sw.ElapsedMilliseconds }
                continue
            }
        } catch {
            # Unreachable: tried last.
        }
        $bad += $s
    }
    return @(@($ok | Sort-Object Ms | ForEach-Object { $_.Site }) + $bad)
}

function Select-Site([string]$TmpDir) {
    if ($env:BUZZ_SITE) {
        $candidates = @($env:BUZZ_SITE.Trim().TrimEnd('/'))
    } else {
        Write-Status 'info' (T '\u6b63\u5728\u6d4b\u8bd5\u7ebf\u8def\u5ef6\u8fdf...' 'Testing route latency...')
        $candidates = Get-SiteOrder
    }
    foreach ($site in $candidates) {
        Write-Status 'info' (T ('\u6b63\u5728\u4ece ' + $site + ' \u4e0b\u8f7d skill \u6587\u4ef6') ('Downloading skill files from ' + $site))
        $dest = Join-Path $TmpDir 'SKILL.md'
        if ((Get-SkillFile "$site/$SkillRel/SKILL.md" $dest 15) -and (Test-SkillFile $dest 'SKILL.md')) {
            $script:DocsUrl = $site + '/' + $DocsPath
            return $site
        }
        Write-Status 'warn' ($site + ' ' + (T '\u4e0d\u53ef\u7528,\u5c1d\u8bd5\u4e0b\u4e00\u4e2a\u7ad9\u70b9' 'unavailable, trying next site'))
    }
    throw (T '\u6240\u6709\u7ad9\u70b9\u90fd\u4e0b\u8f7d\u5931\u8d25,\u8bf7\u68c0\u67e5\u7f51\u7edc\u540e\u91cd\u8bd5' 'all sites failed; check your network and retry')
}

function Download-Skill([string]$TmpDir) {
    $null = New-Item -ItemType Directory -Path (Join-Path $TmpDir 'scripts') -Force
    $site = Select-Site $TmpDir
    foreach ($rel in @('scripts/gen.sh', 'scripts/gen.ps1')) {
        $dest = Join-Path $TmpDir ($rel -replace '/', '\')
        if (-not (Get-SkillFile "$site/$SkillRel/$rel" $dest)) {
            throw ((T '\u4e0b\u8f7d\u5931\u8d25' 'download failed') + ': ' + $rel)
        }
        if (-not (Test-SkillFile $dest $rel)) {
            throw (T '\u6821\u9a8c\u5931\u8d25,\u5df2\u4e2d\u6b62\u5b89\u88c5,\u65e7\u7248\u672c\u672a\u6539\u52a8' 'validation failed; install aborted, existing install untouched')
        }
    }
    Write-Status 'ok' (T '\u6587\u4ef6\u5df2\u4e0b\u8f7d\u5e76\u901a\u8fc7\u6821\u9a8c' 'files downloaded and validated')
    return $site
}

function Show-InstalledVersion([string]$TmpDir) {
    # The version lives in gen.ps1 ($BuzzImageVersion = "x.y"), the same value the skill sends as its User-Agent.
    $line = Select-String -LiteralPath (Join-Path $TmpDir 'scripts\gen.ps1') -Pattern '^\$BuzzImageVersion\s*=' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($line) {
        $ver = ($line.Line -replace '^\$BuzzImageVersion\s*=\s*', '').Trim().Trim('"', "'")
        if ($ver) {
            Write-Status 'info' ((T '\u7248\u672c' 'Version') + ': ' + $ver)
        }
    }
}

# Stages the new copy beside the old one, then swaps it in; restores the old copy if the swap fails.
function Install-Skill([string]$TmpDir) {
    $target = Get-InstallDir
    $skillsDir = Split-Path -Parent $target
    $stamp = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $skillsDir ('.buzz-image.new-' + $stamp)
    $backup = Join-Path $skillsDir ('.buzz-image.old-' + $stamp)

    $null = New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force
    try {
        Copy-Item -LiteralPath (Join-Path $TmpDir 'SKILL.md') -Destination (Join-Path $stage 'SKILL.md') -Force
        Copy-Item -LiteralPath (Join-Path $TmpDir 'scripts\gen.sh') -Destination (Join-Path $stage 'scripts\gen.sh') -Force
        Copy-Item -LiteralPath (Join-Path $TmpDir 'scripts\gen.ps1') -Destination (Join-Path $stage 'scripts\gen.ps1') -Force
    } catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        throw (T '\u590d\u5236\u6587\u4ef6\u5931\u8d25' 'failed to copy files')
    }

    $hadOld = Test-Path -LiteralPath $target
    if ($hadOld) {
        Move-Item -LiteralPath $target -Destination $backup -Force
    }
    try {
        Move-Item -LiteralPath $stage -Destination $target -Force
    } catch {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        if ($hadOld) {
            Move-Item -LiteralPath $backup -Destination $target -Force -ErrorAction SilentlyContinue
        }
        throw (T '\u5b89\u88c5\u5931\u8d25,\u5df2\u8fd8\u539f\u65e7\u7248\u672c' 'install failed; previous version restored')
    }
    if ($hadOld) {
        Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Status 'ok' ((T '\u5df2\u5b89\u88c5\u5230' 'Installed to') + ' ' + $target)
}

# Base URL from the environment first, then settings.local.json and settings.json (env block). Key is never read.
# Same order as the skill: BUZZ_BASE_URL (relay/proxy setups) wins over Claude Code's address.
function Get-BaseUrl {
    if ($env:BUZZ_BASE_URL) {
        return [string]$env:BUZZ_BASE_URL
    }
    if ($env:ANTHROPIC_BASE_URL) {
        return [string]$env:ANTHROPIC_BASE_URL
    }
    $cfg = Get-ConfigDir
    foreach ($f in @((Join-Path $cfg 'settings.local.json'), (Join-Path $cfg 'settings.json'))) {
        if (-not (Test-Path -LiteralPath $f)) {
            continue
        }
        try {
            $json = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            $v = $json.env.BUZZ_BASE_URL
            if (-not $v) {
                $v = $json.env.ANTHROPIC_BASE_URL
            }
            if ($v) {
                return [string]$v
            }
        } catch {
            # Unreadable settings file: treat as absent and keep going.
        }
    }
    return ''
}

# Unauthenticated GET /api/status; only a reply containing "gateway":"buzz" counts as connected. Warns only.
function Test-BuzzGateway {
    $base = (Get-BaseUrl).Trim().TrimEnd('/')
    if ($base.EndsWith('/v1')) {
        $base = $base.Substring(0, $base.Length - 3).TrimEnd('/')
    }

    if (-not $base) {
        Write-Status 'warn' (T '\u8b66\u544a: \u672a\u627e\u5230 Claude Code \u7684 ANTHROPIC_BASE_URL \u914d\u7f6e' 'WARNING: no ANTHROPIC_BASE_URL found in Claude Code config')
    } else {
        $connected = $false
        try {
            $resp = Invoke-WebRequest -Uri ($base + '/api/status') -UseBasicParsing -TimeoutSec 10
            if ([string]$resp.Content -match '"gateway"\s*:\s*"buzz"') {
                $connected = $true
            }
        } catch {
            $connected = $false
        }
        if ($connected) {
            Write-Status 'ok' (T 'Claude Code \u5df2\u63a5\u5165 BUZZ\u3002\u91cd\u542f Claude Code \u6216\u8fd0\u884c /reload-skills,\u7136\u540e\u76f4\u63a5\u8bf4\u8981\u7684\u56fe\u7247\u5373\u53ef\u3002' 'Claude Code is connected to BUZZ. Restart Claude Code or run /reload-skills, then just ask for an image.')
            return
        }
        Write-Status 'warn' (T '\u8b66\u544a: \u65e0\u6cd5\u786e\u8ba4\u5f53\u524d\u5730\u5740\u662f BUZZ \u7f51\u5173(\u53ef\u80fd\u6682\u65f6\u65e0\u6cd5\u8bbf\u95ee,\u6216\u7ecf\u672c\u5730\u4e2d\u7ee7/\u4ee3\u7406\u63a5\u5165)' 'WARNING: could not confirm the configured base URL is a BUZZ gateway (unreachable, or behind a local relay/proxy)')
        Write-Status 'warn' (T '\u5982\u679c Claude Code \u7ecf\u672c\u5730\u4e2d\u7ee7\u6216\u4ee3\u7406\u63a5\u5165 BUZZ,\u628a BUZZ_BASE_URL \u8bbe\u4e3a\u4f60\u7684 BUZZ API \u5730\u5740\u5373\u53ef\u3002' 'If Claude Code reaches BUZZ through a local relay or proxy, set BUZZ_BASE_URL to your BUZZ API address.')
    }
    Write-Status 'warn' ((T '\u6ce8\u610f: \u8fd9\u4e2a skill \u53ea\u6709\u5728 Claude Code \u63a5\u5165 BUZZ \u540e\u624d\u80fd\u4f7f\u7528\u3002\u63a5\u5165\u6559\u7a0b:' 'Note: this skill only works when Claude Code is connected to BUZZ. Setup guide:') + ' ' + $DocsUrl)
}

function Install-BuzzImage {
    Write-Status 'info' ((T '\u5b89\u88c5 buzz-image skill \u5230' 'Installing buzz-image skill to') + ' ' + (Get-InstallDir))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('buzz-image-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmp -Force
    try {
        $null = Download-Skill $tmp
        Show-InstalledVersion $tmp
        Install-Skill $tmp
        Test-BuzzGateway
    } finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Uninstall-BuzzImage {
    $target = Get-InstallDir
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Status 'ok' ((T '\u5df2\u5378\u8f7d' 'Removed') + ' ' + $target)
    } else {
        Write-Status 'info' (T '\u672a\u5b89\u88c5 buzz-image,\u65e0\u9700\u5378\u8f7d' 'buzz-image is not installed; nothing to remove')
    }
}

function Invoke-Main([bool]$DoHelp, [bool]$DoUninstall) {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        # Older runtimes without Tls12: rely on the system default.
    }

    try {
        if ($DoHelp) {
            Show-Help
            return
        }
        if ($DoUninstall -or ($env:BUZZ_IMAGE_UNINSTALL -eq '1')) {
            Uninstall-BuzzImage
        } else {
            Install-BuzzImage
        }
    } catch {
        Write-Status 'error' $_.Exception.Message
        # Non-zero exit code for -File runs; does not close the session under irm | iex.
        $host.SetShouldExit(1)
    }
}

Invoke-Main ([bool]$Help) ([bool]$Uninstall)
