import ArgumentParser
import Foundation

@main
struct RenameByDateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rbdate",
        abstract: "Renames PDF files using a date found in the file name or the PDF contents."
    )

    @Flag(help: "Actually apply the renaming (default is a dry run)")
    var apply: Bool = false

    @Flag(help: "Process folders recursively")
    var recursive: Bool = false

    @Flag(help: "Set the file's creation and modification dates to the extracted date")
    var setDate: Bool = false

    @Flag(help: "Print each planned rename")
    var verbose: Bool = false

    @Option(help: "Output directory (defaults to the input folder)")
    var out: String?

    @Option(
        name: [.long, .customLong("prefix", withSingleDash: true)],
        help: "Date prefix format for new names, e.g. \"YYYYMMDD\", \"YYYY-MM-DD\", or strftime style \"%Y%m%d\""
    )
    var prefix: String = "YYYYMMDD"

    @Argument(help: "Folder to process")
    var folder: String

    func run() throws {
        let config = RenameByDateConfig(
            inputFolder: folder,
            outputFolder: out,
            recursive: recursive,
            stamp: setDate,
            apply: apply,
            prefixFormat: prefix
        )

        let engine = RenameByDateEngine()
        let result = try engine.run(config: config)

        if verbose {
            for rename in result.planned {
                print("\(rename.old) -> \(rename.new)")
            }
            for path in result.skipped {
                print("skipped: \(path)")
            }
        }

        print("\(result.planned.count) planned, \(result.skipped.count) skipped, \(result.failed.count) failed, \(result.stamped.count) stamped")
        if !apply {
            print("(dry run — pass --apply to rename)")
        }
    }
}
