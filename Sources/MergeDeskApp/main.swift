import Foundation
import MergeDeskUI

// `MergeDesk --daily` is what the schedule runs: one headless daily run for every added repository, then exit.
// Running it from the app's own binary means its notifications come from Merge Desk. Anything else opens the app.
if CommandLine.arguments.contains(ScheduleModel.dailyArgument) {
    exit(await HeadlessDaily.run())
}
MergeDeskApp.main()
