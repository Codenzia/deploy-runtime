# Seeds the 9 secrets needed on Codenzia/task-off-workspace for VPS deploys.
# Run once.

$repo = 'Codenzia/task-off-workspace'

$pat        = Read-Host "Paste your Codenzia GitHub PAT (CODENZIA_PAT)"
$keyPath    = Read-Host "Path to local VPS deploy private key (e.g. C:\Users\mh2x\.ssh\codenzia_vps_deploy)"

if (-not (Test-Path $keyPath)) {
    Write-Error "Key file not found: $keyPath"
    exit 1
}
$keyContent = Get-Content $keyPath -Raw

# Known fixed values
gh secret set CODENZIA_PAT      --repo $repo --body $pat
gh secret set VPS_HOSTNAME      --repo $repo --body '31.97.78.215'
gh secret set VPS_PORT          --repo $repo --body '22'
gh secret set VPS_SSH_KEY       --repo $repo --body $keyContent

# DB passwords from the create-sites run
gh secret set TASKOFF_DB_PW     --repo $repo --body 'ReVOFO4fCgZa7mVGuys7VAHK'
gh secret set TASKOFFCZ_DB_PW   --repo $repo --body 'IrL74foCSN69Q5JDeJw4sat5'
gh secret set TASKOFFLITE_DB_PW --repo $repo --body 'mn7wB0lCVV0FRHjXCCTVOWQE'
gh secret set TASKOFFSTD_DB_PW  --repo $repo --body 'RZKz4dXxk2TwvdfyIxHZF0LP'
gh secret set TASKOFFPRO_DB_PW  --repo $repo --body 'b23QsaecwqoPcMCTsFjJOb7I'

Write-Host ""
Write-Host "All 9 secrets set on $repo. Verify:"
gh secret list --repo $repo
