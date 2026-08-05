import Foundation

// Standalone offline validation host. Build:
//   swiftc -O Tools/DSPCheckMain.swift ... (see Scripts/run-dsp-validation.sh)

@main
struct DSPCheckMain {
    static func main() {
        let reports = DSPValidation.runAll()
        var failed = 0
        for r in reports {
            let mark = r.passed ? "PASS" : "FAIL"
            print("[\(mark)] \(r.name) — \(r.detail)")
            if !r.passed { failed += 1 }
        }
        if failed > 0 {
            print("\(failed) test(s) failed")
            exit(1)
        }
        print("All \(reports.count) DSP checks passed")
    }
}
