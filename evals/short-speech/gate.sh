#!/bin/bash
# gate.sh <git-rev | path/to/PipelineController.swift>
# Compiles that revision's PipelineController.hasSpeech (+ toneMatch when present) and runs it on every
# *.f32 here, passing the chime start tone as the template when the function takes one (sound on).
set -e
src=$1; cd "$(dirname "$0")"
if [ -f "$src" ]; then cp "$src" pc.swift; tag=wt; else git -C ~/haynoi show "$src:Sources/Haynoi/App/PipelineController.swift" > pc.swift; tag=$src; fi
awk '/static func (hasSpeech|toneMatch)\(/{on=1} on{print} on && /^    }$/{on=0}' pc.swift \
  | sed 's/nonisolated //' | awk '/NSLog\(/{skip=1} skip{ if (/\)$/) {skip=0}; next } {print}' > fn.body
grep -q 'tone: \[Float\]?' fn.body && call='Gate.hasSpeech(s, tone: tone)' || call='Gate.hasSpeech(s)'
{ echo 'import Foundation'; echo 'enum Gate {'; cat fn.body; echo '}'
  cat <<SW
func readWav(_ p: String) -> [Float] {
    let d = FileManager.default.contents(atPath: p)!; let pcm = d.subdata(in: 44..<d.count)
    return pcm.withUnsafeBytes { Array(\$0.bindMemory(to: Int16.self)) }.map { Float(\$0) / 32768 }
}
let tone = readWav("tone.wav")
var pass = 0, total = 0
for f in (try! FileManager.default.contentsOfDirectory(atPath: ".")).filter({ \$0.hasSuffix(".f32") }).sorted() {
    let s: [Float] = FileManager.default.contents(atPath: f)!.withUnsafeBytes { Array(\$0.bindMemory(to: Float.self)) }
    let ok = $call; total += 1; if ok { pass += 1 }
    print(ok ? "PASS" : "DROP", f)
}
print("\(pass)/\(total) passed")
SW
} > harness.swift
swiftc -O -o gate-bin harness.swift 2>&1 | grep -E "error" || true
./gate-bin
