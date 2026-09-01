[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)]
    [string]$Prompt,

    [string]$OutputPath,
    [string[]]$ReferenceImagePath = @(),
    [string]$MaskPath,
    [string]$Model,
    [string]$ApiKey,
    [string]$AuthHeader,
    [string]$AuthScheme,
    [string]$ExtraHeadersJson,
    [string]$CompatibilityProfile,
    [string]$Size = "1024x1024",
    [ValidateSet("low", "medium", "high", "auto")]
    [string]$Quality = "low",
    [ValidateSet("jpeg", "png", "webp")]
    [string]$OutputFormat = "jpeg",
    [ValidateRange(0, 100)]
    [int]$OutputCompression = 70,
    [bool]$Stream = $true,
    [ValidateRange(0, 3)]
    [int]$PartialImages = 1,
    [ValidateRange(1, 10)]
    [int]$NumberOfImages = 1,
    [ValidateRange(0, 5)]
    [int]$MaxRetries = 2,
    [switch]$SavePartialImages,
    [switch]$Overwrite,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($args.Count -gt 0) {
    throw "Unexpected unnamed arguments. Pass all reference images through the named ReferenceImagePath array and invoke this script in the current PowerShell process."
}

function Get-RelaySetting {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$DefaultValue
    )

    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [Environment]::GetEnvironmentVariable($Name, "User")
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $DefaultValue
    }
    return $value
}

function Resolve-InputFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label does not exist or is not a file: $Path"
    }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function Assert-ValidImageSize {
    param(
        [string]$Value,
        [string]$ModelName
    )

    if ($Value -eq "auto") {
        return
    }
    if ($Value -notmatch '^(\d+)x(\d+)$') {
        throw "Size must be 'auto' or WIDTHxHEIGHT: $Value"
    }
    if ($ModelName -ne "gpt-image-2") {
        return
    }

    $width = [int64]$Matches[1]
    $height = [int64]$Matches[2]
    $longEdge = [Math]::Max($width, $height)
    $shortEdge = [Math]::Min($width, $height)
    $pixels = $width * $height
    if ($width % 16 -ne 0 -or $height % 16 -ne 0 -or
        $longEdge -gt 3840 -or ($longEdge / $shortEdge) -gt 3 -or
        $pixels -lt 655360 -or $pixels -gt 8294400) {
        throw "Invalid gpt-image-2 size '$Value'. Edges must be multiples of 16, the longest edge must be <= 3840, aspect ratio <= 3:1, and total pixels between 655360 and 8294400."
    }
}

function Get-PngInfo {
    param(
        [string]$Path,
        [string]$Label
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    if ($bytes.Length -lt 26) {
        throw "$Label is not a valid PNG file: $Path"
    }
    for ($index = 0; $index -lt $signature.Length; $index++) {
        if ($bytes[$index] -ne $signature[$index]) {
            throw "$Label must be a PNG file: $Path"
        }
    }

    $width = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16))
    $height = [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20))
    $colorType = [int]$bytes[25]
    return [pscustomobject]@{
        Width = $width
        Height = $height
        HasAlpha = $colorType -in @(4, 6)
    }
}

