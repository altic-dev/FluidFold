#!/bin/bash
# Starts live lid tracking from the current angle. Move the physical lid; Esc ends the preview.
cat > /tmp/duofy_preview.swift <<'SW'
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.altic.Duofy.preview"), object: nil, userInfo: nil, deliverImmediately: true)
SW
swift /tmp/duofy_preview.swift
