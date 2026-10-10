// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import '../src/OmegaVault.sol';
interface Vm { function createSelectFork(string calldata) external returns(uint256); function envString(string calldata) external returns(string memory); function expectRevert() external; }
contract BaseForkTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256('hevm cheat code')))));
    address constant BASE_USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    function testForkNativeUSDCAndNoProfitFromInternalCycles() public {
        vm.createSelectFork(vm.envString('BASE_RPC_URL'));
        require(block.chainid==8453,'wrong chain');
        require(IERC20Like(BASE_USDC).decimals()==6,'wrong USDC');
        OmegaVault v=new OmegaVault(BASE_USDC);
        require(v.hardNAV()==0,'unexpected balance');
        for(uint i=0;i<6;i++) v.internalMoveNoProfit(0);
        require(v.recognizedExternalRevenue()==0,'fictional profit');
        vm.expectRevert();v.withdrawProfit(1);
    }
}
