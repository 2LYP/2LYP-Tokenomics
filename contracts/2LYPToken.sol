// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol'; // Allows token holders to burn tokens
import '@openzeppelin/contracts/access/Ownable.sol'; // Provides access control for owner-only functions
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol'; // Safe wrapper for ERC20 transfers

/**
 * @title 2LYP Token
 * @notice An ERC20 token with vesting, faucet, airdrop, and on-chain tokenomics initialization.
 * @dev Inherits from OpenZeppelin ERC20Burnable and Ownable. Tokenomics allocations can only be initialized once.
 */
contract TwoLYPToken is ERC20Burnable, Ownable {
    using SafeERC20 for IERC20;

    /// @notice The maximum supply cap of 2LYP tokens
    uint256 public immutable MAX_SUPPLY;

    /// @notice The list of vesting addresses
    address[] public vestingAddresses;

    /// @notice The total burned tokens
    uint256 public totalBurned;

    /// @notice Last faucet claim timestamp per address
    mapping(address => uint256) public lastFaucetClaim;

    /// @notice Cooldown time between faucet claims
    uint256 public faucetCoolDown = 1 hours;

    /// @notice Amount of tokens dispensed per faucet claim
    uint256 public faucetDrip = 100 * 10 ** 18;

    /// @notice Registered users and their airdrop claim info
    mapping(address => AirdropInfo) public airdropList;

    /// @notice Registered vesting schedules per user
    mapping(address => VestingInfo) public vestingList;

    /// @notice Flag to prevent tokenomics reinitialization
    bool public tokenomicsInitialized;

    /// @dev Represents 1 month = 30 days for vesting calculations
    uint256 public constant MONTH = 30 days;

    // === Errors ===
    error MaxSupplyExceeded(uint256 givenAmount);
    error InitSupplyGreaterThanCap(uint256 givenAmount);
    error InvalidTokenProvided(address givenToken);
    error FaucetCoolDownInProgress();
    error AlreadyClaimed();
    error NothingToRelease();
    error CliffNotReached();
    error NotEligible(address userAddress);
    error AlreadyVested();
    error AlreadyInitialized();

    // === Events ===
    /**
     * @notice Emitted when a tokenomics allocation is initialized
     */
    event AllocationInitialized(string indexed category, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when a user claims vested tokens
     */
    event TokensReleased(address indexed beneficiary, uint256 amount);

    /**
     * @notice Emitted when a user claims their airdrop
     */
    event AirdropClaimed(address indexed user, uint256 amount);

    /*
    * @notice Emmited when a user claims a drip from faucet
    */
    event FaucetClaimed(address indexed user, uint256 amount);
    /*
    * @notice Emmited when faucet settings are updated
    */
    event FaucetSettingsUpdated(uint256 newDrip, uint256 newCooldown);
    /*
    * @notice Emmited when tokens are minted to an address
    */
    event TokensMinted(address indexed to, uint256 amount);
    /*
    * @notice Emmited when a non-native token is minted to 2LYP token contract
    */
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    /*
    * @notice Emmited when a new vesting is added 
    */
    event VestingAdded(address indexed beneficiary, uint256 amount, uint256 cliff, uint256 duration);
    /*
    * @notice Emmited when a airdrop is set
    */
    event AirdropSet(address indexed recipient, uint256 amount);

    // === Structs ===

    /**
     * @notice Vesting information for a beneficiary
     * @param totalAllocated Total tokens allocated for vesting
     * @param startTime Timestamp when vesting begins
     * @param cliff Duration before which no tokens are released
     * @param duration Total duration of vesting
     * @param released Amount already released
     */
    struct VestingInfo {
        uint256 totalAllocated;
        uint256 startTime;
        uint256 cliff;
        uint256 duration;
        uint256 released;
    }

    /**
     * @notice Airdrop information per user
     * @param amount Total airdrop amount allocated
     * @param claimed Whether the user has already claimed
     */
    struct AirdropInfo {
        uint256 amount;
        bool claimed;
    }

    /**
     * @notice Initializes the token with initial and max supply.
     * @param _initialSupply Initial mint amount to deployer
     * @param _maxSupply Maximum total supply cap
     */
    constructor(uint256 _initialSupply, uint256 _maxSupply) ERC20("2LYP Token", "2LYP") Ownable(msg.sender) {
        if(_initialSupply >= _maxSupply)
            revert InitSupplyGreaterThanCap(_initialSupply);

        MAX_SUPPLY = _maxSupply * 10 ** decimals();

        _mint(msg.sender, _initialSupply * 10 ** decimals());
    }

    /**
     * @notice Mint new tokens (only callable by owner)
     * @param _to Recipient address
     * @param _amount Amount to mint (raw value)
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        if (totalSupply() + _amount > MAX_SUPPLY)
            revert MaxSupplyExceeded(totalSupply() + _amount);
        _mint(_to, _amount);
        emit TokensMinted(_to, _amount);
    }

    /**
     * @notice burn tokens
     * @param amount to be burned
     */
    function burn(uint256 amount) public override {
        super.burn(amount * 10**18);
        totalBurned += amount*10**18;
    }

    /**
     * @notice Recover tokens accidentally sent to this contract (except this token)
     * @param _token Address of the token to rescue
     * @param _amount Amount to transfer out
     * @param _to Recipient of rescued tokens
     */
    function rescueERC20(address _token, uint256 _amount, address _to) external onlyOwner {
        if (_token == address(this))
            revert InvalidTokenProvided(_token);
        IERC20(_token).safeTransfer(_to, _amount);
        emit TokensRescued(_token, _to, _amount);
    }

    /**
     * @notice Allows user to claim faucet tokens if cooldown passed
     */
    function faucetMint() external {
        if (block.timestamp - lastFaucetClaim[msg.sender] < faucetCoolDown)
            revert FaucetCoolDownInProgress();
        if (totalSupply() + faucetDrip > MAX_SUPPLY)
            revert MaxSupplyExceeded(totalSupply() + faucetDrip);
        _mint(msg.sender, faucetDrip);
        lastFaucetClaim[msg.sender] = block.timestamp;
        emit FaucetClaimed(msg.sender, faucetDrip);
    }

    /**
     * @notice Owner can update faucet settings
     * @param _newDrip New token drip per claim
     * @param _newCoolDown New cooldown in seconds
     */
    function updateFaucetSettings(uint256 _newDrip, uint256 _newCoolDown) external onlyOwner {
        faucetDrip = _newDrip;
        faucetCoolDown = _newCoolDown;
        emit FaucetSettingsUpdated(_newDrip, _newCoolDown);
    }

    /**
     * @dev Internal function to set up a vesting schedule
     */
    function _addVesting(address _beneficiary, uint256 _amount, uint256 _cliffDuration, uint256 _vestingDuration) internal {
        if (vestingList[_beneficiary].totalAllocated > 0 && _vestingDuration <= 0)
            revert AlreadyVested();

        vestingList[_beneficiary] = VestingInfo({
            totalAllocated: _amount,
            released: 0,
            startTime: block.timestamp,
            cliff: _cliffDuration,
            duration: _vestingDuration
        });
        vestingAddresses.push(_beneficiary); 
        emit VestingAdded(_beneficiary, _amount, _cliffDuration, _vestingDuration);
    }

    /**
     * @notice Owner adds a vesting schedule for a beneficiary
     */
    function addVesting(address _beneficiary, uint256 _amount, uint256 _cliffDuration, uint256 _vestingDuration) external onlyOwner {
        _addVesting(_beneficiary, _amount, _cliffDuration, _vestingDuration);
    }
    
    /**
     * @notice Retrives all beneficiary vesting addresses
     */
    function getAllVestingAddresses() external view returns (address[] memory) {
        return vestingAddresses;
    }

    /**
     * @notice Releases vested tokens available to the caller
     */
    function releaseVestedTokens() external {
        VestingInfo storage info = vestingList[msg.sender];

        if (info.totalAllocated == 0 || info.duration == 0) {
            revert NotEligible(msg.sender);
        }

        if (block.timestamp < info.startTime + info.cliff)
            revert CliffNotReached();

        uint256 elapsed = block.timestamp - info.startTime;
        uint256 vested = (info.totalAllocated * elapsed) / info.duration;
        if (vested > info.totalAllocated) vested = info.totalAllocated;

        uint256 unreleased = vested - info.released;
        if (unreleased <= 0)
            revert NothingToRelease();

        info.released += unreleased;
        _mint(msg.sender, unreleased);
        emit TokensReleased(msg.sender, unreleased); 
    }

    /**
     * @notice Owner sets airdrop recipients and amounts
     */
    function setAirdropList(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        require(recipients.length == amounts.length, "Length mismatch");
        for (uint256 i = 0; i < recipients.length; i++) {
            airdropList[recipients[i]] = AirdropInfo({
                amount: amounts[i],
                claimed: false
            });
            emit AirdropSet(recipients[i], amounts[i]);
        }
    }

    /**
     * @notice Allows users to claim their airdropped tokens
     */
    function claimAirDrop() external {
        AirdropInfo storage info = airdropList[msg.sender];
        if (info.amount == 0) revert NotEligible(msg.sender);
        if (info.claimed) revert AlreadyClaimed();
        info.claimed = true;
        _mint(msg.sender, info.amount);
        emit AirdropClaimed(msg.sender, info.amount);
    }

    /**
     * @notice Initializes all major tokenomics allocations (only once)
     */
    function initTokenomics() external onlyOwner {
        if (tokenomicsInitialized)
            revert AlreadyInitialized();

        address teamWallet = 0x5B38Da6a701c568545dCfcB03FcB875f56beddC4;
        address advisorWallet = 0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2;

        address airdropWallet = 0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db;
        address reserveWallet = 0x78731D3Ca6b7E34aC0F824c42a7cC18A495cabaB;

        _mint(airdropWallet, 1_000_000 * 10 ** decimals());
        emit AllocationInitialized("Airdrop", airdropWallet, 1_000_000 * 10 ** decimals());

        _mint(reserveWallet, 1_000_000 * 10 ** decimals());
        emit AllocationInitialized("Reserve", reserveWallet, 1_000_000 * 10 ** decimals());

        _addVesting(teamWallet, 2_000_000 * 10 ** decimals(), 6 * MONTH, 24 * MONTH);
        emit VestingAdded(teamWallet, 2_000_000 * 10 ** decimals(), 6 * MONTH, 24 * MONTH);

        _addVesting(advisorWallet, 1_000_000 * 10 ** decimals(), 6 * MONTH, 10 * MONTH);
        emit VestingAdded(advisorWallet, 1_000_000 * 10 ** decimals(), 6 * MONTH, 10 * MONTH);

        tokenomicsInitialized = true;
    }

    /**
     * @notice View function to get how much is vested and unreleased for a user
     * @param beneficiary The address to check
     * @return vested Total vested amount till now
     * @return unreleased Amount not yet released to the user
     */
    function getVestedAmount(address beneficiary) external view returns (uint256 vested, uint256 unreleased) {
        VestingInfo storage info = vestingList[beneficiary];
        if (block.timestamp < info.startTime + info.cliff)
            return (0, 0);

        uint256 elapsed = block.timestamp - info.startTime;
        vested = (info.totalAllocated * elapsed) / info.duration;
        if (vested > info.totalAllocated) vested = info.totalAllocated;
        unreleased = vested - info.released;
    }
}
