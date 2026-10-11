import Foundation

@main
enum Main {
    static func main() async {
        let args = CommandLine.arguments
        if CommandLineTool.handles(args) {
            await CommandLineTool.run(args)
            return
        }
        LampBarApp.main()
    }
}
