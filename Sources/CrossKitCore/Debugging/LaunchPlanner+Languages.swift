import Foundation

extension LaunchPlanner {
    func planCpp(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                 text: String, purpose: LaunchPurpose) throws {
        throw DebugError.noProgram("C++ launching is not implemented yet.")
    }

    func planScript(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                    text: String, purpose: LaunchPurpose) throws {
        throw DebugError.noProgram("JavaScript launching is not implemented yet.")
    }

    func planWasm(_ plan: inout LaunchPlan, file: URL, root: URL, test: DiscoveredTest?, config: LaunchConfiguration,
                  text: String, purpose: LaunchPurpose) throws {
        throw DebugError.noProgram("WebAssembly launching is not implemented yet.")
    }
}
