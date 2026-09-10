#!/bin/bash
# Runs a fake lid sweep inside Duofy at the real sensor cadence (10 readings/s):
# 105° → 20°, hold 1 s, back to 105°. Usage: scripts/sweep.sh [seconds_per_direction]
cat > /tmp/duofy_sweep.swift <<SW
import Foundation
DistributedNotificationCenter.default().postNotificationName(.init("com.altic.Duofy.sweep"), object: "${1:-1.5}", userInfo: nil, deliverImmediately: true)
SW
swift /tmp/duofy_sweep.swift
