// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IUSDC {function balanceOf(address) external view returns(uint256);function transferFrom(address,address,uint256) external returns(bool);function transfer(address,uint256) external returns(bool);function decimals() external view returns(uint8);}
contract RevenueVault {
 IUSDC public immutable usd; address public immutable owner;
 uint256 public principal; uint256 public recognizedRevenue; uint256 public expenses; uint256 public distributions;uint256 private busy;
 mapping(address=>uint256) public refundsDue; uint256 public aggregateRefunds;
 modifier onlyOwner(){require(msg.sender==owner,"owner");_;}
 modifier nonReentrant(){require(busy==0,"reentrant");busy=1;_;busy=0;}
 constructor(address token){usd=IUSDC(token);require(usd.decimals()==6,"decimals");owner=msg.sender;}
 function seed(uint256 n) external onlyOwner nonReentrant {require(n>0);_pull(msg.sender,n);principal+=n;}
 function pay(uint256 gross,uint256 refundable) external nonReentrant {require(msg.sender!=owner&&gross>0&&refundable<=gross,"payer");_pull(msg.sender,gross);recognizedRevenue+=gross-refundable;refundsDue[msg.sender]+=refundable;aggregateRefunds+=refundable;}
 function refund(uint256 n) external nonReentrant {require(n>0&&refundsDue[msg.sender]>=n,"due");refundsDue[msg.sender]-=n;aggregateRefunds-=n;_send(msg.sender,n);}
 function payExpense(address to,uint256 n) external onlyOwner nonReentrant {require(n>0&&to!=address(0));expenses+=n;require(usd.balanceOf(address(this))>=principal+aggregateRefunds+n,"encumbered");_send(to,n);}
 function distribute(uint256 n) external onlyOwner nonReentrant {require(n>0&&recognizedRevenue>=expenses+distributions+n,"unearned");require(usd.balanceOf(address(this))>=principal+aggregateRefunds+n,"encumbered");distributions+=n;_send(owner,n);}
 function hardNAV() external view returns(uint256){uint b=usd.balanceOf(address(this));require(b>=aggregateRefunds,"insolvent");return b-aggregateRefunds;}
 function _pull(address a,uint n) internal {require(usd.transferFrom(a,address(this),n),"pull");}
 function _send(address a,uint n) internal {require(usd.transfer(a,n),"send");}
}
