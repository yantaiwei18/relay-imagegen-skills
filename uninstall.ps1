[CmdletBinding()]
param(
    [string]$CodexHome,
    [switch]$RemoveCredentials
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = $env:CODEX_HOME
}
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = Join-Path $HOME ".codex"
}
$CodexHome = [IO.Path]::GetFullPath($CodexHome)
$skillsRoot = [IO.Path]::GetFullPath((Join-Path $CodexHome "skills"))
$destinationSkill = [IO.Path]::GetFullPath((Join-Path $skillsRoot "relay-imagegen"))
$expectedPrefix = $skillsRoot.TrimEnd("\") + "\"
if (-not $destinationSkill.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove a skill outside the expected Codex skills directory."
}
if (Test-Path -LiteralPath $destinationSkill) {
    Remove-Item -LiteralPath $destinationSkill -Recurse -Force
}

$agentsPath = Join-Path $CodexHome "AGENTS.md"
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $startMarker = "<!-- BEGIN RELAY-IMAGEGEN MANAGED BLOCK -->"
    $endMarker = "<!-- END RELAY-IMAGEGEN MANAGED BLOCK -->"
    $managedPattern = '(?s)\s*' + [regex]::Escape($startMarker) + '.*?' +
        [regex]::Escape($endMarker) + '\s*'
    $agents = Get-Content -Raw -LiteralPath $agentsPath
    $updated = [regex]::Replace($agents, $managedPattern, "`r`n`r`n").Trim()
    [IO.File]::WriteAllText(
        $agentsPath,
        $(if ([string]::IsNullOrWhiteSpace($updated)) { "" } else { "$updated`r`n" }),
        (New-Object Text.UTF8Encoding($false))
    )
}

if ($RemoveCredentials) {
    foreach ($name in @(
        "RELAY_IMAGE_PROVIDER_NAME",
        "RELAY_IMAGE_GENERATIONS_URL",
        "RELAY_IMAGE_EDITS_URL",
        "RELAY_IMAGE_BATCHES_URL",
        "RELAY_IMAGE_MODEL",
        "RELAY_IMAGE_API_KEY",
        "RELAY_IMAGE_AUTH_HEADER",
        "RELAY_IMAGE_AUTH_SCHEME",
        "RELAY_IMAGE_EXTRA_HEADERS_JSON",
        "RELAY_IMAGE_COMPATIBILITY_PROFILE"
    )) {
        [Environment]::SetEnvironmentVariable($name, $null, "Process")
        if (Test-Path -LiteralPath "HKCU:\Environment") {
            Remove-ItemProperty -Path "HKCU:\Environment" -Name $name -ErrorAction SilentlyContinue
        }
    }
}

[pscustomobject]@{
    uninstalled = $true
    codex_home = $CodexHome
    credentials_removed = [bool]$RemoveCredentials
    restart_codex = $true
} | ConvertTo-Json
