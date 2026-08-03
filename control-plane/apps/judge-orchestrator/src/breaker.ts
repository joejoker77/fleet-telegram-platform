// Circuit breaker for the LLM judge leg (docs 09: a circuit breaker for when the judge
// degrades). After `threshold` consecutive failures the breaker OPENS and the judge
// leg is short-circuited for `cooldownMs` — callers get verdict=error and the
// scanners FAIL-CLOSED (artifact not installed), so a degraded judge can never be
// mistaken for a pass. After the cooldown it goes HALF-OPEN: one trial call is
// allowed; success closes it, failure re-opens it. Purely in-memory + deterministic
// — no timers fire on their own, so it cannot itself trigger any background work.
export type BreakerState = "closed" | "open" | "half-open";

export class CircuitBreaker {
  private failures = 0;
  private openedAt = 0;
  private trialInFlight = false;

  constructor(
    private readonly threshold: number,
    private readonly cooldownMs: number,
    private readonly now: () => number = () => Date.now(),
  ) {}

  state(): BreakerState {
    if (this.failures < this.threshold) return "closed";
    if (this.now() - this.openedAt >= this.cooldownMs) return "half-open";
    return "open";
  }

  // True if a judge call may proceed right now. In half-open, only ONE trial is
  // admitted until it settles (recordSuccess/recordFailure).
  canRequest(): boolean {
    const s = this.state();
    if (s === "closed") return true;
    if (s === "open") return false;
    if (this.trialInFlight) return false;
    this.trialInFlight = true;
    return true;
  }

  recordSuccess(): void {
    this.failures = 0;
    this.openedAt = 0;
    this.trialInFlight = false;
  }

  recordFailure(): void {
    this.failures += 1;
    this.trialInFlight = false;
    if (this.failures >= this.threshold && this.openedAt === 0) {
      this.openedAt = this.now();
    } else if (this.state() === "half-open" || this.failures > this.threshold) {
      // a failed trial (or continued failure) re-arms the cooldown window
      this.openedAt = this.now();
    }
  }
}
