<#
.SYNOPSIS
    Installs EDAMAME for Claude Code (global per-user install) on Windows.

.DESCRIPTION
    PowerShell equivalent of setup/install.sh for Windows environments.
    Copies package files, renders config templates, and prints next steps.

.PARAMETER WorkspaceRoot
    Path to the workspace root. Defaults to the current directory.

.EXAMPLE
    .\setup\install.ps1
    .\setup\install.ps1 -WorkspaceRoot "C:\Users\me\projects\myapp"
#>
[CmdletBinding()]
param(
    [string]$WorkspaceRoot = ""
)

$ErrorActionPreference = "Stop"

$SourceRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $WorkspaceRoot) { $WorkspaceRoot = Get-Location }
$WorkspaceRoot = (Resolve-Path $WorkspaceRoot).Path

$ConfigHome = Join-Path $env:APPDATA "claude-code-edamame"
$StateHome  = Join-Path $env:LOCALAPPDATA "claude-code-edamame\state"
$DataHome   = Join-Path $env:LOCALAPPDATA "claude-code-edamame"

$InstallRoot = Join-Path $DataHome "current"
$ConfigPath  = Join-Path $ConfigHome "config.json"
$ClaudeCodeMcpPath = Join-Path $ConfigHome "claude-code-mcp.json"

$NodeBin = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeBin) { $NodeBin = "node" }

foreach ($dir in @($ConfigHome, $StateHome, $DataHome)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if (Test-Path $InstallRoot) { Remove-Item -Recurse -Force $InstallRoot }
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

$DirsToInstall = @(
    "bridge", "adapters", "prompts", "service",
    "docs", "tests", "setup", ".claude-plugin",
    "agents", "commands", "assets", "skills"
)
foreach ($d in $DirsToInstall) {
    $src = Join-Path $SourceRoot $d
    if (Test-Path $src) {
        Copy-Item -Recurse -Force $src (Join-Path $InstallRoot $d)
    }
}

$FilesToInstall = @("package.json", "README.md", ".mcp.json")
foreach ($f in $FilesToInstall) {
    $src = Join-Path $SourceRoot $f
    if (Test-Path $src) { Copy-Item -Force $src (Join-Path $InstallRoot $f) }
}

# --- Template rendering ---
$WorkspaceBasename = Split-Path -Leaf $WorkspaceRoot
$HashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($WorkspaceRoot)
)
$HashHex = -join ($HashBytes | ForEach-Object { $_.ToString("x2") })
$AgentInstanceId = "$env:COMPUTERNAME-$($HashHex.Substring(0,12))"
$PskPath = Join-Path $StateHome "edamame-mcp.psk"

function PortablePath($p) { $p -replace '\\', '/' }

function Render-Template($Src, $Dst) {
    $content = Get-Content -Raw $Src
    $content = $content `
        -replace '__PACKAGE_ROOT__',                  (PortablePath $InstallRoot) `
        -replace '__CONFIG_PATH__',                   (PortablePath $ConfigPath) `
        -replace '__WORKSPACE_ROOT__',                (PortablePath $WorkspaceRoot) `
        -replace '__WORKSPACE_BASENAME__',            $WorkspaceBasename `
        -replace '__DEFAULT_AGENT_INSTANCE_ID__',     $AgentInstanceId `
        -replace '__DEFAULT_HOST_KIND__',             'edamame_app' `
        -replace '__DEFAULT_POSTURE_CLI_COMMAND__',   '' `
        -replace '__STATE_DIR__',                     (PortablePath $StateHome) `
        -replace '__EDAMAME_MCP_PSK_FILE__',          (PortablePath $PskPath) `
        -replace '__NODE_BIN__',                      (PortablePath $NodeBin)
    $parent = Split-Path -Parent $Dst
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -Path $Dst -Value $content -Encoding UTF8
}

$ConfigTemplate = Join-Path $InstallRoot "setup\claude-code-edamame-config.template.json"
if ((-not (Test-Path $ConfigPath)) -and (Test-Path $ConfigTemplate)) {
    Render-Template $ConfigTemplate $ConfigPath
}

$McpTemplate = Join-Path $InstallRoot "setup\claude-code-mcp.template.json"
if (Test-Path $McpTemplate) {
    Render-Template $McpTemplate $ClaudeCodeMcpPath
}

