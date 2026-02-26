# SalesPOC.APIC.Consumer

Validates a live REST endpoint against an Azure API Center deployed analyzer/ruleset (for example, a Spectral OpenAPI ruleset).

The project provides:
- A PowerShell validation script: `scripts/validate-rest-endpoint-with-apic-ruleset.ps1`
- A GitHub Actions workflow to run the validation in CI: `.github/workflows/validate-rest-endpoint-with-apic-ruleset.yml`

Related API Center ruleset deployment repository:
- https://github.com/csdmichael/SalesPOC.APIC

## What this validation does

1. Discovers an OpenAPI document from the target API base URL using common OpenAPI/Swagger endpoint patterns.
2. Creates temporary API entities in Azure API Center.
3. Imports the discovered OpenAPI specification.
4. Triggers/polls API Center analysis results for the configured analyzer.
5. Detects and records error/critical violations in the report.
6. Cleans up the temporary API entities.

## Prerequisites

- Azure subscription with access to:
  - API Center resource (`Microsoft.ApiCenter/services`)
  - Analyzer config already deployed (default: `spectral-openapi`)
- PowerShell 7+ (`pwsh` recommended)
- Azure CLI installed and authenticated (`az login`)
- API Center CLI extension (the script installs/upgrades `apic-extension` automatically)

## Run locally

From repository root:

```powershell
./scripts/validate-rest-endpoint-with-apic-ruleset.ps1 \
  -SubscriptionId "<subscription-id>" \
  -ResourceGroup "<resource-group>" \
  -ServiceName "<api-center-service-name>" \
  -ApiBaseUrl "https://<gateway>/<api-base-path>" \
  -AnalyzerConfigName "spectral-openapi"
```

### Parameters

Required:
- `SubscriptionId`
- `ResourceGroup`
- `ServiceName`

Optional:
- `ApiBaseUrl` (default: `https://apim-poc-my.azure-api.net/salesapi`)
- `AnalyzerConfigName` (default: `spectral-openapi`)
- `VersionLifecycleStage` (default: `design`)
- `ApiVersion` (default: `2024-06-01-preview`)
- `TimeoutSeconds` (default: `240`)
- `PollSeconds` (default: `10`)
- `FailOnViolations` (default: `true`)
- `ReportPath` (default: `artifacts/apic-analysis-report.json`)

## Validation report output

The script always writes a validation report, even when violations are found.

Generated files:
- JSON report: `artifacts/apic-analysis-report.json`
- Markdown report: `artifacts/apic-analysis-report.md`

Report fields include:
- `status`: `success`, `violations`, or `error`
- `hasViolations`: `true`/`false`
- `resultSource`: `definitionAnalysisResults`, `analyzerExecutions`, or `scriptExecution`
- `message`: human-readable summary
- `payload`: raw analysis payload returned by API Center

Behavior:
- `FailOnViolations=true`: violations return non-zero exit code (fails workflow step)
- `FailOnViolations=false`: violations are reported but workflow continues

In GitHub Actions, this workflow runs with `FailOnViolations=false`, uploads the `artifacts/` folder as an artifact named `apic-analysis-report`, and appends the Markdown report to the job summary page.

## Run in GitHub Actions

Workflow: `.github/workflows/validate-rest-endpoint-with-apic-ruleset.yml`

Triggers:
- Manual: `workflow_dispatch` (supports `api_url` and `analyzer_config_name` inputs)
- Push to `main` when workflow or script changes

### Required repository secrets

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`
- `AZURE_RESOURCE_GROUP`
- `API_CENTER_SERVICE_NAME`

The workflow uses OIDC with `azure/login@v2` and then runs the PowerShell script.

## Expected outcome

- Success: script prints a pass message, writes report files, and returns exit code `0`.
- Violations: script writes report files; in this workflow configuration the job continues and still publishes the report.
- Error: script writes report files and returns non-zero exit code.

## Troubleshooting

- **OpenAPI spec not found**: Ensure your API exposes an OpenAPI/Swagger document at a discoverable route (for example `/openapi.json`, `/swagger.json`, `/openapi/v1.json`).
- **No analysis results**: Verify the analyzer config exists in API Center and has permissions/access to run against imported definitions.
- **Authorization errors**: Confirm the identity running the script has required API Center permissions and correct subscription/resource group values.
- **Timeouts**: Increase `-TimeoutSeconds` for slower analysis completion.

### GitHub OIDC login errors (AADSTS700213)

If GitHub Actions fails during `azure/login` with a message like `AADSTS700213`, the Entra federated credential does not match the workflow token claims.

Use these exact values in the app registration federated credential:
- Issuer: `https://token.actions.githubusercontent.com`
- Audience: `api://AzureADTokenExchange`
- Subject (example for main branch): `repo:csdmichael/SalesPOC.APIC.Consumer:ref:refs/heads/main`

Also verify workflow secrets point to the same app registration where this federated credential exists:
- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

### "Resource '<guid>' does not exist" during identity setup

This usually means a wrong identifier type is being used (for example, passing a client ID where an object ID is required), or the object is in a different tenant.

Quick checks:

```bash
# Verify tenant context
az account show --query "{tenantId:tenantId, subscriptionId:id}" -o table

# Try to resolve as application by appId (client ID)
az ad app list --filter "appId eq '<guid>'" --query "[].{displayName:displayName,id:id,appId:appId}" -o table

# Try to resolve as service principal by appId
az ad sp list --filter "appId eq '<guid>'" --query "[].{displayName:displayName,id:id,appId:appId}" -o table
```

Important:
- `az ad app federated-credential create --id` expects the **application object ID** (`id`), not the client ID (`appId`).
- If you only have client ID, look up the app first and then use its object ID.

## Notes

- Temporary APIs are created with names like `ruleset-test-<timestamp>` and cleaned up in a `finally` block.
- Temporary API versions use a date-based ID (for example `2026-02-26`) for API Center compatibility.
- If cleanup fails, the script prints a warning so the API can be removed manually.
