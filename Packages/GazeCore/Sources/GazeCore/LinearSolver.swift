import Foundation

/// Dense linear algebra helpers shared by the calibration fitters.
///
/// These stay dependency-free so `GazeCore` remains testable on any platform
/// without Accelerate.
enum LinearSolver {
    /// Solves `A x = b` for a square, row-major matrix using Gaussian
    /// elimination with partial pivoting.
    ///
    /// Returns `nil` when the matrix is singular relative to `tolerance`,
    /// scaled by the largest magnitude in the original matrix so the check is
    /// independent of the problem's units.
    static func solve(
        matrix: [Double],
        vector: [Double],
        size n: Int,
        tolerance: Double = 1e-12
    ) -> [Double]? {
        guard matrix.count == n * n, vector.count == n, n > 0 else { return nil }

        var a = matrix
        var b = vector

        let scale = matrix.reduce(0.0) { Swift.max($0, abs($1)) }
        guard scale > 0, scale.isFinite else { return nil }
        let pivotFloor = tolerance * scale

        for column in 0..<n {
            var pivotRow = column
            var pivotMagnitude = abs(a[column * n + column])
            for row in (column + 1)..<n {
                let magnitude = abs(a[row * n + column])
                if magnitude > pivotMagnitude {
                    pivotMagnitude = magnitude
                    pivotRow = row
                }
            }

            guard pivotMagnitude > pivotFloor else { return nil }

            if pivotRow != column {
                for k in 0..<n {
                    a.swapAt(pivotRow * n + k, column * n + k)
                }
                b.swapAt(pivotRow, column)
            }

            let pivot = a[column * n + column]
            for row in (column + 1)..<n {
                let factor = a[row * n + column] / pivot
                guard factor != 0 else { continue }
                for k in column..<n {
                    a[row * n + k] -= factor * a[column * n + k]
                }
                b[row] -= factor * b[column]
            }
        }

        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n {
                sum -= a[row * n + k] * x[k]
            }
            x[row] = sum / a[row * n + row]
        }

        guard x.allSatisfy(\.isFinite) else { return nil }
        return x
    }

    /// Builds and solves the normal equations `AᵀA x = Aᵀb` for an
    /// overdetermined system. `rows` is row-major with `columns` entries each.
    static func leastSquares(
        rows: [[Double]],
        targets: [Double],
        columns: Int,
        tolerance: Double = 1e-12
    ) -> [Double]? {
        guard rows.count == targets.count, rows.count >= columns else { return nil }

        var normal = [Double](repeating: 0, count: columns * columns)
        var rhs = [Double](repeating: 0, count: columns)

        for (row, target) in zip(rows, targets) {
            guard row.count == columns else { return nil }
            for i in 0..<columns {
                rhs[i] += row[i] * target
                for j in i..<columns {
                    normal[i * columns + j] += row[i] * row[j]
                }
            }
        }

        // Mirror the upper triangle into the lower one.
        for i in 0..<columns {
            for j in 0..<i {
                normal[i * columns + j] = normal[j * columns + i]
            }
        }

        return solve(matrix: normal, vector: rhs, size: columns, tolerance: tolerance)
    }
}
