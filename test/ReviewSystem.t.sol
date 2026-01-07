// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ReviewSystem} from "../src/ReviewSystem.sol";

/**
 * @title Test per ReviewSystem
 * @notice Questo contratto testa le funzionalità principali di ReviewRegistry.
 */
contract ReviewSystemTest is Test {
    // Qui scriveremo le nostre variabili di stato per il test e le funzioni di test.
    
    // Variabile di stato per tenere un'istanza del nostro contratto
    ReviewSystem public reviewSystem;

    // Questa funzione viene eseguita prima di ogni test
    function setUp() public {
        // Creiamo una nuova istanza di ReviewRegistry
        reviewSystem = new ReviewSystem();
    }

        // --- Test per la funzione createReview ---

    /**
     * @notice Testa che una recensione possa essere creata con successo con dati validi.
     */
    function test_CreateReview_Success() public {
        // --- 1. Preparazione (Arrange) ---
        uint256 businessId = 1;
        bytes32 contentHash = keccak256(abi.encodePacked("Ottimo servizio!"));
        uint8 rating = 5;

        // --- 2. Azione (Act) ---
        // Chiamiamo la funzione che vogliamo testare
        reviewSystem.createReview(businessId, contentHash, rating);

        // --- 3. Asserzione (Assert) ---
        // Verifichiamo che lo stato del contratto sia cambiato come ci aspettiamo.

        // Il contatore delle recensioni dell'autore dovrebbe essere 1
        assertEq(reviewSystem.reviewCountByAuthor(address(this)), 1, "Review count should be 1");

        // Recuperiamo la recensione appena creata (ID 1, perché è la prima)
        // --- INIZIO DELLA MODIFICA NEL TEST ---
            // Usiamo la nostra nuova funzione getter per recuperare lo struct completo
            ReviewSystem.Review memory review = reviewSystem.getReviewById(1);
            // --- FINE DELLA MODIFICA NEL TEST ---

        // Verifichiamo che i dati della recensione siano corretti
        assertEq(review.id, 1, "Review ID should be 1");
        assertEq(review.author, address(this), "Author should be this test contract");
        assertEq(review.businessId, businessId, "Business ID should match");
        assertEq(review.contentHash, contentHash, "Content hash should match");
        assertEq(review.rating, rating, "Rating should match");
        assertTrue(review.timestamp > 0, "Timestamp should be set");

        // --- NUOVA ASSERZIONE PER LA REPUTAZIONE ---
        assertEq(reviewSystem.reputationScore(address(this)), 1, "Reputation score should be 1");
    }

    /**
     * @notice Testa che la creazione di una recensione fallisca se il rating è > 5.
     */
    function test_Revert_WhenRatingIsTooHigh() public {
        // --- 1. Preparazione (Arrange) ---
        uint256 businessId = 1;
        bytes32 contentHash = keccak256(abi.encodePacked("Testo"));
        uint8 invalidRating = 6; // Rating non valido

        // --- 2. Azione e Asserzione (Act & Assert) ---
        // Ci aspettiamo che questa chiamata fallisca con un messaggio specifico.
        // vm.expectRevert prende come argomento il messaggio di errore esatto che ci aspettiamo.
        vm.expectRevert(bytes("Rating must be between 1 and 5"));

        // Eseguiamo la chiamata che dovrebbe fallire
        reviewSystem.createReview(businessId, contentHash, invalidRating);
    }

    /**
     * @notice Testa che la creazione di una recensione fallisca se il rating è 0.
     */
    function test_Revert_WhenRatingIsZero() public {
        uint256 businessId = 1;
        bytes32 contentHash = keccak256(abi.encodePacked("Testo"));
        uint8 invalidRating = 0; // Rating non valido

        vm.expectRevert(bytes("Rating must be between 1 and 5"));
        reviewSystem.createReview(businessId, contentHash, invalidRating);
    }
    
    /**
     * @notice Testa che la creazione di una recensione fallisca se il businessId è 0.
     */
    function test_Revert_WhenBusinessIdIsZero() public {
        uint256 invalidBusinessId = 0; // Business ID non valido
        bytes32 contentHash = keccak256(abi.encodePacked("Testo"));
        uint8 rating = 4;

        vm.expectRevert(bytes("Business ID must be valid"));
        reviewSystem.createReview(invalidBusinessId, contentHash, rating);
    }

    /**
     * @notice Testa che il punteggio di reputazione si incrementi correttamente.
     */
    function test_ReputationIncrementsCorrectly() public {
        // Primo controllo: il punteggio iniziale è 0
        assertEq(reviewSystem.reputationScore(address(this)), 0);

        // Crea la prima recensione
        reviewSystem.createReview(1, keccak256("Test 1"), 5);
        assertEq(reviewSystem.reputationScore(address(this)), 1);

        // Crea la seconda recensione
        reviewSystem.createReview(2, keccak256("Test 2"), 4);
        assertEq(reviewSystem.reputationScore(address(this)), 2);
    }

    /**
     * @notice Foundry permette di intercettare gli eventi emessi dal contratto.
     * È utile, soprattutto in sede di tesi, perché verifica che vengano emessi
     * gli specifici eventi, e che i parametri emessi siano esattamente quelli
     * che ci si aspetta.
     */
    function test_EventIsEmittedOnReview() public {
        uint256 businessId = 123;
        bytes32 contentHash = keccak256("EventTest");
        uint8 rating = 4;

        vm.expectEmit(true, true, true, false, address(reviewSystem)); // emissione simulata dell’evento prima della chiamata che lo produrrà
        emit ReviewSystem.ReviewCreated(1, address(this), businessId, rating);
        reviewSystem.createReview(businessId, contentHash, rating);
    }

    /**
     * @notice Funzione per testare comportamenti “da altro utente”, 
     * sfruttiamo i cheatcode Foundry per cambiare temporaneamente il sender.
     */
    function test_DifferentUsers() public {
        address utenteA = address(0x1234);
        vm.prank(utenteA);
        reviewSystem.createReview(1, keccak256("Recensione A"), 5);

        address utenteB = address(0x5678);
        vm.prank(utenteB);
        reviewSystem.createReview(2, keccak256("Recensione B"), 4);

        assertEq(reviewSystem.reputationScore(utenteA), 1);
        assertEq(reviewSystem.reputationScore(utenteB), 1);
    }

    /**
     * @notice Fuzz test: verifica che la creazione di recensioni con rating valido funzioni SEMPRE.
     * Foundry chiamerà la funzione con tantissimi valori diversi di rating: noi limitiamo l'esecuzione ai valori validi.
     */
    function testFuzz_CreateReview_ValidRating(uint256 businessId, uint8 rating) public {
        // Limitiamo gli input ai valori validi per rating e businessId
        vm.assume(rating >= 1 && rating <= 5);
        vm.assume(businessId > 0); // L'id business deve essere valido
        bytes32 contentHash = keccak256("FuzzReview");

        // Non ci deve mai essere revert
        reviewSystem.createReview(businessId, contentHash, rating);

        // Verifica che la review sia stata salvata e reputazione sia aggiornata
        ReviewSystem.Review memory review = reviewSystem.getReviewById(reviewSystem.reviewCountByAuthor(address(this)));
        assertEq(review.rating, rating, "Il rating della review deve essere quello generato");
        assertEq(review.businessId, businessId, "BusinessId salvato deve essere quello generato");
        assertEq(reviewSystem.reputationScore(address(this)), reviewSystem.reviewCountByAuthor(address(this)), "Reputazione e review devono essere uguali");
    }

    /**
     * @notice Fuzz test: verifica che la creazione di una recensione fallisca SEMPRE con rating non valido.
     */
    function testFuzz_Revert_CreateReview_InvalidRating(uint8 rating) public {
        // Limitiamo agli input NON validi per rating
        vm.assume(rating > 100 || rating == 0); // Forziamo solo rating fuori range tipico
        uint256 businessId = 1;
        bytes32 contentHash = keccak256("FuzzFail");

        vm.expectRevert(bytes("Rating must be between 1 and 5"));
        reviewSystem.createReview(businessId, contentHash, rating);
    }

    /**
     * @notice Fuzz test: verifica il comportamento rispetto a businessId non valido.
     */
    function testFuzz_Revert_CreateReview_InvalidBusinessId(uint256 businessId) public {
        vm.assume(businessId == 0); // Solo l'id zero deve causare revert
        uint8 rating = 4;
        bytes32 contentHash = keccak256("FuzzFailBiz");

        vm.expectRevert(bytes("Business ID must be valid"));
        reviewSystem.createReview(businessId, contentHash, rating);
    }

}