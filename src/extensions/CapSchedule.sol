// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title CapSchedule
/// @notice Linear deposit-cap ramp for CappedVault.
///
/// The owner sets a start cap, an end cap and a duration, then calls `step()` on
/// whatever cadence it likes. `step()` returns the cap implied by the linear curve
/// at `block.timestamp`; the caller pushes it with `vault.setCap(returned)`, so the
/// vault never has to trust or store a second progression.
///
/// Kept out of the vault on purpose: the schedule is policy, not accounting, and a
/// wrong one is fixed by deploying a new schedule instead of migrating the vault.
contract CapSchedule {
    error NotOwner();
    error EmptyCurve();
    error StartTimeInPast();

    event CurveSet(uint256 startCap, uint256 endCap, uint64 startTime, uint64 duration);
    event Stepped(uint256 cap);

    address public immutable owner;
    uint256 public startCap;
    uint256 public endCap;
    uint64 public startTime;
    uint64 public duration;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_, uint256 startCap_, uint256 endCap_, uint64 startTime_, uint64 duration_) {
        if (owner_ == address(0)) revert NotOwner();
        owner = owner_;
        _setCurve(startCap_, endCap_, startTime_, duration_);
    }

    /// @notice Cap implied by the curve at `timestamp`. Clamped at both ends.
    function capAt(uint256 timestamp) public view returns (uint256) {
        if (duration == 0) return endCap;
        if (timestamp <= startTime) return startCap;
        uint256 elapsed = timestamp - startTime;
        if (elapsed >= duration) return endCap;
        return startCap + ((endCap - startCap) * elapsed) / duration;
    }

    /// @notice Progress through the ramp in basis points, clamped to 10_000.
    function progressBps(uint256 timestamp) public view returns (uint256) {
        if (duration == 0) return 10_000;
        if (timestamp <= startTime) return 0;
        uint256 elapsed = timestamp - startTime;
        return elapsed >= duration ? 10_000 : (elapsed * 10_000) / duration;
    }

    function isFinished(uint256 timestamp) external view returns (bool) {
        return timestamp >= startTime + duration;
    }

    /// @notice Current cap, ready to be handed to `vault.setCap`.
    function step() external onlyOwner returns (uint256 cap) {
        cap = capAt(block.timestamp);
        emit Stepped(cap);
    }

    /// @notice Replaces the curve. Already-applied caps stay where they are, so
    /// shrinking `endCap` below the live vault cap needs a manual `setCap`.
    function setCurve(uint256 startCap_, uint256 endCap_, uint64 startTime_, uint64 duration_) external onlyOwner {
        _setCurve(startCap_, endCap_, startTime_, duration_);
    }

    function _setCurve(uint256 startCap_, uint256 endCap_, uint64 startTime_, uint64 duration_) private {
        if (startCap_ == 0 && endCap_ == 0) revert EmptyCurve();
        if (startTime_ < block.timestamp) revert StartTimeInPast();
        startCap = startCap_;
        endCap = endCap_;
        startTime = startTime_;
        duration = duration_;
        emit CurveSet(startCap_, endCap_, startTime_, duration_);
    }
}
