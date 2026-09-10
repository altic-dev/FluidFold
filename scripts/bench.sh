#!/bin/bash
# Benchmark one configuration: restart the app with the given defaults, run N fast sweeps, print a one-line summary.
# Usage: scripts/bench.sh "label" [n] [-- key value ...]
# Run it detached (nohup … &) so the terminal/Claude window is idle while it measures.
LABEL="$1"; N="${2:-3}"; shift 2 2>/dev/null; [ "$1" = "--" ] && shift
while [ $# -ge 2 ]; do defaults write com.altic.Hinge "$1" "$2"; shift 2; done
killall Hinge 2>/dev/null; sleep 1; open /Applications/Hinge.app; sleep 3
for i in $(seq 1 "$N"); do "$(dirname "$0")/sweep.sh" 0.9; sleep "${GAP:-5}"; done
"$(dirname "$0")/last_fold.sh" "$N" | awk -v L="$LABEL" '
  /start  /{match($0,/irregular +[0-9]+/); a+=substr($0,RSTART+10,RLENGTH-10); match($0,/missed +[0-9]+/); am+=substr($0,RSTART+7,RLENGTH-7)}
  /middle/{match($0,/irregular +[0-9]+/); b+=substr($0,RSTART+10,RLENGTH-10); match($0,/missed +[0-9]+/); bm+=substr($0,RSTART+7,RLENGTH-7)}
  /end  /{match($0,/irregular +[0-9]+/); e+=substr($0,RSTART+10,RLENGTH-10)}
  /worst/{w=w" "$4}
  /on screen/{match($0,/\([0-9]+ fps\)/); f=f" "substr($0,RSTART+1,RLENGTH-6)}
  /first frame/{match($0,/first frame -?[0-9?]+ms/); ff=ff" "substr($0,RSTART+12,RLENGTH-12)}
  END{printf "%-34s irregular start %3d  middle %3d  end %2d (missed %d/%d) | fps%s | worst drawable ms%s | first frame%s\n", L, a, b, e, am, bm, f, w, ff}'
