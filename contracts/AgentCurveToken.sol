// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

interface IAgentId { function balanceOf(address owner) external view returns (uint256); }
interface IPancakeFactory {
    function getPair(address a, address b) external view returns (address);
    function createPair(address a, address b) external returns (address);
}
interface IPancakePair {
    function mint(address to) external returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
}
interface IWBNB {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

/// Bonding-curve token that only Binance Agentic Wallets (SPACE ID Agent ID holders) can buy.
/// Curve (sato-style, exponential): minted supply m at curve reserve e is m(e) = K * (1 - exp(-e / S)),
/// marginal price p(m) = S / (K - m). Buys and sells move along the curve; sells redeem from the reserve.
/// When the reserve reaches GRAD_RESERVE the whole reserve plus the remaining K - m tokens are put into a
/// PancakeSwap V2 pool and the LP is burned. Because GRAD_RESERVE == S, the pool opens exactly at the
/// curve's last marginal price and total supply ends at exactly K.
/// Tokens cannot be transferred before graduation (only minted/burned), so nobody can seed the pair early.
/// After graduation every transfer into or out of the pair pays the same 0.1% fee (in tokens) to feeTo;
/// wallet-to-wallet transfers are free. Sells through the router need the *SupportingFeeOnTransferTokens functions.
/// No owner, no admin functions.
contract AgentCurveToken is ERC20, ReentrancyGuard {
    uint256 public constant K = 21_000_000 ether;      // total supply after graduation
    uint256 public constant S = 100 ether;             // curve scale, in BNB
    uint256 public constant GRAD_RESERVE = 100 ether;  // must equal S for a seamless pool price
    uint256 public constant MAX_BUY = 0.1 ether;       // per transaction, BNB
    uint256 public constant FEE_BPS = 10;              // 0.1% on every curve buy and sell
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IAgentId public immutable agentId;
    IPancakeFactory public immutable factory;
    address public immutable wbnb;
    address public immutable feeTo;
    uint256 public immutable maxWallet;

    uint256 public reserve;      // BNB held for the curve
    bool public graduated;
    address public pair;
    mapping(address => uint256) public lastBuyBlock;

    event Buy(address indexed buyer, uint256 bnbIn, uint256 tokensOut, uint256 fee, uint256 reserveAfter);
    event Sell(address indexed seller, uint256 tokensIn, uint256 bnbOut, uint256 fee, uint256 reserveAfter);
    event Graduated(address indexed pair, uint256 bnb, uint256 tokens);

    constructor(string memory name_, string memory symbol_, address agentId_, address factory_, address wbnb_, uint256 maxWalletBps)
        ERC20(name_, symbol_)
    {
        require(maxWalletBps > 0 && maxWalletBps <= 10_000, "bad maxWallet");
        agentId = IAgentId(agentId_);
        factory = IPancakeFactory(factory_);
        wbnb = wbnb_;
        feeTo = msg.sender;
        maxWallet = K * maxWalletBps / 10_000;
    }

    // ---- views ----

    function isAgent(address a) public view returns (bool) { return agentId.balanceOf(a) > 0; }

    /// BNB per token, 18 decimals: curve marginal price, or the PancakeSwap pool price after graduation
    function price() external view returns (uint256) {
        if (graduated) {
            (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
            (uint256 rt, uint256 rb) = address(this) < wbnb ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            return Math.mulDiv(rb, 1e18, rt);
        }
        return Math.mulDiv(S, 1e18, K - totalSupply());
    }

    /// tokens for `net` BNB that reaches the curve (after fee): (K - m) * (1 - exp(-net / S)), rounded down
    function curveTokensFor(uint256 net) public view returns (uint256) {
        uint256 left = K - totalSupply();
        uint256 expX = ud(net).div(ud(S)).exp().unwrap();
        return left - Math.mulDiv(left, 1e18, expX, Math.Rounding.Ceil);
    }

    /// BNB released by burning `amount`: S * ln((K - m + amount) / (K - m)), rounded down
    function curveBnbFor(uint256 amount) public view returns (uint256) {
        uint256 left = K - totalSupply();
        uint256 ratio = Math.mulDiv(left + amount, 1e18, left);
        return ud(ratio).ln().mul(ud(S)).unwrap();
    }

    /// what a buy of `bnbIn` gives right now: tokens out, BNB actually used, refund (only on the graduating buy)
    function quoteBuy(uint256 bnbIn) public view returns (uint256 tokens, uint256 used, uint256 refund) {
        uint256 fee = bnbIn * FEE_BPS / 10_000;
        uint256 net = bnbIn - fee;
        if (reserve + net > GRAD_RESERVE) {
            net = GRAD_RESERVE - reserve;
            fee = Math.mulDiv(net, FEE_BPS, 10_000 - FEE_BPS, Math.Rounding.Ceil);
            refund = bnbIn - net - fee;
        }
        return (curveTokensFor(net), net + fee, refund);
    }

    function quoteSell(uint256 amount) public view returns (uint256 bnbOut) {
        uint256 gross = curveBnbFor(amount);
        if (gross > reserve) gross = reserve;
        return gross - gross * FEE_BPS / 10_000;
    }

    // ---- curve ----

    function buy(uint256 minTokens) external payable nonReentrant returns (uint256 tokens) {
        require(!graduated, "graduated, trade on PancakeSwap");
        require(isAgent(msg.sender), "Binance Agent ID wallets only");
        require(msg.value > 0 && msg.value <= MAX_BUY, "buy must be 0 < BNB <= 0.1");

        uint256 fee = msg.value * FEE_BPS / 10_000;
        uint256 net = msg.value - fee;
        uint256 refund;
        if (reserve + net > GRAD_RESERVE) {
            net = GRAD_RESERVE - reserve;
            fee = Math.mulDiv(net, FEE_BPS, 10_000 - FEE_BPS, Math.Rounding.Ceil);
            refund = msg.value - net - fee;
        }

        tokens = curveTokensFor(net);
        require(tokens > 0 && tokens >= minTokens, "slippage");
        require(balanceOf(msg.sender) + tokens <= maxWallet, "wallet cap");

        reserve += net;
        lastBuyBlock[msg.sender] = block.number;
        _mint(msg.sender, tokens);
        emit Buy(msg.sender, net + fee, tokens, fee, reserve);

        _send(feeTo, fee);
        if (refund > 0) _send(msg.sender, refund);
        if (reserve >= GRAD_RESERVE) _graduate();
    }

    function sell(uint256 amount, uint256 minBnb) external nonReentrant returns (uint256 bnbOut) {
        require(!graduated, "graduated, trade on PancakeSwap");
        require(lastBuyBlock[msg.sender] != block.number, "cannot sell in the block you bought");
        require(amount > 0, "zero");

        uint256 gross = curveBnbFor(amount);
        if (gross > reserve) gross = reserve;
        uint256 fee = gross * FEE_BPS / 10_000;
        bnbOut = gross - fee;
        require(bnbOut >= minBnb, "slippage");

        _burn(msg.sender, amount);
        reserve -= gross;
        emit Sell(msg.sender, amount, bnbOut, fee, reserve);

        _send(feeTo, fee);
        _send(msg.sender, bnbOut);
    }

    function _graduate() internal {
        graduated = true;
        address p = factory.getPair(address(this), wbnb);
        if (p == address(0)) p = factory.createPair(address(this), wbnb);
        pair = p;

        uint256 bnb = reserve;
        uint256 tokens = K - totalSupply();
        reserve = 0;
        IWBNB(wbnb).deposit{value: bnb}();
        require(IWBNB(wbnb).transfer(p, bnb), "wbnb transfer");
        _mint(p, tokens);
        // any WBNB someone donated to the pair beforehand just joins the pool; LP goes to dead
        IPancakePair(p).mint(DEAD);
        emit Graduated(p, bnb, tokens);
    }

    function _send(address to, uint256 value) private {
        if (value == 0) return;
        (bool ok,) = to.call{value: value}("");
        require(ok, "BNB send failed");
    }

    function _update(address from, address to, uint256 value) internal override {
        require(graduated || from == address(0) || to == address(0), "transfers open after graduation");
        // after graduation: 0.1% of every PancakeSwap buy/sell (any transfer into or out of the pair), paid in tokens to feeTo
        if (graduated && from != address(0) && to != address(0) && (from == pair || to == pair)) {
            uint256 fee = value * FEE_BPS / 10_000;
            if (fee > 0) {
                super._update(from, feeTo, fee);
                value -= fee;
            }
        }
        super._update(from, to, value);
    }
}
