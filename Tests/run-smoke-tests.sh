#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
test_dir=$(mktemp -d /tmp/savior-smoke.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/cache" Savior/DownloadModel.swift Savior/DownloadStore.swift Tests/DownloaderSmokeTests.swift -o "$test_dir/smoke-tests"
"$test_dir/smoke-tests" "$@"
