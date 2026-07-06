# One-shot PAT rotation: paste the new codenzia-private token once, push it
# to every repo where it's used. Sets CODENZIA_PAT on 34 repos + GH_PACKAGES_TOKEN
# on Codenzia/satis.

$repos = @(
    'task-off-workspace','codenziaWebsite','BuyMyProducts','tajir-express',
    'studio','aqarkom','toolenza','serveeta','souqhadaya','gamephoria',
    'my-own-store-website','task-off','wikibanknotes','snapcar','asset-flow',
    'plugins-demo','filament-panel-base-dev','swiftdelivery','DropFlow',
    'filament-diagrammer-dev','laravel-feedback-dev','RubixSmartNavigator-V2',
    'filament-workflow-dev','filament-gantt-dev','filament-system-tools-dev',
    'filament-gantt-lite-dev','filament-comments-dev','filament-carousel-dev',
    'project-essentials-dev','LaraFilCommerce','browser-console-dev',
    'LaraPress','filament-media-dev','LarafilPos'
)

$tok = Read-Host "Paste the NEW codenzia-private PAT value" -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($tok))

Write-Host ""
Write-Host "Setting GH_PACKAGES_TOKEN on Codenzia/satis..."
gh secret set GH_PACKAGES_TOKEN --repo Codenzia/satis --body $plain

Write-Host ""
Write-Host "Setting CODENZIA_PAT on $($repos.Count) repos..."
foreach ($r in $repos) {
    gh secret set CODENZIA_PAT --repo "Codenzia/$r" --body $plain
    Write-Host "  Codenzia/$r"
}

Write-Host ""
Write-Host "Done. The OLD token value is now invalid (you regenerated it)."
Write-Host "Remember to update any local checkouts that use it via 'composer config -g'."
