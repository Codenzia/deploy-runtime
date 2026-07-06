# Fires off the GitHub Actions deploy workflow on all 14 Codenzia apps with fresh=true + DemoSeeder.
# Prints a watch URL for each so you can monitor.

$repos = @(
    'BuyMyProducts','LaraFilCommerce','gamephoria','LarafilPos','LaraPress',
    'plugins-demo','asset-flow','swiftdelivery','snapcar','task-off',
    'DropFlow','tajir-express','wikiBankNotes','my-own-store-website'
)

foreach ($r in $repos) {
    Write-Host "[$r] triggering deploy..."
    gh workflow run deploy.yml --repo "Codenzia/$r" -f fresh=true -f seeder=DemoSeeder 2>&1 | Out-Host
}

Write-Host ""
Write-Host "All triggered. Watch them at:"
foreach ($r in $repos) {
    Write-Host "  https://github.com/Codenzia/$r/actions"
}
