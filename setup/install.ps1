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
# MIIuvgYJKoZIhvcNAQcCoIIurzCCLqsCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCG/whnInZxKivX
# 2XhMWBB2Qnr8rEAbosZ7NnxLA2UHLqCCE38wggVyMIIDWqADAgECAhB2U/6sdUZI
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
# W9or4/lAG8TpxEIhCq5czxCsdM4cih0fkzGCGpUwghqRAgEBMGkwWTELMAkGA1UE
# BhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExLzAtBgNVBAMTJkdsb2Jh
# bFNpZ24gR0NDIFI0NSBDb2RlU2lnbmluZyBDQSAyMDIwAgwQ/xxnW9oIEyiP5Bsw
# DQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkq
# hkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGC
# NwIBFTAvBgkqhkiG9w0BCQQxIgQg5hzeuhYOiW1LZBn+6PYFliNlLkRfgHDATmfV
# q3ul6YswDQYJKoZIhvcNAQEBBQAEggIAMi0iVFnvTIrWik54it8xzsaX8EWvYWwm
# iscxPzAhVAUOAQKlEeHbgFLHIiE6Mn+GrqNae0znelq2q+ccuCtnMjoO0Pl8phA/
# PJ/dBJXsGmItSkI1kQXmsaLGsFeiFhv5NqJQpH3GGJHioCl4P945iEtw7mhobwgl
# eVM/W2Au2WSsov7j0aEWm0pzzZzU6QPpU20qprBdfoetj3CXlKSc0p1aDNz9Drxm
# T6hEid33qNjOmVCj6v6vTjL0U1KR5+xU05SLtsGwMHmsOnXAVYveqBsfR6Z4Dn1L
# FqHo2zwbzc7IOSsLN4/0YM7BfBD91zO5n49g8AaGPqH2e5ovkcA3ZyTCyo+TZE/6
# /yc4Lz+BuSa3MWknozyQxZTvamOXIcFjBSvyvPkVwmxkVBLJvso1eJvvYQvJ+VDs
# qp1nCpZ3FtIEvO/GpPEXroVepE8tdwwDaqW1hMt09nyOlqnzivZCat053Ib+hsv6
# EY4cIgpoiL1hT3QuweOwTdW5wyh4/igv7I6LBfBjhgb6U/xFlnucEF46N4jaTVsi
# B5CAvus+mOe8YfL1qU7dRPnM8fsz53PXfxkG6es81dZ6eyzP4UdlMuVul9Xjk7kj
# imR3TF5G25EZjiKrzuBC0F9S02NwUGIHAJMQ/oYPUoVMAlV0hCYiEOnL4u9/RMhv
# hWiy0QNCZy+hghd2MIIXcgYKKwYBBAGCNwMDATGCF2IwghdeBgkqhkiG9w0BBwKg
# ghdPMIIXSwIBAzEPMA0GCWCGSAFlAwQCAQUAMHcGCyqGSIb3DQEJEAEEoGgEZjBk
# AgEBBglghkgBhv1sBwEwMTANBglghkgBZQMEAgEFAAQgIGE9VN/YrXY2RltDxQwK
# Jb9ftMnbso/ixttc+2bJGcYCEBBq0vr66zy/7vLPL87MmZ4YDzIwMjYwMzI3MjE1
# MzUxWqCCEzowggbtMIIE1aADAgECAhAKgO8YS43xBYLRxHanlXRoMA0GCSqGSIb3
# DQEBCwUAMGkxCzAJBgNVBAYTAlVTMRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFB
# MD8GA1UEAxM4RGlnaUNlcnQgVHJ1c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5
# NiBTSEEyNTYgMjAyNSBDQTEwHhcNMjUwNjA0MDAwMDAwWhcNMzYwOTAzMjM1OTU5
# WjBjMQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNV
# BAMTMkRpZ2lDZXJ0IFNIQTI1NiBSU0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIg
# MjAyNSAxMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0EasLRLGntDq
# rmBWsytXum9R/4ZwCgHfyjfMGUIwYzKomd8U1nH7C8Dr0cVMF3BsfAFI54um8+dn
# xk36+jx0Tb+k+87H9WPxNyFPJIDZHhAqlUPt281mHrBbZHqRK71Em3/hCGC5Kyyn
# eqiZ7syvFXJ9A72wzHpkBaMUNg7MOLxI6E9RaUueHTQKWXymOtRwJXcrcTTPPT2V
# 1D/+cFllESviH8YjoPFvZSjKs3SKO1QNUdFd2adw44wDcKgH+JRJE5Qg0NP3yiSy
# i5MxgU6cehGHr7zou1znOM8odbkqoK+lJ25LCHBSai25CFyD23DZgPfDrJJJK77e
# pTwMP6eKA0kWa3osAe8fcpK40uhktzUd/Yk0xUvhDU6lvJukx7jphx40DQt82yep
# yekl4i0r8OEps/FNO4ahfvAk12hE5FVs9HVVWcO5J4dVmVzix4A77p3awLbr89A9
# 0/nWGjXMGn7FQhmSlIUDy9Z2hSgctaepZTd0ILIUbWuhKuAeNIeWrzHKYueMJtIt
# nj2Q+aTyLLKLM0MheP/9w6CtjuuVHJOVoIJ/DtpJRE7Ce7vMRHoRon4CWIvuiNN1
# Lk9Y+xZ66lazs2kKFSTnnkrT3pXWETTJkhd76CIDBbTRofOsNyEhzZtCGmnQigpF
# Hti58CSmvEyJcAlDVcKacJ+A9/z7eacCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHQYDVR0OBBYEFOQ7/PIx7f391/ORcWMZUEPPYYzoMB8GA1UdIwQYMBaAFO9v
# U0rp5AZ8esrikFb2L9RJ7MtOMA4GA1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAK
# BggrBgEFBQcDCDCBlQYIKwYBBQUHAQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBdBggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5
# NlNIQTI1NjIwMjVDQTEuY3J0MF8GA1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwz
# LmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQw
# OTZTSEEyNTYyMDI1Q0ExLmNybDAgBgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgB
# hv1sBwEwDQYJKoZIhvcNAQELBQADggIBAGUqrfEcJwS5rmBB7NEIRJ5jQHIh+OT2
# Ik/bNYulCrVvhREafBYF0RkP2AGr181o2YWPoSHz9iZEN/FPsLSTwVQWo2H62yGB
# vg7ouCODwrx6ULj6hYKqdT8wv2UV+Kbz/3ImZlJ7YXwBD9R0oU62PtgxOao872bO
# ySCILdBghQ/ZLcdC8cbUUO75ZSpbh1oipOhcUT8lD8QAGB9lctZTTOJM3pHfKBAE
# cxQFoHlt2s9sXoxFizTeHihsQyfFg5fxUFEp7W42fNBVN4ueLaceRf9Cq9ec1v5i
# QMWTFQa0xNqItH3CPFTG7aEQJmmrJTV3Qhtfparz+BW60OiMEgV5GWoBy4RVPRwq
# xv7Mk0Sy4QHs7v9y69NBqycz0BZwhB9WOfOu/CIJnzkQTwtSSpGGhLdjnQ4eBpjt
# P+XB3pQCtv4E5UCSDag6+iX8MmB10nfldPF9SVD7weCC3yXZi/uuhqdwkgVxuiMF
# zGVFwYbQsiGnoa9F5AaAyBjFBtXVLcKtapnMG3VH3EmAp/jsJ3FVF3+d1SVDTmjF
# jLbNFZUWMXuZyvgLfgyPehwJVxwC+UpX2MSey2ueIu9THFVkT+um1vshETaWyQo8
# gmBto/m3acaP9QsuLj3FNwFlTxq25+T4QwX9xa6ILs84ZPvmpovq90K8eWyG2N01
# c4IhSOxqt81nMIIGtDCCBJygAwIBAgIQDcesVwX/IZkuQEMiDDpJhjANBgkqhkiG
# 9w0BAQsFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkw
# FwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVz
# dGVkIFJvb3QgRzQwHhcNMjUwNTA3MDAwMDAwWhcNMzgwMTE0MjM1OTU5WjBpMQsw
# CQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMTOERp
# Z2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2IDIw
# MjUgQ0ExMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAtHgx0wqYQXK+
# PEbAHKx126NGaHS0URedTa2NDZS1mZaDLFTtQ2oRjzUXMmxCqvkbsDpz4aH+qbxe
# Lho8I6jY3xL1IusLopuW2qftJYJaDNs1+JH7Z+QdSKWM06qchUP+AbdJgMQB3h2D
# Z0Mal5kYp77jYMVQXSZH++0trj6Ao+xh/AS7sQRuQL37QXbDhAktVJMQbzIBHYJB
# YgzWIjk8eDrYhXDEpKk7RdoX0M980EpLtlrNyHw0Xm+nt5pnYJU3Gmq6bNMI1I7G
# b5IBZK4ivbVCiZv7PNBYqHEpNVWC2ZQ8BbfnFRQVESYOszFI2Wv82wnJRfN20VRS
# 3hpLgIR4hjzL0hpoYGk81coWJ+KdPvMvaB0WkE/2qHxJ0ucS638ZxqU14lDnki7C
# coKCz6eum5A19WZQHkqUJfdkDjHkccpL6uoG8pbF0LJAQQZxst7VvwDDjAmSFTUm
# s+wV/FbWBqi7fTJnjq3hj0XbQcd8hjj/q8d6ylgxCZSKi17yVp2NL+cnT6Toy+rN
# +nM8M7LnLqCrO2JP3oW//1sfuZDKiDEb1AQ8es9Xr/u6bDTnYCTKIsDq1BtmXUqE
# G1NqzJKS4kOmxkYp2WyODi7vQTCBZtVFJfVZ3j7OgWmnhFr4yUozZtqgPrHRVHhG
# NKlYzyjlroPxul+bgIspzOwbtmsgY1MCAwEAAaOCAV0wggFZMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHQYDVR0OBBYEFO9vU0rp5AZ8esrikFb2L9RJ7MtOMB8GA1UdIwQY
# MBaAFOzX44LScV1kTN8uZz/nupiuHA9PMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUE
# DDAKBggrBgEFBQcDCDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGGGGh0dHA6
# Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2NhY2VydHMu
# ZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3RlZFJvb3RHNC5jcnQwQwYDVR0fBDww
# OjA4oDagNIYyaHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0VHJ1c3Rl
# ZFJvb3RHNC5jcmwwIAYDVR0gBBkwFzAIBgZngQwBBAIwCwYJYIZIAYb9bAcBMA0G
# CSqGSIb3DQEBCwUAA4ICAQAXzvsWgBz+Bz0RdnEwvb4LyLU0pn/N0IfFiBowf0/D
# m1wGc/Do7oVMY2mhXZXjDNJQa8j00DNqhCT3t+s8G0iP5kvN2n7Jd2E4/iEIUBO4
# 1P5F448rSYJ59Ib61eoalhnd6ywFLerycvZTAz40y8S4F3/a+Z1jEMK/DMm/axFS
# goR8n6c3nuZB9BfBwAQYK9FHaoq2e26MHvVY9gCDA/JYsq7pGdogP8HRtrYfctSL
# ANEBfHU16r3J05qX3kId+ZOczgj5kjatVB+NdADVZKON/gnZruMvNYY2o1f4MXRJ
# DMdTSlOLh0HCn2cQLwQCqjFbqrXuvTPSegOOzr4EWj7PtspIHBldNE2K9i697cva
# iIo2p61Ed2p8xMJb82Yosn0z4y25xUbI7GIN/TpVfHIqQ6Ku/qjTY6hc3hsXMrS+
# U0yy+GWqAXam4ToWd2UQ1KYT70kZjE4YtL8Pbzg0c1ugMZyZZd/BdHLiRu7hAWE6
# bTEm4XYRkA6Tl4KSFLFk43esaUeqGkH/wyW4N7OigizwJWeukcyIPbAvjSabnf7+
# Pu0VrFgoiovRDiyx3zEdmcif/sYQsfch28bZeUz2rtY/9TCA6TD8dC3JE3rYkrhL
# ULy7Dc90G6e8BlqmyIjlgp2+VqsS9/wQD7yFylIz0scmbKvFoW2jNrbM1pD2T7m3
# XDCCBY0wggR1oAMCAQICEA6bGI750C3n79tQ4ghAGFowDQYJKoZIhvcNAQEMBQAw
# ZTELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQ
# d3d3LmRpZ2ljZXJ0LmNvbTEkMCIGA1UEAxMbRGlnaUNlcnQgQXNzdXJlZCBJRCBS
# b290IENBMB4XDTIyMDgwMTAwMDAwMFoXDTMxMTEwOTIzNTk1OVowYjELMAkGA1UE
# BhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRpZ2lj
# ZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MIICIjAN
# BgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAv+aQc2jeu+RdSjwwIjBpM+zCpyUu
# ySE98orYWcLhKac9WKt2ms2uexuEDcQwH/MbpDgW61bGl20dq7J58soR0uRf1gU8
# Ug9SH8aeFaV+vp+pVxZZVXKvaJNwwrK6dZlqczKU0RBEEC7fgvMHhOZ0O21x4i0M
# G+4g1ckgHWMpLc7sXk7Ik/ghYZs06wXGXuxbGrzryc/NrDRAX7F6Zu53yEioZldX
# n1RYjgwrt0+nMNlW7sp7XeOtyU9e5TXnMcvak17cjo+A2raRmECQecN4x7axxLVq
# GDgDEI3Y1DekLgV9iPWCPhCRcKtVgkEy19sEcypukQF8IUzUvK4bA3VdeGbZOjFE
# mjNAvwjXWkmkwuapoGfdpCe8oU85tRFYF/ckXEaPZPfBaYh2mHY9WV1CdoeJl2l6
# SPDgohIbZpp0yt5LHucOY67m1O+SkjqePdwA5EUlibaaRBkrfsCUtNJhbesz2cXf
# SwQAzH0clcOP9yGyshG3u3/y1YxwLEFgqrFjGESVGnZifvaAsPvoZKYz0YkH4b23
# 5kOkGLimdwHhD5QMIR2yVCkliWzlDlJRR3S+Jqy2QXXeeqxfjT/JvNNBERJb5RBQ
# 6zHFynIWIgnffEx1P2PsIV/EIFFrb7GrhotPwtZFX50g/KEexcCPorF+CiaZ9eRp
# L5gdLfXZqbId5RsCAwEAAaOCATowggE2MA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0O
# BBYEFOzX44LScV1kTN8uZz/nupiuHA9PMB8GA1UdIwQYMBaAFEXroq/0ksuCMS1R
# i6enIZ3zbcgPMA4GA1UdDwEB/wQEAwIBhjB5BggrBgEFBQcBAQRtMGswJAYIKwYB
# BQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0
# cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENB
# LmNydDBFBgNVHR8EPjA8MDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2VydC5jb20v
# RGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMBEGA1UdIAQKMAgwBgYEVR0gADAN
# BgkqhkiG9w0BAQwFAAOCAQEAcKC/Q1xV5zhfoKN0Gz22Ftf3v1cHvZqsoYcs7IVe
# qRq7IviHGmlUIu2kiHdtvRoU9BNKei8ttzjv9P+Aufih9/Jy3iS8UgPITtAq3vot
# Vs/59PesMHqai7Je1M/RQ0SbQyHrlnKhSLSZy51PpwYDE3cnRNTnf+hZqPC/Lwum
# 6fI0POz3A8eHqNJMQBk1RmppVLC4oVaO7KTVPeix3P0c2PR3WlxUjG/voVA9/HYJ
# aISfb8rbII01YBwCA8sgsKxYoA5AY8WYIsGyWfVVa88nq2x2zm8jLfR+cWojayL/
# ErhULSd+2DrZ8LaHlv1b0VysGMNNn3O3AamfV6peKOK5lDGCA3wwggN4AgEBMH0w
# aTELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQD
# EzhEaWdpQ2VydCBUcnVzdGVkIEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1
# NiAyMDI1IENBMQIQCoDvGEuN8QWC0cR2p5V0aDANBglghkgBZQMEAgEFAKCB0TAa
# BgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwHAYJKoZIhvcNAQkFMQ8XDTI2MDMy
# NzIxNTM1MVowKwYLKoZIhvcNAQkQAgwxHDAaMBgwFgQU3WIwrIYKLTBr2jixaHlS
# MAf7QX4wLwYJKoZIhvcNAQkEMSIEINu3mcmrGjNAB6ne0HzIsQoQsm7QrIf/4TXw
# R1aW52ihMDcGCyqGSIb3DQEJEAIvMSgwJjAkMCIEIEqgP6Is11yExVyTj4KOZ2uc
# rsqzP+NtJpqjNPFGEQozMA0GCSqGSIb3DQEBAQUABIICAGHcJjWcSpnEHfVF9Jyz
# 3O7y1uE5IQygglgurG7ytgcG4qCJBTZfP1AhzpWpk/jvvI4YIv+e2OEZi4bPCKiM
# uHpVKgz+gIfcN1mNSTiMNwOO8iWXZTZ0wc9vBQbmc4A2rJeFueivP4cy5hv6yn4e
# O8e/3epZb0UTbxd0sy2XftPQ9iicSw0tgw1KkSe6/2Rwzy+fhYa9PrsK7xnc9mA4
# pFn3Yc5yYngTxIfLhje+B1DN2lGkFIUY/DlzMFwdjMu1yhZBtp0XXkx7LyvjgipL
# qIc2PYdvzFAntvdYYd222H8AsFf4lFVRmRak3pw+GyUuphD3mpqapypodM84KySR
# 9rWhG+WFc7JKWx+mir8e1LrtPEo0VIaFxSorpOCt1ZHyjVrcdsrc7QRuh3JhMobq
# 80/shA86FB/1ivSJw05dzXcj16fynb/0VOt9jdjufNKGZkaWlrvPXr2xPlc4HHXj
# gBGHGzD+5WGaei133uZKUcjwyz5XuNTbiOFBYxwmfXxR4RKBs12lIevVsZO/JVH1
# +34W3Hrry6FBDmtxm+RiC/mJJOnicQr33xFuo1jylYS+8CQO/E0pPyHp28Kl0eX1
# z86IA82y/jihin4xoK7XF4plvJz7mTzoFaCn49rX+wG4fmGmuQYgv0E64tx4dfIY
# lBP0dKyoNG5vZaNLVOjd9tXD
# SIG # End signature block
