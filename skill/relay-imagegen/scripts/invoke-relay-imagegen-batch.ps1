[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet("submit", "list", "status", "items", "download", "content", "cancel", "delete")]
    [string]$Action = "submit",

    [string[]]$Prompt = @(),
    [string]$TaskName,
    [string]$BatchId,
    [string]$ItemId,
    [ValidateRange(0, 10)]
    [int]$ImageIndex = 0,
    [string]$OutputDirectory,
    [string]$OutputPath,
    [string]$ResumeFile,
    [string]$RequestFile,
    [string]$Model,
    [string]$ApiKey,
    [string]$AuthHeader,
    [string]$AuthScheme,
    [string]$ExtraHeadersJson,
    [string]$BatchesUrl,
    [ValidateSet("1K", "2K", "4K")]
    [string]$ImageSize = "1K",
    [string]$ResponseMimeType = "image/png",
    [ValidateRange(1, 4)]
    [int]$OutputCount = 1,
    [string[]]$ReferenceImagePath = @(),
    [ValidateRange(1, 100)]
    [int]$Limit = 20,
    [string]$StatusFilter,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if ($args.Count -gt 0) {
    throw "Unexpected unnamed arguments. Use named parameters."
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

function Get-AbsoluteHttpUri {
    param([Parameter(Mandatory = $true)][string]$Value)

    $uri = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @("http", "https") -or
        [string]::IsNullOrWhiteSpace($uri.Host)) {
        throw "Batches URL must be an absolute HTTP or HTTPS URL."
    }
    return $uri.AbsoluteUri.TrimEnd("/")
}

function Get-BatchesEndpoint {
    if (-not [string]::IsNullOrWhiteSpace($BatchesUrl)) {
        return Get-AbsoluteHttpUri -Value $BatchesUrl
    }

    $configured = Get-RelaySetting -Name "RELAY_IMAGE_BATCHES_URL"
    if (-not [string]::IsNullOrWhiteSpace($configured)) {
        return Get-AbsoluteHttpUri -Value $configured
    }

    $generationUrl = Get-RelaySetting -Name "RELAY_IMAGE_GENERATIONS_URL"
    if ($generationUrl -match '(?i)/images/generations/?$') {
        return ($generationUrl -replace '(?i)/images/generations/?$', '/images/batches').TrimEnd('/')
    }
    throw "RELAY_IMAGE_BATCHES_URL is not configured. Pass -BatchesUrl or run the relay installer again."
}

function Get-AuthHeaders {
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        $script:ApiKey = Get-RelaySetting -Name "RELAY_IMAGE_API_KEY"
    }
    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw "RELAY_IMAGE_API_KEY is not configured."
    }
    if ([string]::IsNullOrWhiteSpace($AuthHeader)) {
        $script:AuthHeader = Get-RelaySetting -Name "RELAY_IMAGE_AUTH_HEADER" -DefaultValue "Authorization"
    }
    if ([string]::IsNullOrWhiteSpace($AuthScheme)) {
        $script:AuthScheme = Get-RelaySetting -Name "RELAY_IMAGE_AUTH_SCHEME" -DefaultValue "Bearer"
    }
    $headers = @{}
    $extraJson = $ExtraHeadersJson
    if ([string]::IsNullOrWhiteSpace($extraJson)) {
        $extraJson = Get-RelaySetting -Name "RELAY_IMAGE_EXTRA_HEADERS_JSON"
    }
    if (-not [string]::IsNullOrWhiteSpace($extraJson)) {
        try {
            $extra = $extraJson | ConvertFrom-Json
            foreach ($property in $extra.PSObject.Properties) {
                $headers[$property.Name] = [string]$property.Value
            }
        } catch {
            throw "RELAY_IMAGE_EXTRA_HEADERS_JSON must be a JSON object."
        }
    }
    $authValue = if ([string]::IsNullOrWhiteSpace($AuthScheme) -or $AuthScheme -eq "none") {
        $ApiKey
    } else {
        "$AuthScheme $ApiKey"
    }
    $headers[$AuthHeader] = $authValue
    return $headers
}