# --- MCP auto-injection into ~/.claude.json ---
$GlobalMcpPath = Join-Path $env:USERPROFILE ".claude.json"
try {
    $SnippetContent = Get-Content -Raw $ClaudeCodeMcpPath | ConvertFrom-Json
    $Entry = $SnippetContent.mcpServers.'edamame-code'
    if ($Entry) {
        if (Test-Path $GlobalMcpPath) {
            Copy-Item -Force $GlobalMcpPath "$GlobalMcpPath.bak"
            try {
                $GlobalCfg = Get-Content -Raw $GlobalMcpPath | ConvertFrom-Json
            } catch {
                Write-Warning "$GlobalMcpPath contains malformed JSON, skipping MCP injection"
                $GlobalCfg = $null
            }
        } else {
            $GlobalCfg = [PSCustomObject]@{}
        }
        if ($null -ne $GlobalCfg) {
            if (-not $GlobalCfg.PSObject.Properties["mcpServers"]) {
                $GlobalCfg | Add-Member -NotePropertyName "mcpServers" -NotePropertyValue ([PSCustomObject]@{})
            }
            if ($GlobalCfg.mcpServers.PSObject.Properties["edamame-code"]) {
                $GlobalCfg.mcpServers.'edamame-code' = $Entry
            } else {
                $GlobalCfg.mcpServers | Add-Member -NotePropertyName "edamame-code" -NotePropertyValue $Entry
            }
            $GlobalDir = Split-Path -Parent $GlobalMcpPath
            if ($GlobalDir -and -not (Test-Path $GlobalDir)) { New-Item -ItemType Directory -Path $GlobalDir -Force | Out-Null }
            $GlobalCfg | ConvertTo-Json -Depth 10 | Set-Content -Path $GlobalMcpPath -Encoding UTF8
        }
    }
} catch {
    Write-Warning "Could not inject MCP entry: $_"
}

Write-Host @"

Installed EDAMAME for Claude Code to:
  $InstallRoot

Primary config:
  $ConfigPath

Claude Code MCP snippet:
  $ClaudeCodeMcpPath

MCP server registered automatically in ~\.claude.json

Next steps:
1. Launch Claude Code and run the edamame_claude_code_control_center tool.
2. Click 'Request pairing from app' in the control center, or paste a PSK manually.
3. Run: node "$InstallRoot\service\healthcheck_cli.mjs" --strict --json
"@

