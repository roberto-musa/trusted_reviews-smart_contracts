// SimpleStorage.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;		// Versione

contract SimpleStorage {        // Contratto di esempio per illustrare la struttura di un file Solidity

    // 1. Variabili di stato
    uint256 private storedNumber;
    address public owner;

    // 2. Eventi
    event NumberUpdated(uint256 oldValue, uint256 newValue, address indexed updatedBy);

    // 3. Modificatori
    modifier onlyOwner() {
        require(msg.sender == owner, "Not the owner");
        _;
    }

    // 4. Costruttore
    constructor(uint256 _initialNumber) {
        owner = msg.sender;
        storedNumber = _initialNumber;
    }

    // 5. Funzioni di scrittura
    function setNumber(uint256 _newNumber) external onlyOwner {
        uint256 old = storedNumber;
        storedNumber = _newNumber;
        emit NumberUpdated(old, _newNumber, msg.sender);
    }

    // 6. Funzioni di lettura (view)
    function getNumber() external view returns (uint256) {
        return storedNumber;
    }
}
