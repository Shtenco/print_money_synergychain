// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IERC20Like { function balanceOf(address) external view returns(uint256); function transferFrom(address,address,uint256) external returns(bool); function transfer(address,uint256) external returns(bool); function decimals() external view returns(uint8); }
contract OmegaVault {
    IERC20Like public immutable usdc;
    address public immutable owner;
    uint256 public principal;
    uint256 public recognizedExternalRevenue;
    uint256 public ownerWithdrawals;
    uint256 private entered;
    error NotOwner(); error BadFunding(); error Reentry();
    constructor(address token) { owner=msg.sender;usdc=IERC20Like(token);require(usdc.decimals()==6,'USDC decimals'); }
    modifier onlyOwner(){if(msg.sender!=owner)revert NotOwner();_;}
    modifier lock(){if(entered!=0)revert Reentry();entered=1;_;entered=0;}
    function fundPrincipal(uint256 amount) external onlyOwner lock { require(amount>0);_pull(msg.sender,amount);principal+=amount; }
    function payServiceFee(uint256 amount) external lock { if(msg.sender==owner||amount==0)revert BadFunding(); _pull(msg.sender,amount); recognizedExternalRevenue+=amount; }
    function internalMoveNoProfit(uint256 amount) external onlyOwner { require(amount<=usdc.balanceOf(address(this))); }
    function withdrawProfit(uint256 amount) external onlyOwner lock {
        require(amount<=recognizedExternalRevenue-ownerWithdrawals,'unearned');
        require(usdc.balanceOf(address(this))>=principal+amount,'principal at risk');
        ownerWithdrawals+=amount;require(usdc.transfer(owner,amount),'transfer');
    }
    function hardNAV() external view returns(uint256){return usdc.balanceOf(address(this));}
    function _pull(address from,uint256 amount) internal {require(usdc.transferFrom(from,address(this),amount),'transferFrom');}
}
