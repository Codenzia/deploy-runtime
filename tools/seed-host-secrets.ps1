# Sets HOST_HOSTNAME, HOST_PORT, HOST_USER, HOST_SSH_KEY on the 4 new repos that are missing them.
# Run once. You'll be prompted for the SSH private key path (a file on disk — easiest way to
# pass a multi-line value).

$repos = 'DropFlow','tajir-express','my-own-store-website','CodenziaWebsite'

$hostname = Read-Host "HOST_HOSTNAME (e.g. 76.13.73.180)"
$port     = Read-Host "HOST_PORT (e.g. 65002)"
$user     = Read-Host "HOST_USER (e.g. u396571706)"
$keyPath  = Read-Host "Path to your SSH private key file (e.g. C:\Users\mh2x\.ssh\hostinger_id_rsa)"

if (-not (Test-Path $keyPath)) {
    Write-Error "Key file not found: $keyPath"
    exit 1
}

$keyContent = Get-Content $keyPath -Raw

foreach ($r in $repos) {
    Write-Host "[$r] setting 4 host secrets..."
    gh secret set HOST_HOSTNAME --repo "Codenzia/$r" --body $hostname
    gh secret set HOST_PORT     --repo "Codenzia/$r" --body $port
    gh secret set HOST_USER     --repo "Codenzia/$r" --body $user
    gh secret set HOST_SSH_KEY  --repo "Codenzia/$r" --body $keyContent
}

Write-Host ""
Write-Host "Done. Re-trigger deploys on the 4 repos."
