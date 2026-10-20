"""Compile the app history loaders against synthetic CLI output only."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check():
    source = (ROOT / "Scrollback/History.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="scrollback-history-") as temp:
        root = Path(temp)
        # Substitute external records at the same interfaces the app reads.
        harness = r'''import Foundation
var testRows = ""
var testRuns: [String] = []
let historyScript = "synthetic-history"
func historyLines() -> [String] { testRuns }
func shell(_ script: String, _ args: String...) -> String { testRows }
func NSHomeDirectory() -> String { ProcessInfo.processInfo.environment["SCROLLBACK_TEST_ROOT"]! }
func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { print("FAIL: " + message); exit(1) }
}
'''
        tests = r'''
let demo = CommandLine.arguments.contains("--demo")
if demo {
    require(!Day.loadForPanel().isEmpty, "explicit demo must provide sample days")
    require(!Run.loadForPanel().isEmpty, "explicit demo must provide sample runs")
    require(Run.loadForPanel().allSatisfy { $0.trigger == "demo" }, "sample runs must be labelled demo")
} else {
    require(Run.loadForPanel().isEmpty, "empty real history must have no successful runs")
    require(Day.loadForPanel().isEmpty, "empty real history must have no sample days")
    testRows = ["2026-10-18|0", "2026-10-19|3", "2026-10-20|0"].joined(separator: "\n")
    require(Day.loadForPanel().map { $0.collected } == [0, 3, 0], "real zero counts must remain zero")
    testRuns = ["2026-10-19T12:00:00Z|3|manual|fail|0|2026-10-19T12:00:01Z"]
    let runs = Run.loadForPanel()
    require(runs.count == 1 && !runs[0].ok && runs[0].chats == 3, "failed real run must remain the only run")
    let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".beatbar/demo-history.json")
    require(!FileManager.default.fileExists(atPath: cache.path), "normal history must not create a demo cache")
    try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
    let oldDemo = Data("{\"2026-10-18\":99}".utf8)
    try oldDemo.write(to: cache)
    require(Day.loadForPanel().map { $0.collected } == [0, 3, 0], "old demo cache must not replace real counts")
    let remainingDemo = try Data(contentsOf: cache)
    require(remainingDemo == oldDemo, "real history must leave old demo cache untouched")
}
print(demo ? "Explicit demo history passed" : "Real panel history passed")
'''
        (root / "main.swift").write_text(harness + "\n" + source + "\n" + tests)
        binary = root / "history-test"
        subprocess.run(["swiftc", "-module-cache-path", str(root / "module-cache"), str(root / "main.swift"), "-o", str(binary)], check=True)
        env = dict(os.environ, SCROLLBACK_TEST_ROOT=temp)
        subprocess.run([str(binary)], env=env, check=True)
        subprocess.run([str(binary), "--demo"], env=env, check=True)


if __name__ == "__main__":
    check()
