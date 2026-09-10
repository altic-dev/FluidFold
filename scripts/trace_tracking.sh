#!/bin/bash
# Start 90 seconds of bounded sensor-to-presentation telemetry in the running app.
set -euo pipefail
swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.altic.Dusk.trace"), object: nil, userInfo: nil, deliverImmediately: true)'
