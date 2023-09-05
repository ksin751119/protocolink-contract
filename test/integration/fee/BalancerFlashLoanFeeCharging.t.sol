// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {SafeCast160} from 'permit2/libraries/SafeCast160.sol';
import {Router} from 'src/Router.sol';
import {DataType} from 'src/libraries/DataType.sol';
import {IAgent} from 'src/interfaces/IAgent.sol';
import {BalancerV2FlashLoanCallback, IBalancerV2FlashLoanCallback} from 'src/callbacks/BalancerV2FlashLoanCallback.sol';
import {FeeLibrary} from 'src/libraries/FeeLibrary.sol';

contract BalancerFlashLoanFeeCalculatorTest is Test {
    using SafeCast160 for uint256;

    event Charged(address indexed token, uint256 amount, bytes32 metadata);

    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address public constant BALANCER_V2_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    address public constant PERMIT2_ADDRESS = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant ANY_TO_ADDRESS = address(0);
    bytes4 public constant BALANCER_FLASHLOAN_SELECTOR =
        bytes4(keccak256(bytes('flashLoan(address,address[],uint256[],bytes)')));
    bytes4 public constant PERMIT2_TRANSFER_FROM_SELECTOR =
        bytes4(keccak256(bytes('transferFrom(address,address,uint160,address)')));
    bytes4 public constant NATIVE_FEE_SELECTOR = 0xeeeeeeee;
    uint256 public constant BPS_NOT_USED = 0;
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant FEE_RATE = 5;
    bytes32 public constant BALANCER_META_DATA = bytes32(bytes('balancer-v2:flash-loan'));
    uint256 public constant SIGNER_REFERRAL = 1;

    address public user;
    address public user2;
    IAgent public userAgent;
    address public feeCollector;
    address public flashLoanFeeCalculator;
    address public nativeFeeCalculator;
    address public permit2FeeCalculator;
    Router public router;
    IBalancerV2FlashLoanCallback public flashLoanCallback;

    // Empty arrays
    address[] public tokensReturnEmpty;
    DataType.Input[] public inputsEmpty;
    bytes[] public datasEmpty;

    function setUp() external {
        user = makeAddr('User');
        user2 = makeAddr('User2');
        feeCollector = makeAddr('FeeCollector');

        // Deploy contracts
        router = new Router(
            makeAddr('WrappedNative'),
            PERMIT2_ADDRESS,
            address(this),
            makeAddr('Pauser'),
            feeCollector
        );
        vm.prank(user);
        userAgent = IAgent(router.newAgent());
        flashLoanCallback = new BalancerV2FlashLoanCallback(address(router), BALANCER_V2_VAULT, FEE_RATE);

        vm.label(address(router), 'Router');
        vm.label(address(userAgent), 'UserAgent');
        vm.label(feeCollector, 'FeeCollector');
        vm.label(PERMIT2_ADDRESS, 'Permit2');
        vm.label(address(flashLoanCallback), 'BalancerV2FlashLoanCallback');
        vm.label(BALANCER_V2_VAULT, 'BalancerV2Vault');
        vm.label(USDC, 'USDC');
    }

    function testChargeFlashLoanFee(uint256 amount) external {
        amount = bound(amount, 0, (IERC20(USDC).balanceOf(BALANCER_V2_VAULT) * (BPS_BASE - FEE_RATE)) / BPS_BASE);

        // Encode flash loan userData
        DataType.Logic[] memory flashLoanLogics = new DataType.Logic[](1);
        flashLoanLogics[0] = _logicTransferFlashLoanAmount(address(flashLoanCallback), USDC, amount);
        bytes memory userData = abi.encode(flashLoanLogics);

        // Encode logic
        address[] memory tokens = new address[](1);
        tokens[0] = USDC;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;

        DataType.Logic[] memory logics = new DataType.Logic[](1);
        logics[0] = _logicBalancerV2FlashLoan(tokens, amounts, userData);

        _distributeToken(tokens, amounts);

        // Prepare assert data
        uint256 expectedFee = FeeLibrary.calcFeeFromAmount(amount, FEE_RATE);
        uint256 feeCollectorBalanceBefore = IERC20(USDC).balanceOf(feeCollector);

        // Execute
        if (expectedFee > 0) {
            vm.expectEmit(true, true, true, true, address(flashLoanCallback));
            emit Charged(USDC, expectedFee, BALANCER_META_DATA);
        }
        vm.prank(user);
        router.execute(datasEmpty, logics, tokensReturnEmpty, SIGNER_REFERRAL);

        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20(USDC).balanceOf(address(userAgent)), 0);
        assertEq(IERC20(USDC).balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee);
    }

    /// This test will do flash loan + send native token(inside flash loan)
    function testChargeFlashLoanFeeWithFeeScenarioInside(uint256 amount, uint256 nativeAmount) external {
        amount = bound(amount, 0, (IERC20(USDC).balanceOf(BALANCER_V2_VAULT) * (BPS_BASE - FEE_RATE)) / BPS_BASE);
        nativeAmount = bound(nativeAmount, 0, 5000 ether);

        // Encode flash loan userData
        DataType.Logic[] memory flashLoanLogics = new DataType.Logic[](2);
        flashLoanLogics[0] = _logicTransferFlashLoanAmount(address(flashLoanCallback), USDC, amount);
        flashLoanLogics[1] = _logicSendNativeToken(user2, nativeAmount);
        bytes memory userData = abi.encode(flashLoanLogics);

        // Get new logics and msg.value amount
        DataType.Logic[] memory logics = new DataType.Logic[](1);
        {
            // Encode logic
            address[] memory tokens = new address[](1);
            tokens[0] = USDC;

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;

            logics[0] = _logicBalancerV2FlashLoan(tokens, amounts, userData);

            deal(user, nativeAmount);
            _distributeToken(tokens, amounts);
        }

        // Prepare assert data
        uint256 expectedFee = FeeLibrary.calcFeeFromAmount(amount, FEE_RATE);
        uint256 feeCollectorBalanceBefore = IERC20(USDC).balanceOf(feeCollector);
        uint256 feeCollectorNativeBalanceBefore = feeCollector.balance;
        uint256 user2NativeBalanceBefore = user2.balance;

        {
            // Execute
            if (expectedFee > 0) {
                vm.expectEmit(true, true, true, true, address(flashLoanCallback));
                emit Charged(USDC, expectedFee, BALANCER_META_DATA);
            }
            vm.prank(user);
            router.execute{value: nativeAmount}(datasEmpty, logics, tokensReturnEmpty, SIGNER_REFERRAL);
        }

        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20(USDC).balanceOf(address(userAgent)), 0);
        assertEq(IERC20(USDC).balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee);
        assertEq(feeCollector.balance, feeCollectorNativeBalanceBefore);
        assertEq(user2.balance - user2NativeBalanceBefore, nativeAmount);
    }

    function _logicBalancerV2FlashLoan(
        address[] memory tokens,
        uint256[] memory amounts,
        bytes memory userData
    ) public view returns (DataType.Logic memory) {
        return
            DataType.Logic(
                BALANCER_V2_VAULT, // to
                abi.encodeWithSelector(
                    BALANCER_FLASHLOAN_SELECTOR,
                    address(flashLoanCallback),
                    tokens,
                    amounts,
                    userData
                ),
                inputsEmpty,
                DataType.WrapMode.NONE,
                address(0), // approveTo
                address(flashLoanCallback) // callback
            );
    }

    function _logicSendNativeToken(address to, uint256 amount) internal pure returns (DataType.Logic memory) {
        // Encode inputs
        DataType.Input[] memory inputs = new DataType.Input[](1);
        inputs[0].token = NATIVE;
        inputs[0].balanceBps = BPS_NOT_USED;
        inputs[0].amountOrOffset = amount;

        return
            DataType.Logic(
                to,
                new bytes(0),
                inputs,
                DataType.WrapMode.NONE,
                address(0), // approveTo
                address(0) // callback
            );
    }

    function _logicTransferFlashLoanAmount(
        address to,
        address token,
        uint256 amount
    ) internal view returns (DataType.Logic memory) {
        uint256 amountWithFee = FeeLibrary.calcAmountWithFee(amount, FEE_RATE);
        return
            DataType.Logic(
                token,
                abi.encodeWithSelector(IERC20.transfer.selector, to, amountWithFee),
                inputsEmpty,
                DataType.WrapMode.NONE,
                address(0), // approveTo
                address(0) // callback
            );
    }

    function _distributeToken(address[] memory tokens, uint256[] memory amounts) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            // Airdrop router flash loan fee to agent
            uint256 routerFee = FeeLibrary.calcFeeFromAmount(amounts[i], FEE_RATE);

            deal(tokens[i], address(userAgent), routerFee);
        }
    }
}
