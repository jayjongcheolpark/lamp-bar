import Foundation

@main
enum Main {
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--probe") {
            await Probe.run()
            return
        }
        LampBarApp.main()
    }
}
