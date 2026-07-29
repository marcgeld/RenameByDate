import ArgumentParser
import Foundation

@main
struct RenameByDateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rbdate",
        abstract: "Renames PDF files using a date found in the file name or the PDF contents."
    )

    @Flag(name: .customLong("dryrun"), help: "Show planned renames without changing any files")
    var dryRun: Bool = false

    @Flag(help: "Process folders recursively")
    var recursive: Bool = false

    @Flag(help: "Set the file's creation and modification dates to the extracted date")
    var setDate: Bool = false

    @Flag(help: "Print each planned rename")
    var verbose: Bool = false

    @Flag(name: .customLong("showpath"), help: "Print full paths instead of file names")
    var showPath: Bool = false

    @Option(help: "Output directory (defaults to the input folder)")
    var out: String?

    @Option(
        name: [.long, .customLong("prefix", withSingleDash: true)],
        help: "Date prefix format for new names, e.g. \"YYYYMMDD\", \"YYYY-MM-DD\", or strftime style \"%Y%m%d\""
    )
    var prefix: String = "YYYYMMDD"

    @Option(help: "Characters not allowed in generated file names; they are removed. Without this option, everything except letters, digits, space, and \"( ) - _ .\" is removed")
    var disallowed: String?

    @Argument(help: "Folder to process")
    var folder: String

    func run() throws {
        let config = RenameByDateConfig(
            inputFolder: folder,
            outputFolder: out,
            recursive: recursive,
            stamp: setDate,
            apply: !dryRun,
            prefixFormat: prefix,
            disallowedCharacters: disallowed
        )

        let engine = RenameByDateEngine()
        let result = try engine.run(config: config)

        // A dry run should show the actual plan, not only its total count.
        // Applied runs stay concise unless --verbose is explicitly requested.
        if dryRun || verbose {
            for rename in result.planned {
                let oldName = showPath ? rename.old : (rename.old as NSString).lastPathComponent
                let newName = showPath ? rename.new : (rename.new as NSString).lastPathComponent
                print("\(oldName) -> \(newName)")
            }
        }

        if verbose {
            for path in result.skipped {
                print("skipped: \(path)")
            }
        }

        print("\(result.planned.count) planned, \(result.skipped.count) skipped, \(result.failed.count) failed, \(result.stamped.count) stamped")
        if dryRun {
            print("(dry run — no files were changed)")
        }
    }
}
