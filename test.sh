#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/Quota.swift Sources/CodexClient.swift Tests/main.swift -o build/quota-tests
chmod +x Tests/fake-codex.py
build/quota-tests --fake "$PWD/Tests/fake-codex.py" "$@"
xcrun swiftc -module-cache-path "$PWD/build/module-cache" Sources/PanelPlacement.swift Tests/Placement.swift -o build/placement-tests
build/placement-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/module-cache" \
  Sources/Quota.swift Sources/CodexClient.swift Sources/QuotaModel.swift Tests/Monitoring.swift \
  -o build/monitoring-tests -framework AppKit -framework ServiceManagement
build/monitoring-tests
