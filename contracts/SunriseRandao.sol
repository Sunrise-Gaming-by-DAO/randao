// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

interface IRewardToken is IERC20 {
    function mint(address to, uint amount) external;
}

interface IGameChainManager {
    function refillETH(address _account) external;
}

struct RandaoInfo {
    uint randseed;
    uint16 participants;    // number of participants
    uint192 reward;
}

struct RoundInfo {
    uint commit;
    uint reveal;
    uint reward;
    bool claimed;
}

struct Checkpoint {
    uint32 fromBlock;
    uint192 value;
}

contract SunriseRandao is Initializable, OwnableUpgradeable, AccessControlUpgradeable {

    using ECDSA for bytes32;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE"); 

    struct RANDAO {
        uint randseed;
        uint16 participants;    // number of participants
        uint240 reserved;
        mapping(address => uint) commits;
        mapping(address => uint) reveals;
    }

    struct Participant {
        uint64 tokenTime;
        uint192 reward;
        mapping(uint => bool) claimedRound;
        uint256 lastCommitBlockNo;
    }

    uint public RANDAO_PERIOD;      // duration of COMMIT/REVEAL phase (in blocks)
    uint64 public TOKEN_VALID_DURATION;
    address public SIGNER;          // the address that verifies the eligbility of a participant
    IRewardToken public REWARD_TOKEN;

    Checkpoint[] rewardPerBlockCheckpoints;

    mapping(uint => RANDAO) randao;
    mapping(address => Participant) participants;

    IGameChainManager public GAME_MANAGER;

    event Commit(address account, uint randaoId, uint hashValue);
    event Reveal(address account, uint randaoId, uint secretValue);
    event FailReveal(address account, uint randaoId, uint commitValue, uint revealValue);

    event ClaimReward(address account, uint fromBlock, uint toBlock, uint192 totalReward);
    event RewardPerBlock(uint fromBlock, uint192 value);
    event RandaoPeriodUpdated(uint value);
    event TokenDurationUpdated(uint value);
    event SignerUpdated(address indexed signer);
    event GameManagerUpdated(address manager);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    modifier onlyOperator() {
        require(hasRole(OPERATOR_ROLE, _msgSender()), "SunriseRandao: Must be operator");
        _;
    }

    function initialize(uint period, uint192 rewardPerBlock, uint64 tokenDuration, IRewardToken rewardToken, address signer, IGameChainManager gameManager) initializer public {
        __Ownable_init();
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _setupRole(OPERATOR_ROLE, _msgSender());
        RANDAO_PERIOD = period;
        TOKEN_VALID_DURATION = tokenDuration;
        REWARD_TOKEN = rewardToken;
        SIGNER = signer;
        GAME_MANAGER = gameManager;
        rewardPerBlockCheckpoints.push(Checkpoint(0, rewardPerBlock));
    }

    function isCommitPhase(uint randaoId) private view returns(bool) {
        return (block.number >= randaoId) && (block.number < randaoId + RANDAO_PERIOD);
    }

    function isRevealPhase(uint randaoId) private view returns(bool) {
        return (block.number >= randaoId + RANDAO_PERIOD) && (block.number < randaoId + 2 * RANDAO_PERIOD);
    }

    function isClosed(uint randaoId) private view returns(bool) {
        return block.number >= randaoId + 2 * RANDAO_PERIOD;
    }

    function setRewardPerBlock(uint192 value) external onlyOperator {
        Checkpoint storage cp = rewardPerBlockCheckpoints[rewardPerBlockCheckpoints.length - 1];
        if (cp.fromBlock < block.number)
            rewardPerBlockCheckpoints.push(Checkpoint(uint32(block.number), value));
        else
            cp.value = value;
        
        emit RewardPerBlock(block.number, value);
    }

    function setRandaoPeriod(uint value) external onlyOperator {
        require(value >= 5, 'RANDAO: period is too small');
        if (RANDAO_PERIOD != value)
            RANDAO_PERIOD = value;
        
        emit RandaoPeriodUpdated(value);
    }

    function setTokenDuration(uint64 value) external onlyOperator {
        if (TOKEN_VALID_DURATION != value)
            TOKEN_VALID_DURATION = value;
        
        emit TokenDurationUpdated(value);
    }

    function setSigner(address signer) external onlyOwner {
        if (SIGNER == signer)
            return;
        SIGNER = signer;

        emit SignerUpdated(signer);
    }

    function setGameManager(IGameChainManager value) external onlyOwner {
        if (address(value) != address(GAME_MANAGER)) 
            GAME_MANAGER = value;

        emit GameManagerUpdated(address(value));
    }

    function participate(uint[] memory commits, uint[] memory reveals, uint blockNo, uint64 tokenTime, bytes calldata tokenSignature) external {

        require(block.timestamp < TOKEN_VALID_DURATION + _verifyTokenTime(tokenTime, tokenSignature), 'RANDAO: invalid token time');

        blockNo = block.number;

        uint len = commits.length <= RANDAO_PERIOD ? commits.length : RANDAO_PERIOD;
        for (uint i = 0; i < len && blockNo > i; i++) {
            if (!isCommitPhase(blockNo - i)) 
                break;

            RANDAO storage rand = randao[blockNo - i];
            rand.commits[msg.sender] = commits[i];

            emit Commit(msg.sender, blockNo - i, commits[i]);
        }
        Participant storage participant = participants[msg.sender];
        uint revealBlockNo = participant.lastCommitBlockNo;
        participant.lastCommitBlockNo = blockNo;

        len = reveals.length <= RANDAO_PERIOD ? reveals.length : RANDAO_PERIOD;
        for (uint i = 0; i < len && revealBlockNo > i; i++) {
            if (!isRevealPhase(revealBlockNo - i))
                continue;

            RANDAO storage rand = randao[revealBlockNo - i];
            
            if (rand.reveals[msg.sender] != 0 || 
                rand.commits[msg.sender] != uint(keccak256(abi.encode(reveals[i])))) 
            {
                emit FailReveal(msg.sender, revealBlockNo - i, rand.commits[msg.sender], uint(keccak256(abi.encode(reveals[i]))));
                continue;
            }

            rand.reveals[msg.sender] = reveals[i];
            rand.participants++;
            rand.randseed = uint(keccak256(abi.encodePacked(rand.randseed, reveals[i] + 1)));

            emit Reveal(msg.sender, revealBlockNo - i, reveals[i]);
        }

        if (revealBlockNo > 2 * RANDAO_PERIOD) {
            collectReward(revealBlockNo - 2 * RANDAO_PERIOD + 1, revealBlockNo - RANDAO_PERIOD);
        }

        if (address(GAME_MANAGER) != address(0))
            GAME_MANAGER.refillETH(msg.sender);
    }

    function random(uint randaoId, uint salt, uint sugar) external view returns(uint) {
        require(isClosed(randaoId), 'RANDAO: randseed not finalized');
        uint seed = sugar;
        for (uint i = 0; i <= salt; i++)
            seed = uint(keccak256(abi.encodePacked(abi.encodePacked(seed, randao[randaoId - i].randseed))));
        return seed;
    }

    function collectReward(uint fromBlock, uint toBlock) public {
        uint192 totalReward;

        Participant storage participant = participants[msg.sender];
        for (uint i = fromBlock; i <= toBlock; i++) {
            if (!isClosed(i)) 
                break;
            RANDAO storage rand = randao[i];
            if (rand.reveals[msg.sender] > 0 && !participant.claimedRound[i]) {
                participant.claimedRound[i] = true;
                totalReward += _rewardPerBlock(i) / rand.participants;
            }
        }
        
        if (totalReward > 0) {
            if (address(REWARD_TOKEN) != address(0)) {
                if (REWARD_TOKEN.balanceOf(address(this)) >= totalReward) 
                    REWARD_TOKEN.transfer(msg.sender, totalReward);
                else REWARD_TOKEN.mint(msg.sender, totalReward);
            }

            participant.reward += totalReward;
        }

        emit ClaimReward(msg.sender, fromBlock, toBlock, totalReward);
    }

    function randaoStats(uint fromBlock, uint toBlock) external view returns(RandaoInfo[] memory result) {
        if (toBlock < fromBlock)
            return result;

        result = new RandaoInfo[](toBlock - fromBlock + 1);
        for (uint i = toBlock; i >= fromBlock; i--) {
            RANDAO storage rand = randao[i];
            result[toBlock - i] = RandaoInfo(rand.randseed, rand.participants, _rewardPerBlock(i));
        }

        return result;
    }

    function getCheckpointCount() external view returns(uint256) {
        return rewardPerBlockCheckpoints.length;
    }

    function getRewardPerBlock() external view returns(uint192) {
        uint currentBlock = block.number;
        uint len = rewardPerBlockCheckpoints.length;
        Checkpoint storage cp = _unsafeAccess(rewardPerBlockCheckpoints, len - 1);
        return cp.fromBlock < currentBlock ? cp.value : _checkpointsLookup(rewardPerBlockCheckpoints, currentBlock);
    }

    function participantStats(address account, uint fromBlock, uint toBlock) external view returns(RoundInfo[] memory result) {
        if (toBlock < fromBlock)
            return result;

        result = new RoundInfo[](toBlock - fromBlock + 1);
        Participant storage participant = participants[account];
        for (uint i = toBlock; i >= fromBlock; i--) {
            RANDAO storage rand = randao[i];
            uint secret = rand.reveals[account];
            uint reward = secret > 0 ? _rewardPerBlock(i) / rand.participants : 0; 
            result[toBlock - i] = RoundInfo(rand.commits[account], secret, reward, participant.claimedRound[i]);
        }

        return result;
    }

    function participantInfo(address account) external view returns(uint accumReward, uint lastCommitBlock) {
        Participant storage participant = participants[account];
        return (participant.reward, participant.lastCommitBlockNo);
    }

    function tokenHash(uint64 tokenTime) public pure returns(bytes32) {
        return keccak256(abi.encodePacked(tokenTime)).toEthSignedMessageHash();
    }

    function _rewardPerBlock(uint blockNo) internal view returns(uint192) {
        require(blockNo < block.number, 'RANDAO: block is not mined');
        uint len = rewardPerBlockCheckpoints.length;
        Checkpoint storage cp = _unsafeAccess(rewardPerBlockCheckpoints, len - 1);
        return cp.fromBlock < blockNo ? cp.value : _checkpointsLookup(rewardPerBlockCheckpoints, blockNo);
    }

    function _verifyTokenTime(uint64 tokenTime, bytes calldata signature) internal returns(uint64) {
        Participant storage participant = participants[msg.sender];
        if (participant.tokenTime == tokenTime)
            return tokenTime;
        if (participant.tokenTime < tokenTime) {
            // check for valid signature
            require(tokenHash(tokenTime).recover(signature) == SIGNER, 'RANDAO: invalid token signature');
            participant.tokenTime = tokenTime;
            return tokenTime;
        }
        return participant.tokenTime;
    }

    function _checkpointsLookup(Checkpoint[] storage ckpts, uint256 blockNumber) private view returns (uint192) {
        // We run a binary search to look for the earliest checkpoint taken after `blockNumber`.
        //
        // Initially we check if the block is recent to narrow the search range.
        // During the loop, the index of the wanted checkpoint remains in the range [low-1, high).
        // With each iteration, either `low` or `high` is moved towards the middle of the range to maintain the invariant.
        // - If the middle checkpoint is after `blockNumber`, we look in [low, mid)
        // - If the middle checkpoint is before or equal to `blockNumber`, we look in [mid+1, high)
        // Once we reach a single value (when low == high), we've found the right checkpoint at the index high-1, if not
        // out of bounds (in which case we're looking too far in the past and the result is 0).
        // Note that if the latest checkpoint available is exactly for `blockNumber`, we end up with an index that is
        // past the end of the array, so we technically don't find a checkpoint after `blockNumber`, but it works out
        // the same.
        uint256 length = ckpts.length;

        uint256 low = 0;
        uint256 high = length;

        if (length > 5) {
            uint256 mid = length - Math.sqrt(length);
            if (_unsafeAccess(ckpts, mid).fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        while (low < high) {
            uint256 mid = Math.average(low, high);
            if (_unsafeAccess(ckpts, mid).fromBlock > blockNumber) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        return high == 0 ? 0 : _unsafeAccess(ckpts, high - 1).value;
    }

    function _unsafeAccess(Checkpoint[] storage ckpts, uint256 pos) private pure returns (Checkpoint storage result) {
        assembly {
            mstore(0, ckpts.slot)
            result.slot := add(keccak256(0, 0x20), pos)
        }
    }

}
