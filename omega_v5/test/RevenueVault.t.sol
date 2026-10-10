// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "../src/RevenueVault.sol";
interface Vm {function prank(address) external;function expectRevert() external;function createSelectFork(string calldata) external returns(uint256);function envString(string calldata) external returns(string memory);}
contract MockUSDC {
 uint8 public constant decimals=6;
 mapping(address=>uint256) public balanceOf; mapping(address=>mapping(address=>uint256)) public allowance;
 function mint(address to,uint256 n) external {balanceOf[to]+=n;}
 function approve(address to,uint256 n) external returns(bool){allowance[msg.sender][to]=n;return true;}
 function transfer(address to,uint256 n) external returns(bool){require(balanceOf[msg.sender]>=n);balanceOf[msg.sender]-=n;balanceOf[to]+=n;return true;}
 function transferFrom(address from,address to,uint256 n) external returns(bool){require(allowance[from][msg.sender]>=n);allowance[from][msg.sender]-=n;require(balanceOf[from]>=n);balanceOf[from]-=n;balanceOf[to]+=n;return true;}
}
contract RevenueVaultTest {
 Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
 uint256 constant U=1e6;address constant customer=address(0xBEEF);address constant vendor=address(0xCAFE);
 MockUSDC token; RevenueVault vault;
 function setUp() public {token=new MockUSDC();vault=new RevenueVault(address(token));token.mint(address(this),10000*U);token.mint(customer,150*U);token.approve(address(vault),10000*U);vault.seed(10000*U);vm.prank(customer);token.approve(address(vault),150*U);}
 function testSelfFundingNotProfit() public {require(vault.hardNAV()==10000*U);vm.expectRevert();vault.distribute(U);}
 function testExternalFees() public {vm.prank(customer);vault.pay(150*U,0);vault.payExpense(vendor,15*U);require(vault.hardNAV()==10135*U);vault.distribute(40500000);require(vault.hardNAV()==10094500000);}
 function testRefundLiability() public {vm.prank(customer);vault.pay(100*U,70*U);require(vault.hardNAV()==10030*U);vm.prank(customer);vault.refund(70*U);require(vault.hardNAV()==10030*U);}
 function testOwnerCannotFakeCustomer() public {vm.expectRevert();vault.pay(U,0);}
}
contract BaseForkSmoke {
 Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
 address constant USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
 function testBaseUSDC() public {vm.createSelectFork(vm.envString("BASE_RPC_URL"));require(block.chainid==8453);require(IUSDC(USDC).decimals()==6);RevenueVault v=new RevenueVault(USDC);require(v.hardNAV()==0);}
}