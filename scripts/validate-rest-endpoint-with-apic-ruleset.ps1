[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string]$ServiceName,

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl = "https://apim-poc-my.azure-api.net/salesapi",

    [Parameter(Mandatory = $false)]
    [string]$AnalyzerConfigName = "spectral-openapi",

    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "2024-06-01-preview",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 240,

    [Parameter(Mandatory = $false)]
    [int]$PollSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AzCli {
    param([string]$Command)

    Write-Host "> $Command"
    $result = Invoke-Expression $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Command`n$result"
    }
    return $result
}

function Try-AzRestJson {
    param(
        [string]$Method,
        [string]$Url,
        [string]$Body
    )

    $base = "az rest --method $Method --url `"$Url`" -o json"
    if ($Body) {
        $base += " --body '$Body' --headers `"Content-Type=application/json`""
    }

    $result = Invoke-Expression $base 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    try {
        return ($result | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-SpecCandidates {
    param([string]$BaseUrl)

    $trimmed = $BaseUrl.TrimEnd('/')
    $apiRoot = $trimmed

    if ($trimmed -match '/v[0-9]+$') {
        $apiRoot = $trimmed.Substring(0, $trimmed.LastIndexOf('/'))
    }

    return @(
        "$trimmed/v1/openapi/v1.json",
        "$trimmed/openapi/v1.json",
        "$trimmed/openapi.json",
        "$trimmed/openapi.yaml",
        "$trimmed/swagger.json",
        "$trimmed/swagger/v1/swagger.json",
        "$trimmed/v1/swagger.json",
        "$trimmed/openapi?format=json",
        "$apiRoot/v1/openapi/v1.json",
        "$apiRoot/openapi/v1.json",
        "$apiRoot/openapi.json",
        "$apiRoot/openapi.yaml",
        "$apiRoot/swagger.json",
        "$apiRoot/openapi?format=json",
        "${apiRoot}?format=openapi",
        "${apiRoot}?format=swagger",
        "${apiRoot}?format=swagger-link-json"
    )
}

function Get-OpenApiSpec {
    param([string]$BaseUrl)

    $candidates = Get-SpecCandidates -BaseUrl $BaseUrl

    foreach ($url in $candidates) {
        Write-Host "Trying: $url"
        try {
            $response = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec 20
            if (-not $response.Content) { continue }

            $content = $response.Content
            if ($content -match '"openapi"|"swagger"|^openapi:') {
                Write-Host "Found OpenAPI spec at: $url" -ForegroundColor Green
                return @{
                    Url = $url
                    Content = $content
                }
            }
        }
        catch {
            continue
        }
    }

    throw "Could not discover OpenAPI document for base URL: $BaseUrl"
}

function Test-HasViolations {
    param($Payload)

    if (-not $Payload) { return $false }

    $json = ($Payload | ConvertTo-Json -Depth 20)
    $lower = $json.ToLowerInvariant()

    if ($lower -match '"severity"\s*:\s*"(error|critical)"') { return $true }
    if ($lower -match '"level"\s*:\s*"(error|critical)"') { return $true }
    if ($lower -match '"result"\s*:\s*"(failed|fail|error)"') { return $true }
    if ($lower -match '"state"\s*:\s*"(failed|error)"') { return $true }
    if ($lower -match '"totalerrors"\s*:\s*[1-9]') { return $true }
    if ($lower -match '"errors"\s*:\s*[1-9]') { return $true }

    return $false
}

$serviceBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName"
$runId = (Get-Date -Format "yyyyMMddHHmmss")
$apiId = "ruleset-test-$runId"
$versionId = "v1"
$definitionId = "openapi"
$cleanupNeeded = $false
$startUtc = (Get-Date).ToUniversalTime()

try {
    Invoke-AzCli "az account set --subscription `"$SubscriptionId`""

    Write-Host "Ensuring apic-extension is installed..."
    Invoke-AzCli "az extension add --name apic-extension --upgrade --only-show-errors"

    $spec = Get-OpenApiSpec -BaseUrl $ApiBaseUrl

    Write-Host "Creating temporary API entities in API Center..."
    Invoke-AzCli "az apic api create -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --title `"Ruleset Test $runId`" --type rest"
    try {
        Invoke-AzCli "az apic api version create -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --version-id `"$versionId`" --title `"v1`""
    }
    catch {
        Write-Warning "Version create without lifecycle stage failed. Retrying with '--lifecycle-stage testing'."
        Invoke-AzCli "az apic api version create -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --version-id `"$versionId`" --title `"v1`" --lifecycle-stage testing"
    }
    Invoke-AzCli "az apic api definition create -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --version-id `"$versionId`" --definition-id `"$definitionId`" --title `"OpenAPI`""
    $cleanupNeeded = $true

    $escapedSpec = $spec.Content.Replace("'", "''")
    $specification = '{"name":"openapi","version":"3.0.1"}'

    Write-Host "Importing API specification into temporary API definition..."
    Invoke-AzCli "az apic api definition import-specification -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --version-id `"$versionId`" --definition-id `"$definitionId`" --format inline --value '$escapedSpec' --specification '$specification'"

    $definitionBase = "$serviceBase/workspaces/default/apis/$apiId/versions/$versionId/definitions/$definitionId"

    Write-Host "Requesting analysis refresh (best effort)..."
    $null = Try-AzRestJson -Method "POST" -Url "$definitionBase/updateAnalysisState?api-version=$ApiVersion" -Body "{}"

    Write-Host "Polling for API Center analysis results..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $analysisPayload = $null

    while ((Get-Date) -lt $deadline) {
        $analysisPayload = Try-AzRestJson -Method "GET" -Url "$definitionBase/analysisResults?api-version=$ApiVersion"
        if ($analysisPayload -and $analysisPayload.value -and $analysisPayload.value.Count -gt 0) {
            break
        }

        Start-Sleep -Seconds $PollSeconds
    }

    if (-not $analysisPayload -or -not $analysisPayload.value -or $analysisPayload.value.Count -eq 0) {
        Write-Warning "No definition-level analysis results found. Trying analyzer execution feed..."

        $executionsPayload = Try-AzRestJson -Method "GET" -Url "$serviceBase/workspaces/default/analyzerConfigs/$AnalyzerConfigName/analysisExecutions?api-version=$ApiVersion"
        if (-not $executionsPayload -or -not $executionsPayload.value -or $executionsPayload.value.Count -eq 0) {
            throw "Could not retrieve analysis results from API Center (definition analysisResults and analyzer analysisExecutions were empty/unavailable)."
        }

        $recentExecutions = @()
        foreach ($entry in $executionsPayload.value) {
            $raw = $entry | ConvertTo-Json -Depth 12
            if ($raw -match [Regex]::Escape($apiId) -or $raw -match [Regex]::Escape($definitionId)) {
                $recentExecutions += $entry
            }
        }

        if ($recentExecutions.Count -eq 0) {
            $recentExecutions = $executionsPayload.value
        }

        if (Test-HasViolations -Payload $recentExecutions) {
            Write-Host "Analyzer execution payload:" -ForegroundColor Yellow
            $recentExecutions | ConvertTo-Json -Depth 12 | Write-Host
            throw "API Center analyzer execution indicates ruleset violations."
        }

        Write-Host "No failing analyzer execution markers detected." -ForegroundColor Green
        Write-Host "Validation passed for endpoint: $ApiBaseUrl" -ForegroundColor Green
        exit 0
    }

    if (Test-HasViolations -Payload $analysisPayload.value) {
        Write-Host "Definition analysis results:" -ForegroundColor Yellow
        $analysisPayload.value | ConvertTo-Json -Depth 12 | Write-Host
        throw "API Center analysisResults indicate ruleset violations."
    }

    Write-Host "Analysis completed with no failing markers." -ForegroundColor Green
    Write-Host "Discovered spec URL: $($spec.Url)"
    Write-Host "Validation passed for endpoint: $ApiBaseUrl" -ForegroundColor Green
}
finally {
    if ($cleanupNeeded) {
        Write-Host "Cleaning up temporary API Center entities..."
        try {
            Invoke-AzCli "az apic api delete -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --yes"
        }
        catch {
            Write-Warning "Cleanup failed for API '$apiId'. You can delete it manually."
        }
    }
}
