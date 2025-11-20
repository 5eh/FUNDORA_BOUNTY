// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./fundoraV4Lib.sol";

/**
 * @title Chainlink Price Feed Interface
 * @notice Interface for reading ETH/USD prices from Chainlink oracles
 */
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );

    function decimals() external view returns (uint8);
}

contract FundoraLending is ERC721, Ownable, ReentrancyGuard {
    using ManagerLib for ManagerLib.ManagerData;

    // Constants
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant BP = 10000;
    uint256 private constant MAX_PAYOFF_BUFFER_BPS = 50;
    uint256 private constant MAX_INTEREST_RATE_BPS = 5000;
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 1000;

    enum LoanStatus {
        Pending,
        Active,
        PaidOff,
        Rejected,
        ForceClosed
    }

    struct LoanRequest {
        address debtor;
        address creditor;
        address token;
        uint256 amount;
        uint256 interestRate;
        uint256 duration;
        uint256 expiry;
        string description;
    }

    struct Loan {
        LoanRequest request;
        LoanStatus status;
        address actualCreditor;
        uint256 startTime;
        uint256 amountPaid;
        uint256 lastPayment;
    }

    // State
    mapping(uint256 => Loan) public loans;
    uint256 public currentLoanId;
    uint256 public protocolFee = 100;
    mapping(address => uint256) public accumulatedFees;
    mapping(address => uint256) public accumulatedETHFees;
    ManagerLib.ManagerData private managerData;

    // Chainlink Price Feed for ETH/USD
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    // Events
    event LoanRequested(
        uint256 indexed loanId,
        address indexed debtor,
        address indexed creditor,
        uint256 amount,
        uint256 interestRate
    );
    event LoanAccepted(
        uint256 indexed loanId,
        address indexed creditor,
        uint256 timestamp
    );
    event LoanPaid(
        uint256 indexed loanId,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 protocolFee,
        bool paidInETH
    );
    event LoanCompleted(
        uint256 indexed loanId,
        uint256 totalPrincipal,
        uint256 totalInterest
    );
    event LoanRejected(uint256 indexed loanId, address indexed rejectedBy);
    event ProtocolFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(
        address indexed token,
        uint256 amount,
        address indexed recipient
    );
    event ETHFeesWithdrawn(uint256 amount, address indexed recipient);
    event LoanTermsUpdated(
        uint256 indexed loanId,
        uint256 newInterestRate,
        uint256 newDuration,
        address indexed updatedBy
    );
    event LoanForceCompleted(
        uint256 indexed loanId,
        address indexed completedBy,
        string reason
    );
    event LoanForceDeleted(
        uint256 indexed loanId,
        address indexed deletedBy,
        string reason
    );

    // Errors
    error InvalidAmount();
    error InvalidInterestRate();
    error InvalidDuration();
    error InvalidExpiry();
    error LoanNotPending();
    error LoanExpired();
    error NotAuthorized();
    error LoanNotActive();
    error NotDebtor();
    error ZeroPayment();
    error PaymentTooLarge();
    error PaymentExceedsBuffer();
    error TransferFailed();
    error InvalidProtocolFee();
    error DebtNFTNonTransferable();
    error DebtNFTCannotApprove();
    error LoanNotPaidOff();
    error InvalidLoanStatus();
    error InsufficientETHSent();
    error ETHRefundFailed();
    error InvalidPrice();

    modifier onlyManager() {
        managerData.check(msg.sender, owner());
        _;
    }

    /**
     * @notice Initialize the contract with Chainlink price feed
     * @dev Uses Sepolia testnet ETH/USD feed by default
     * For mainnet, change to: 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
     */
    constructor()
        ERC721("Fundora FACT Obligation", "FACT")
        Ownable(msg.sender)
    {
        ethUsdPriceFeed = AggregatorV3Interface(
            0x694AA1769357215DE4FAC081bf1f309aDC325306
        );
    }

    receive() external payable {}

    // ============================================
    // MANAGER FUNCTIONS
    // ============================================

    function addManager(address manager) external onlyOwner {
        managerData.add(manager, owner());
    }

    function removeManager(address manager) external onlyOwner {
        managerData.remove(manager);
    }

    function getManagers() external view returns (address[] memory) {
        return managerData.list;
    }

    function isManager(address account) external view returns (bool) {
        return managerData.isManager[account];
    }

    function updateLoanTerms(
        uint256 loanId,
        uint256 newInterestRate,
        uint256 newDuration
    ) external onlyManager {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Pending) revert InvalidLoanStatus();
        if (newInterestRate > MAX_INTEREST_RATE_BPS)
            revert InvalidInterestRate();
        if (newDuration == 0) revert InvalidDuration();

        loan.request.interestRate = newInterestRate;
        loan.request.duration = newDuration;
        emit LoanTermsUpdated(loanId, newInterestRate, newDuration, msg.sender);
    }

    /**
     * @notice Force complete loan and burn NFT (admin/manager only)
     * @param loanId The loan ID to force complete
     * @param reason Reason for force completion
     */
    function forceCompleteLoan(
        uint256 loanId,
        string calldata reason
    ) external onlyManager {
        Loan storage loan = loans[loanId];
        if (
            loan.status != LoanStatus.Active &&
            loan.status != LoanStatus.Pending
        ) revert InvalidLoanStatus();

        loan.status = LoanStatus.PaidOff;
        loan.amountPaid = loan.request.amount;

        if (_ownerOf(loanId) != address(0)) _burn(loanId);

        emit LoanForceCompleted(loanId, msg.sender, reason);
        emit LoanCompleted(loanId, loan.request.amount, 0);
    }

    /**
     * @notice Completely delete/terminate a loan and remove NFT (admin/manager only)
     * @param loanId The loan ID to delete
     * @param reason Reason for deletion
     */
    function forceDeleteLoan(
        uint256 loanId,
        string calldata reason
    ) external onlyManager {
        Loan storage loan = loans[loanId];
        address nftOwner = _ownerOf(loanId);

        loan.status = LoanStatus.ForceClosed;

        if (nftOwner != address(0)) _burn(loanId);

        emit LoanForceDeleted(loanId, msg.sender, reason);
    }

    function cancelLoanRequest(uint256 loanId) external onlyManager {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Pending) revert LoanNotPending();
        loan.status = LoanStatus.Rejected;
        emit LoanRejected(loanId, msg.sender);
    }

    // ============================================
    // CORE LOAN FUNCTIONS
    // ============================================

    function requestLoan(
        address creditor,
        address token,
        uint256 amount,
        uint256 interestRate,
        uint256 duration,
        uint256 expiry,
        string memory description
    ) external returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        if (interestRate > MAX_INTEREST_RATE_BPS) revert InvalidInterestRate();
        if (duration == 0) revert InvalidDuration();
        if (expiry <= block.timestamp) revert InvalidExpiry();

        uint256 loanId = currentLoanId++;
        loans[loanId] = Loan({
            request: LoanRequest(
                msg.sender,
                creditor,
                token,
                amount,
                interestRate,
                duration,
                expiry,
                description
            ),
            status: LoanStatus.Pending,
            actualCreditor: address(0),
            startTime: 0,
            amountPaid: 0,
            lastPayment: 0
        });

        emit LoanRequested(loanId, msg.sender, creditor, amount, interestRate);
        return loanId;
    }

    function acceptLoan(uint256 loanId) external nonReentrant {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Pending) revert LoanNotPending();
        if (block.timestamp > loan.request.expiry) revert LoanExpired();
        if (
            loan.request.creditor != address(0) &&
            loan.request.creditor != msg.sender
        ) revert NotAuthorized();

        loan.status = LoanStatus.Active;
        loan.actualCreditor = msg.sender;
        loan.startTime = block.timestamp;
        loan.lastPayment = block.timestamp;

        _mint(loan.request.debtor, loanId);

        if (
            !IERC20(loan.request.token).transferFrom(
                msg.sender,
                loan.request.debtor,
                loan.request.amount
            )
        ) revert TransferFailed();

        emit LoanAccepted(loanId, msg.sender, block.timestamp);
    }

    function rejectLoan(uint256 loanId) external {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Pending) revert LoanNotPending();
        if (
            loan.request.creditor != address(0) &&
            loan.request.creditor != msg.sender
        ) revert NotAuthorized();

        loan.status = LoanStatus.Rejected;
        emit LoanRejected(loanId, msg.sender);
    }

    // ============================================
    // PAYMENT FUNCTIONS - ERC20
    // ============================================

    function payLoan(
        uint256 loanId,
        uint256 paymentAmount
    ) external nonReentrant {
        _processPayment(loanId, paymentAmount, false);
    }

    function payoffLoan(
        uint256 loanId,
        uint256 maxPayment
    ) external nonReentrant {
        _processPayoff(loanId, maxPayment, false);
    }

    // ============================================
    // PAYMENT FUNCTIONS - ETH
    // ============================================

    /**
     * @notice Pay loan installment with ETH
     * @param loanId The loan ID to pay
     */
    function payLoanWithETH(uint256 loanId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroPayment();

        // Convert ETH value to WYST equivalent using Chainlink price feed
        uint256 wystEquivalent = _convertETHtoWYST(msg.value);

        _processPayment(loanId, wystEquivalent, true);
    }

    /**
     * @notice Pay off entire loan with ETH
     * @param loanId The loan ID to pay off
     */
    function payoffLoanWithETH(uint256 loanId) external payable nonReentrant {
        if (msg.value == 0) revert ZeroPayment();

        // Convert ETH value to WYST equivalent using Chainlink price feed
        uint256 wystEquivalent = _convertETHtoWYST(msg.value);

        _processPayoff(loanId, wystEquivalent, true);
    }

    // ============================================
    // INTERNAL PAYMENT LOGIC
    // ============================================

    function _processPayment(
        uint256 loanId,
        uint256 paymentAmount,
        bool isETH
    ) internal {
        if (paymentAmount == 0) revert ZeroPayment();

        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active) revert LoanNotActive();
        if (msg.sender != loan.request.debtor) revert NotDebtor();

        uint256 totalDue = getTotalDue(loanId);
        if (paymentAmount > totalDue) revert PaymentTooLarge();

        uint256 remainingPrincipal = loan.request.amount - loan.amountPaid;
        uint256 interest = _calcInterest(
            remainingPrincipal,
            loan.request.interestRate,
            block.timestamp - loan.lastPayment
        );

        uint256 interestPayment = paymentAmount > interest
            ? interest
            : paymentAmount;
        uint256 principalPayment = paymentAmount - interestPayment;
        uint256 feeAmount = (interestPayment * protocolFee) / BP;
        uint256 creditorAmount = paymentAmount - feeAmount;

        loan.amountPaid += principalPayment;
        loan.lastPayment = block.timestamp;

        bool fullPaid = loan.amountPaid >= loan.request.amount &&
            interestPayment == interest;
        if (fullPaid) loan.status = LoanStatus.PaidOff;

        if (isETH) {
            // ETH payment - convert back to ETH for distribution
            uint256 ethCreditorAmount = _convertWYSTtoETH(creditorAmount);
            uint256 ethFeeAmount = msg.value - ethCreditorAmount;

            if (ethFeeAmount > 0)
                accumulatedETHFees[loan.request.token] += ethFeeAmount;

            (bool success, ) = loan.actualCreditor.call{
                value: ethCreditorAmount
            }("");
            if (!success) revert TransferFailed();
        } else {
            // ERC20 payment
            if (feeAmount > 0) accumulatedFees[loan.request.token] += feeAmount;
            if (
                !IERC20(loan.request.token).transferFrom(
                    msg.sender,
                    address(this),
                    paymentAmount
                )
            ) revert TransferFailed();
            if (
                creditorAmount > 0 &&
                !IERC20(loan.request.token).transfer(
                    loan.actualCreditor,
                    creditorAmount
                )
            ) revert TransferFailed();
        }

        emit LoanPaid(
            loanId,
            principalPayment,
            interestPayment,
            feeAmount,
            isETH
        );

        if (fullPaid) {
            _burn(loanId);
            emit LoanCompleted(loanId, loan.request.amount, interestPayment);
        }
    }

    function _processPayoff(
        uint256 loanId,
        uint256 wystEquivalentPayment,
        bool isETH
    ) internal {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active) revert LoanNotActive();
        if (msg.sender != loan.request.debtor) revert NotDebtor();

        uint256 remainingPrincipal = loan.request.amount - loan.amountPaid;
        uint256 interest = _calcInterest(
            remainingPrincipal,
            loan.request.interestRate,
            block.timestamp - loan.lastPayment
        );
        uint256 totalDue = remainingPrincipal + interest;

        if (
            wystEquivalentPayment >
            totalDue + ((totalDue * MAX_PAYOFF_BUFFER_BPS) / BP)
        ) revert PaymentExceedsBuffer();
        if (totalDue > wystEquivalentPayment) revert PaymentTooLarge();

        uint256 feeAmount = (interest * protocolFee) / BP;
        uint256 creditorAmount = totalDue - feeAmount;

        loan.amountPaid = loan.request.amount;
        loan.lastPayment = block.timestamp;
        loan.status = LoanStatus.PaidOff;

        if (isETH) {
            // ETH payment - convert back to ETH for distribution
            uint256 ethTotalDue = _convertWYSTtoETH(totalDue);
            uint256 ethCreditorAmount = _convertWYSTtoETH(creditorAmount);
            uint256 ethFeeAmount = ethTotalDue - ethCreditorAmount;

            if (ethFeeAmount > 0)
                accumulatedETHFees[loan.request.token] += ethFeeAmount;

            (bool success, ) = loan.actualCreditor.call{
                value: ethCreditorAmount
            }("");
            if (!success) revert TransferFailed();

            // Refund excess ETH
            if (msg.value > ethTotalDue) {
                (bool refundSuccess, ) = msg.sender.call{
                    value: msg.value - ethTotalDue
                }("");
                if (!refundSuccess) revert ETHRefundFailed();
            }
        } else {
            // ERC20 payment
            if (feeAmount > 0) accumulatedFees[loan.request.token] += feeAmount;
            if (
                !IERC20(loan.request.token).transferFrom(
                    msg.sender,
                    address(this),
                    totalDue
                )
            ) revert TransferFailed();
            if (
                creditorAmount > 0 &&
                !IERC20(loan.request.token).transfer(
                    loan.actualCreditor,
                    creditorAmount
                )
            ) revert TransferFailed();
        }

        _burn(loanId);
        emit LoanPaid(loanId, remainingPrincipal, interest, feeAmount, isETH);
        emit LoanCompleted(loanId, loan.request.amount, interest);
    }

    // ============================================
    // PRICE CONVERSION HELPERS
    // ============================================

    /**
     * @notice Convert WYST amount to ETH amount using Chainlink price feed
     * @dev Assumes 1 WYST = 1 USD (stablecoin)
     * @param wystAmount Amount of WYST tokens (18 decimals)
     * @return ethAmount Equivalent amount in ETH (18 decimals)
     */
    function _convertWYSTtoETH(
        uint256 wystAmount
    ) internal view returns (uint256) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();

        // Price has 8 decimals, wystAmount has 18 decimals
        // Formula: (wystAmount * 1e8) / price
        // Result will be in 18 decimals (ETH amount)
        return (wystAmount * 1e8) / uint256(price);
    }

    /**
     * @notice Convert ETH amount to WYST amount using Chainlink price feed
     * @dev Assumes 1 WYST = 1 USD (stablecoin)
     * @param ethAmount Amount of ETH (18 decimals)
     * @return wystAmount Equivalent amount in WYST (18 decimals)
     */
    function _convertETHtoWYST(
        uint256 ethAmount
    ) internal view returns (uint256) {
        (, int256 price, , , ) = ethUsdPriceFeed.latestRoundData();
        if (price <= 0) revert InvalidPrice();

        // Price has 8 decimals, ethAmount has 18 decimals
        // Formula: (ethAmount * price) / 1e8
        // Result will be in 18 decimals (WYST amount)
        return (ethAmount * uint256(price)) / 1e8;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    function getPayoffAmount(uint256 loanId) external view returns (uint256) {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active) return 0;
        uint256 principal = loan.request.amount - loan.amountPaid;
        if (principal == 0) return 0;
        return
            principal +
            _calcInterest(
                principal,
                loan.request.interestRate,
                block.timestamp - loan.lastPayment
            );
    }

    /**
     * @notice Get payoff amount in ETH using real-time Chainlink price feed
     * @param loanId The loan ID
     * @return ethAmount Amount of ETH needed to pay off the loan
     */
    function getPayoffAmountInETH(
        uint256 loanId
    ) external view returns (uint256) {
        uint256 wystAmount = this.getPayoffAmount(loanId);
        return _convertWYSTtoETH(wystAmount);
    }

    function getTotalDue(uint256 loanId) public view returns (uint256) {
        Loan storage loan = loans[loanId];
        if (loan.status != LoanStatus.Active) return 0;
        uint256 principal = loan.request.amount - loan.amountPaid;
        if (principal == 0) return 0;
        return
            principal +
            _calcInterest(
                principal,
                loan.request.interestRate,
                block.timestamp - loan.lastPayment
            );
    }

    /**
     * @notice Get total due in ETH using real-time Chainlink price feed
     * @param loanId The loan ID
     * @return ethAmount Amount of ETH currently due
     */
    function getTotalDueInETH(uint256 loanId) external view returns (uint256) {
        uint256 wystAmount = getTotalDue(loanId);
        return _convertWYSTtoETH(wystAmount);
    }

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    function getPendingLoans() external view returns (uint256[] memory) {
        uint256 count;
        for (uint256 i = 0; i < currentLoanId; i++) {
            if (
                loans[i].status == LoanStatus.Pending &&
                block.timestamp <= loans[i].request.expiry
            ) count++;
        }

        uint256[] memory pending = new uint256[](count);
        uint256 idx;
        for (uint256 i = 0; i < currentLoanId; i++) {
            if (
                loans[i].status == LoanStatus.Pending &&
                block.timestamp <= loans[i].request.expiry
            ) {
                pending[idx++] = i;
            }
        }
        return pending;
    }

    function getRecommendedMaxPayment(
        uint256 loanId
    ) external view returns (uint256) {
        uint256 payoff = this.getPayoffAmount(loanId);
        return payoff + ((payoff * MAX_PAYOFF_BUFFER_BPS) / BP);
    }

    /**
     * @notice Get recommended max payment in ETH with buffer
     * @param loanId The loan ID
     * @return ethAmount Recommended max ETH to send (includes 0.5% buffer)
     */
    function getRecommendedMaxPaymentInETH(
        uint256 loanId
    ) external view returns (uint256) {
        uint256 wystAmount = this.getRecommendedMaxPayment(loanId);
        return _convertWYSTtoETH(wystAmount);
    }

    /**
     * @notice Get current ETH/USD price from Chainlink
     * @return price ETH price in USD with 8 decimals
     * @return decimals Number of decimals in the price
     */
    function getETHPrice()
        external
        view
        returns (int256 price, uint8 decimals)
    {
        (, price, , , ) = ethUsdPriceFeed.latestRoundData();
        decimals = ethUsdPriceFeed.decimals();
        return (price, decimals);
    }

    function _calcInterest(
        uint256 principal,
        uint256 rate,
        uint256 time
    ) internal pure returns (uint256) {
        return (principal * rate * time) / (BP * SECONDS_PER_YEAR);
    }

    // ============================================
    // ADMIN FUNCTIONS
    // ============================================

    function setProtocolFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_PROTOCOL_FEE_BPS) revert InvalidProtocolFee();
        emit ProtocolFeeUpdated(protocolFee, newFee);
        protocolFee = newFee;
    }

    function withdrawFees(address token) external onlyOwner {
        uint256 amount = accumulatedFees[token];
        if (amount > 0) {
            accumulatedFees[token] = 0;
            if (!IERC20(token).transfer(owner(), amount))
                revert TransferFailed();
            emit FeesWithdrawn(token, amount, owner());
        }
    }

    function withdrawETHFees(address token) external onlyOwner {
        uint256 amount = accumulatedETHFees[token];
        if (amount > 0) {
            accumulatedETHFees[token] = 0;
            (bool success, ) = owner().call{value: amount}("");
            if (!success) revert TransferFailed();
            emit ETHFeesWithdrawn(amount, owner());
        }
    }

    // ============================================
    // NFT SECURITY
    // ============================================

    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from == address(0)) return super._update(to, tokenId, auth);
        if (to == address(0)) {
            if (
                loans[tokenId].status != LoanStatus.PaidOff &&
                loans[tokenId].status != LoanStatus.ForceClosed
            ) {
                revert LoanNotPaidOff();
            }
            return super._update(to, tokenId, auth);
        }
        revert DebtNFTNonTransferable();
    }

    function approve(address, uint256) public pure override {
        revert DebtNFTCannotApprove();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert DebtNFTCannotApprove();
    }

    function tokenURI(
        uint256 tokenId
    ) public view override returns (string memory) {
        _requireOwned(tokenId);
        Loan storage loan = loans[tokenId];
        return
            string(
                abi.encodePacked(
                    'data:application/json,{"name":"Fundora FACT #',
                    _toString(tokenId),
                    '","description":"Debt obligation of ',
                    _toString(loan.request.amount),
                    " at ",
                    _toString(loan.request.interestRate / 100),
                    '% APR"}'
                )
            );
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
