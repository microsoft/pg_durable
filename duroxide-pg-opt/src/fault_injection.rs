//! Fault injection for testing resilience scenarios.
//!
//! This module provides a comprehensive fault injection mechanism to simulate
//! failure conditions in tests without complex runtime manipulation.
//!
//! ## Supported Faults
//!
//! - `disable_notifier`: Prevents the notifier thread from starting
//! - `refresh_delay`: Adds artificial delay to refresh queries
//! - `force_reconnect`: Triggers a reconnection in the notifier
//! - `refresh_should_error`: Makes the next refresh query fail
//! - `notifier_should_panic`: Simulates a panic in the notifier thread

use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::time::Duration;

/// Fault injector for testing resilience scenarios.
///
/// Thread-safe structure that can be shared across provider and tests
/// to inject faults dynamically during test execution.
#[derive(Debug, Default)]
pub struct FaultInjector {
    /// If true, the notifier thread will not be spawned
    notifier_disabled: AtomicBool,

    /// Artificial delay (in milliseconds) to add to refresh queries
    refresh_delay_ms: AtomicU64,

    /// If true, forces the notifier to simulate a connection drop and reconnect
    force_reconnect: AtomicBool,

    /// If true, the next refresh query should return an error
    refresh_should_error: AtomicBool,

    /// If true, simulates a panic in the notifier thread
    notifier_should_panic: AtomicBool,

    /// Clock skew offset in milliseconds (can be positive or negative).
    /// This value is added to all time calculations in the provider,
    /// simulating a node whose clock is ahead (positive) or behind (negative).
    clock_skew_ms: AtomicI64,
}

impl FaultInjector {
    /// Create a new fault injector with no faults enabled.
    pub fn new() -> Self {
        Self::default()
    }

    // =========================================================================
    // Notifier Control
    // =========================================================================

    /// Disable the notifier - prevents it from being spawned.
    ///
    /// When called before provider creation, the notifier thread will not start,
    /// simulating a notifier failure scenario.
    pub fn disable_notifier(&self) {
        self.notifier_disabled.store(true, Ordering::SeqCst);
    }

    /// Check if the notifier is disabled.
    pub fn is_notifier_disabled(&self) -> bool {
        self.notifier_disabled.load(Ordering::SeqCst)
    }

    /// Set whether the notifier should panic on next iteration.
    pub fn set_notifier_should_panic(&self, should_panic: bool) {
        self.notifier_should_panic
            .store(should_panic, Ordering::SeqCst);
    }

    /// Check if the notifier should panic.
    pub fn should_notifier_panic(&self) -> bool {
        self.notifier_should_panic.swap(false, Ordering::SeqCst)
    }

    // =========================================================================
    // Refresh Query Control
    // =========================================================================

    /// Set artificial delay for refresh queries (simulates slow database).
    pub fn set_refresh_delay(&self, delay: Duration) {
        self.refresh_delay_ms
            .store(delay.as_millis() as u64, Ordering::SeqCst);
    }

    /// Get the current refresh delay.
    pub fn get_refresh_delay(&self) -> Duration {
        Duration::from_millis(self.refresh_delay_ms.load(Ordering::SeqCst))
    }

    /// Set whether the next refresh query should return an error.
    pub fn set_refresh_should_error(&self, should_error: bool) {
        self.refresh_should_error
            .store(should_error, Ordering::SeqCst);
    }

    /// Check and consume the refresh error flag.
    pub fn should_refresh_error(&self) -> bool {
        self.refresh_should_error.swap(false, Ordering::SeqCst)
    }

    // =========================================================================
    // Connection Control
    // =========================================================================

    /// Force the notifier to reconnect (simulates connection drop).
    pub fn trigger_reconnect(&self) {
        self.force_reconnect.store(true, Ordering::SeqCst);
    }

    /// Check and consume the reconnect flag.
    pub fn should_reconnect(&self) -> bool {
        self.force_reconnect.swap(false, Ordering::SeqCst)
    }

