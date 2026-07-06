# Readiness check for all 14 Codenzia apps before bulk-deploying.
# For each repo it reports:
#   - deploy.yml present on remote main?
#   - local uncommitted changes?
#   - local commits not yet pushed to main?
#   - last deploy run status (if any)

$repos = @(
    @{name='BuyMyProducts';        local='BuyMyProducts'},
    @{name='LaraFilCommerce';      local='LaraFilCommerce'},
    @{name='gamephoria';           local='gamephoria'},
    @{name='LarafilPos';           local='LarafilPos'},
    @{name='LaraPress';            local='LaraPress'},
    @{name='plugins-demo';         local='plugins-demo'},
    @{name='asset-flow';           local='asset-flow'},
    @{name='swiftdelivery';        local='swiftdelivery'},
    @{name='snapcar';              local='snapcar'},
    @{name='task-off';             local='task-off'},
    @{name='DropFlow';             local='DropFlow'},
    @{name='tajir-express';        local='tajir-express'},
    @{name='wikiBankNotes';        local='wikiBankNotes'},
    @{name='my-own-store-website'; local='my-own-store-website'}
)

$ghRoot = 'C:\mh2\Projects\Codenzia\GitHub'

"{0,-22} {1,-12} {2,-12} {3,-12} {4}" -f 'repo','deploy.yml','local-clean','pushed','last deploy'
"{0,-22} {1,-12} {2,-12} {3,-12} {4}" -f '----','----------','-----------','------','-----------'

foreach ($r in $repos) {
    $name = $r.name
    $dir  = Join-Path $ghRoot $r.local

    $hasWorkflow = (gh api "repos/Codenzia/$name/contents/.github/workflows/deploy.yml?ref=main" 2>$null) ? 'YES' : 'NO'

    $clean = 'no-checkout'
    $pushed = 'no-checkout'
    if (Test-Path $dir) {
        Push-Location $dir
        try {
            $dirty = git status --porcelain 2>$null
            $clean = if ([string]::IsNullOrWhiteSpace($dirty)) { 'CLEAN' } else { 'DIRTY' }

            $ahead = (git rev-list --count "origin/main..HEAD" 2>$null) -as [int]
            $pushed = if ($ahead -eq 0) { 'YES' } else { "BEHIND($ahead)" }
        } finally { Pop-Location }
    }

    $lastRun = (gh run list --repo "Codenzia/$name" --workflow deploy.yml --limit 1 --json conclusion,createdAt 2>$null | ConvertFrom-Json)
    $lastDeploy = if ($lastRun) { "$($lastRun.conclusion ?? 'in_progress') ($([datetime]$lastRun.createdAt))" } else { 'never' }

    "{0,-22} {1,-12} {2,-12} {3,-12} {4}" -f $name, $hasWorkflow, $clean, $pushed, $lastDeploy
}
