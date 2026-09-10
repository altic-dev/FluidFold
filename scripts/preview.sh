#!/bin/bash
# Triggers Duofy's on-screen lid sweep (same as menu bar → Preview on screen).
cat > /tmp/duofy_preview.swift <<'SW'
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.altic.Duofy.preview"), object: nil, userInfo: nil, deliverImmediately: true)
SW
swift /tmp/duofy_preview.swift
