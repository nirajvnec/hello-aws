<#
  Creates (or updates) everything hello-aws needs in AWS, then deploys the app.
  Safe to run again: anything that already exists is reused.

  Usage (from D:\hello-aws):
    pwsh -File .\infra\up.ps1
    pwsh -File .\infra\up.ps1 -BudgetEmail you@example.com   # also create a $10/month budget alert
#>
param(
    [string]$BudgetEmail = ""
)
. "$PSScriptRoot\common.ps1"
$RepoRoot = Split-Path $PSScriptRoot -Parent

Step "Account $AccountId, region $Region"

# ---------------------------------------------------------------- 1. ECR
Step "1/7 ECR repository '$EcrRepository'"
if (Try-Aws ecr describe-repositories --repository-names $EcrRepository) { Ok "already exists" }
else { Run-Aws ecr create-repository --repository-name $EcrRepository | Out-Null; Ok "created" }

# ---------------------------------------------------------------- 2. ECS roles
function Ensure-ServiceRole($name, $servicePrincipal, $policyName) {
    if (Try-Aws iam get-role --role-name $name) { Ok "$name already exists"; return }
    $trust = @{ Version = "2012-10-17"; Statement = @(@{
        Effect = "Allow"; Principal = @{ Service = $servicePrincipal }; Action = "sts:AssumeRole" }) }
    Run-Aws iam create-role --role-name $name --assume-role-policy-document (JsonFile $trust) | Out-Null
    $policyArn = (Run-Aws iam list-policies --scope AWS --query "Policies[?PolicyName=='$policyName'].Arn | [0]" --output text).Trim()
    if (-not $policyArn -or $policyArn -eq "None") { throw "AWS managed policy $policyName not found" }
    Run-Aws iam attach-role-policy --role-name $name --policy-arn $policyArn | Out-Null
    Ok "$name created (with $policyName)"
}
Step "2/7 ECS roles"
Ensure-ServiceRole $ExecRoleName  "ecs-tasks.amazonaws.com" "AmazonECSTaskExecutionRolePolicy"
Ensure-ServiceRole $InfraRoleName "ecs.amazonaws.com"       "AmazonECSInfrastructureRoleforExpressGatewayServices"
$ExecRoleArn  = "arn:aws:iam::${AccountId}:role/$ExecRoleName"
$InfraRoleArn = "arn:aws:iam::${AccountId}:role/$InfraRoleName"

