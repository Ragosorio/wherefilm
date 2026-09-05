import Foundation
import ArgumentParser
import WhereFilmCore

struct Usage: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect, enable or erase local search learning.",
        subcommands: [UsageStatus.self, UsageEnable.self, UsageDisable.self, UsageForget.self],
        defaultSubcommand: UsageStatus.self)
}

struct UsageStatus: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Print exportable aggregate weights as JSON. No queries or paths.")
    @OptionGroup var storeOptions: StoreOptions
    func run() throws {
        let report = try storeOptions.makeStore().usageReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
struct UsageEnable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable experimental local learning in this catalog.")
    @OptionGroup var storeOptions: StoreOptions
    func run() throws {
        try storeOptions.makeStore().setUsageLearningEnabled(true)
        print("Enabled. The app records opens and settled reformulations; weights require 200 actions.")
    }
}
struct UsageDisable: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Stop recording and using local preferences.")
    @OptionGroup var storeOptions: StoreOptions
    func run() throws { try storeOptions.makeStore().setUsageLearningEnabled(false); print("Disabled.") }
}
struct UsageForget: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "forget", abstract: "Erase all usage history and restore the original order.")
    @OptionGroup var storeOptions: StoreOptions
    @Flag(name: .long, help: "Confirm erasing this catalog's usage history.") var yes = false
    func run() throws {
        guard yes else { throw ValidationError("Pass --yes to erase usage history. Media and analysis are preserved.") }
        try storeOptions.makeStore().forgetUsage()
        print("Usage erased. Original weights restored.")
    }
}
