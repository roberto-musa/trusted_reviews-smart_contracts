// SimpleStorage.t.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// 1. Import della libreria di test Forge
//    - Test.sol fornisce funzioni di asserzione (assertEq, assertTrue, ecc.)
//    - Espone anche l'oggetto `vm` con le cheatcode (vm.prank, vm.expectRevert, ecc.) [web:151][web:165]
import {Test} from "../lib/forge-std/src/Test.sol";

// 2. Import del contratto da testare
import {SimpleStorage} from "../src/SimpleStorage.sol";

// 3. Contratto di test
//    - Eredita da Test, così può usare assert*, vm.*, ecc. [web:151][web:157]
contract SimpleStorageTest is Test {
    // 4. Variabili usate nei test
    //    - Riferimento al contratto sotto test
    //    - Indirizzi che useremo come owner e non-owner [web:154][web:160]
    SimpleStorage internal storageContract;
    address internal owner;
    address internal attacker;

    // 5. Funzione di setup
    //    - Viene eseguita automaticamente prima di OGNI test (pattern consigliato in Foundry) [web:151][web:167]
    function setUp() public {
        // Creiamo due indirizzi “fittizi” per simulare attori diversi
        owner = makeAddr("owner");        // helper di forge-std per generare indirizzi leggibili [web:151]
        attacker = makeAddr("attacker");

        // Simuliamo il deploy fatto dall'owner:
        // vm.prank fa sì che la CHIAMATA successiva abbia msg.sender = owner. [web:165][web:159]
        vm.prank(owner);
        storageContract = new SimpleStorage(42); // il costruttore imposta owner e storedNumber = 42

        // (opzionale) etichettiamo gli indirizzi per avere trace più chiari in output
        vm.label(address(storageContract), "SimpleStorage");
        vm.label(owner, "Owner");
        vm.label(attacker, "Attacker");
    }

    // 6. Test: verifica dei valori iniziali
    //    - Controlla che il contratto parta dallo stato atteso dopo il costruttore. [web:151][web:157]
    function test_InitialState() public {
        // getNumber dovrebbe restituire il valore passato al costruttore (42)
        uint256 value = storageContract.getNumber();
        assertEq(value, 42, "Valore iniziale errato");

        // owner del contratto deve essere l'indirizzo che ha fatto il deploy (owner)
        assertEq(storageContract.owner(), owner, "Owner iniziale errato");
    }

    // 7. Test: aggiornamento del numero da parte del proprietario
    //    - Verifica il flusso "positivo": l'owner può chiamare setNumber e aggiornare lo stato. [web:151][web:163]
    function test_SetNumber_AsOwner() public {
        // Simuliamo una chiamata dal proprietario (msg.sender = owner)
        vm.prank(owner);
        storageContract.setNumber(100);

        // Controlliamo che il valore sia stato aggiornato
        uint256 value = storageContract.getNumber();
        assertEq(value, 100, "Valore non aggiornato correttamente");
    }

    // 8. Test: blocco di un non-owner
    //    - Verifica il controllo di accesso: un indirizzo diverso dall'owner deve essere rifiutato. [web:159][web:168]
    function test_Revert_SetNumber_AsNonOwner() public {
        // Indichiamo che ci aspettiamo un revert con un certo messaggio
        vm.prank(attacker);
        vm.expectRevert(bytes("Not the owner"));
        storageContract.setNumber(999);
    }

    // 9. Test: emissione dell'evento NumberUpdated
    //    - Verifica che la logica emetta l'evento con i parametri attesi. [web:151][web:157]
    function test_NumberUpdated_EventEmitted() public {
        // Prepariamo l'aspettativa sull'evento:
        // emit NumberUpdated(oldValue, newValue, updatedBy)
        // vm.expectEmit controlla che il prossimo evento emesso corrisponda ai parametri indicati. [web:165]
        vm.prank(owner);

        // Impostiamo cosa vogliamo catturare:
        // (checkTopic1, checkTopic2, checkTopic3, checkData)
        // Qui: vogliamo controllare TUTTI i topic e i dati.
        vm.expectEmit(true, true, true, true);
        emit SimpleStorage.NumberUpdated(42, 77, owner);

        // Chiamata che dovrebbe emettere l'evento
        storageContract.setNumber(77);
    }
}
