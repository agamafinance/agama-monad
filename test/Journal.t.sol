// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgamaJournal} from "../src/journal/AgamaJournal.sol";

contract JournalTest is Test {
    AgamaJournal internal journal;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        journal = new AgamaJournal();
    }

    function test_eachWriterHasTheirOwn() public {
        vm.prank(alice);
        journal.write(hex"aa01");
        vm.prank(bob);
        journal.write(hex"bb02");
        assertEq(journal.journalOf(alice), hex"aa01");
        assertEq(journal.journalOf(bob), hex"bb02");
        assertEq(journal.writes(alice), 1);
    }

    function test_theLatestWriteReplaces() public {
        vm.startPrank(alice);
        journal.write(hex"aa01");
        vm.expectEmit(true, true, false, true);
        emit AgamaJournal.JournalWritten(alice, 2, keccak256(hex"cc0303"), 3);
        journal.write(hex"cc0303");
        vm.stopPrank();
        assertEq(journal.journalOf(alice), hex"cc0303");
        assertEq(journal.writes(alice), 2);
    }

    function test_emptyClears() public {
        vm.startPrank(alice);
        journal.write(hex"aa01");
        journal.write("");
        vm.stopPrank();
        assertEq(journal.journalOf(alice).length, 0);
    }

    function test_refusesOversize() public {
        bytes memory big = new bytes(journal.MAX_BYTES() + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(AgamaJournal.TooLarge.selector, big.length));
        journal.write(big);
    }
}
