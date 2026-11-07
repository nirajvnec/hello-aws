<#
  Deletes the hello-aws resources that cost money, so nothing keeps billing.

  Usage (from D:\hello-aws):
    pwsh -File .\infra\down.ps1          # service (load balancer, tasks, etc.), ECR images, logs
    pwsh -File .\infra\down.ps1 -All     # everything: also IAM roles, GitHub OIDC provider,
                                         # the 'default' cluster and the monthly-10-usd budget

  Without -All, the free items (IAM roles, empty cluster, budget) are kept for next time.
  Never touched: budgets you created yourself (e.g. "My Zero-Spend Budget").
#>
param(
    [switch]$All
)
. "$PSScriptRoot\common.ps1"

Step "Account $AccountId, region $Region"
$what = if ($All) { "ALL hello-aws resources (service, images, logs, IAM roles, OIDC provider, cluster, budget)" } else { "the '$ServiceName' service, its images and logs" }
$answer = Read-Host "This permanently deletes $what. Type 'yes' to continue"
if ($answer -ne "yes") { Write-Host "Cancelled. Nothing was deleted."; exit 0 }

# ---------------------------------------------------------------- 1. Express service
Step "1/4 Express service '$ServiceName'"
$status = Try-Aws ecs describe-express-gateway-service --service-arn $ServiceArn --query "service.status.statusCode" --output text
if ($status -and $status.Trim() -eq "ACTIVE") {
    $logGroup = Try-Aws ecs describe-express-gateway-service --service-arn $ServiceArn --query "service.activeConfigurations[0].primaryContainer.awsLogsConfiguration.logGroup" --output text
    Run-Aws ecs delete-express-gateway-service --service-arn $ServiceArn | Out-Null
    Info "delete started; waiting until it is gone (a few minutes)..."
    Run-Aws ecs wait services-inactive --cluster $Cluster --services $ServiceName
    Ok "deleted (load balancer, listener, target groups, security groups, certificate, scaling, alarm)"
} else {
    $logGroup = $null
    Ok "not found or already deleted"
}

# ---------------------------------------------------------------- 2. Logs
Step "2/4 CloudWatch logs"
if ($logGroup -and $logGroup.Trim() -and $logGroup.Trim() -ne "None") {
    $logGroup = $logGroup.Trim()
    if (Try-Aws logs delete-log-group --log-group-name $logGroup) { Ok "deleted $logGroup" } else { Ok "$logGroup already gone" }
} else { Info "no log group recorded, skipped" }

# ---------------------------------------------------------------- 3. ECR
Step "3/4 ECR repository '$EcrRepository' (and all its images)"
if (Try-Aws ecr describe-repositories --repository-names $EcrRepository) {
    Run-Aws ecr delete-repository --repository-name $EcrRepository --force | Out-Null
    Ok "deleted"
} else { Ok "not found or already deleted" }

# ---------------------------------------------------------------- 4. IAM (only with -All)
Step "4/4 IAM roles"
if (-not $All) {
    Info "kept (free; re-used by up.ps1). Use -All to delete them too."
} else {
    function Remove-Role($name) {
        if (-not (Try-Aws iam get-role --role-name $name)) { Ok "$name not found"; return }
        foreach ($p in (Run-Aws iam list-role-policies --role-name $name --query "PolicyNames" --output text) -split "\s+") {
            if ($p) { Run-Aws iam delete-role-policy --role-name $name --policy-name $p | Out-Null }
        }
        foreach ($p in (Run-Aws iam list-attached-role-policies --role-name $name --query "AttachedPolicies[].PolicyArn" --output text) -split "\s+") {
            if ($p) { Run-Aws iam detach-role-policy --role-name $name --policy-arn $p | Out-Null }
        }
        Run-Aws iam delete-role --role-name $name | Out-Null
        Ok "$name deleted"
    }
    Remove-Role $GitHubRoleName
    Remove-Role $ExecRoleName
    Remove-Role $InfraRoleName
    $oidcArn = "arn:aws:iam::${AccountId}:oidc-provider/token.actions.githubusercontent.com"
    if (Try-Aws iam get-open-id-connect-provider --open-id-connect-provider-arn $oidcArn) {
        Run-Aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $oidcArn | Out-Null
        Ok "GitHub OIDC provider deleted"
    } else { Ok "GitHub OIDC provider not found" }

    Step "Cluster '$Cluster'"
    $clusterStatus = Try-Aws ecs describe-clusters --clusters $Cluster --query "clusters[0].status" --output text
    if ($clusterStatus -and $clusterStatus.Trim() -eq "ACTIVE") {
        if (Try-Aws ecs delete-cluster --cluster $Cluster) { Ok "deleted" }
        else { Info "could not delete yet (AWS may still be cleaning up the service). Re-run with -All in a few minutes." }
    } else { Ok "not found or already deleted" }

    Step "Budget 'monthly-10-usd'"
    if (Try-Aws budgets describe-budget --account-id $AccountId --budget-name monthly-10-usd) {
        Run-Aws budgets delete-budget --account-id $AccountId --budget-name monthly-10-usd | Out-Null
        Ok "deleted"
    } else { Ok "not found or already deleted" }
}

Write-Host "`nDone. Nothing billable from hello-aws is left running." -ForegroundColor Green
Write-Host "Recreate everything later with: pwsh -File .\infra\up.ps1"
