# Seeds the 3 VPS secrets (VPS_HOSTNAME, VPS_PORT, VPS_SSH_KEY) on any repo.
# Reuses the codenzia_vps_deploy key already on disk at C:\Users\mh2x\.ssh\
# Pass the repo name as an argument, or list repos at the top to batch.

param(
    [Parameter(Mandatory=$true)]
    [string[]]$Repos
)

$keyPath = 'C:\Users\mh2x\.ssh\codenzia_vps_deploy'
if (-not (Test-Path $keyPath)) {
    Write-Error "Key file not found: $keyPath — copy it from VPS first."
    exit 1
}
$keyContent = Get-Content $keyPath -Raw

foreach ($repo in $Repos) {
    Write-Host "[$repo] setting VPS secrets..."
    gh secret set VPS_HOSTNAME --repo $repo --body '31.97.78.215'
    gh secret set VPS_PORT     --repo $repo --body '22'
    gh secret set VPS_SSH_KEY  --repo $repo --body $keyContent
}
