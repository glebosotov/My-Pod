import Foundation

@main
struct MyPodCommand {
    @MainActor static func main() async {
        exit(await MyPodCLI.run(Array(CommandLine.arguments.dropFirst())))
    }
}
