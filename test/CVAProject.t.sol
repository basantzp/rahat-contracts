// SPDX-License-Identifier: LGPL-3.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CVAProject} from "../src/rahat-app/contracts/projects/CVAProject.sol";
import {RahatCommunity} from "../src/rahat-app/contracts/RahatCommunity.sol";
import {RahatClaim} from "../src/rahat-app/contracts/RahatClaim.sol";
import {RahatToken} from "../src/rahat-app/contracts/RahatToken.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

contract CVAProjectTest is Test {
    CVAProject public project;
    RahatCommunity public community;
    RahatClaim public rahatClaim;
    RahatToken public token;
    ERC2771Forwarder public forwarder;

    address public admin = address(this);
    address public donor = makeAddr("donor");
    address public otpServer = makeAddr("otpServer");
    address public vendor1 = makeAddr("vendor1");
    address public vendor2 = makeAddr("vendor2");
    address public ben1 = makeAddr("ben1");
    address public ben2 = makeAddr("ben2");

    bytes32 public constant VENDOR_ROLE = keccak256("VENDOR");

    function setUp() public {
        forwarder = new ERC2771Forwarder("RahatForwarder");
        community = new RahatCommunity("Nepal Community", admin);

        token = new RahatToken("Rahat Relief Token", "RHT", admin, 18);
        rahatClaim = new RahatClaim();

        project = new CVAProject(
            "Sindhupalchok Flood Relief",
            address(token),
            address(rahatClaim),
            otpServer,
            address(community),
            address(forwarder)
        );

        // Approve project in community
        community.approveProject(address(project));

        // Setup Vendor Role
        community.grantRole(VENDOR_ROLE, vendor1);
        community.grantRole(VENDOR_ROLE, vendor2);

        // Mint tokens to donor
        token.mint(donor, 100_000 * 1e18);

        // Donor transfers tokens to project via acceptToken (simulated admin flow)
        vm.prank(donor);
        token.approve(address(project), type(uint256).max);

        // Community admin accepts token from donor
        project.acceptToken(donor, 50_000 * 1e18);

        // Add beneficiaries to Community first
        community.addBeneficiary(ben1);
        community.addBeneficiary(ben2);

        // Add beneficiaries to project
        project.addBeneficiary(ben1);
        project.addBeneficiary(ben2);
    }

    function test_InitialState() public view {
        assertEq(project.defaultToken(), address(token));
        assertEq(project.otpServerAddress(), otpServer);
        assertTrue(project.isDonor(donor));
        assertEq(token.balanceOf(address(project)), 50_000 * 1e18);
    }

    // ==========================================
    // CLAIM ASSIGNMENT TESTS (O(1) & NON-DOUBLE-COUNTING)
    // ==========================================

    function test_AssignClaims_Success() public {
        project.assignClaims(ben1, 1_000 * 1e18);
        assertEq(project.beneficiaryClaims(ben1), 1_000 * 1e18);
        assertEq(project.totalClaimsAssgined(), 1_000 * 1e18);
    }

    function test_AssignClaims_ReassignmentDoesNotDoubleCount() public {
        project.assignClaims(ben1, 1_000 * 1e18);
        assertEq(project.totalClaimsAssgined(), 1_000 * 1e18);

        // Reassigning same amount should succeed and not require extra balance
        project.assignClaims(ben1, 1_000 * 1e18);
        assertEq(project.beneficiaryClaims(ben1), 1_000 * 1e18);
        assertEq(project.totalClaimsAssgined(), 1_000 * 1e18);

        // Adjusting upwards
        project.assignClaims(ben1, 1_500 * 1e18);
        assertEq(project.beneficiaryClaims(ben1), 1_500 * 1e18);
        assertEq(project.totalClaimsAssgined(), 1_500 * 1e18);
    }

    function test_RemoveBeneficiaryZerosClaim() public {
        project.assignClaims(ben1, 1_000 * 1e18);
        assertEq(project.beneficiaryClaims(ben1), 1_000 * 1e18);

        project.removeBeneficiary(ben1);
        assertEq(project.beneficiaryClaims(ben1), 0);
        assertEq(project.totalClaimsAssgined(), 0);
    }

    // ==========================================
    // VENDOR ALLOWANCE & TOTAL ALLOCATION RECOVERY
    // ==========================================

    function test_VendorAllowanceAllocationLifecycle() public {
        project.assignClaims(ben1, 5_000 * 1e18);

        // Admin allocates to vendor
        project.sendAllowanceToVendor(vendor1, 2_000 * 1e18);
        assertEq(project.vendorAllowance(vendor1), 2_000 * 1e18);
        assertEq(project.totalVendorAllocation(), 2_000 * 1e18);

        // Lock project for aid distribution
        vm.prank(donor);
        project.lockProject();
        assertTrue(project.isLocked());

        // Process offline voucher distribution via otpServer
        vm.prank(otpServer);
        project.sendBeneficiaryTokenToVendor(ben1, vendor1, 1_000 * 1e18);

        // Vendor received tokens
        assertEq(token.balanceOf(vendor1), 1_000 * 1e18);
        assertEq(project.beneficiaryClaims(ben1), 4_000 * 1e18);
        assertEq(project.vendorAllowance(vendor1), 1_000 * 1e18);

        // CRITICAL FIX VERIFICATION: totalVendorAllocation MUST decrease on claim
        assertEq(project.totalVendorAllocation(), 1_000 * 1e18);

        // Process remaining 1,000 allowance
        vm.prank(otpServer);
        project.sendBeneficiaryTokenToVendor(ben1, vendor1, 1_000 * 1e18);

        assertEq(project.vendorAllowance(vendor1), 0);
        assertEq(project.totalVendorAllocation(), 0);
        assertEq(token.balanceOf(vendor1), 2_000 * 1e18);
    }

    // ==========================================
    // BATCH OFFLINE VENDOR TRANSACTIONS (DISASTER RELIEF)
    // ==========================================

    function test_SendBeneficiaryTokenToVendorBatch_Success() public {
        project.assignClaims(ben1, 3_000 * 1e18);
        project.assignClaims(ben2, 2_000 * 1e18);

        project.sendAllowanceToVendor(vendor1, 3_000 * 1e18);
        project.sendAllowanceToVendor(vendor2, 2_000 * 1e18);

        vm.prank(donor);
        project.lockProject();

        address[] memory bens = new address[](2);
        bens[0] = ben1;
        bens[1] = ben2;

        address[] memory vendors = new address[](2);
        vendors[0] = vendor1;
        vendors[1] = vendor2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_500 * 1e18;
        amounts[1] = 1_000 * 1e18;

        vm.prank(otpServer);
        project.sendBeneficiaryTokenToVendorBatch(bens, vendors, amounts);

        assertEq(token.balanceOf(vendor1), 1_500 * 1e18);
        assertEq(token.balanceOf(vendor2), 1_000 * 1e18);
        assertEq(project.beneficiaryClaims(ben1), 1_500 * 1e18);
        assertEq(project.beneficiaryClaims(ben2), 1_000 * 1e18);
        assertEq(project.totalVendorAllocation(), 2_500 * 1e18);
    }

    function test_RevertWhen_BatchCallerNotOtpServer() public {
        project.assignClaims(ben1, 1_000 * 1e18);
        project.sendAllowanceToVendor(vendor1, 1_000 * 1e18);

        vm.prank(donor);
        project.lockProject();

        address[] memory bens = new address[](1);
        bens[0] = ben1;
        address[] memory vendors = new address[](1);
        vendors[0] = vendor1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 500 * 1e18;

        vm.prank(ben1);
        vm.expectRevert("unauthorized");
        project.sendBeneficiaryTokenToVendorBatch(bens, vendors, amounts);
    }

    function test_RevertWhen_BatchLengthMismatch() public {
        vm.prank(donor);
        project.lockProject();

        address[] memory bens = new address[](2);
        bens[0] = ben1;
        bens[1] = ben2;
        address[] memory vendors = new address[](1);
        vendors[0] = vendor1;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500 * 1e18;
        amounts[1] = 500 * 1e18;

        vm.prank(otpServer);
        vm.expectRevert("length mismatch");
        project.sendBeneficiaryTokenToVendorBatch(bens, vendors, amounts);
    }

    // ==========================================
    // ACCESS CONTROL & ONLYLOCKED GUARDS
    // ==========================================

    function test_RevertWhen_TokenRequestWhenUnlocked() public {
        // Project is unlocked initially
        assertFalse(project.isLocked());

        vm.expectRevert("project unlocked");
        project.initiateTokenRequestForVendor(vendor1, ben1, 100 * 1e18);

        vm.expectRevert("project unlocked");
        project.processTokenRequestForVendor(vendor1, ben1, "123456");
    }

    // ==========================================
    // FUZZ TESTING
    // ==========================================

    function testFuzz_AssignAndAdjustClaims(uint256 initialAmount, uint256 newAmount) public {
        uint256 maxBalance = 25_000 * 1e18;
        initialAmount = bound(initialAmount, 1, maxBalance);
        newAmount = bound(newAmount, 0, maxBalance);

        project.assignClaims(ben1, initialAmount);
        assertEq(project.beneficiaryClaims(ben1), initialAmount);

        project.assignClaims(ben1, newAmount);
        assertEq(project.beneficiaryClaims(ben1), newAmount);
    }

    function testFuzz_VendorAllowanceAndClaims(uint256 allowance, uint256 claimAmt) public {
        uint256 maxAmount = 10_000 * 1e18;
        allowance = bound(allowance, 1 * 1e18, maxAmount);
        claimAmt = bound(claimAmt, 1, allowance);

        project.assignClaims(ben1, allowance);
        project.sendAllowanceToVendor(vendor1, allowance);
        assertEq(project.totalVendorAllocation(), allowance);

        vm.prank(donor);
        project.lockProject();

        vm.prank(otpServer);
        project.sendBeneficiaryTokenToVendor(ben1, vendor1, claimAmt);

        assertEq(project.totalVendorAllocation(), allowance - claimAmt);
        assertEq(project.vendorAllowance(vendor1), allowance - claimAmt);
        assertEq(token.balanceOf(vendor1), claimAmt);
    }
}
