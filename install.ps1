[CmdletBinding()]
param(
    [string]$CodexHome,
    [string]$ProviderName,
    [string]$GenerationsUrl,
    [string]$EditsUrl,
    [string]$Model,
    [string]$ApiKey,
    [string]$AuthHeader,
    [string]$AuthScheme,
    [string]$ExtraHeadersJson,
    [ValidateSet("full", "standard", "minimal")]
    [string]$CompatibilityProfile,
    [ValidateSet("User", "Process")]
    [string]$EnvironmentTarget = "User",
    [switch]$NonInteractive
)

$ErrorActionPreference = "Stop"

function Get-PlainTextFromSecureString {
    param([Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-AbsoluteHttpUri {
    param(
        [string]$Value,
        [string]$Label
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @("http", "https") -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "$Label must be an absolute HTTP or HTTPS URL."
    }
    return $uri
}

function Get-GenerationEndpoint {
    param([string]$InputUrl)

    $uri = Get-AbsoluteHttpUri -Value $InputUrl -Label "Generation URL"
    $path = $uri.AbsolutePath.TrimEnd("/")
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = "/v1/images/generations"
    } elseif ($path -match '(?i)/v1$') {
        $path = "$path/images/generations"
    }
    $builder = New-Object System.UriBuilder -ArgumentList $uri
    $builder.Path = $path.TrimStart("/")
    $builder.Query = ""
    $builder.Fragment = ""
    return $builder.Uri.AbsoluteUri.TrimEnd("/")
}

function Get-EditEndpoint {
    param(
        [string]$GenerationEndpoint,
        [string]$ExplicitEditUrl
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitEditUrl)) {
        if ($ExplicitEditUrl.Trim().ToLowerInvariant() -eq "none") {
            return ""
        }
        $uri = Get-AbsoluteHttpUri -Value $ExplicitEditUrl -Label "Edit URL"
        $path = $uri.AbsolutePath.TrimEnd("/")
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = "/v1/images/edits"
        } elseif ($path -match '(?i)/v1$') {
            $path = "$path/images/edits"
        }
        $builder = New-Object System.UriBuilder -ArgumentList $uri
        $builder.Path = $path.TrimStart("/")
        $builder.Query = ""
        $builder.Fragment = ""
        return $builder.Uri.AbsoluteUri.TrimEnd("/")
    }

    if ($GenerationEndpoint -match '(?i)/images/generations$') {
        return $GenerationEndpoint -replace '(?i)/images/generations$', '/images/edits'
    }
    return ""
}

function Set-RelayEnvironmentValue {
    param(
        [string]$Name,
        [string]$Value,
        [string]$Target
    )

    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    if ($Target -eq "User") {
        if (-not (Test-Path -LiteralPath "HKCU:\Environment")) {
            throw "The Windows user environment registry key is unavailable."
        }
        Set-ItemProperty -Path "HKCU:\Environment" -Name $Name -Value $Value -Type String
    }
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = $env:CODEX_HOME
}
if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = Join-Path $HOME ".codex"
}
$CodexHome = [IO.Path]::GetFullPath($CodexHome)