# ---------------------------------------------------------------- 3. GitHub OIDC + deploy role
Step "3/7 GitHub Actions access ($GitHubRepo, branch $GitHubBranch)"
$oidcArn = "arn:aws:iam::${AccountId}:oidc-provider/token.actions.githubusercontent.com"
if (Try-Aws iam get-open-id-connect-provider --open-id-connect-provider-arn $oidcArn) { Ok "OIDC provider already exists" }
else {
    Run-Aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com | Out-Null
    Ok "OIDC provider created"
}
$trust = @{ Version = "2012-10-17"; Statement = @(@{
    Effect = "Allow"; Principal = @{ Federated = $oidcArn }; Action = "sts:AssumeRoleWithWebIdentity"
    Condition = @{ StringEquals = @{
        "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        "token.actions.githubusercontent.com:sub" = "repo:${GitHubRepo}:ref:refs/heads/$GitHubBranch" } } }) }
$deployPolicy = @{ Version = "2012-10-17"; Statement = @(
    @{ Sid = "EcsExpressDeploy"; Effect = "Allow"; Resource = "*"; Action = @(
        "ecs:CreateCluster","ecs:RegisterTaskDefinition","ecs:CreateExpressGatewayService",
        "ecs:UpdateExpressGatewayService","ecs:DescribeExpressGatewayService","ecs:DescribeClusters",
        "ecs:DescribeServices","ecs:UpdateService","ecs:ListServiceDeployments",
        "ecs:DescribeServiceDeployments","ecs:TagResource","ecs:UntagResource") },
    @{ Sid = "PassOnlyTheTwoEcsRoles"; Effect = "Allow"; Action = "iam:PassRole"
       Resource = @($ExecRoleArn, $InfraRoleArn)
       Condition = @{ StringEquals = @{ "iam:PassedToService" = "ecs.amazonaws.com" } } },
    @{ Sid = "PushToThisRepoOnly"; Effect = "Allow"
       Resource = "arn:aws:ecr:${Region}:${AccountId}:repository/$EcrRepository"
       Action = @("ecr:BatchGetImage","ecr:BatchCheckLayerAvailability","ecr:CompleteLayerUpload",
                  "ecr:GetDownloadUrlForLayer","ecr:InitiateLayerUpload","ecr:PutImage","ecr:UploadLayerPart") },
    @{ Sid = "EcrLogin"; Effect = "Allow"; Action = "ecr:GetAuthorizationToken"; Resource = "*" }) }
if (Try-Aws iam get-role --role-name $GitHubRoleName) {
    Run-Aws iam update-assume-role-policy --role-name $GitHubRoleName --policy-document (JsonFile $trust) | Out-Null
    Ok "$GitHubRoleName already exists (trust policy refreshed)"
} else {
    Run-Aws iam create-role --role-name $GitHubRoleName --assume-role-policy-document (JsonFile $trust) | Out-Null
    Ok "$GitHubRoleName created"
}
Run-Aws iam put-role-policy --role-name $GitHubRoleName --policy-name hello-aws-deploy --policy-document (JsonFile $deployPolicy) | Out-Null
Ok "deploy permissions attached"

# ---------------------------------------------------------------- 4. Optional budget
Step "4/7 Budget alert"
if (-not $BudgetEmail) { Info "skipped (pass -BudgetEmail you@example.com to create one)" }
elseif (Try-Aws budgets describe-budget --account-id $AccountId --budget-name monthly-10-usd) { Ok "monthly-10-usd already exists" }
else {
    $budget = @{ BudgetName = "monthly-10-usd"; BudgetLimit = @{ Amount = "10"; Unit = "USD" }; TimeUnit = "MONTHLY"; BudgetType = "COST" }
    $subs   = @(@{ SubscriptionType = "EMAIL"; Address = $BudgetEmail })
    $notes  = @(
        @{ Notification = @{ NotificationType = "ACTUAL";     ComparisonOperator = "GREATER_THAN"; Threshold = 80;  ThresholdType = "PERCENTAGE" }; Subscribers = $subs },
        @{ Notification = @{ NotificationType = "FORECASTED"; ComparisonOperator = "GREATER_THAN"; Threshold = 100; ThresholdType = "PERCENTAGE" }; Subscribers = $subs })
    Run-Aws budgets create-budget --account-id $AccountId --budget (JsonFile $budget) --notifications-with-subscribers (JsonFile $notes) | Out-Null
    Ok "monthly-10-usd created (emails $BudgetEmail)"
}

# ---------------------------------------------------------------- 5. Build and push image
Step "5/7 Build and push image"
Push-Location $RepoRoot
try {
    $tag = (& git rev-parse --short HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $tag) { $tag = "manual-" + (Get-Date -Format "yyyyMMddHHmmss") }
    $tag = $tag.Trim()
    $image = "$Registry/${EcrRepository}:$tag"
    (Run-Aws ecr get-login-password) | docker login --username AWS --password-stdin $Registry | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker login failed - is Docker Desktop running?" }
    docker build --build-arg APP_VERSION=$tag -t $image .
    if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
    docker push $image
    if ($LASTEXITCODE -ne 0) { throw "docker push failed" }
    Ok "pushed $image"
} finally { Pop-Location }

# ---------------------------------------------------------------- 6. Create or update the Express service
Step "6/7 Express service '$ServiceName' in cluster '$Cluster'"
Run-Aws ecs create-cluster --cluster-name $Cluster | Out-Null   # no-op if it already exists
$container = @{ image = $image; containerPort = $ContainerPort }
$scaling   = @{ minTaskCount = $MinTasks; maxTaskCount = $MaxTasks; autoScalingMetric = "AVERAGE_CPU"; autoScalingTargetValue = 60 }
$status    = Try-Aws ecs describe-express-gateway-service --service-arn $ServiceArn --query "service.status.statusCode" --output text
if ($status -and $status.Trim() -eq "ACTIVE") {
    $update = @{ serviceArn = $ServiceArn; executionRoleArn = $ExecRoleArn; healthCheckPath = $HealthCheckPath
                 cpu = $Cpu; memory = $Memory; primaryContainer = $container; scalingTarget = $scaling }
    Run-Aws ecs update-express-gateway-service --cli-input-json (JsonFile $update) | Out-Null
    Ok "update started (rolling deployment, no downtime)"
} else {
    $create = @{ serviceName = $ServiceName; cluster = $Cluster; executionRoleArn = $ExecRoleArn
                 infrastructureRoleArn = $InfraRoleArn; healthCheckPath = $HealthCheckPath
                 cpu = $Cpu; memory = $Memory; primaryContainer = $container; scalingTarget = $scaling }
    Run-Aws ecs create-express-gateway-service --cli-input-json (JsonFile $create) | Out-Null
    Ok "create started (load balancer, certificate and networking are set up automatically)"
}

# ---------------------------------------------------------------- 7. Wait until healthy
Step "7/7 Waiting for the service to become stable (usually 5-10 minutes)..."
Run-Aws ecs wait services-stable --cluster $Cluster --services $ServiceName
$url = (Run-Aws ecs describe-express-gateway-service --service-arn $ServiceArn --query "service.activeConfigurations[0].ingressPaths[0].endpoint" --output text).Trim()
if ($url -and $url -notmatch "^https?://") { $url = "https://$url" }
Ok "stable"
Write-Host "`nDone. App URL: $url" -ForegroundColor Green
Write-Host "If it shows 503 at first, wait 1-2 minutes and refresh."
