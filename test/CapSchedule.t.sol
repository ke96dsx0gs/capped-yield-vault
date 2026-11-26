// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {CapSchedule} from "../src/extensions/CapSchedule.sol";

contract CapScheduleTest is Test {
    CapSchedule internal schedule;
    uint64 internal start;

    function setUp() public {
        start = uint64(block.timestamp + 1 days);
        schedule = new CapSchedule(address(this), 100e18, 1_000e18, start, 10 days);
    }

    function testCapInterpolatesLinearly() public {
        assertEq(schedule.capAt(start - 1), 100e18, "clamped at start");
        assertEq(schedule.capAt(start + 5 days), 550e18, "halfway up the curve");
        assertEq(schedule.capAt(start + 10 days), 1_000e18, "clamped at end");
        assertEq(schedule.capAt(start + 30 days), 1_000e18, "stays at end cap");
    }

    function testProgressIsClamped() public {
        assertEq(schedule.progressBps(start - 1), 0);
        assertEq(schedule.progressBps(start + 5 days), 5_000);
        assertEq(schedule.progressBps(start + 11 days), 10_000);
    }

    function testStepUsesCurrentTimeAndEmits() public {
        vm.warp(start + 2 days);
        vm.expectEmit(address(schedule));
        emit CapSchedule.Stepped(280e18);
        uint256 cap = schedule.step();
        assertEq(cap, 280e18);
    }

    function testStepIsOwnerOnly() public {
        vm.prank(address(0xB0B));
        vm.expectRevert(CapSchedule.NotOwner.selector);
        schedule.step();
    }

    function testZeroDurationJumpsToEndCap() public {
        CapSchedule instant = new CapSchedule(address(this), 1, 9, uint64(block.timestamp), 0);
        assertEq(instant.capAt(block.timestamp), 9);
        assertTrue(instant.isFinished(block.timestamp));
    }

    function testRejectsPastStartAndEmptyCurve() public {
        vm.expectRevert(CapSchedule.StartTimeInPast.selector);
        schedule.setCurve(1, 2, uint64(block.timestamp - 1), 1 days);

        vm.expectRevert(CapSchedule.EmptyCurve.selector);
        schedule.setCurve(0, 0, start, 1 days);
    }

    function testFuzzMonotonic(uint32 delta) public {
        uint256 a = schedule.capAt(start + (delta % 10 days));
        uint256 b = schedule.capAt(start + (uint256(delta) % 10 days) + 1);
        assertLe(a, b);
    }
}
