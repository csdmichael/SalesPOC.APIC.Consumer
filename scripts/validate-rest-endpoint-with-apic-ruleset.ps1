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
    [string]$VersionLifecycleStage = "design",

    [Parameter(Mandatory = $false)]
    [string]$ApiVersion = "2024-06-01-preview",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 240,

    [Parameter(Mandatory = $false)]
    [int]$PollSeconds = 10,

    [Parameter(Mandatory = $false)]
    [bool]$FailOnViolations = $true,

    [Parameter(Mandatory = $false)]
    [string]$ReportPath = "artifacts/apic-analysis-report.json"
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

function Write-ValidationReport {
    param(
        [hashtable]$Report,
        [string]$JsonPath
    )

    $resolvedJsonPath = $JsonPath
    if (-not [System.IO.Path]::IsPathRooted($resolvedJsonPath)) {
        $resolvedJsonPath = Join-Path (Get-Location) $resolvedJsonPath
    }

    $jsonDir = Split-Path -Path $resolvedJsonPath -Parent
    if ($jsonDir -and -not (Test-Path -Path $jsonDir)) {
        New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null
    }

    $payloadJson = $Report.payload | ConvertTo-Json -Depth 25
    $Report | ConvertTo-Json -Depth 25 | Set-Content -Path $resolvedJsonPath -Encoding utf8

    $markdownPath = [System.IO.Path]::ChangeExtension($resolvedJsonPath, ".md")
    $markdownLines = @(
        "# API Center Ruleset Validation Report",
        "",
        "- Status: **$($Report.status)**",
        "- Has Violations: **$($Report.hasViolations)**",
        "- Result Source: **$($Report.resultSource)**",
        "- API Base URL: $($Report.apiBaseUrl)",
        "- Discovered Spec URL: $($Report.discoveredSpecUrl)",
        "- Analyzer Config: $($Report.analyzerConfigName)",
        "- Started UTC: $($Report.startedUtc)",
        "- Finished UTC: $($Report.finishedUtc)",
        "- Message: $($Report.message)",
        "",
        "## Payload",
        "",
        '```json',
        $payloadJson,
        '```'
    )
    $markdownLines -join [Environment]::NewLine | Set-Content -Path $markdownPath -Encoding utf8

    if ($env:GITHUB_STEP_SUMMARY) {
        $summaryLines = @(
            "## API Center Ruleset Validation",
            "",
            "- Status: **$($Report.status)**",
            "- Has Violations: **$($Report.hasViolations)**",
            "- Source: **$($Report.resultSource)**",
            "- Message: $($Report.message)",
            "- Report JSON: $resolvedJsonPath",
            "- Report Markdown: $markdownPath",
            ""
        )
        Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($summaryLines -join [Environment]::NewLine)
    }

    Write-Host "Validation report (json): $resolvedJsonPath"
    Write-Host "Validation report (md):   $markdownPath"
}

$serviceBase = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.ApiCenter/services/$ServiceName"
$runId = (Get-Date -Format "yyyyMMddHHmmss")
$apiId = "ruleset-test-$runId"
$versionId = (Get-Date -Format "yyyy-MM-dd")
$definitionId = "openapi"
$cleanupNeeded = $false
$startUtc = (Get-Date).ToUniversalTime()
$exitCode = 0
$report = @{
    runId = $runId
    apiId = $apiId
    versionId = $versionId
    definitionId = $definitionId
    subscriptionId = $SubscriptionId
    resourceGroup = $ResourceGroup
    serviceName = $ServiceName
    apiBaseUrl = $ApiBaseUrl
    analyzerConfigName = $AnalyzerConfigName
    status = "unknown"
    hasViolations = $false
    resultSource = "none"
    discoveredSpecUrl = $null
    message = "Validation did not complete."
    startedUtc = $startUtc.ToString("o")
    finishedUtc = $null
    payload = $null
}

try {
    Invoke-AzCli "az account set --subscription `"$SubscriptionId`""

    Write-Host "Ensuring apic-extension is installed..."
    Invoke-AzCli "az extension add --name apic-extension --upgrade --only-show-errors"

    $spec = Get-OpenApiSpec -BaseUrl $ApiBaseUrl
    $report.discoveredSpecUrl = $spec.Url

    Write-Host "Creating temporary API entities in API Center..."
    Invoke-AzCli "az apic api create -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --title `"Ruleset Test $runId`" --type rest"
    Invoke-AzCli "az apic api version create -g `"$ResourceGroup`" -n `"$ServiceName`" --api-id `"$apiId`" --version-id `"$versionId`" --title `"$versionId`" --lifecycle-stage `"$VersionLifecycleStage`""
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

        $hasViolations = Test-HasViolations -Payload $recentExecutions
        $report.payload = $recentExecutions
        $report.resultSource = "analyzerExecutions"
        $report.hasViolations = $hasViolations

        if ($hasViolations) {
            Write-Host "Analyzer execution payload:" -ForegroundColor Yellow
            $recentExecutions | ConvertTo-Json -Depth 12 | Write-Host
            $report.status = "violations"
            $report.message = "API Center analyzer execution indicates ruleset violations."
            if ($FailOnViolations) {
                $exitCode = 1
            }
            else {
                Write-Warning "Ruleset violations found, but FailOnViolations is false. Workflow will continue."
            }
        }
        else {
            Write-Host "No failing analyzer execution markers detected." -ForegroundColor Green
            Write-Host "Validation passed for endpoint: $ApiBaseUrl" -ForegroundColor Green
            $report.status = "success"
            $report.message = "No failing analyzer execution markers detected."
        }
    }
    else {
        $hasViolations = Test-HasViolations -Payload $analysisPayload.value
        $report.payload = $analysisPayload.value
        $report.resultSource = "definitionAnalysisResults"
        $report.hasViolations = $hasViolations

        if ($hasViolations) {
            Write-Host "Definition analysis results:" -ForegroundColor Yellow
            $analysisPayload.value | ConvertTo-Json -Depth 12 | Write-Host
            $report.status = "violations"
            $report.message = "API Center analysisResults indicate ruleset violations."
            if ($FailOnViolations) {
                $exitCode = 1
            }
            else {
                Write-Warning "Ruleset violations found, but FailOnViolations is false. Workflow will continue."
            }
        }
        else {
            Write-Host "Analysis completed with no failing markers." -ForegroundColor Green
            Write-Host "Discovered spec URL: $($spec.Url)"
            Write-Host "Validation passed for endpoint: $ApiBaseUrl" -ForegroundColor Green
            $report.status = "success"
            $report.message = "Analysis completed with no failing markers."
        }
    }
}
catch {
    $report.status = "error"
    $report.message = $_.Exception.Message
    $report.resultSource = if ($report.resultSource -eq "none") { "scriptExecution" } else { $report.resultSource }
    if (-not $report.payload) {
        $report.payload = @{
            error = $_.Exception.Message
        }
    }
    $exitCode = 1
    Write-Error $report.message
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

    $report.finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
    Write-ValidationReport -Report $report -JsonPath $ReportPath
}

if ($exitCode -ne 0) {
    exit $exitCode
}
