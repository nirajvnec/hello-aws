# Shared settings for up.ps1 and down.ps1. Change values here, not in the scripts.
$Region          = "ap-south-1"
$Cluster         = "default"
$ServiceName     = "hello-aws"
$EcrRepository   = "hello-aws"
$GitHubRepo      = "nirajvnec/hello-aws"   # owner/repo allowed to deploy via GitHub Actions
$GitHubBranch    = "main"

# Container and size settings (smallest size, max 2 tasks)
$ContainerPort   = 8080
$HealthCheckPath = "/health"
$Cpu             = "256"    # 0.25 vCPU
$Memory          = "512"    # 0.5 GB
$MinTasks        = 1
$MaxTasks        = 2

# IAM role names
$ExecRoleName    = "ecsTaskExecutionRole"
$InfraRoleName   = "ecsInfrastructureRoleForExpressServices"
$GitHubRoleName  = "github-hello-aws-deploy"
