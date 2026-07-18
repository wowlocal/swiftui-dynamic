#!/bin/zsh
# Vendor PACKAGE DEPENDENCIES into corpus checkouts (External is a
# gitignored local cache — this script makes the environment reproducible).
# Natively SPM fetches these; the interpreted merge can only see what is on
# disk, so absent deps made whole API families absorb (the TestCheck
# "tuple binding ... got UIKitStub" class: free withDependencies lives in
# swift-dependencies, not the TCA repo). Vendored packages are pruned to
# Sources/ — their own Tests would balloon the merge (i88 lesson: the
# unpruned merge ran 5x longer).
set -eu
cd "$(dirname "$0")/.."
D=External/oss/swift-composable-architecture/VendoredDependencies
mkdir -p "$D"
cd "$D"
for repo in swift-dependencies swift-clocks combine-schedulers \
            swift-concurrency-extras swift-custom-dump \
            xctest-dynamic-overlay swift-perception; do
  [ -d "$repo" ] || git clone --quiet --depth 1 "https://github.com/pointfreeco/$repo"
  # Sources only: the deps' own tests/fixtures never belong in the merge.
  find "$repo" -maxdepth 1 -type d ! -name Sources ! -path "$repo" -exec rm -rf {} + 2>/dev/null || true
  find "$repo" -maxdepth 1 -type f -delete 2>/dev/null || true
done
echo "vendored: $(ls | tr '\n' ' ')"
