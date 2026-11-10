import Foundation

public struct OrganicLayoutConfiguration: Sendable {
    public let quality: OrganicLayoutQuality
    public var initialization: OrganicInitialization = .automatic
    public var nodeSeparation: Float = 20
    public var scope: OrganicScope = .all
    private var storedIterationBudget: Float = 0

    /// Compatibility step count. Setting it replaces any fractional budget.
    public var iterations: Int {
        get {
            guard storedIterationBudget.isFinite, storedIterationBudget >= 0,
                Double(storedIterationBudget) < Double(Int.max / 16)
            else { return 0 }
            return Int(ceil(storedIterationBudget))
        }
        set { storedIterationBudget = Float(newValue) }
    }

    /// Legacy mode executes ceil(budget) steps and cools using the original fractional
    /// divisor. Quality mode retains its CPU contract of rounding the budget up first.
    public var iterationBudget: Float {
        get { storedIterationBudget }
        set { storedIterationBudget = newValue }
    }

    public var initialTemperature: Float = 100

    /// Nominal strength; quality mode compares half, nominal and double strength.
    public var repulsionForce: Float
    public var attractionForce: Float = 0.05
    var preparedPositions = false

    public init(quality: OrganicLayoutQuality = .quality) {
        self.quality = quality
        storedIterationBudget = quality == .quality ? 600 : 100
        repulsionForce = quality == .quality ? 100 : 2000
    }

    func validate() throws {
        guard iterationBudget.isFinite, iterationBudget >= 0, Double(iterationBudget) < Double(Int.max / 16),
            [initialTemperature, repulsionForce, attractionForce, nodeSeparation]
                .allSatisfy({ $0.isFinite && $0 >= 0 }),
            (repulsionForce * repulsionForce * 4).isFinite
        else {
            throw LayoutExecutionError.invalidInput(
                "Iterations, temperature, forces and separation must be finite, nonnegative and within numerical range."
            )
        }
    }
}
