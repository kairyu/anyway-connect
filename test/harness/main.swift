import Foundation

// The harness entry point. `main.swift` is the only file Swift allows top-level
// statements in, which is why the app's own 16-line main.swift is the ONE source
// test/run-swift-harness.sh must not copy.
//
// Suites 1-9 cover the shared pure layer: the on-link guard, the route-table
// parser, the configd key reduction, the derivation ladder, the reconcile
// planner, the sweep list, the command formatter, the reconcile gate and the
// netstate decoder. Suite 13 covers clause (f)'s install-target ladder, added by
// the defect-3 fix. Suites 10-12 are added by the two fixes that follow.
//
// Nothing here touches the live system: no `Process`, no socket, no file outside
// test/fixtures and test/harness/expected, no window, no NSApp. See
// Support.swift for the four standing constraints and the runner for the static
// gates that enforce them.

Suite01Guard.run()
Suite02Parse.run()
Suite03ConfigdKeys.run()
Suite04Derivation.run()
Suite05Plan.run()
Suite06Sweep.run()
Suite07Commands.run()
Suite08Gate.run()
Suite09NetState.run()
Suite13InstallTarget.run()

H.report()
