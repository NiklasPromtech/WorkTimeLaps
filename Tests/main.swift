import Foundation

// Entry point for the test binary built by scripts/test.sh.

CoreTests.run()
HighlightsTests.run()
DiaryTests.run()

print("\n\(testCount) tests, \(testFailures) failure\(testFailures == 1 ? "" : "s")")
exit(testFailures == 0 ? 0 : 1)
