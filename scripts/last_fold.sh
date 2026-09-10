#!/bin/bash
# Print the newest fold smoothness report(s). Usage: scripts/last_fold.sh [count]
awk -v n="${1:-1}" 'BEGIN{RS=""; ORS="\n\n"} {a[NR]=$0} END{for(i=NR-n+1;i<=NR;i++) if(i>0) print a[i]}' ~/Library/Logs/Hinge/folds.log