# SIG # Begin signature block
# MIIuvwYJKoZIhvcNAQcCoIIusDCCLqwCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCD5UMRCbuu118lW
# D/ONddccRlRAHqzEzKIOnFABktGQmqCCE38wggVyMIIDWqADAgECAhB2U/6sdUZI
# k/Xl10pIOk74MA0GCSqGSIb3DQEBDAUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQK
# ExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2ln
# bmluZyBSb290IFI0NTAeFw0yMDAzMTgwMDAwMDBaFw00NTAzMTgwMDAwMDBaMFMx
# CzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQD
# EyBHbG9iYWxTaWduIENvZGUgU2lnbmluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBALYtxTDdeuirkD0DcrA6S5kWYbLl/6VnHTcc5X7s
# k4OqhPWjQ5uYRYq4Y1ddmwCIBCXp+GiSS4LYS8lKA/Oof2qPimEnvaFE0P31PyLC
# o0+RjbMFsiiCkV37WYgFC5cGwpj4LKczJO5QOkHM8KCwex1N0qhYOJbp3/kbkbuL
# ECzSx0Mdogl0oYCve+YzCgxZa4689Ktal3t/rlX7hPCA/oRM1+K6vcR1oW+9YRB0
# RLKYB+J0q/9o3GwmPukf5eAEh60w0wyNA3xVuBZwXCR4ICXrZ2eIq7pONJhrcBHe
# OMrUvqHAnOHfHgIB2DvhZ0OEts/8dLcvhKO/ugk3PWdssUVcGWGrQYP1rB3rdw1G
# R3POv72Vle2dK4gQ/vpY6KdX4bPPqFrpByWbEsSegHI9k9yMlN87ROYmgPzSwwPw
# jAzSRdYu54+YnuYE7kJuZ35CFnFi5wT5YMZkobacgSFOK8ZtaJSGxpl0c2cxepHy
# 1Ix5bnymu35Gb03FhRIrz5oiRAiohTfOB2FXBhcSJMDEMXOhmDVXR34QOkXZLaRR
# kJipoAc3xGUaqhxrFnf3p5fsPxkwmW8x++pAsufSxPrJ0PBQdnRZ+o1tFzK++Ol+
# A/Tnh3Wa1EqRLIUDEwIrQoDyiWo2z8hMoM6e+MuNrRan097VmxinxpI68YJj8S4O
# JGTfAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB0G
# A1UdDgQWBBQfAL9GgAr8eDm3pbRD2VZQu86WOzANBgkqhkiG9w0BAQwFAAOCAgEA
# Xiu6dJc0RF92SChAhJPuAW7pobPWgCXme+S8CZE9D/x2rdfUMCC7j2DQkdYc8pzv
# eBorlDICwSSWUlIC0PPR/PKbOW6Z4R+OQ0F9mh5byV2ahPwm5ofzdHImraQb2T07
# alKgPAkeLx57szO0Rcf3rLGvk2Ctdq64shV464Nq6//bRqsk5e4C+pAfWcAvXda3
# XaRcELdyU/hBTsz6eBolSsr+hWJDYcO0N6qB0vTWOg+9jVl+MEfeK2vnIVAzX9Rn
# m9S4Z588J5kD/4VDjnMSyiDN6GHVsWbcF9Y5bQ/bzyM3oYKJThxrP9agzaoHnT5C
# JqrXDO76R78aUn7RdYHTyYpiF21PiKAhoCY+r23ZYjAf6Zgorm6N1Y5McmaTgI0q
# 41XHYGeQQlZcIlEPs9xOOe5N3dkdeBBUO27Ql28DtR6yI3PGErKaZND8lYUkqP/f
# obDckUCu3wkzq7ndkrfxzJF0O2nrZ5cbkL/nx6BvcbtXv7ePWu16QGoWzYCELS/h
# AtQklEOzFfwMKxv9cW/8y7x1Fzpeg9LJsy8b1ZyNf1T+fn7kVqOHp53hWVKUQY9t
# W76GlZr/GnbdQNJRSnC0HzNjI3c/7CceWeQIh+00gkoPP/6gHcH1Z3NFhnj0qinp
# J4fGGdvGExTDOUmHTaCX4GUT9Z13Vunas1jHOvLAzYIwggbmMIIEzqADAgECAhB3
# vQ4DobcI+FSrBnIQ2QRHMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkw
# FwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENv
# ZGUgU2lnbmluZyBSb290IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAw
# MDBaMFkxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMS8w
# LQYDVQQDEyZHbG9iYWxTaWduIEdDQyBSNDUgQ29kZVNpZ25pbmcgQ0EgMjAyMDCC
# AiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANZCTfnjT8Yj9GwdgaYw90g9
# z9DljeUgIpYHRDVdBs8PHXBg5iZU+lMjYAKoXwIC947Jbj2peAW9jvVPGSSZfM8R
# Fpsfe2vSo3toZXer2LEsP9NyBjJcW6xQZywlTVYGNvzBYkx9fYYWlZpdVLpQ0LB/
# okQZ6dZubD4Twp8R1F80W1FoMWMK+FvQ3rpZXzGviWg4QD4I6FNnTmO2IY7v3Y2F
# QVWeHLw33JWgxHGnHxulSW4KIFl+iaNYFZcAJWnf3sJqUGVOU/troZ8YHooOX1Re
# veBbz/IMBNLeCKEQJvey83ouwo6WwT/Opdr0WSiMN2WhMZYLjqR2dxVJhGaCJedD
# CndSsZlRQv+hst2c0twY2cGGqUAdQZdihryo/6LHYxcG/WZ6NpQBIIl4H5D0e6lS
# TmpPVAYqgK+ex1BC+mUK4wH0sW6sDqjjgRmoOMieAyiGpHSnR5V+cloqexVqHMRp
# 5rC+QBmZy9J9VU4inBDgoVvDsy56i8Te8UsfjCh5MEV/bBO2PSz/LUqKKuwoDy3K
# 1JyYikptWjYsL9+6y+JBSgh3GIitNWGUEvOkcuvuNp6nUSeRPPeiGsz8h+WX4VGH
# aekizIPAtw9FbAfhQ0/UjErOz2OxtaQQevkNDCiwazT+IWgnb+z4+iaEW3VCzYkm
# eVmda6tjcWKQJQ0IIPH/AgMBAAGjggGuMIIBqjAOBgNVHQ8BAf8EBAMCAYYwEwYD
# VR0lBAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU
# 2rONwCSQo2t30wygWd0hZ2R2C3gwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lW
# ULvOljswgZMGCCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2Nz
# cC5nbG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKG
# Omh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5n
# cm9vdHI0NS5jcnQwQQYDVR0fBDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxz
# aWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFYGA1UdIARPME0wQQYJKwYB
# BAGgMgEyMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29t
# L3JlcG9zaXRvcnkvMAgGBmeBDAEEATANBgkqhkiG9w0BAQsFAAOCAgEACIhyJsav
# +qxfBsCqjJDa0LLAopf/bhMyFlT9PvQwEZ+PmPmbUt3yohbu2XiVppp8YbgEtfjr
# y/RhETP2ZSW3EUKL2Glux/+VtIFDqX6uv4LWTcwRo4NxahBeGQWn52x/VvSoXMNO
# Ca1Za7j5fqUuuPzeDsKg+7AE1BMbxyepuaotMTvPRkyd60zsvC6c8YejfzhpX0FA
# Z/ZTfepB7449+6nUEThG3zzr9s0ivRPN8OHm5TOgvjzkeNUbzCDyMHOwIhz2hNab
# XAAC4ShSS/8SS0Dq7rAaBgaehObn8NuERvtz2StCtslXNMcWwKbrIbmqDvf+28rr
# vBfLuGfr4z5P26mUhmRVyQkKwNkEcUoRS1pkw7x4eK1MRyZlB5nVzTZgoTNTs/Z7
# KtWJQDxxpav4mVn945uSS90FvQsMeAYrz1PYvRKaWyeGhT+RvuB4gHNU36cdZytq
# tq5NiYAkCFJwUPMB/0SuL5rg4UkI4eFb1zjRngqKnZQnm8qjudviNmrjb7lYYuA2
# eDYB+sGniXomU6Ncu9Ky64rLYwgv/h7zViniNZvY/+mlvW1LWSyJLC9Su7UpkNpD
# R7xy3bzZv4DB3LCrtEsdWDY3ZOub4YUXmimi/eYI0pL/oPh84emn0TCOXyZQK8ei
# 4pd3iu/YTT4m65lAYPM8Zwy2CHIpNVOBNNwwggcbMIIFA6ADAgECAgwQ/xxnW9oI
# EyiP5BswDQYJKoZIhvcNAQELBQAwWTELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExLzAtBgNVBAMTJkdsb2JhbFNpZ24gR0NDIFI0NSBDb2Rl
# U2lnbmluZyBDQSAyMDIwMB4XDTI1MDYzMDA3NDM0OFoXDTI4MDgwODEzMTQyM1ow
# gYgxCzAJBgNVBAYTAkZSMRcwFQYDVQQIEw5IYXV0cy1kZS1TZWluZTEaMBgGA1UE
# BwwRQ2jDonRlbmF5LU1hbGFicnkxITAfBgNVBAoTGEVEQU1BTUUgVEVDSE5PTE9H
# SUVTIFNBUzEhMB8GA1UEAxMYRURBTUFNRSBURUNITk9MT0dJRVMgU0FTMIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA2COWggmYCeO4uNeo7WG4ts7wV8A+
# C3/LOK2FeMS0kkbU4V2o9NYBtRuBSCoc6c6noi+Vp26etTmnTZyUwk3LKSIrh1Lh
# b/3YaAKhYdlNS0RdMqDXzZBHo040y9OA+r5+tBhixPxLZpcu71W9g54p6jwW/cDT
# WDmHo5vBwL5pONAZlEvSSaxJolhIrcOXrbhg6E95YBrTiPCuJYKCEen9Q7jR0BTC
# lyTM/JyITSkH9qVClk9gYC6KrKRimvvciQiIz/ywLCONuCcbKSp6EwiBiqO84acj
# 7wv00OCumLwPpya9sSPoTP+XxVRRf9mJXb+nEpse0zd9ugzT5RbdLq1l3iamxSTQ
# id5Scy3Eb4pi4FEwDx9PdtT7PCF4f4ew+RIsXyKI9FxfkIjHtiVGAeG3rfxfoq3g
# L1mm0v50yfxl9L2ErMJJ73/H+FEtTTBgqPz5moWoZoaDU8rs3xB1pU+7E8GFeJeE
# CXMqcuPkWjN3X2Sa+xhah9joXib0+4vwhJgYo75nFDaxMEb1q6Zr5WqU9YyECisW
# FG13ZdH47qXlLuPjBEf06ZynZERAFX03RYmd3iJHIiGGkjb4vkEZknEN2RLPSbEv
# dSeaSwQXvitK0JpCQdpV5oa13gyA80sV7ZkqAX77hjJCmuXxBroSJ+XmmabbPieO
# 0BMYtpYRKLZKJn0CAwEAAaOCAbEwggGtMA4GA1UdDwEB/wQEAwIHgDCBmwYIKwYB
# BQUHAQEEgY4wgYswSgYIKwYBBQUHMAKGPmh0dHA6Ly9zZWN1cmUuZ2xvYmFsc2ln
# bi5jb20vY2FjZXJ0L2dzZ2NjcjQ1Y29kZXNpZ25jYTIwMjAuY3J0MD0GCCsGAQUF
# BzABhjFodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNvbS9nc2djY3I0NWNvZGVzaWdu
# Y2EyMDIwMFYGA1UdIARPME0wQQYJKwYBBAGgMgEyMDQwMgYIKwYBBQUHAgEWJmh0
# dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMAgGBmeBDAEEATAJ
# BgNVHRMEAjAAMEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwuZ2xvYmFsc2ln
# bi5jb20vZ3NnY2NyNDVjb2Rlc2lnbmNhMjAyMC5jcmwwEwYDVR0lBAwwCgYIKwYB
# BQUHAwMwHwYDVR0jBBgwFoAU2rONwCSQo2t30wygWd0hZ2R2C3gwHQYDVR0OBBYE
# FIosFHt7TbjoY1CPvvzSV2F/1i+BMA0GCSqGSIb3DQEBCwUAA4ICAQAFC1cUFKCz
# g5cCCY4eRmi5EQv073drt2tTKgjN4itaYcQRH9wMt+uwb9b/bfcAeg3+kFxbWe/8
# qYzUhIPcLn+qc0kqsyDBfWv9+0nWGUR7c/W3HfLG40Jep+CImUMfyFW4fUmHkDWp
# xnpc46Jv2fLKDQTfh9ZvKcHye96ShmcmXFpq4hbuvsRn2U8z3tvT5VspbPsxHqNs
# qeIboLwUWeNP/wZFTt17T9fWp1mT20vLErqykyNfN/bm5eSvnHaxnpXS7yt5q3Vs
# 1MJaLdZhkoz5Xh2FK8zMDObPZkMvOxbbs6JENS+Xsqi5tpKe+rtRE7IrjYBlDFlC
# yWmvCbskmW7lbm6FIObNJuXATRiRT2lSCGWVcDrqByaofSRtzy2axDP5rDdhYsKG
# ZuNrzwp/6Sl2RYrF0wBCO1j3CsryQOlfYIJHIyMEMFVzrVtXUT/YxvBcHJqulVcb
# xrQXcTLjXy/UMGx++y44TJD8BOZUljzlAJKmizNEBvdu4FXcigR2gAjbg/yrxqiO
# aMlKkAtsodCT/uP8RsaATUPfqq1Uk/7X5zP7gjrySGpxam1mjfMRStFtgEvvpgC5
# Z8iucUJrxO663fvVqBZLqtd+/y7IpEeTI5JcWx1TKtCJ5K+CqzR1BXUXgpRhMWrk
# W9or4/lAG8TpxEIhCq5czxCsdM4cih0fkzGCGpYwghqSAgEBMGkwWTELMAkGA1UE
# BhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExLzAtBgNVBAMTJkdsb2Jh
# bFNpZ24gR0NDIFI0NSBDb2RlU2lnbmluZyBDQSAyMDIwAgwQ/xxnW9oIEyiP5Bsw
# DQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkq
# hkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGC
# NwIBFTAvBgkqhkiG9w0BCQQxIgQgnGF+N5potEiqbc0ezW8eydKyePmyBRkLN5gb
# EuNvb/EwDQYJKoZIhvcNAQEBBQAEggIAVPLSfBYn2ltnWOz2b789m1KLbollvYDG
# /vXnP22Pjrdd++w1ZY9sB0p4MvcF9JqIZ5THlgQBb0nAnfsaoDeVSndp6GCjNEVx
# 8tMK6gIJEz9gdVL3AQcfNWzum5aD92/AP7075xSqlF/l31wxvZijmojiJWUSDXjf
# bV1h2SyudksTnzZW77uluC/EhmAXeeptWMFcKgjtb67lUN3yP9xlHBkBKkLzi5EJ
# aZsZ56s3xWAQjw+P4ot9wBrSQ55NFD7F+Wsrr31LaYpJYUUt8HUqgFBL2fzKX4y+
# wkpYm9WaRjfnt/j8nb0Vt9fRcClIsk3GVSBMEIA4KnemwDet9oNsJnhzXVsjOfJn
# s8q7Tg9UGkKzkWNKIr8XueeGxYLGMyIpB6UIG0jfMnW4RTCOL1LyYOLLtleaM52e
# QPhmkbdb+qCdxE0hN2FXhO+Z2p0ZnxsEEnmXj6pcILa714gwDfTkwH9fTmOkDmD8
# y5MW1nvPaGno8PuaJuY39pQEW4GsJcK5/zX4eB28sivDiPKP7792jt+ggpFHfDCD
# 9HZQGqzx2KDmfNkLf833Bn8LcY6A8iMGkgdsuM+y/hxSiKNeAGlEWMRlKAaypVzV
# P7x13JTPyDIJZaGSkhsP3K3+weGvf7CnQqFsazY3vs9IYeZCoqmFhIMAsJLb9Mse
# C7jYmlCjW52hghd3MIIXcwYKKwYBBAGCNwMDATGCF2MwghdfBgkqhkiG9w0BBwKg
# ghdQMIIXTAIBAzEPMA0GCWCGSAFlAwQCAQUAMHgGCyqGSIb3DQEJEAEEoGkEZzBl
# AgEBBglghkgBhv1sBwEwMTANBglghkgBZQMEAgEFAAQgfKKH0MpNgmBmklI1yNfz
# LC8N8xPm7xAaATGu7HrJ8Y4CEQDEkXW2CnTqA62NtcUCgjsIGA8yMDI2MDUwMTEw
# MzQzN1qgghM6MIIG7TCCBNWgAwIBAgIQCoDvGEuN8QWC0cR2p5V0aDANBgkqhkiG
# 9w0BAQsFADBpMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4x
# QTA/BgNVBAMTOERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQw
# OTYgU0hBMjU2IDIwMjUgQ0ExMB4XDTI1MDYwNDAwMDAwMFoXDTM2MDkwMzIzNTk1
# OVowYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMTswOQYD
# VQQDEzJEaWdpQ2VydCBTSEEyNTYgUlNBNDA5NiBUaW1lc3RhbXAgUmVzcG9uZGVy
# IDIwMjUgMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANBGrC0Sxp7Q
# 6q5gVrMrV7pvUf+GcAoB38o3zBlCMGMyqJnfFNZx+wvA69HFTBdwbHwBSOeLpvPn
# Z8ZN+vo8dE2/pPvOx/Vj8TchTySA2R4QKpVD7dvNZh6wW2R6kSu9RJt/4QhguSss
# p3qome7MrxVyfQO9sMx6ZAWjFDYOzDi8SOhPUWlLnh00Cll8pjrUcCV3K3E0zz09
# ldQ//nBZZREr4h/GI6Dxb2UoyrN0ijtUDVHRXdmncOOMA3CoB/iUSROUINDT98ok
# souTMYFOnHoRh6+86Ltc5zjPKHW5KqCvpSduSwhwUmotuQhcg9tw2YD3w6ySSSu+
# 3qU8DD+nigNJFmt6LAHvH3KSuNLoZLc1Hf2JNMVL4Q1OpbybpMe46YceNA0LfNsn
# qcnpJeItK/DhKbPxTTuGoX7wJNdoRORVbPR1VVnDuSeHVZlc4seAO+6d2sC26/PQ
# PdP51ho1zBp+xUIZkpSFA8vWdoUoHLWnqWU3dCCyFG1roSrgHjSHlq8xymLnjCbS
# LZ49kPmk8iyyizNDIXj//cOgrY7rlRyTlaCCfw7aSUROwnu7zER6EaJ+AliL7ojT
# dS5PWPsWeupWs7NpChUk555K096V1hE0yZIXe+giAwW00aHzrDchIc2bQhpp0IoK
# RR7YufAkprxMiXAJQ1XCmnCfgPf8+3mnAgMBAAGjggGVMIIBkTAMBgNVHRMBAf8E
# AjAAMB0GA1UdDgQWBBTkO/zyMe39/dfzkXFjGVBDz2GM6DAfBgNVHSMEGDAWgBTv
# b1NK6eQGfHrK4pBW9i/USezLTjAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAww
# CgYIKwYBBQUHAwgwgZUGCCsGAQUFBwEBBIGIMIGFMCQGCCsGAQUFBzABhhhodHRw
# Oi8vb2NzcC5kaWdpY2VydC5jb20wXQYIKwYBBQUHMAKGUWh0dHA6Ly9jYWNlcnRz
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQw
# OTZTSEEyNTYyMDI1Q0ExLmNydDBfBgNVHR8EWDBWMFSgUqBQhk5odHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkRzRUaW1lU3RhbXBpbmdSU0E0
# MDk2U0hBMjU2MjAyNUNBMS5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZI
# AYb9bAcBMA0GCSqGSIb3DQEBCwUAA4ICAQBlKq3xHCcEua5gQezRCESeY0ByIfjk
# 9iJP2zWLpQq1b4URGnwWBdEZD9gBq9fNaNmFj6Eh8/YmRDfxT7C0k8FUFqNh+tsh
# gb4O6Lgjg8K8elC4+oWCqnU/ML9lFfim8/9yJmZSe2F8AQ/UdKFOtj7YMTmqPO9m
# zskgiC3QYIUP2S3HQvHG1FDu+WUqW4daIqToXFE/JQ/EABgfZXLWU0ziTN6R3ygQ
# BHMUBaB5bdrPbF6MRYs03h4obEMnxYOX8VBRKe1uNnzQVTeLni2nHkX/QqvXnNb+
# YkDFkxUGtMTaiLR9wjxUxu2hECZpqyU1d0IbX6Wq8/gVutDojBIFeRlqAcuEVT0c
# Ksb+zJNEsuEB7O7/cuvTQasnM9AWcIQfVjnzrvwiCZ85EE8LUkqRhoS3Y50OHgaY
# 7T/lwd6UArb+BOVAkg2oOvol/DJgddJ35XTxfUlQ+8Hggt8l2Yv7roancJIFcboj
# BcxlRcGG0LIhp6GvReQGgMgYxQbV1S3CrWqZzBt1R9xJgKf47CdxVRd/ndUlQ05o
# xYy2zRWVFjF7mcr4C34Mj3ocCVccAvlKV9jEnstrniLvUxxVZE/rptb7IRE2lskK
# PIJgbaP5t2nGj/ULLi49xTcBZU8atufk+EMF/cWuiC7POGT75qaL6vdCvHlshtjd
# NXOCIUjsarfNZzCCBrQwggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZI
# hvcNAQELBQAwYjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZ
# MBcGA1UECxMQd3d3LmRpZ2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1
# c3RlZCBSb290IEc0MB4XDTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTEL
# MAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhE
# aWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAy
# MDI1IENBMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFy
# vjxGwBysddujRmh0tFEXnU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8
# Xi4aPCOo2N8S9SLrC6Kbltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4d
# g2dDGpeZGKe+42DFUF0mR/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2C
# QWIM1iI5PHg62IVwxKSpO0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSO
# xm+SAWSuIr21Qomb+zzQWKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFU
# Ut4aS4CEeIY8y9IaaGBpPNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55Iu
# wnKCgs+nrpuQNfVmUB5KlCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1
# JrPsFfxW1gaou30yZ46t4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6Mvq
# zfpzPDOy5y6gqztiT96Fv/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1K
# hBtTasySkuJDpsZGKdlsjg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4
# RjSpWM8o5a6D8bpfm4CLKczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8E
# CDAGAQH/AgEAMB0GA1UdDgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSME
# GDAWgBTs1+OC0nFdZEzfLmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0l
# BAwwCgYIKwYBBQUHAwgwdwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRw
# Oi8vb2NzcC5kaWdpY2VydC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRz
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8
# MDowOKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0
# ZWRSb290RzQuY3JsMCAGA1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATAN
# BgkqhkiG9w0BAQsFAAOCAgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9P
# w5tcBnPw6O6FTGNpoV2V4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFAT
# uNT+ReOPK0mCefSG+tXqGpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sR
# UoKEfJ+nN57mQfQXwcAEGCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LU
# iwDRAXx1Neq9ydOal95CHfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0
# SQzHU0pTi4dBwp9nEC8EAqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L
# 2oiKNqetRHdqfMTCW/NmKLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0
# vlNMsvhlqgF2puE6FndlENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFh
# Om0xJuF2EZAOk5eCkhSxZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+
# /j7tFaxYKIqL0Q4ssd8xHZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4
# S1C8uw3PdBunvAZapsiI5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5
# t1wwggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0GCSqGSIb3DQEBDAUA
# MGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQg
# Um9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5NTlaMGIxCzAJBgNV
# BAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdp
# Y2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvkXUo8MCIwaTPswqcl
# LskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdtHauyefLKEdLkX9YF
# PFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu34LzB4TmdDttceIt
# DBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0QF+xembud8hIqGZX
# V59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2kZhAkHnDeMe2scS1
# ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM1LyuGwN1XXhm2Tox
# RJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmIdph2PVldQnaHiZdp
# ekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZK37AlLTSYW3rM9nF
# 30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72gLD76GSmM9GJB+G9
# t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqsX40/ybzTQRESW+UQ
# UOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyhHsXAj6KxfgommfXk
# aS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8EBTADAQH/MB0GA1Ud
# DgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAWgBRF66Kv9JLLgjEt
# UYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUHAQEEbTBrMCQGCCsG
# AQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYBBQUHMAKGN2h0
# dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RD
# QS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29t
# L0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAECjAIMAYGBFUdIAAw
# DQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX979XB72arKGHLOyF
# XqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offyct4kvFIDyE7QKt76
# LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3J0TU53/oWajwvy8L
# punyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0d1pcVIxv76FQPfx2
# CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6tsds5vIy30fnFqI2si
# /xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQxggN8MIIDeAIBATB9
# MGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UE
# AxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEy
# NTYgMjAyNSBDQTECEAqA7xhLjfEFgtHEdqeVdGgwDQYJYIZIAWUDBAIBBQCggdEw
# GgYJKoZIhvcNAQkDMQ0GCyqGSIb3DQEJEAEEMBwGCSqGSIb3DQEJBTEPFw0yNjA1
# MDExMDM0MzdaMCsGCyqGSIb3DQEJEAIMMRwwGjAYMBYEFN1iMKyGCi0wa9o4sWh5
# UjAH+0F+MC8GCSqGSIb3DQEJBDEiBCC3wG72nMHAsM/WDSRCxDOD2ni5FNojH9KA
# eb9ORWd/nDA3BgsqhkiG9w0BCRACLzEoMCYwJDAiBCBKoD+iLNdchMVck4+Cjmdr
# nK7Ksz/jbSaaozTxRhEKMzANBgkqhkiG9w0BAQEFAASCAgASDBDQlCLtm5XofgQR
# xgpVM3KQOeAW44OBx8OeMIvXpa2ReS+HbtQ6zoW6SZwK4F6836o8m2uwIbVHk0I6
# MCVbjLHUQhVi4fdlK2G4HEIcyzOLXODATfqmnAfWbHbK6kZjBf0d4n3kT5KVPpsC
# A1F3DpjS7yuthOK13LMeHqSEAYLk9NvQCm4zS+Wme76A/bZOnUQhiuZ/WgI4ZqvG
# u6R+HsmdjQXJhodPKJe8C1uOLnQRCuaVmrXjn+/wIHvEIg/xXYK2UQ19fqvWdwvz
# m4WfRHmE9a6zJ6eVZtKzsfdYzigfQ6f3etSkhFKNCzI2o61MVkbL9CJ0iMb3A2zr
# C0WdWIdKfBBZ6DMz+FBfu9hgKZLpqVzKS1DoN7OVylFX7bDlEk8aIHWZ2qSPrlu9
# i23PaGtA33B00QcqUEMXl8cCNj60xHQB9M4JqI1Ic3KosSaw16xb/vhboK+sBcrr
# 92lV4ZDCiq+eD8Htim0XokSQHw0TsLdSS3sxyR/EhrOU/0Nvs+L8QUtI//P8JdAP
# kpKibogMB321EUsbSnno2Fp0Y2cd35Ce+6LxxRxNllykDe4hz1hMXQg4mklW65Qo
# Fj/WfYO7rBdLpkvhJRK8tvNR4ZwF2XHrJDvfX92rTEJljuwbocaEEzFxTdDExU0P
# mhcMaNvoQNs+euOx8DGZk1fQnw==
# SIG # End signature block
