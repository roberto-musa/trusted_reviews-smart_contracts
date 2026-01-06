// src/ReviewSystem.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ReviewSystem
 * @author Roberto Musa
 * @notice Questo contratto funge da registro immutabile per gli hash delle recensioni.
 */


contract ReviewSystem {
    // Qui definiremo le nostre variabili di stato, la struttura dati e le funzioni.
    // --- Struttura Dati ---
    // Definiamo come è fatta una recensione on-chain.
    struct Review {
        uint256 id;         // Usiamo una unsigned Int a 256 bit per l'ID dell'utente
        address author;     // L'indirizzo EVM dell'autore della recensione
        uint256 businessId; // Usiamo una unsigned Int a 256 bit per l'ID del business
        bytes32 contentHash; // Usiamo bytes32 per l'hash, è più efficiente
        uint8 rating;       // uint8 è sufficiente per un voto da 1 a 5
        uint256 timestamp;
    }

    // --- Variabili di Stato ---
    
    // Un contatore per assegnare un ID univoco e progressivo ad ogni recensione.
    // Il _ iniziale è una convenzione per le variabili private.
    uint256 private _reviewCounter;

    // Un mapping per associare un ID di recensione alla sua struttura dati.
    // È come un dizionario o una hash map.
    mapping(uint256 => Review) internal reviews;

    // Un mapping per tenere traccia di quante recensioni ha scritto ogni utente.
    mapping(address => uint256) public reviewCountByAuthor;

    // --- NUOVA FUNZIONE GETTER ---
    /**
     * @notice Restituisce i dati di una recensione dato il suo ID.
     * @param _reviewId L'ID della recensione da recuperare.
     * @return review La struttura dati completa della recensione.
     */
    function getReviewById(uint256 _reviewId) external view returns (Review memory) {
        return reviews[_reviewId];
    }

    // --- NUOVE VARIABILI DI STATO PER LA REPUTAZIONE ---
    mapping(address => uint256) public reputationScore;

    // --- Eventi ---

    // Viene emesso ogni volta che una nuova recensione viene creata con successo.
    // I parametri 'indexed' possono essere usati per filtrare gli eventi più facilmente.
    event ReviewCreated(
        uint256 indexed id,
        address indexed author,
        uint256 indexed businessId,
        uint8 rating
    );

    // --- NUOVO EVENTO PER LA REPUTAZIONE ---
    event ReputationUpdated(address indexed user, uint256 newScore);

    // --- Funzioni Esterne ---

    /**
    * @notice Permette a un utente di registrare una nuova recensione.
    * @param _businessId L'ID dell'attività che viene recensita.
    * @param _contentHash L'hash Keccak256 del testo della recensione.
    * @param _rating Il voto, da 1 a 5.
    */

    function createReview(
        uint256 _businessId,
        bytes32 _contentHash,
        uint8 _rating
    ) external {
        // --- Controlli di Validità (Requirements) ---
        // Se una di queste condizioni non è vera, la transazione fallisce e viene annullata.
        require(_rating >= 1 && _rating <= 5, "Rating must be between 1 and 5");
        require(_businessId > 0, "Business ID must be valid");

        // --- Logica di Stato ---
            
        // Incrementa il contatore per il nuovo ID.
        _reviewCounter++;
        uint256 newReviewId = _reviewCounter;

        // Crea la nuova struttura Review in memoria.
        Review memory newReview = Review({
            id: newReviewId,
            author: msg.sender, // msg.sender è l'indirizzo che ha chiamato la funzione
            businessId: _businessId,
            contentHash: _contentHash,
            rating: _rating,
            timestamp: block.timestamp // block.timestamp è il timestamp del blocco corrente
        });

        // Salva la nuova recensione nello storage della blockchain.
        reviews[newReviewId] = newReview;
        reviewCountByAuthor[msg.sender]++;

        // --- INIZIO MODIFICA: AGGIORNA REPUTAZIONE ---
        reputationScore[msg.sender]++;
        // --- FINE MODIFICA ---

        // Emetti l'evento per notificare le applicazioni esterne.
        emit ReviewCreated(newReviewId, msg.sender, _businessId, _rating);
        emit ReputationUpdated(msg.sender, reputationScore[msg.sender]);
    }
}