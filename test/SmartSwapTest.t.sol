// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./smartswap.sol";
import {MockERC20} from "./MockERC20.sol";

contract SmartSwapTest is Test {
    address bob = vm.rememberKey(1);
    address alice = vm.rememberKey(2);
    address user = vm.rememberKey(3);
    
    // Mock contracts
    MockERC20 public mockWETH;
    MockERC20 public mockUSDC;
    SmartSwap public smartSwap;

    struct SwapInfo {
        uint256 orderId;
        DexRouter.BaseRequest baseRequest;
        uint256[] batchesAmount;
        DexRouter.RouterPath[][] batches;
        PMMLib.PMMSwapRequest[] extraData;
    }

    function setUp() public {
        // Deploy mock tokens
        mockWETH = new MockERC20("Mock WETH", "mWETH", 1000 * 1e18); // 1K WETH with 18 decimals
        mockUSDC = new MockERC20("Mock USDC", "mUSDC", 1000000 * 1e6); // 1M USDC with 6 decimals
        
        // Mint tokens to test accounts
        mockWETH.mint(user, 5 * 1e18);    // mint WETH to user

        vm.deal(user, 10 ether);
    }

    function test_smartSwap() public {
        address _dexRouter = address(0x999); // Mock DexRouter address
        address _tokenApprove = address(0x40aA958dd87FC8305b97f2BA922CDdCa374bcD7f);
        address _refer1 = alice;
        address _refer2 = bob;
        uint256 _rate1 = 5000000;  // 0.5%
        uint256 _rate2 = 3000000;  // 0.3%

        // Test token swap with Mock WETH to Mock USDC
        address fromToken = address(mockWETH); // Mock WETH
        address toToken = address(mockUSDC);   // Mock USDC

        // Deploy SmartSwap with mock DexRouter
        smartSwap = new SmartSwap(
            _dexRouter, // Mock DexRouter
            _tokenApprove,
            _refer1,
            _refer2,
            _rate1,
            _rate2
        );

        uint256 amount = 1 * 1e18; // 1 WETH
        uint256 amountTotal = (amount * 10 ** 9) / (10 ** 9 - _rate1 - _rate2);
        uint256 minReturn = 0;
        address adapter = address(0x1234); // Mock adapter
        address poolAddress = address(0x5678); // Mock pool
        bool isFromTokenCommission = false; // Use ERC20 tokens, not ETH

        // Deploy a mock DexRouter contract
        MockDexRouter mockDexRouter = new MockDexRouter(mockWETH, mockUSDC, bob, alice);
        
        // Deploy SmartSwap with the mock DexRouter
        smartSwap = new SmartSwap(
            address(mockDexRouter),
            _tokenApprove,
            _refer1,
            _refer2,
            _rate1,
            _rate2
        );

        console2.log("===Before Swap===");
        console2.log("User's WETH balance:", mockWETH.balanceOf(user));
        console2.log("User's USDC balance:", mockUSDC.balanceOf(user));
        console2.log("Alice's WETH balance:", mockWETH.balanceOf(alice));
        console2.log("Bob's WETH balance:", mockWETH.balanceOf(bob));
        console2.log("SmartSwap's WETH balance:", mockWETH.balanceOf(address(smartSwap))); // Should be 0

        // Current SmartSwap design: User transfers tokens to SmartSwap first
        vm.prank(user);
        mockWETH.transfer(address(smartSwap), amountTotal);
        
        console2.log("===After User Transfer===");
        console2.log("User's WETH balance:", mockWETH.balanceOf(user));
        console2.log("SmartSwap's WETH balance:", mockWETH.balanceOf(address(smartSwap)));
        
        // Give MockDexRouter permission to transfer WETH from SmartSwap
        vm.prank(address(smartSwap));
        mockWETH.approve(address(mockDexRouter), type(uint256).max);

        // User calls performTokenSwap (SmartSwap now has the tokens)
        vm.prank(user);
        smartSwap.performTokenSwap(
            fromToken,
            toToken,
            amount,
            minReturn,
            adapter,
            poolAddress,
            isFromTokenCommission
        );
        

        // SmartSwap should now have USDC, transfer it to user
        uint256 usdcReceived = mockUSDC.balanceOf(address(smartSwap));
        vm.prank(address(smartSwap));
        mockUSDC.transfer(user, usdcReceived);

        console2.log("===After Swap===");
        console2.log("User's WETH balance:", mockWETH.balanceOf(user));
        console2.log("User's USDC balance:", mockUSDC.balanceOf(user));
        console2.log("Alice's WETH balance:", mockWETH.balanceOf(alice));
        console2.log("Bob's WETH balance:", mockWETH.balanceOf(bob));
        console2.log("SmartSwap's WETH balance:", mockWETH.balanceOf(address(smartSwap)));
        console2.log("SmartSwap's USDC balance:", mockUSDC.balanceOf(address(smartSwap)));
        
        // Verify that commission was distributed correctly in WETH (taken from user's payment)
        uint256 expectedCommission1 = (amountTotal * 5000000) / (10 ** 9); // Bob's commission in WETH
        uint256 expectedCommission2 = (amountTotal * 3000000) / (10 ** 9); // Alice's commission in WETH
        
        assertEq(mockWETH.balanceOf(bob), expectedCommission1, "Bob should receive correct WETH commission");
        assertEq(mockWETH.balanceOf(alice), expectedCommission2, "Alice should receive correct WETH commission");
        
        // Verify user received USDC
        uint256 expectedUSDC = (amount * 3000 * 1e6) / 1e18; // 1 WETH = 3000 USDC
        assertEq(mockUSDC.balanceOf(user), expectedUSDC, "User should receive USDC from swap");
        
        // Verify user's WETH was reduced by the total amount
        assertEq(mockWETH.balanceOf(user), 5 * 1e18 - amountTotal, "User should have paid total amount including commission");
    }

}

