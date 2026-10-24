import Foundation
import SwiftUI

@main
struct MyPodEntry {
    @MainActor static func main() async {
        #if MYPOD_TESTS
        await RegressionTests.run()
        #else
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--cli" || URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "mypod" {
            let code = await MyPodCLI.run(arguments.first == "--cli" ? Array(arguments.dropFirst()) : arguments)
            exit(code)
        } else {
            My_PodApp.main()
        }
        #endif
    }
}
