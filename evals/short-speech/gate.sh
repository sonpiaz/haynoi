#!/bin/bash
# gate.sh <git-rev> : compile that revision's PipelineController.hasSpeech and run it on every *.f32 buffer here.
set -e
rev=$1; dir=$(dirname "$0"); cd "$dir"
if [ -f "$rev" ]; then cp "$rev" pc.swift; rev=wt; else git -C ~/haynoi show "$rev:Sources/Haynoi/App/PipelineController.swift" > pc.swift; fi
awk '/static func hasSpeech\(/{on=1} on{print} on && /^    }$/{exit}' pc.swift | sed 's/nonisolated //; s/NSLog(.*$/_ = 0/' > fn.body
# NSLog spans 2 lines in the source; drop its continuation line.
grep -v '^ *average, floor, voiced' fn.body > fn2.body
{ echo 'import Foundation'; echo 'enum Gate {'; cat fn2.body; echo '}';
  cat <<'SW'
let fm = FileManager.default
var pass = 0, total = 0
for f in (try! fm.contentsOfDirectory(atPath: ".")).filter({ $0.hasSuffix(".f32") }).sorted() {
    let d = fm.contents(atPath: f)!
    let s: [Float] = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let ok = Gate.hasSpeech(s); total += 1; if ok { pass += 1 }
    print(ok ? "PASS" : "DROP", f)
}
print("\(pass)/\(total) passed")
SW
} > harness.swift
swiftc -O -o gate-$rev harness.swift 2>&1 | grep -v warning || true
./gate-$rev
