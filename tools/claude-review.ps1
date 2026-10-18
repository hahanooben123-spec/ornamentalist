param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$reviewRoot = Split-Path -Parent $PSScriptRoot
$claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
$claudeExecutable = if ($claudeCommand) { $claudeCommand.Source } else {
    Join-Path $env:USERPROFILE '.local\bin\claude.exe'
}
if (-not (Test-Path -LiteralPath $claudeExecutable)) {
    throw 'Claude Code is not installed. See docs/CLAUDE.md.'
}

$authText = & $claudeExecutable auth status
$authExit = $LASTEXITCODE
$auth = $authText | ConvertFrom-Json
if ($CheckOnly) {
    [pscustomobject]@{
        Installed = $true
        LoggedIn = ($authExit -eq 0 -and $auth.loggedIn -eq $true)
        Project = $reviewRoot
    } | ConvertTo-Json
    exit 0
}
if ($authExit -ne 0 -or -not $auth.loggedIn) {
    throw 'Claude login required. Run claude auth login --claudeai in your own terminal. Do not paste login codes or keys into chat.'
}

$reviewPrompt = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'claude-review.txt') -Raw
Push-Location -LiteralPath $reviewRoot
try {
    & $claudeExecutable --restricted --strict-mcp-config `
        --tools 'Read,Glob,Grep' --allowedTools 'Read,Glob,Grep' `
        --permission-mode plan --no-session-persistence `
        --append-system-prompt-file (Join-Path $reviewRoot 'CLAUDE.md') `
        --print $reviewPrompt
    $reviewExit = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $reviewExit
