import XCTest
@testable import ComposerApp

final class GraphExpressionTests: XCTestCase {
  func testImplicitMultiplication() {
    XCTAssertEqual(evaluate("2x", at: 2), 4, accuracy: 0.000001)
  }

  func testStripsFunctionAssignmentHead() {
    XCTAssertEqual(evaluate("f(x) = 2x", at: 2), 4, accuracy: 0.000001)
  }

  func testParsesMixedAssignmentVariableHead() {
    XCTAssertNotNil(GraphExpression(latex: "f(n)=2x"))
  }

  func testPowerPrecedence() {
    XCTAssertEqual(evaluate("x^2+1", at: 2), 5, accuracy: 0.000001)
  }

  func testLatexSin() {
    XCTAssertEqual(evaluate("\\sin(x)", at: 0), 0, accuracy: 0.000001)
  }

  func testLatexFraction() {
    XCTAssertEqual(evaluate("\\frac{x}{2}", at: 4), 2, accuracy: 0.000001)
  }

  func testImplicitMultiplicationBeforeLatexFunction() {
    XCTAssertNotNil(GraphExpression(latex: "2\\sin(x)+1"))
  }

  func testLatexSquareRoot() {
    XCTAssertEqual(evaluate("\\sqrt{x}", at: 9), 3, accuracy: 0.000001)
  }

  func testEulerConstant() {
    XCTAssertEqual(evaluate("e^x", at: 0), 1, accuracy: 0.000001)
  }

  func testGarbageReturnsNil() {
    XCTAssertNil(GraphExpression(latex: "hello world"))
    XCTAssertNil(GraphExpression(latex: "\\boldsymbol{x}"))
  }

  private func evaluate(_ latex: String, at x: Double, file: StaticString = #filePath, line: UInt = #line) -> Double {
    guard let expression = GraphExpression(latex: latex) else {
      XCTFail("Expected expression to parse: \(latex)", file: file, line: line)
      return .nan
    }
    return expression.evaluate(x)
  }
}
