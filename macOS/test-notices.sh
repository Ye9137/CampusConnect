#!/bin/zsh
set -euo pipefail
task_source="${0:A:h}/source"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/campus-notices.XXXXXX")"
trap 'rm -rf "${task_build}"' EXIT
xcrun swiftc -swift-version 5 "${task_source}/Core.swift" "${task_source}/WiFi.swift" \
  "${task_source}/WiredAuthentication.swift" "${task_source}/Connectivity.swift" \
  "${task_source}/CampusProxy.swift" "${task_source}/Portal.swift" "${task_source}/PortalNoticeTests.swift" \
  -framework AppKit -framework SwiftUI -framework CoreWLAN -framework CoreLocation \
  -framework SystemConfiguration -framework WebKit -framework Network -o "${task_build}/notice-tests"
"${task_build}/notice-tests"
