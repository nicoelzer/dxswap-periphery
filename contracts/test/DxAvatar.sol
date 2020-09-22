pragma solidity =0.6.6;

import '../libraries/TransferHelper.sol';
import '../interfaces/IERC20.sol';

contract DxAvatar{

    event GenericCall(address indexed _contract, bytes _data, uint _value, bool _success);
    event SendEther(uint256 _amountInWei, address indexed _to);
    event ExternalTokenTransfer(address indexed _externalToken, address indexed _to, uint256 _value);
    event ExternalTokenTransferFrom(address indexed _externalToken, address _from, address _to, uint256 _value);
    event ExternalTokenApproval(address indexed _externalToken, address _spender, uint256 _value);

    function genericCall(address _contract, bytes memory _data, uint256 _value)
    public
    returns(bool success, bytes memory returnValue) {
      // solhint-disable-next-line avoid-call-value
        (success, returnValue) = _contract.call.value(_value)(_data);
        emit GenericCall(_contract, _data, _value, success);
    }

    function sendEther(uint256 _amountInWei, address payable _to) public returns(bool) {
        _to.transfer(_amountInWei);
        emit SendEther(_amountInWei, _to);
        return true;
    }

    function externalTokenTransfer(IERC20 _externalToken, address _to, uint256 _value)
    public returns(bool)
    {

        TransferHelper.safeTransfer(address(_externalToken), _to, _value);
        emit ExternalTokenTransfer(address(_externalToken), _to, _value);
        return true;
    }

    function externalTokenTransferFrom(
        IERC20 _externalToken,
        address _from,
        address _to,
        uint256 _value
    )
    public returns(bool)
    {
        TransferHelper.safeTransferFrom(address(_externalToken), _from, _to, _value);
        emit ExternalTokenTransferFrom(address(_externalToken), _from, _to, _value);
        return true;
    }

    function externalTokenApproval(IERC20 _externalToken, address _spender, uint256 _value)
    public returns(bool)
    {
        TransferHelper.safeApprove(address(_externalToken), _spender, _value);
        emit ExternalTokenApproval(address(_externalToken), _spender, _value);
        return true;
    }

    fallback() external payable { }

}