# Helpers shared by up.ps1 and down.ps1
$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""
if (-not $env:AWS_PROFILE) { $env:AWS_PROFILE = "hello-aws" }
. "$PSScriptRoot\config.ps1"

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "   $text" -ForegroundColor Green }
function Info($text) { Write-Host "   $text" }

# Run an aws command; stop the script if it fails.
function Run-Aws {
    $out = & aws.exe @args --region $Region
    if ($LASTEXITCODE -ne 0) { throw "aws $($args -join ' ') failed (exit $LASTEXITCODE)" }
    return $out
}

# Run an aws command that is allowed to fail (used for "does it exist?" checks).
function Try-Aws {
    $out = & aws.exe @args --region $Region 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

# Write JSON to a temp file and return a file:// path the AWS CLI can read.
function JsonFile($object) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("hello-aws-" + [guid]::NewGuid() + ".json")
    $object | ConvertTo-Json -Depth 20 | Set-Content -Path $path -Encoding utf8
    return "file://$path"
}

$AccountId  = (Run-Aws sts get-caller-identity --query Account --output text).Trim()
$ServiceArn = "arn:aws:ecs:${Region}:${AccountId}:service/$Cluster/$ServiceName"
$Registry   = "$AccountId.dkr.ecr.$Region.amazonaws.com"
