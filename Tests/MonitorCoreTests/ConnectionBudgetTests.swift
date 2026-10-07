@testable import MonitorServer
import Testing

@Test func parallelTLSConnectionsShareTheBoundedConnectionBudget() {
  let budget = ConnectionBudget()
  for _ in 0..<16 { #expect(budget.acquire(tls: true)) }
  #expect(!budget.acquire(tls: true))
  #expect(!budget.acquire(tls: false))
  budget.handshakeDone()
  // Completing a handshake does not free its connection slot.
  #expect(!budget.acquire(tls: true))
  budget.release(handshakePending: false)
  #expect(budget.acquire(tls: true))
}
