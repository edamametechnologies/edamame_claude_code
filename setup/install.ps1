<#
.SYNOPSIS
    Installs the Claude Code EDAMAME package for a target workspace on Windows.

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
$RenderedDir = Join-Path $ConfigHome "rendered"
$ConfigPath  = Join-Path $ConfigHome "config.json"
$ClaudeCodeMcpPath = Join-Path $ConfigHome "claude-code-mcp.json"

$NodeBin = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeBin) { $NodeBin = "node" }

foreach ($dir in @($ConfigHome, $StateHome, $DataHome, $RenderedDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

if (Test-Path $InstallRoot) { Remove-Item -Recurse -Force $InstallRoot }
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null

$DirsToInstall = @(
    "bridge", "adapters", "prompts", "scheduler", "service",
    "docs", "tests", "setup", ".claude-plugin",
    "agents", "assets", "skills"
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

Write-Host @"

Installed Claude Code EDAMAME package to:
  $InstallRoot

Primary config:
  $ConfigPath

Claude Code MCP snippet:
  $ClaudeCodeMcpPath

Rendered scheduler templates:
  $RenderedDir

Next steps:
1. Copy the MCP snippet into your Claude Code MCP configuration.
2. Launch Claude Code and run the edamame_claude_code_control_center tool.
3. Click 'Request pairing from app' in the control center, or paste a PSK manually.
4. Run: node "$InstallRoot\setup\healthcheck.sh" --strict --json
"@