function Get-AvailableOutputPath {
    param(
        [string]$DesiredPath,
        [bool]$AllowOverwrite
    )

    if ($AllowOverwrite -or -not (Test-Path -LiteralPath $DesiredPath)) {
        return $DesiredPath
    }

    $directory = Split-Path -Parent $DesiredPath
    $stem = [IO.Path]::GetFileNameWithoutExtension($DesiredPath)
    $extension = [IO.Path]::GetExtension($DesiredPath)
    $version = 2
    do {
        $candidate = Join-Path $directory ("{0}-v{1}{2}" -f $stem, $version, $extension)
        $version++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Get-VariantOutputPath {
    param(
        [string]$BasePath,
        [int]$Index,
        [int]$Count,
        [bool]$AllowOverwrite
    )

    $desired = $BasePath
    if ($Count -gt 1) {
        $directory = Split-Path -Parent $BasePath
        $stem = [IO.Path]::GetFileNameWithoutExtension($BasePath)
        $extension = [IO.Path]::GetExtension($BasePath)
        $desired = Join-Path $directory ("{0}-{1}{2}" -f $stem, $Index, $extension)
    }
    return Get-AvailableOutputPath -DesiredPath $desired -AllowOverwrite $AllowOverwrite
}

function Get-ImageFormatFromBytes {
    param([byte[]]$Bytes)

    if ($Bytes.Length -ge 8 -and $Bytes[0] -eq 137 -and $Bytes[1] -eq 80 -and
        $Bytes[2] -eq 78 -and $Bytes[3] -eq 71) {
        return "png"
    }
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 216 -and
        $Bytes[2] -eq 255) {
        return "jpeg"
    }
    if ($Bytes.Length -ge 12 -and [Text.Encoding]::ASCII.GetString($Bytes, 0, 4) -eq "RIFF" -and
        [Text.Encoding]::ASCII.GetString($Bytes, 8, 4) -eq "WEBP") {
        return "webp"
    }
    return $null
}

function Save-Base64Image {
    param(
        [string]$Base64,
        [string]$Path
    )

    if ($Base64 -match '^data:image/[^;]+;base64,(.+)$') {
        $Base64 = $Matches[1]
    }
    $bytes = [Convert]::FromBase64String($Base64)
    $detectedFormat = Get-ImageFormatFromBytes -Bytes $bytes
    if ([string]::IsNullOrWhiteSpace($detectedFormat)) {
        throw "The API returned data that is not a recognized PNG, JPEG, or WebP image."
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
    return $detectedFormat
}

function Write-ApiDiagnostics {
    param(
        [string]$Content,
        [string]$BaseOutputPath
    )

    $diagnosticsPath = "$BaseOutputPath.response.txt"
    [IO.File]::WriteAllText($diagnosticsPath, $Content, [Text.Encoding]::UTF8)
    return $diagnosticsPath
}

function Expand-ReferenceImagePaths {
    param(
        [string[]]$Paths
    )

    $expanded = @()
    foreach ($rawPath in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($rawPath)) {
            continue
        }

        if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
            $expanded += $rawPath
            continue
        }

        $parts = @(
            $rawPath -split '\s*[,;]\s*' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $allPartsExist = $parts.Count -gt 1
        foreach ($part in $parts) {
            if (-not (Test-Path -LiteralPath $part -PathType Leaf)) {
                $allPartsExist = $false
                break
            }
        }

        if ($allPartsExist) {
            $expanded += $parts
        } else {
            $expanded += $rawPath
        }
    }
    return $expanded
}

function Find-NamedString {
    param(
        $Node,
        [string[]]$Names
    )

    if ($null -eq $Node -or $Node -is [string] -or $Node -is [ValueType]) {
        return $null
    }

    if ($Node -is [System.Collections.IEnumerable] -and
        $Node -isnot [System.Management.Automation.PSCustomObject]) {
        foreach ($item in $Node) {
            $found = Find-NamedString -Node $item -Names $Names
            if (-not [string]::IsNullOrWhiteSpace($found)) {
                return $found
            }
        }
        return $null
    }

    foreach ($property in $Node.PSObject.Properties) {
        if ($Names -contains $property.Name -and $property.Value -is [string] -and
            -not [string]::IsNullOrWhiteSpace($property.Value)) {
            return [string]$property.Value
        }
    }

    foreach ($property in $Node.PSObject.Properties) {
        $found = Find-NamedString -Node $property.Value -Names $Names
        if (-not [string]::IsNullOrWhiteSpace($found)) {
            return $found
        }
    }
    return $null
}

$referenceImageCandidates = @(Expand-ReferenceImagePaths -Paths $ReferenceImagePath)
$resolvedReferenceImages = @()
foreach ($path in $referenceImageCandidates) {
    if (-not [string]::IsNullOrWhiteSpace($path)) {
        $resolvedReferenceImages += Resolve-InputFile -Path $path -Label "Reference image"
    }
}

$maskWasExplicitlyProvided = $PSBoundParameters.ContainsKey("MaskPath") -and
    -not [string]::IsNullOrWhiteSpace($MaskPath)
$resolvedMask = $null
if ($maskWasExplicitlyProvided) {
    if ($resolvedReferenceImages.Count -eq 0) {
        throw "MaskPath requires at least one ReferenceImagePath."
    }
    $resolvedMask = Resolve-InputFile -Path $MaskPath -Label "Mask image"
}

$mode = if ($resolvedReferenceImages.Count -gt 0) { "edit" } else { "generate" }
$endpoint = if ($mode -eq "edit") {
    Get-RelaySetting -Name "RELAY_IMAGE_EDITS_URL"
} else {
    Get-RelaySetting -Name "RELAY_IMAGE_GENERATIONS_URL"
}
if ([string]::IsNullOrWhiteSpace($endpoint)) {
    $requiredEndpoint = if ($mode -eq "edit") {
        "RELAY_IMAGE_EDITS_URL"
    } else {
        "RELAY_IMAGE_GENERATIONS_URL"
    }
    throw "$requiredEndpoint is not configured. Run the relay installer first."
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = Get-RelaySetting -Name "RELAY_IMAGE_MODEL"
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    throw "RELAY_IMAGE_MODEL is not configured. Run the relay installer first."
}
if ([string]::IsNullOrWhiteSpace($CompatibilityProfile)) {
    $CompatibilityProfile = Get-RelaySetting `
        -Name "RELAY_IMAGE_COMPATIBILITY_PROFILE" `
        -DefaultValue "full"
}
$CompatibilityProfile = $CompatibilityProfile.ToLowerInvariant()
if ($CompatibilityProfile -notin @("full", "standard", "minimal")) {
    throw "CompatibilityProfile must be full, standard, or minimal."
}
if ([string]::IsNullOrWhiteSpace($AuthHeader)) {
    $AuthHeader = Get-RelaySetting -Name "RELAY_IMAGE_AUTH_HEADER" -DefaultValue "Authorization"
}
if ([string]::IsNullOrWhiteSpace($AuthScheme)) {
    $AuthScheme = Get-RelaySetting -Name "RELAY_IMAGE_AUTH_SCHEME" -DefaultValue "Bearer"
}
if ($AuthScheme -eq "none") {
    $AuthScheme = ""
}
if ([string]::IsNullOrWhiteSpace($ExtraHeadersJson)) {
    $ExtraHeadersJson = Get-RelaySetting -Name "RELAY_IMAGE_EXTRA_HEADERS_JSON"
}
$providerName = Get-RelaySetting -Name "RELAY_IMAGE_PROVIDER_NAME" -DefaultValue "configured relay"
$extraHeaders = @{}
if (-not [string]::IsNullOrWhiteSpace($ExtraHeadersJson)) {
    try {
        $extraHeaderObject = $ExtraHeadersJson | ConvertFrom-Json
        foreach ($property in $extraHeaderObject.PSObject.Properties) {
            $extraHeaders[$property.Name] = [string]$property.Value
        }
    } catch {
        throw "RELAY_IMAGE_EXTRA_HEADERS_JSON must be a JSON object of header names and values."
    }
}
Assert-ValidImageSize -Value $Size -ModelName $Model

if ($maskWasExplicitlyProvided) {
    $maskInfo = Get-PngInfo -Path $resolvedMask -Label "Mask image"
    if (-not $maskInfo.HasAlpha) {
        throw "Mask image must be a PNG with an alpha channel: $resolvedMask"
    }
    $firstReferenceInfo = Get-PngInfo `
        -Path $resolvedReferenceImages[0] `
        -Label "The first reference image used with a mask"
    if ($maskInfo.Width -ne $firstReferenceInfo.Width -or
        $maskInfo.Height -ne $firstReferenceInfo.Height) {
        throw "Mask image dimensions must match the first reference image. Mask: $($maskInfo.Width)x$($maskInfo.Height); reference: $($firstReferenceInfo.Width)x$($firstReferenceInfo.Height)."
    }
}

$requestDetails = [ordered]@{
    mode = $mode
    provider = $providerName
    endpoint = $endpoint
    model = $Model
    compatibility_profile = $CompatibilityProfile
    auth_header = $AuthHeader
    auth_scheme = if ([string]::IsNullOrWhiteSpace($AuthScheme)) { "none" } else { $AuthScheme }
    extra_header_names = @($extraHeaders.Keys)
    prompt = $Prompt
    size = $Size
    quality = $Quality
    output_format = $OutputFormat
    output_compression = if ($OutputFormat -in @("jpeg", "webp")) {
        $OutputCompression
    } else {
        $null
    }
    stream = $Stream
    partial_images = if ($Stream) { $PartialImages } else { $null }
    n = $NumberOfImages
    max_retries = $MaxRetries
    save_partial_images = [bool]$SavePartialImages
    reference_images = $resolvedReferenceImages
    mask = $resolvedMask
}

if ($DryRun) {
    [pscustomobject]@{
        request = $requestDetails
        credential_configured = -not [string]::IsNullOrWhiteSpace(
            $(if ([string]::IsNullOrWhiteSpace($ApiKey)) {
                Get-RelaySetting -Name "RELAY_IMAGE_API_KEY"
            } else {
                $ApiKey
            })
        )
    } | ConvertTo-Json -Depth 5
    exit 0
}

if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = Get-RelaySetting -Name "RELAY_IMAGE_API_KEY"
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw "RELAY_IMAGE_API_KEY is not configured."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $extension = if ($OutputFormat -eq "jpeg") { "jpg" } else { $OutputFormat }
    $outputDirectory = Join-Path (Get-Location) "outputs"
    $OutputPath = Join-Path $outputDirectory (
        "relay-{0}.{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $extension
    )
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputExtension = if ($OutputFormat -eq "jpeg") { ".jpg" } else { ".$OutputFormat" }
if ((Test-Path -LiteralPath $OutputPath -PathType Container) -or
    $OutputPath.EndsWith([IO.Path]::DirectorySeparatorChar) -or
    $OutputPath.EndsWith([IO.Path]::AltDirectorySeparatorChar)) {
    $OutputPath = Join-Path $OutputPath (
        "relay-{0}{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $outputExtension
    )
} elseif ([string]::IsNullOrWhiteSpace([IO.Path]::GetExtension($OutputPath))) {
    $OutputPath = "$OutputPath$outputExtension"
}
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$headers = @{}
foreach ($name in $extraHeaders.Keys) {
    $headers[$name] = $extraHeaders[$name]
}
$authValue = if ([string]::IsNullOrWhiteSpace($AuthScheme)) {
    $ApiKey
} else {
    "$AuthScheme $ApiKey"
}
$headers[$AuthHeader] = $authValue
if ($mode -eq "edit") {
    if ($null -eq (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw "curl.exe is required for multipart reference-image uploads."
    }

    $curlArguments = @(
        "-sS",
        "--max-time", "600",
        "--request", "POST",
        $endpoint
    )
    foreach ($name in $headers.Keys) {
        $curlArguments += @("--header", ("{0}: {1}" -f $name, $headers[$name]))
    }
    $curlArguments += @(
        "--form-string", "model=$Model",
        "--form-string", "prompt=$Prompt"
    )
    if ($CompatibilityProfile -ne "minimal") {
        $curlArguments += @(
            "--form-string", "size=$Size",
            "--form-string", "quality=$Quality"
        )
    }
    if ($CompatibilityProfile -in @("full", "standard")) {
        $curlArguments += @(
            "--form-string", "output_format=$OutputFormat",
            "--form-string", "n=$NumberOfImages"
        )
    }
    if ($CompatibilityProfile -eq "full") {
        $curlArguments += @(
            "--form-string", ("stream={0}" -f $Stream.ToString().ToLowerInvariant())
        )
        if ($OutputFormat -in @("jpeg", "webp")) {
            $curlArguments += @("--form-string", "output_compression=$OutputCompression")
        }
        if ($Stream) {
            $curlArguments += @("--form-string", "partial_images=$PartialImages")
        }
    }
    foreach ($referenceImage in $resolvedReferenceImages) {
        $curlArguments += @("--form", "image[]=@$referenceImage")
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedMask)) {
        $curlArguments += @("--form", "mask=@$resolvedMask")
    }

    $content = $null
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        $attemptArguments = $curlArguments + @(
            "--write-out", "`n__RELAY_HTTP_STATUS__:%{http_code}"
        )
        $response = & curl.exe @attemptArguments
        $curlExitCode = $LASTEXITCODE
        $rawContent = @($response) -join "`n"
        $statusCode = 0
        $statusMatch = [regex]::Match(
            $rawContent,
            '(?s)\r?\n__RELAY_HTTP_STATUS__:(\d{3})\s*$'
        )
        if ($statusMatch.Success) {
            $statusCode = [int]$statusMatch.Groups[1].Value
            $content = $rawContent.Substring(0, $statusMatch.Index)
        } else {
            $content = $rawContent
        }

        $isTransient = $curlExitCode -ne 0 -or $statusCode -in @(408, 409, 425, 429) -or
            $statusCode -ge 500
        if ($isTransient -and $attempt -lt $MaxRetries) {
            Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
            continue
        }
        if ($curlExitCode -ne 0 -or $statusCode -ge 400 -or $statusCode -eq 0) {
            $diagnosticsPath = Write-ApiDiagnostics -Content $content -BaseOutputPath $OutputPath
            throw "Image edit request failed (curl=$curlExitCode, HTTP=$statusCode). Response saved to $diagnosticsPath"
        }
        break
    }
} else {
    $payload = [ordered]@{
        model = $Model
        prompt = $Prompt
    }
    if ($CompatibilityProfile -ne "minimal") {
        $payload.size = $Size
        $payload.quality = $Quality
    }
    if ($CompatibilityProfile -in @("full", "standard")) {
        $payload.output_format = $OutputFormat
        $payload.n = $NumberOfImages
    }
    if ($CompatibilityProfile -eq "full") {
        $payload.stream = $Stream
        if ($OutputFormat -in @("jpeg", "webp")) {
            $payload.output_compression = $OutputCompression
        }
        if ($Stream) {
            $payload.partial_images = $PartialImages
        }
    }

    $body = $payload | ConvertTo-Json -Depth 5 -Compress
    $content = $null
    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            $response = Invoke-WebRequest `
                -Uri $endpoint `
                -Method Post `
                -Headers $headers `
                -ContentType "application/json" `
                -Body $body `
                -UseBasicParsing `
                -TimeoutSec 600
            $content = [string]$response.Content
            break
        } catch {
            $statusCode = 0
            $errorContent = $_.Exception.Message
            if ($null -ne $_.Exception.Response) {
                try {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($null -ne $stream) {
                        $reader = New-Object IO.StreamReader($stream)
                        $errorContent = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                } catch {
                    $statusCode = 0
                }
            }
            $isTransient = $statusCode -in @(0, 408, 409, 425, 429) -or $statusCode -ge 500
            if ($isTransient -and $attempt -lt $MaxRetries) {
                Start-Sleep -Seconds ([Math]::Pow(2, $attempt))
                continue
            }
            $diagnosticsPath = Write-ApiDiagnostics -Content $errorContent -BaseOutputPath $OutputPath
            throw "Image generation request failed (HTTP=$statusCode). Response saved to $diagnosticsPath"
        }
    }
}

$objects = New-Object System.Collections.Generic.List[object]
try {
    $objects.Add(($content | ConvertFrom-Json))
} catch {
    foreach ($line in ($content -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith("data:")) {
            continue
        }
        $eventData = $trimmed.Substring(5).Trim()
        if ([string]::IsNullOrWhiteSpace($eventData) -or $eventData -eq "[DONE]") {
            continue
        }
        try {
            $objects.Add(($eventData | ConvertFrom-Json))
        } catch {
            continue
        }
    }
}

$finalCandidates = New-Object System.Collections.Generic.List[object]
$partialCandidates = New-Object System.Collections.Generic.List[object]
$usage = $null

foreach ($object in $objects) {
    $eventType = ""
    $typeProperty = $object.PSObject.Properties["type"]
    if ($null -ne $typeProperty) {
        $eventType = [string]$typeProperty.Value
    }
    $usageProperty = $object.PSObject.Properties["usage"]
    if ($null -ne $usageProperty -and $null -ne $usageProperty.Value) {
        $usage = $usageProperty.Value
    }

    $dataProperty = $object.PSObject.Properties["data"]
    if ($null -ne $dataProperty -and $null -ne $dataProperty.Value) {
        foreach ($item in @($dataProperty.Value)) {
            $itemBase64 = Find-NamedString -Node $item -Names @(
                "b64_json", "image_b64", "image_base64"
            )
            $itemUrl = Find-NamedString -Node $item -Names @("url")
            if (-not [string]::IsNullOrWhiteSpace($itemBase64) -or
                -not [string]::IsNullOrWhiteSpace($itemUrl)) {
                [void]$finalCandidates.Add([pscustomobject]@{
                    Base64 = $itemBase64
                    Url = $itemUrl
                })
            }
        }
        continue
    }

    $candidateBase64 = Find-NamedString -Node $object -Names @(
        "b64_json", "image_b64", "image_base64", "partial_image_b64"
    )
    $candidateUrl = Find-NamedString -Node $object -Names @("url")
    if ([string]::IsNullOrWhiteSpace($candidateBase64) -and
        [string]::IsNullOrWhiteSpace($candidateUrl)) {
        continue
    }

    $candidateRecord = [pscustomobject]@{
        Base64 = $candidateBase64
        Url = $candidateUrl
    }
    if ($eventType -match 'partial_image') {
        [void]$partialCandidates.Add($candidateRecord)
    } else {
        [void]$finalCandidates.Add($candidateRecord)
    }
}

$warnings = New-Object System.Collections.Generic.List[string]
if ($finalCandidates.Count -eq 0 -and $partialCandidates.Count -gt 0) {
    [void]$finalCandidates.Add($partialCandidates[$partialCandidates.Count - 1])
    [void]$warnings.Add("The API returned no explicit final event; the last partial image was saved as the final output.")
}
if ($finalCandidates.Count -eq 0) {
    $diagnosticsPath = Write-ApiDiagnostics -Content $content -BaseOutputPath $OutputPath
    throw "No image data was found in the API response. Response saved to $diagnosticsPath"
}

$partialPaths = @()
if ($SavePartialImages) {
    $partialDirectory = Split-Path -Parent $OutputPath
    $partialStem = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
    $partialExtension = [IO.Path]::GetExtension($OutputPath)
    for ($index = 0; $index -lt $partialCandidates.Count; $index++) {
        $partialPath = Join-Path $partialDirectory (
            "{0}.partial-{1}{2}" -f $partialStem, ($index + 1), $partialExtension
        )
        $partialPath = Get-AvailableOutputPath -DesiredPath $partialPath -AllowOverwrite $false
        $partialCandidate = $partialCandidates[$index]
        if (-not [string]::IsNullOrWhiteSpace($partialCandidate.Base64)) {
            [void](Save-Base64Image -Base64 $partialCandidate.Base64 -Path $partialPath)
        } elseif (-not [string]::IsNullOrWhiteSpace($partialCandidate.Url)) {
            Invoke-WebRequest -Uri $partialCandidate.Url -OutFile $partialPath -UseBasicParsing -TimeoutSec 600
        }
        if (Test-Path -LiteralPath $partialPath -PathType Leaf) {
            $partialPaths += (Resolve-Path -LiteralPath $partialPath).ProviderPath
        }
    }
}

$savedPaths = @()
$savedFiles = @()
for ($index = 0; $index -lt $finalCandidates.Count; $index++) {
    $finalPath = Get-VariantOutputPath `
        -BasePath $OutputPath `
        -Index ($index + 1) `
        -Count $finalCandidates.Count `
        -AllowOverwrite ([bool]$Overwrite)
    $candidate = $finalCandidates[$index]
    $detectedFormat = $null
    if (-not [string]::IsNullOrWhiteSpace($candidate.Base64)) {
        $detectedFormat = Save-Base64Image -Base64 $candidate.Base64 -Path $finalPath
    } elseif (-not [string]::IsNullOrWhiteSpace($candidate.Url)) {
        Invoke-WebRequest -Uri $candidate.Url -OutFile $finalPath -UseBasicParsing -TimeoutSec 600
        $detectedFormat = Get-ImageFormatFromBytes -Bytes ([IO.File]::ReadAllBytes($finalPath))
        if ([string]::IsNullOrWhiteSpace($detectedFormat)) {
            throw "Downloaded output is not a recognized PNG, JPEG, or WebP image: $finalPath"
        }
    }

    if ($detectedFormat -ne $OutputFormat) {
        [void]$warnings.Add("Requested $OutputFormat but the API returned $detectedFormat for $finalPath.")
    }
    $file = Get-Item -LiteralPath $finalPath
    if ($file.Length -le 0) {
        throw "The generated image file is empty: $finalPath"
    }
    $savedPaths += $file.FullName
    $savedFiles += [pscustomobject]@{
        path = $file.FullName
        bytes = $file.Length
        detected_format = $detectedFormat
    }
}

if ($savedPaths.Count -ne $NumberOfImages) {
    [void]$warnings.Add("Requested $NumberOfImages image(s), but the API returned $($savedPaths.Count).")
}

[pscustomobject]@{
    path = $savedPaths[0]
    paths = $savedPaths
    files = $savedFiles
    partial_paths = $partialPaths
    mode = $mode
    provider = $providerName
    compatibility_profile = $CompatibilityProfile
    model = $Model
    size = $Size
    quality = $Quality
    format = $OutputFormat
    requested_image_count = $NumberOfImages
    returned_image_count = $savedPaths.Count
    reference_image_count = $resolvedReferenceImages.Count
    mask_used = $maskWasExplicitlyProvided
    prompt = $Prompt
    usage = $usage
    warnings = @($warnings)
} | ConvertTo-Json -Depth 8 -Compress