    // =========================================================================
    // Clock Skew Simulation
    // =========================================================================

    /// Set clock skew offset in milliseconds.
    ///
    /// Positive values simulate a clock that is ahead (future timestamps).
    /// Negative values simulate a clock that is behind (past timestamps).
    ///
    /// This offset is added to all `now_millis()` calculations in the provider,
    /// allowing simulation of clock drift between nodes.
    ///
    /// # Example
    /// ```
    /// use duroxide_pg_opt::FaultInjector;
    /// use std::time::Duration;
    ///
    /// let fi = FaultInjector::new();
    /// // Simulate clock 500ms ahead
    /// fi.set_clock_skew(Duration::from_millis(500));
    ///
    /// // Simulate clock 200ms behind
    /// fi.set_clock_skew_signed(-200);
    /// ```
    pub fn set_clock_skew(&self, skew: Duration) {
        self.clock_skew_ms
            .store(skew.as_millis() as i64, Ordering::SeqCst);
    }

    /// Set clock skew offset in milliseconds (signed).
    ///
    /// Positive values simulate a clock that is ahead.
    /// Negative values simulate a clock that is behind.
    pub fn set_clock_skew_signed(&self, skew_ms: i64) {
        self.clock_skew_ms.store(skew_ms, Ordering::SeqCst);
    }

    /// Get the current clock skew offset in milliseconds.
    pub fn get_clock_skew_ms(&self) -> i64 {
        self.clock_skew_ms.load(Ordering::SeqCst)
    }

    /// Clear the clock skew (reset to 0).
    pub fn clear_clock_skew(&self) {
        self.clock_skew_ms.store(0, Ordering::SeqCst);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fault_injector_default() {
        let fi = FaultInjector::new();
        assert!(!fi.is_notifier_disabled());
        assert_eq!(fi.get_refresh_delay(), Duration::ZERO);
        assert!(!fi.should_reconnect());
    }

    #[test]
    fn test_disable_notifier() {
        let fi = FaultInjector::new();
        fi.disable_notifier();
        assert!(fi.is_notifier_disabled());
    }

    #[test]
    fn test_refresh_delay() {
        let fi = FaultInjector::new();
        fi.set_refresh_delay(Duration::from_secs(5));
        assert_eq!(fi.get_refresh_delay(), Duration::from_secs(5));
    }

    #[test]
    fn test_reconnect_flag() {
        let fi = FaultInjector::new();
        assert!(!fi.should_reconnect());
        fi.trigger_reconnect();
        assert!(fi.should_reconnect());
        // Flag should be consumed
        assert!(!fi.should_reconnect());
    }

    #[test]
    fn test_refresh_error_flag() {
        let fi = FaultInjector::new();
        assert!(!fi.should_refresh_error());
        fi.set_refresh_should_error(true);
        assert!(fi.should_refresh_error());
        // Flag should be consumed
        assert!(!fi.should_refresh_error());
    }

    #[test]
    fn test_notifier_panic_flag() {
        let fi = FaultInjector::new();
        assert!(!fi.should_notifier_panic());
        fi.set_notifier_should_panic(true);
        assert!(fi.should_notifier_panic());
        // Flag should be consumed
        assert!(!fi.should_notifier_panic());
    }

    #[test]
    fn test_clock_skew() {
        let fi = FaultInjector::new();
        assert_eq!(fi.get_clock_skew_ms(), 0);

        // Positive skew (clock ahead)
        fi.set_clock_skew(Duration::from_millis(500));
        assert_eq!(fi.get_clock_skew_ms(), 500);

        // Negative skew (clock behind)
        fi.set_clock_skew_signed(-200);
        assert_eq!(fi.get_clock_skew_ms(), -200);

        // Clear
        fi.clear_clock_skew();
        assert_eq!(fi.get_clock_skew_ms(), 0);
    }
}