function Invoke-RelayJsonRequest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "DELETE")][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Body,
        [string]$IdempotencyKey
    )

    $headers = Get-AuthHeaders
    if (-not [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        $headers["Idempotency-Key"] = $IdempotencyKey
    }
    try {
        $requestParams = @{
            Uri = $Uri
            Method = $Method
            Headers = $headers
            UseBasicParsing = $true
            TimeoutSec = 600
        }
        if ($null -ne $Body) {
            $requestParams.ContentType = "application/json"
            $requestParams.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        }
        $response = Invoke-WebRequest @requestParams
        if ([string]::IsNullOrWhiteSpace($response.Content)) {
            return $null
        }
        return ($response.Content | ConvertFrom-Json)
    } catch {
        $message = $_.Exception.Message
        if ($null -ne $_.ErrorDetails -and
            -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            $message = $_.ErrorDetails.Message
        }
        $status = 0
        $errorBody = $null
        if ($null -ne $_.Exception.Response) {
            try {
                $status = [int]$_.Exception.Response.StatusCode
                $stream = $_.Exception.Response.GetResponseStream()
                if ($null -ne $stream) {
                    $reader = New-Object IO.StreamReader($stream)
                    $errorBody = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            } catch {
                $status = 0
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($errorBody)) {
            $message = $errorBody
        }
        throw "Batch API request failed (HTTP=$status): $message"
    }
}

function Get-ImageMimeType {
    param([Parameter(Mandatory = $true)][string]$Path)

    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($extension) {
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".webp" { return "image/webp" }
        default { throw "Unsupported reference image format: $Path. Use PNG, JPEG, or WebP." }
    }
}

function New-ReferenceImageRecords {
    param([string[]]$Paths)

    $records = @()
    foreach ($path in @($Paths)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Reference image does not exist or is not a file: $path"
        }
        $resolved = (Resolve-Path -LiteralPath $path).ProviderPath
        $bytes = [IO.File]::ReadAllBytes($resolved)
        if ($bytes.Length -gt 10MB) {
            throw "Reference image is larger than 10 MB: $resolved"
        }
        $records += [pscustomobject]@{
            id = [IO.Path]::GetFileName($resolved)
            type = "reference"
            mime_type = Get-ImageMimeType -Path $resolved
            data = [Convert]::ToBase64String($bytes)
        }
    }
    return $records
}

function Get-SafeStem {
    param([string]$Value)
    $safe = $Value -replace '[^\w.-]+', '_'
    $safe = $safe.Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { return "relay-batch" }
    return $safe
}

function Get-ResumeObject {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "ResumeFile is required for this action."
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Resume file does not exist: $Path"
    }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Write-ResumeObject {
    param(
        [Parameter(Mandatory = $true)]$Resume,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $Resume.last_checked_at = (Get-Date).ToUniversalTime().ToString("o")
    [IO.File]::WriteAllText($Path, ($Resume | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}

function Get-ResumePath {
    param($Resume)
    if ($Resume.resume_file) { return [string]$Resume.resume_file }
    return $ResumeFile
}

function Get-BatchIdFromInput {
    if (-not [string]::IsNullOrWhiteSpace($BatchId)) { return $BatchId }
    $resume = Get-ResumeObject -Path $ResumeFile
    if ([string]::IsNullOrWhiteSpace($resume.batch_id)) { throw "Resume file has no batch_id." }
    return [string]$resume.batch_id
}

function Get-ResponseValue {
    param($Object, [string[]]$Names)
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

$endpoint = Get-BatchesEndpoint
if ($Action -ne "submit" -and $DryRun) {
    throw "DryRun is only supported for submit."
}

switch ($Action) {
    "list" {
        $query = "limit=$Limit"
        if (-not [string]::IsNullOrWhiteSpace($StatusFilter)) {
            $query += "&status=$([Uri]::EscapeDataString($StatusFilter))"
        }
        $result = Invoke-RelayJsonRequest -Method GET -Uri "${endpoint}?$query"
        $result | ConvertTo-Json -Depth 10 -Compress
        break
    }
    "submit" {
        if (@($Prompt).Count -eq 0 -or @($Prompt | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "Submit requires one or more non-empty Prompt values."
        }
        $expectedCount = @($Prompt).Count * $OutputCount
        if ($expectedCount -gt 200) {
            throw "This batch would produce $expectedCount images. Split it into batches of 200 or fewer."
        }
        if ([string]::IsNullOrWhiteSpace($Model)) {
            $Model = Get-RelaySetting -Name "RELAY_IMAGE_MODEL"
        }
        if ([string]::IsNullOrWhiteSpace($Model)) {
            throw "RELAY_IMAGE_MODEL is not configured."
        }
        if ([string]::IsNullOrWhiteSpace($TaskName)) {
            $TaskName = "relay-batch-$(Get-Date -Format yyyyMMdd-HHmmss)"
        }
        if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
            $OutputDirectory = Join-Path (Join-Path (Get-Location) "outputs") (Get-SafeStem -Value $TaskName)
        }
        $OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        $references = New-ReferenceImageRecords -Paths $ReferenceImagePath
        $items = @()
        for ($index = 0; $index -lt @($Prompt).Count; $index++) {
            $items += [ordered]@{
                custom_id = "img_{0:D3}" -f ($index + 1)
                prompt = [string]$Prompt[$index]
                output_count = $OutputCount
                reference_images = @($references)
            }
        }
        $payload = [ordered]@{
            model = $Model
            task_name = $TaskName
            image_size = $ImageSize
            response_mime_type = $ResponseMimeType
            items = $items
        }
        $timestamp = Get-Date -Format yyyyMMdd-HHmmss
        if ([string]::IsNullOrWhiteSpace($RequestFile)) {
            $RequestFile = Join-Path $OutputDirectory "batch-request-$timestamp.json"
        }
        $RequestFile = [IO.Path]::GetFullPath($RequestFile)
        if ((Test-Path -LiteralPath $RequestFile) -and -not $Force) {
            throw "Request file already exists. Use -Force to replace it: $RequestFile"
        }
        if ($DryRun) {
            [pscustomobject]@{
                action = "submit"
                endpoint = $endpoint
                task_name = $TaskName
                model = $Model
                image_size = $ImageSize
                response_mime_type = $ResponseMimeType
                prompt_count = @($Prompt).Count
                expected_output_count = $expectedCount
                reference_image_count_per_item = @($references).Count
                request_file = $RequestFile
                credential_configured = -not [string]::IsNullOrWhiteSpace((Get-RelaySetting -Name "RELAY_IMAGE_API_KEY"))
            } | ConvertTo-Json -Depth 8 -Compress
            break
        }
        $requestJson = $payload | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($RequestFile, $requestJson, (New-Object Text.UTF8Encoding($false)))
        $idempotencyKey = [guid]::NewGuid().ToString()
        $response = Invoke-RelayJsonRequest -Method POST -Uri $endpoint -Body $payload -IdempotencyKey $idempotencyKey
        $id = Get-ResponseValue -Object $response -Names @("id", "batch_id")
        if ([string]::IsNullOrWhiteSpace([string]$id)) {
            throw "Batch submit returned no batch id. The sanitized response was: $($response | ConvertTo-Json -Compress)"
        }
        $resumePath = Join-Path $OutputDirectory "batch-image-resume.json"
        $resume = [ordered]@{
            endpoint = $endpoint
            task_name = $TaskName
            batch_id = [string]$id
            model = $Model
            output_dir = $OutputDirectory
            request_file = $RequestFile
            idempotency_key = $idempotencyKey
            resume_file = $resumePath
            submitted_at = (Get-Date).ToUniversalTime().ToString("o")
            last_checked_at = $null
            last_status = [string](Get-ResponseValue -Object $response -Names @("status"))
            status_url = "$endpoint/$([Uri]::EscapeDataString([string]$id))"
            items_url = "$endpoint/$([Uri]::EscapeDataString([string]$id))/items"
            download_url = "$endpoint/$([Uri]::EscapeDataString([string]$id))/download"
            prompt_count = @($Prompt).Count
            expected_output_count = $expectedCount
            success_count = 0
            failed_count = 0
            actual_cost = $null
            failed_items = @()
            custom_id_to_prompt = @($items | ForEach-Object { [pscustomobject]@{ custom_id = $_.custom_id; prompt = $_.prompt } })
        }
        Write-ResumeObject -Resume ([pscustomobject]$resume) -Path $resumePath
        [pscustomobject]@{
            action = "submit"
            batch_id = [string]$id
            task_name = $TaskName
            status = $resume.last_status
            resume_file = $resumePath
            request_file = $RequestFile
            status_url = $resume.status_url
            expected_output_count = $expectedCount
        } | ConvertTo-Json -Depth 8 -Compress
        break
    }
    "status" {
        $resume = if (-not [string]::IsNullOrWhiteSpace($ResumeFile)) { Get-ResumeObject -Path $ResumeFile } else { $null }
        $id = Get-BatchIdFromInput
        $result = Invoke-RelayJsonRequest -Method GET -Uri "$endpoint/$([Uri]::EscapeDataString($id))"
        if ($null -ne $resume) {
            $resume.last_status = [string](Get-ResponseValue -Object $result -Names @("status", "last_status"))
            $resume.success_count = Get-ResponseValue -Object $result -Names @("success_count", "succeeded_count", "completed_count")
            $resume.failed_count = Get-ResponseValue -Object $result -Names @("failed_count", "error_count")
            $resume.actual_cost = Get-ResponseValue -Object $result -Names @("actual_cost", "cost", "total_cost")
            Write-ResumeObject -Resume $resume -Path (Get-ResumePath -Resume $resume)
        }
        $result | ConvertTo-Json -Depth 12 -Compress
        break
    }
    "items" {
        $resume = if (-not [string]::IsNullOrWhiteSpace($ResumeFile)) { Get-ResumeObject -Path $ResumeFile } else { $null }
        $id = Get-BatchIdFromInput
        $uri = "$endpoint/$([Uri]::EscapeDataString($id))/items"
        if (-not [string]::IsNullOrWhiteSpace($StatusFilter)) { $uri += "?status=$([Uri]::EscapeDataString($StatusFilter))" }
        $result = Invoke-RelayJsonRequest -Method GET -Uri $uri
        if ($null -ne $resume) {
            $data = @(Get-ResponseValue -Object $result -Names @("data", "items"))
            $resume.success_count = @($data | Where-Object { $_.status -in @("completed", "succeeded", "success") }).Count
            $resume.failed_count = @($data | Where-Object { $_.status -in @("failed", "error") }).Count
            $resume.failed_items = @($data | Where-Object { $_.status -in @("failed", "error") } | ForEach-Object {
                [pscustomobject]@{ custom_id = $_.custom_id; status = $_.status; error = $_.error }
            })
            Write-ResumeObject -Resume $resume -Path (Get-ResumePath -Resume $resume)
        }
        $result | ConvertTo-Json -Depth 15 -Compress
        break
    }
    "download" {
        $resume = if (-not [string]::IsNullOrWhiteSpace($ResumeFile)) { Get-ResumeObject -Path $ResumeFile } else { $null }
        $id = Get-BatchIdFromInput
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $directory = if ($OutputDirectory) { $OutputDirectory } elseif ($resume.output_dir) { $resume.output_dir } else { Join-Path (Get-Location) "outputs" }
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $OutputPath = Join-Path $directory ("batch-{0}.zip" -f $id)
        }
        $headers = Get-AuthHeaders
        Invoke-WebRequest -Uri "$endpoint/$([Uri]::EscapeDataString($id))/download" -Headers $headers -OutFile $OutputPath -UseBasicParsing -TimeoutSec 600
        [pscustomobject]@{ action = "download"; batch_id = $id; path = (Resolve-Path -LiteralPath $OutputPath).ProviderPath } | ConvertTo-Json -Compress
        break
    }
    "content" {
        if ([string]::IsNullOrWhiteSpace($ItemId)) { throw "Content requires -ItemId." }
        $id = Get-BatchIdFromInput
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            $directory = if ($OutputDirectory) { $OutputDirectory } else { Join-Path (Get-Location) "outputs" }
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $OutputPath = Join-Path $directory ("{0}-{1}.png" -f $ItemId, $ImageIndex)
        }
        $headers = Get-AuthHeaders
        $query = "?image_index=$ImageIndex"
        Invoke-WebRequest -Uri "$endpoint/$([Uri]::EscapeDataString($id))/items/$([Uri]::EscapeDataString($ItemId))/content$query" -Headers $headers -OutFile $OutputPath -UseBasicParsing -TimeoutSec 600
        [pscustomobject]@{ action = "content"; batch_id = $id; item_id = $ItemId; image_index = $ImageIndex; path = (Resolve-Path -LiteralPath $OutputPath).ProviderPath } | ConvertTo-Json -Compress
        break
    }
    "cancel" {
        if (-not $Force) { throw "Cancel changes server state. Re-run with -Force after confirming successful items remain billable." }
        $id = Get-BatchIdFromInput
        $result = Invoke-RelayJsonRequest -Method POST -Uri "$endpoint/$([Uri]::EscapeDataString($id))/cancel"
        $result | ConvertTo-Json -Depth 10 -Compress
        break
    }
    "delete" {
        if (-not $Force) { throw "Delete changes server state. Re-run with -Force after confirming the batch is no longer needed." }
        $id = Get-BatchIdFromInput
        $result = Invoke-RelayJsonRequest -Method DELETE -Uri "$endpoint/$([Uri]::EscapeDataString($id))"
        if ($null -eq $result) { [pscustomobject]@{ action = "delete"; batch_id = $id; deleted = $true } | ConvertTo-Json -Compress } else { $result | ConvertTo-Json -Depth 10 -Compress }
        break
    }
}
