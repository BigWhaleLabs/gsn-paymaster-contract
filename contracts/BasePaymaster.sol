// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.14;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import "@opengsn/contracts/src/utils/GsnTypes.sol";
import "@opengsn/contracts/src/interfaces/IPaymaster.sol";
import "@opengsn/contracts/src/interfaces/IRelayHub.sol";
import "@opengsn/contracts/src/utils/GsnEip712Library.sol";
import "@opengsn/contracts/src/forwarder/IForwarder.sol";

/**
 * @notice An abstract base class to be inherited by a concrete Paymaster.
 * A subclass must implement:
 *  - preRelayedCall
 *  - postRelayedCall
 */
abstract contract BasePaymaster is IPaymaster, Ownable, ERC165 {
  using ERC165Checker for address;

  IRelayHub internal relayHub;
  address private _trustedForwarder;

  /// @inheritdoc IPaymaster
  function getRelayHub() public view override returns (address) {
    return address(relayHub);
  }

  //overhead of forwarder verify+signature, plus hub overhead.
  uint256 public forwarderHubOverhead = 50000;

  //These parameters are documented in IPaymaster.GasAndDataLimits
  uint256 public preRelayedCallGasLimit = 500000;
  uint256 public postRelayedCallGasLimit = 510000;
  uint256 public paymasterAcceptanceBudget =
    preRelayedCallGasLimit + forwarderHubOverhead;
  uint256 public calldataSizeLimit = 20500;

  /// @inheritdoc IERC165
  function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override(IERC165, ERC165)
    returns (bool)
  {
    return
      interfaceId == type(IPaymaster).interfaceId ||
      interfaceId == type(Ownable).interfaceId ||
      super.supportsInterface(interfaceId);
  }

  /// @inheritdoc IPaymaster
  function getGasAndDataLimits()
    public
    view
    override
    returns (IPaymaster.GasAndDataLimits memory limits)
  {
    return
      IPaymaster.GasAndDataLimits(
        paymasterAcceptanceBudget,
        preRelayedCallGasLimit,
        postRelayedCallGasLimit,
        calldataSizeLimit
      );
  }

  function setGasAndDataLimits(
    uint256 _preRelayedCallGasLimit,
    uint256 _postRelayedCallGasLimit,
    uint256 _paymasterAcceptanceBudget,
    uint256 _calldataSizeLimit
  ) public onlyOwner {
    preRelayedCallGasLimit = _preRelayedCallGasLimit;
    postRelayedCallGasLimit = _postRelayedCallGasLimit;
    paymasterAcceptanceBudget = _paymasterAcceptanceBudget;
    calldataSizeLimit = _calldataSizeLimit;
  }

  /**
   * @notice this method must be called from preRelayedCall to validate that the forwarder
   * is approved by the paymaster as well as by the recipient contract.
   */
  function _verifyForwarder(GsnTypes.RelayRequest calldata relayRequest)
    internal
    view
    virtual
  {
    require(
      getTrustedForwarder() == relayRequest.relayData.forwarder,
      "Forwarder is not trusted"
    );
    GsnEip712Library.verifyForwarderTrusted(relayRequest);
  }

  function _verifyRelayHubOnly() internal view virtual {
    require(msg.sender == getRelayHub(), "can only be called by RelayHub");
  }

  function _verifyValue(GsnTypes.RelayRequest calldata relayRequest)
    internal
    view
    virtual
  {
    require(relayRequest.request.value == 0, "value transfer not supported");
  }

  function _verifyPaymasterData(GsnTypes.RelayRequest calldata relayRequest)
    internal
    view
    virtual
  {
    require(
      relayRequest.relayData.paymasterData.length == 0,
      "should have no paymasterData"
    );
  }

  function _verifyApprovalData(bytes calldata approvalData)
    internal
    view
    virtual
  {
    require(approvalData.length == 0, "should have no approvalData");
  }

  /**
   * @notice The owner of the Paymaster can change the instance of the RelayHub this Paymaster works with.
   * :warning: **Warning** :warning: The deposit on the previous RelayHub must be withdrawn first.
   */
  function setRelayHub(IRelayHub hub) public onlyOwner {
    require(
      address(hub).supportsInterface(type(IRelayHub).interfaceId),
      "target is not a valid IRelayHub"
    );
    relayHub = hub;
  }

  /**
   * @notice The owner of the Paymaster can change the instance of the Forwarder this Paymaster works with.
   * @notice the Recipients must trust this Forwarder as well in order for the configuration to remain functional.
   */
  function setTrustedForwarder(address forwarder) public virtual onlyOwner {
    require(
      forwarder.supportsInterface(type(IForwarder).interfaceId),
      "target is not a valid IForwarder"
    );
    _trustedForwarder = forwarder;
  }

  function getTrustedForwarder()
    public
    view
    virtual
    override
    returns (address)
  {
    return _trustedForwarder;
  }

  /**
   * @notice Any native Ether transferred into the paymaster is transferred as a deposit to the RelayHub.
   * This way, we don't need to understand the RelayHub API in order to replenish the paymaster.
   */
  receive() external payable virtual {
    require(address(relayHub) != address(0), "relay hub address not set");
    relayHub.depositFor{value: msg.value}(address(this));
  }

  /**
   * @notice Withdraw deposit from the RelayHub.
   * @param amount The amount to be subtracted from the sender.
   * @param target The target to which the amount will be transferred.
   */
  function withdrawRelayHubDepositTo(uint256 amount, address payable target)
    public
    onlyOwner
  {
    relayHub.withdraw(target, amount);
  }

  /// @inheritdoc IPaymaster
  function preRelayedCall(
    GsnTypes.RelayRequest calldata relayRequest,
    bytes calldata signature,
    bytes calldata approvalData,
    uint256 maxPossibleGas
  ) external override returns (bytes memory, bool) {
    _verifyRelayHubOnly();
    _verifyForwarder(relayRequest);
    _verifyValue(relayRequest);
    _verifyPaymasterData(relayRequest);
    _verifyApprovalData(approvalData);
    return
      _preRelayedCall(relayRequest, signature, approvalData, maxPossibleGas);
  }

  /**
   * @notice internal logic the paymasters need to provide to select which transactions they are willing to pay for
   * @notice see the documentation for `IPaymaster::preRelayedCall` for details
   */
  function _preRelayedCall(
    GsnTypes.RelayRequest calldata,
    bytes calldata,
    bytes calldata,
    uint256
  ) internal virtual returns (bytes memory, bool);

  /// @inheritdoc IPaymaster
  function postRelayedCall(
    bytes calldata context,
    bool success,
    uint256 gasUseWithoutPost,
    GsnTypes.RelayData calldata relayData
  ) external override {
    _verifyRelayHubOnly();
    _postRelayedCall(context, success, gasUseWithoutPost, relayData);
  }

  /**
   * @notice internal logic the paymasters need to provide if they need to take some action after the transaction
   * @notice see the documentation for `IPaymaster::postRelayedCall` for details
   */
  function _postRelayedCall(
    bytes calldata,
    bool,
    uint256,
    GsnTypes.RelayData calldata
  ) internal virtual;
}