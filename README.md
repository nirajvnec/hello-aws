# hello-aws

Minimal ASP.NET Core (.NET 10) API deployed to **Amazon ECS (Express Mode, Fargate)** via **GitHub Actions**.

- `GET /` → hello message with version (git commit SHA) and container name
- `GET /health` → `Healthy` (used by the load balancer health check)

## Flow

```
git push main → GitHub Actions → dotnet build → docker build → push to ECR → new ECS task definition → rolling deploy
```

## Run locally

```bash
dotnet run --project HelloAws          # or:
docker build -t hello-aws . && docker run -p 8080:8080 hello-aws
```

## One-time AWS setup (region ap-south-1)

### 1. Create the ECR repository
Console → **ECR** → Create repository → name `hello-aws`. Or:
```bash
aws ecr create-repository --repository-name hello-aws --region ap-south-1
```

### 2. Push the first image manually
Express Mode needs an image to exist before it can create the service.
```bash
ACCOUNT=070638634270
REG=$ACCOUNT.dkr.ecr.ap-south-1.amazonaws.com
aws ecr get-login-password --region ap-south-1 | docker login --username AWS --password-stdin $REG
docker build -t $REG/hello-aws:v1 .
docker push $REG/hello-aws:v1
```

### 3. Create the service with ECS Express Mode
Console → **ECS → Express Mode** → Browse ECR images → `hello-aws:v1`.
Under *Additional configurations*: container port **8080**, health check path **/health**.
Click **Create**, wait until it's running, then open the URL it gives you.
Note the **cluster name**, **service name** and **container name** it created.

> Cost: this starts billing (Fargate task + load balancer, roughly $20–40/month). Delete the service when done.

### 4. Let GitHub deploy without access keys (OIDC)
1. IAM → Identity providers → Add provider → **OpenID Connect**
   - URL `https://token.actions.githubusercontent.com`, audience `sts.amazonaws.com`
2. IAM → Roles → Create role → **Web identity** → that provider
   - Restrict to your repo: `repo:<github-user>/hello-aws:ref:refs/heads/main`
   - Permissions: `AmazonEC2ContainerRegistryPowerUser` plus an inline policy allowing
     `ecs:DescribeServices`, `ecs:DescribeTaskDefinition`, `ecs:RegisterTaskDefinition`,
     `ecs:UpdateService`, and `iam:PassRole` on the task execution role
     (`ecsTaskExecutionRole`).
   - Name it e.g. `github-hello-aws-deploy` and copy its ARN.

### 5. Configure the GitHub repo
Settings → Secrets and variables → Actions:

| Type | Name | Example |
|---|---|---|
| Secret | `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::070638634270:role/github-hello-aws-deploy` |
| Variable | `AWS_REGION` | `ap-south-1` |
| Variable | `ECR_REPOSITORY` | `hello-aws` |
| Variable | `ECS_CLUSTER` | from step 3 |
| Variable | `ECS_SERVICE` | from step 3 |
| Variable | `CONTAINER_NAME` | from step 3 |

### 6. Deploy
Change the message in `Program.cs`, commit, push to `main`. The Actions tab shows the run;
when it's green, refresh the service URL and the `version` field shows the new commit SHA.

## Clean up
Delete the ECS Express service (removes load balancer and tasks), then the ECR repository.
