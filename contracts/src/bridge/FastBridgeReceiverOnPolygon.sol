// SPDX-License-Identifier: MIT

/**
 *  @authors: [@jaybuidl, @shotaronowhere, @hrishibhat]
 *  @reviewers: []
 *  @auditors: []
 *  @bounties: []
 *  @deployments: []
 */

pragma solidity ^0.8.0;

import "./interfaces/IFastBridgeReceiver.sol";
import "./interfaces/ISafeBridgeReceiver.sol";
import "./canonical/polygon/FxBaseChildTunnel.sol";

/**
 * Fast Receiver On Polygon
 * Counterpart of `FastSenderFromArbitrum`
 */
contract FastBridgeReceiverOnPolygon is FxBaseChildTunnel, IFastBridgeReceiver, ISafeBridgeReceiver {
    // **************************************** //
    // *                                      * //
    // *     Polygon Receiver Specific        * //
    // *                                      * //
    // **************************************** //

    // ************************************* //
    // *              Views                * //
    // ************************************* //

    function isSentBySafeBridge() internal view override returns (bool) {
        return (msg.sender == fxChild);
    }

    /**
     * @dev Constructor.
     * @param _deposit The deposit amount to submit a claim in wei.
     * @param _epochPeriod The duration of each epoch.
     * @param _challengePeriod The duration of the period allowing to challenge a claim.
     * @param _safeBridgeSender The address of the Safe Bridge Sender on the connecting chain. fxRootTunnel contract in ethereum
     * @param _fxChild The the fxChild contract on Polygon Chain.
     */
    constructor(
        uint256 _deposit,
        uint256 _epochPeriod,
        uint256 _challengePeriod,
        address _safeBridgeSender, // Polygon receiver specific
        address _fxChild // Polygon receiver specific
    ) FxBaseChildTunnel(_fxChild) {
        deposit = _deposit;
        epochPeriod = _epochPeriod;
        challengePeriod = _challengePeriod;
        safeBridgeSender = _safeBridgeSender;
        setFxRootTunnel(_safeBridgeSender);
    }

    // ************************************** //
    // *                                    * //
    // *         General Receiver           * //
    // *                                    * //
    // ************************************** //

    // ************************************* //
    // *         Enums / Structs           * //
    // ************************************* //

    struct Claim {
        bytes32 batchMerkleRoot;
        address bridger;
        uint32 timestamp;
        bool honest;
        bool verificationAttempted;
        bool depositAndRewardWithdrawn;
    }

    struct Challenge {
        address challenger;
        bool honest;
        bool depositAndRewardWithdrawn;
    }

    // ************************************* //
    // *             Storage               * //
    // ************************************* //

    uint256 public immutable deposit; // The deposit required to submit a claim or challenge
    uint256 public immutable override epochPeriod; // Epochs mark the period between potential batches of messages.
    uint256 public immutable override challengePeriod; // Epochs mark the period between potential batches of messages.
    address public immutable safeBridgeSender; // The address of the Safe Bridge Sender on the connecting chain.

    mapping(uint256 => bytes32) public fastInbox; // epoch => validated batch merkle root(optimistically, or challenged and verified with the safe bridge)
    mapping(uint256 => Claim) public claims; // epoch => claim
    mapping(uint256 => Challenge) public challenges; // epoch => challenge
    mapping(uint256 => mapping(uint256 => bytes32)) public relayed; // epoch => packed replay bitmap

    // ************************************* //
    // *         State Modifiers           * //
    // ************************************* //

    /**
     * @dev Submit a claim about the `_batchMerkleRoot` for the last completed epoch from the Fast Bridge  and submit a deposit. The `_batchMerkleRoot` should match the one on the sending side otherwise the sender will lose his deposit.
     * @param _epoch The epoch in which the batch to claim.
     * @param _batchMerkleRoot The batch merkle root claimed for the last completed epoch.
     */
    function claim(uint256 _epoch, bytes32 _batchMerkleRoot) external payable override {
        require(msg.value >= deposit, "Insufficient claim deposit.");
        require(_batchMerkleRoot != bytes32(0), "Invalid claim.");

        uint256 epochNow = block.timestamp / epochPeriod;
        // allow claim about current or previous epoch
        require(_epoch == epochNow || _epoch == epochNow + 1, "Invalid Claim");
        require(claims[_epoch].bridger == address(0), "Claim already made for most recent finalized epoch.");

        claims[_epoch] = Claim({
            batchMerkleRoot: _batchMerkleRoot,
            bridger: msg.sender,
            timestamp: uint32(block.timestamp),
            honest: false,
            verificationAttempted: false,
            depositAndRewardWithdrawn: false
        });
        emit ClaimReceived(_epoch, _batchMerkleRoot);
    }

    /**
     * @dev Submit a challenge for the claim of the current epoch's Fast Bridge batch merkleroot state and submit a deposit. The `batchMerkleRoot` in the claim already made for the last finalized epoch should be different from the one on the sending side, otherwise the sender will lose his deposit.
     * @param _epoch The epoch of the claim to challenge.
     */
    function challenge(uint256 _epoch) external payable override {
        require(msg.value >= deposit, "Not enough claim deposit");

        // Can only challenge the only active claim, about the previous epoch
        require(claims[_epoch].bridger != address(0), "No claim to challenge.");
        require(block.timestamp < uint256(claims[_epoch].timestamp) + challengePeriod, "Challenge period elapsed.");

        challenges[_epoch] = Challenge({challenger: msg.sender, honest: false, depositAndRewardWithdrawn: false});
        emit ClaimChallenged(_epoch);
    }

    /**
     * @dev Resolves the optimistic claim for '_epoch'.
     * @param _epoch The epoch of the optimistic claim.
     */
    function verifyBatch(uint256 _epoch) external override {
        Claim storage claim = claims[_epoch];
        require(claim.bridger != address(0), "Invalid epoch, no claim to verify.");
        require(claim.verificationAttempted == false, "Optimistic verification already attempted.");
        require(
            block.timestamp > uint256(claims[_epoch].timestamp) + challengePeriod,
            "Challenge period has not yet elapsed."
        );

        if (challenges[_epoch].challenger == address(0)) {
            // optimistic happy path
            claim.honest = true;
            fastInbox[_epoch] = claim.batchMerkleRoot;
            emit BatchVerified(_epoch);
        }
        claim.verificationAttempted = true;
    }

    /**
     * Note: Access restricted to the Safe Bridge.
     * @dev Resolves any challenge of the optimistic claim for '_epoch'.
     * @param _epoch The epoch to verify.
     * @param _batchMerkleRoot The true batch merkle root for the epoch.
     */
    function verifySafeBatch(uint256 _epoch, bytes32 _batchMerkleRoot) external override onlyFromSafeBridge {
        // TODO
        revert("Not implemented");
    }

    /**
     * @dev Verifies merkle proof for the given message and associated nonce for the epoch and relays the message.
     * @param _epoch The epoch in which the message was batched by the bridge.
     * @param _proof The merkle proof to prove the membership of the message and nonce in the merkle tree for the epoch.
     * @param _message The data on the cross-domain chain for the message.
     */
    function verifyAndRelayMessage(
        uint256 _epoch,
        bytes32[] calldata _proof,
        bytes calldata _message
    ) external override {
        bytes32 batchMerkleRoot = fastInbox[_epoch];
        require(batchMerkleRoot != bytes32(0), "Invalid epoch.");

        // Claim assessment if any
        require(validateProof(_proof, sha256(_message), batchMerkleRoot) == true, "Invalid proof.");
        require(_checkReplayAndRelay(_epoch, _message), "Failed to call contract"); // Checks-Effects-Interaction
    }

    /**
     * @dev Handles incoming messages from Ethereum via the canonical Polygon bridge.
     * @param _stateId The epoch in which the message was batched by the bridge.
     * @param _sender The merkle proof to prove the membership of the message and nonce in the merkle tree for the epoch.
     * @param _data The data on the cross-domain chain for the message.
     */
    function _processMessageFromRoot(
        uint256 _stateId,
        address _sender,
        bytes memory _data
    ) internal override validateSender(_sender) {
        // TODO
        revert("Not implemented");
        // (uint256 _epoch, bytes32 _batchMerkleRoot) = abi.decode(data, (uint256, bytes32));

        // fastInbox[_epoch] = _batchMerkleRoot;

        // if (_batchMerkleRoot == claims[_epoch].batchMerkleRoot) {
        //     claims[_epoch].honest = true;
        // } else {
        //     challenges[_epoch].honest = true;
        // }
    }

    /**
     * @dev Sends the deposit back to the Bridger if their claim is not successfully challenged. Includes a portion of the Challenger's deposit if unsuccessfully challenged.
     * @param _epoch The epoch associated with the claim deposit to withraw.
     */
    function withdrawClaimDeposit(uint256 _epoch) external override {
        Claim storage claim = claims[_epoch];

        require(claim.bridger != address(0), "Claim does not exist");
        require(claim.honest == true, "Claim not verified.");
        require(claim.depositAndRewardWithdrawn == false, "Claim deposit and any rewards already withdrawn.");

        uint256 amount = deposit;
        if (challenges[_epoch].challenger != address(0) && challenges[_epoch].honest == false) {
            amount += deposit / 2; // half burnt
        }

        claim.depositAndRewardWithdrawn = true;
        emit ClaimDepositWithdrawn(_epoch, claim.bridger);

        payable(claim.bridger).send(amount); // Use of send to prevent reverting fallback. User is responsibility for accepting ETH.
        // Checks-Effects-Interaction
    }

    /**
     * @dev Sends the deposit back to the Challenger if their challenge is successful. Includes a portion of the Bridger's deposit.
     * @param _epoch The epoch associated with the challenge deposit to withraw.
     */
    function withdrawChallengeDeposit(uint256 _epoch) external override {
        Challenge storage challenge = challenges[_epoch];

        require(challenge.challenger != address(0), "Challenge does not exist");
        require(challenge.honest == true, "Challenge not verified.");
        require(challenge.depositAndRewardWithdrawn == false, "Challenge deposit and rewards already withdrawn.");

        uint256 amount = deposit;
        if (claims[_epoch].bridger != address(0) && claims[_epoch].honest == false) {
            amount += deposit / 2; // half burnt
        }

        challenge.depositAndRewardWithdrawn = true;
        emit ChallengeDepositWithdrawn(_epoch, challenge.challenger);

        payable(challenge.challenger).send(amount); // Use of send to prevent reverting fallback. User is responsibility for accepting ETH.
        // Checks-Effects-Interaction
    }

    // ********************************** //
    // *         Merkle Proof           * //
    // ********************************** //

    /**
     * @dev Validates membership of leaf in merkle tree with merkle proof.
     * Note: Inlined from `merkle/MerkleProof.sol` for performance.
     * @param proof The merkle proof.
     * @param leaf The leaf to validate membership in merkle tree.
     * @param merkleRoot The root of the merkle tree.
     */
    function validateProof(
        bytes32[] memory proof,
        bytes32 leaf,
        bytes32 merkleRoot
    ) internal pure returns (bool) {
        return (merkleRoot == calculateRoot(proof, leaf));
    }

    /**
     * @dev Calculates merkle root from proof.
     * @param proof The merkle proof.
     * @param leaf The leaf to validate membership in merkle tree..
     */
    function calculateRoot(bytes32[] memory proof, bytes32 leaf) private pure returns (bytes32) {
        uint256 proofLength = proof.length;
        require(proofLength <= 32, "Invalid Proof");
        bytes32 h = leaf;
        for (uint256 i = 0; i < proofLength; i++) {
            bytes32 proofElement = proof[i];
            // effecient hash
            if (proofElement > h)
                assembly {
                    mstore(0x00, h)
                    mstore(0x20, proofElement)
                    h := keccak256(0x00, 0x40)
                }
            else
                assembly {
                    mstore(0x00, proofElement)
                    mstore(0x20, h)
                    h := keccak256(0x00, 0x40)
                }
        }
        return h;
    }

    // ************************************* //
    // *           Public Views            * //
    // ************************************* //

    /**
     * @dev Returns the `start` and `end` time of challenge period for this `epoch`.
     * @param _epoch The epoch of the claim to request the challenge period.
     * @return start The start time of the challenge period.
     * @return end The end time of the challenge period.
     */
    function claimChallengePeriod(uint256 _epoch) external view override returns (uint256 start, uint256 end) {
        // start begins latest after the claim deadline expiry
        // however can begin as soon as a claim is made
        // can only challenge the only active claim, about the previous epoch
        start = claims[_epoch].timestamp;
        end = start + challengePeriod;
    }

    // ************************ //
    // *       Internal       * //
    // ************************ //

    function _checkReplayAndRelay(uint256 _epoch, bytes calldata _messageData) internal returns (bool success) {
        // Decode the receiver address from the data encoded by the IFastBridgeSender
        (uint256 nonce, address receiver, bytes memory data) = abi.decode(_messageData, (uint256, address, bytes));

        uint256 index = nonce / 256;
        uint256 offset = nonce % 256;
        bytes32 replay = relayed[_epoch][index];
        require(((replay >> offset) & bytes32(uint256(1))) == 0, "Message already relayed");
        relayed[_epoch][index] = replay | bytes32(1 << offset);
        emit MessageRelayed(_epoch, nonce);

        (success, ) = receiver.call(data);
        // Checks-Effects-Interaction
    }
}
