#!/bin/bash
# Starts live lid tracking from the current angle. Move the physical lid; Esc ends the preview.
cat > /tmp/hinge_preview.swift <<'SW'
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.altic.Hinge.preview"), object: nil, userInfo: nil, deliverImmediately: true)
SW
swift /tmp/hinge_preview.swift