$sourceSkill = Join-Path $PSScriptRoot "skill\relay-imagegen"
$requiredSourceFiles = @(
    (Join-Path $sourceSkill "SKILL.md"),
    (Join-Path $sourceSkill "agents\openai.yaml"),
    (Join-Path $sourceSkill "scripts\invoke-relay-imagegen.ps1")
)
foreach ($requiredFile in $requiredSourceFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Portable package is incomplete. Missing: $requiredFile"
    }
}
if ($null -eq (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    throw "curl.exe is required for multipart image uploads."
}

if ([string]::IsNullOrWhiteSpace($ProviderName)) {
    if ($NonInteractive) {
        $ProviderName = "Image Relay"
    } else {
        $ProviderName = Read-Host "Relay name [Image Relay]"
        if ([string]::IsNullOrWhiteSpace($ProviderName)) {
            $ProviderName = "Image Relay"
        }
    }
}
if ([string]::IsNullOrWhiteSpace($GenerationsUrl)) {
    if ($NonInteractive) {
        throw "Generation URL is required. Pass -GenerationsUrl."
    }
    $GenerationsUrl = Read-Host "Generation URL (base, /v1, or full endpoint)"
}
if ([string]::IsNullOrWhiteSpace($GenerationsUrl)) {
    throw "Generation URL cannot be empty."
}
$generationEndpoint = Get-GenerationEndpoint -InputUrl $GenerationsUrl

if (-not $PSBoundParameters.ContainsKey("EditsUrl") -and -not $NonInteractive) {
    $EditsUrl = Read-Host "Edit URL [auto; enter none to disable reference-image editing]"
}
$editEndpoint = Get-EditEndpoint `
    -GenerationEndpoint $generationEndpoint `
    -ExplicitEditUrl $EditsUrl

if ([string]::IsNullOrWhiteSpace($Model)) {
    if ($NonInteractive) {
        throw "Model is required. Pass -Model."
    }
    $Model = Read-Host "Image model identifier"
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    throw "Model cannot be empty."
}

if ([string]::IsNullOrWhiteSpace($AuthHeader)) {
    if ($NonInteractive) {
        $AuthHeader = "Authorization"
    } else {
        $AuthHeader = Read-Host "API key header [Authorization]"
        if ([string]::IsNullOrWhiteSpace($AuthHeader)) {
            $AuthHeader = "Authorization"
        }
    }
}
if ([string]::IsNullOrWhiteSpace($AuthScheme)) {
    if ($NonInteractive) {
        $AuthScheme = "Bearer"
    } else {
        $AuthScheme = Read-Host "API key prefix [Bearer; enter none for no prefix]"
        if ([string]::IsNullOrWhiteSpace($AuthScheme)) {
            $AuthScheme = "Bearer"
        }
    }
}
if ([string]::IsNullOrWhiteSpace($CompatibilityProfile)) {
    if ($NonInteractive) {
        $CompatibilityProfile = "full"
    } else {
        $CompatibilityProfile = Read-Host "Compatibility profile [full/standard/minimal; default full]"
        if ([string]::IsNullOrWhiteSpace($CompatibilityProfile)) {
            $CompatibilityProfile = "full"
        }
    }
}
$CompatibilityProfile = $CompatibilityProfile.ToLowerInvariant()
if ($CompatibilityProfile -notin @("full", "standard", "minimal")) {
    throw "Compatibility profile must be full, standard, or minimal."
}

if (-not $PSBoundParameters.ContainsKey("ExtraHeadersJson") -and -not $NonInteractive) {
    $ExtraHeadersJson = Read-Host 'Extra headers JSON [optional, for example {"X-Client":"Codex"}]'
}
if ([string]::IsNullOrWhiteSpace($ExtraHeadersJson)) {
    $ExtraHeadersJson = "{}"
}
try {
    $extraHeaderObject = $ExtraHeadersJson | ConvertFrom-Json
    if ($null -eq $extraHeaderObject -or $extraHeaderObject -is [array]) {
        throw "invalid"
    }
} catch {
    throw "ExtraHeadersJson must be a JSON object."
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = [Environment]::GetEnvironmentVariable("RELAY_IMAGE_API_KEY", "Process")
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = [Environment]::GetEnvironmentVariable("RELAY_IMAGE_API_KEY", "User")
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    if ($NonInteractive) {
        throw "Relay image API key is required in non-interactive mode."
    }
    $secureKey = Read-Host "Relay image API key" -AsSecureString
    $ApiKey = Get-PlainTextFromSecureString -SecureValue $secureKey
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "Relay image API key cannot be empty."
}

New-Item -ItemType Directory -Path $CodexHome -Force | Out-Null
$skillsRoot = Join-Path $CodexHome "skills"
$destinationSkill = Join-Path $skillsRoot "relay-imagegen"
New-Item -ItemType Directory -Path $destinationSkill -Force | Out-Null
Copy-Item -Path (Join-Path $sourceSkill "*") -Destination $destinationSkill -Recurse -Force

$settings = @{
    RELAY_IMAGE_PROVIDER_NAME = $ProviderName
    RELAY_IMAGE_GENERATIONS_URL = $generationEndpoint
    RELAY_IMAGE_EDITS_URL = $editEndpoint
    RELAY_IMAGE_MODEL = $Model
    RELAY_IMAGE_API_KEY = $ApiKey
    RELAY_IMAGE_AUTH_HEADER = $AuthHeader
    RELAY_IMAGE_AUTH_SCHEME = $AuthScheme
    RELAY_IMAGE_EXTRA_HEADERS_JSON = $ExtraHeadersJson
    RELAY_IMAGE_COMPATIBILITY_PROFILE = $CompatibilityProfile
}
foreach ($name in $settings.Keys) {
    Set-RelayEnvironmentValue -Name $name -Value $settings[$name] -Target $EnvironmentTarget
}

$agentsPath = Join-Path $CodexHome "AGENTS.md"
$startMarker = "<!-- BEGIN RELAY-IMAGEGEN MANAGED BLOCK -->"
$endMarker = "<!-- END RELAY-IMAGEGEN MANAGED BLOCK -->"
$managedBlock = @'
<!-- BEGIN RELAY-IMAGEGEN MANAGED BLOCK -->
# Global Image Generation Preference

For every request to generate or edit a raster image, including requests with
one or more reference images or a mask, use the `relay-imagegen` skill and its
bundled script instead of the built-in `imagegen` provider. Read endpoints,
model, authentication settings, and credential from `RELAY_IMAGE_*` variables.
Never print, echo, or embed the API key in generated files.

Only use another image provider when the user explicitly requests it. Use the
configured relay edits endpoint for reference-image generation and editing.
<!-- END RELAY-IMAGEGEN MANAGED BLOCK -->
'@

$existingAgents = ""
if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
    $existingAgents = Get-Content -Raw -LiteralPath $agentsPath
    Copy-Item -LiteralPath $agentsPath -Destination "$agentsPath.relay-imagegen.bak" -Force
}
$managedPattern = '(?s)' + [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
if ([regex]::IsMatch($existingAgents, $managedPattern)) {
    $updatedAgents = [regex]::Replace($existingAgents, $managedPattern, $managedBlock)
} elseif ([string]::IsNullOrWhiteSpace($existingAgents)) {
    $updatedAgents = "$managedBlock`r`n"
} else {
    $updatedAgents = $existingAgents.TrimEnd() + "`r`n`r`n" + $managedBlock + "`r`n"
}
[IO.File]::WriteAllText($agentsPath, $updatedAgents, (New-Object Text.UTF8Encoding($false)))

$installedScript = Join-Path $destinationSkill "scripts\invoke-relay-imagegen.ps1"
$selfTest = & $installedScript -Prompt "portable installation self-test" -DryRun | ConvertFrom-Json
if (-not $selfTest.credential_configured -or
    $selfTest.request.endpoint -ne $generationEndpoint -or
    $selfTest.request.model -ne $Model -or
    $selfTest.request.auth_header -ne $AuthHeader -or
    $selfTest.request.compatibility_profile -ne $CompatibilityProfile) {
    throw "Installation self-test failed."
}

[pscustomobject]@{
    installed = $true
    codex_home = $CodexHome
    skill_path = $destinationSkill
    provider = $ProviderName
    generations_url = $generationEndpoint
    edits_url = $editEndpoint
    edit_support_configured = -not [string]::IsNullOrWhiteSpace($editEndpoint)
    model = $Model
    auth_header = $AuthHeader
    auth_scheme = $AuthScheme
    compatibility_profile = $CompatibilityProfile
    environment_target = $EnvironmentTarget
    restart_codex = ($EnvironmentTarget -eq "User")
} | ConvertTo-Json -Depth 4