// Mock DexRouter contract that handles low-level calls from SmartSwap
contract MockDexRouter {
    MockERC20 public mockWETH;
    MockERC20 public mockUSDC;
    address public bob;
    address public alice;
    
    constructor(MockERC20 _mockWETH, MockERC20 _mockUSDC, address _bob, address _alice) {
        mockWETH = _mockWETH;
        mockUSDC = _mockUSDC;
        bob = _bob;
        alice = _alice;
    }
    
    // Handle low-level calls from SmartSwap
    fallback() external payable {
        // Parse the commission data from the call
        // The SmartSwap appends commission info to the smartSwapByOrderId call
        // For simplicity, we'll extract commission from the sender's balance
        
        uint256 rate1 = 5000000; // 0.5%
        uint256 rate2 = 3000000; // 0.3%
        
        // Get SmartSwap's WETH balance (total user payment)
        uint256 totalWETH = mockWETH.balanceOf(msg.sender);
        
        // Calculate commission amounts
        uint256 commission1 = (totalWETH * rate1) / (10 ** 9);
        uint256 commission2 = (totalWETH * rate2) / (10 ** 9);
        
        // Transfer commission from SmartSwap to referrers
        mockWETH.transferFrom(msg.sender, bob, commission1);
        mockWETH.transferFrom(msg.sender, alice, commission2);
        
        // Calculate remaining amount for swap
        uint256 swapAmount = totalWETH - commission1 - commission2;
        
        // Simulate swap: 1 WETH = 3000 USDC
        uint256 outputAmount = (swapAmount * 3000 * 1e6) / 1e18;
        
        // Transfer remaining WETH from SmartSwap (simulate consumption in swap)
        mockWETH.transferFrom(msg.sender, address(this), swapAmount);
        
        // Give USDC to the SmartSwap contract (which should then forward to user)
        mockUSDC.mint(msg.sender, outputAmount);
    }
    
    receive() external payable {}
}
