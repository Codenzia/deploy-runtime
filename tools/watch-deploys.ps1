# Polls the in-flight deploy run on each of the 14 repos and shows status.
# Re-run any time to refresh.

$repos = @(
    'BuyMyProducts','LaraFilCommerce','gamephoria','LarafilPos','LaraPress',
    'plugins-demo','asset-flow','swiftdelivery','snapcar','task-off',
    'DropFlow','tajir-express','wikiBankNotes','my-own-store-website'
)

"{0,-22} {1,-12} {2,-12} {3}" -f 'repo','status','conclusion','url'
"{0,-22} {1,-12} {2,-12} {3}" -f '----','------','----------','---'

foreach ($r in $repos) {
    $run = (gh run list --repo "Codenzia/$r" --workflow deploy.yml --limit 1 --json status,conclusion,url,createdAt 2>$null | ConvertFrom-Json)
    if ($run) {
        "{0,-22} {1,-12} {2,-12} {3}" -f $r, $run.status, ($run.conclusion ?? '-'), $run.url
    } else {
        "{0,-22} no runs" -f $r
    }
}
