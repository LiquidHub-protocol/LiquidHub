// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title SequencerCheckedAggregator
/// @notice Wrapper Chainlink "sequencer-checké" pour les L2 (Arbitrum). Implémente AggregatorV3Interface et se
///         comporte comme un PASS-THROUGH TRANSPARENT du vrai feed Chainlink (mêmes décimales, même tuple),
///         SAUF qu'il REVERT si le séquenceur L2 est down ou vient de redémarrer (grace period non écoulée).
/// @dev audit V1 (M3-B-fix6, retour Codex) — corrige l'absence de check séquenceur L2 (faille L2 classique :
///      au redémarrage du séquenceur, Chainlink peut servir un prix périmé pendant la fenêtre de grâce).
///
///      POURQUOI UN WRAPPER plutôt que modifier les contrats :
///      - Les prix Chainlink sont lus à PLUSIEURS endroits hors du cache RangeManager : Treasury.collectAndBridge,
///        AaveHedgeManager (_oracleMaxUsdcForWeth, _requireLpNotDeviated). Un fix dans RangeOperations.updatePriceCache
///        n'aurait couvert QUE le cache. Le wrapper couvre TOUS les consommateurs d'un coup.
///      - ZÉRO modification (donc zéro bytecode/storage) des contrats critiques RangeManager/Treasury/HedgeManager,
///        qui continuent d'appeler latestRoundData() sur ce qu'ils croient être un feed Chainlink. Crucial vu la
///        marge EIP-170 très faible côté DN.
///      DÉPLOIEMENT : déployer 1 wrapper par feed distinct (ETH/USD, USDC/USD), puis pointer TOKEN0_ORACLE_ADDRESS /
///      TOKEN1_ORACLE_ADDRESS / ETH_ORACLE_ADDRESS sur les wrappers dans le .env (au lieu des feeds bruts).
///
///      STALENESS : NON géré ici (pass-through pur). Les contrats conservent leur propre check updatedAt
///      (MAX_AGE0/1 cote RangeManager ; max age configurable cote Treasury/HedgeManager). Pas de double comptage.
contract SequencerCheckedAggregator is AggregatorV3Interface {
    /// @notice Le vrai feed Chainlink (ex: ETH/USD) auquel on délègue les données de prix.
    AggregatorV3Interface public immutable underlyingFeed;
    /// @notice Le Sequencer Uptime Feed du L2 (Arbitrum : 0xFdB631F5EE196F0ed6FAa767959853A9F217697D).
    AggregatorV3Interface public immutable sequencerUptimeFeed;
    /// @notice Délai (s) après redémarrage du séquenceur avant de refaire confiance aux prix (typ. 3600 = 1h).
    uint256 public immutable gracePeriod;

    error SequencerDown();
    error GracePeriodNotOver();

    /// @param _underlyingFeed Le feed Chainlink réel (ETH/USD, USDC/USD, ...).
    /// @param _sequencerUptimeFeed Le Sequencer Uptime Feed du L2.
    /// @param _gracePeriod Fenêtre de grâce en secondes (ex: 3600).
    constructor(address _underlyingFeed, address _sequencerUptimeFeed, uint256 _gracePeriod) {
        require(_underlyingFeed != address(0) && _sequencerUptimeFeed != address(0), "zero feed");
        require(_gracePeriod > 0 && _gracePeriod <= 86400, "bad grace"); // borne 0<g<=24h
        underlyingFeed = AggregatorV3Interface(_underlyingFeed);
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
        gracePeriod = _gracePeriod;
    }

    /// @dev Revert si le séquenceur L2 est down OU si la grace period n'est pas écoulée depuis son redémarrage.
    ///      Sequencer Uptime Feed : answer == 0 => UP, answer == 1 => DOWN. startedAt = timestamp du dernier
    ///      changement d'état (donc du dernier redémarrage quand answer revient à 0).
    function _checkSequencer() private view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            sequencerUptimeFeed.latestRoundData();
        if (updatedAt == 0 || answeredInRound < roundId) revert SequencerDown();
        // answer == 1 => séquenceur DOWN. (answer == 0 => UP)
        if (answer != 0) revert SequencerDown();
        // startedAt == 0 : round invalide / pas encore initialisé -> on refuse (conservateur).
        if (startedAt == 0) revert SequencerDown();
        // Grace period : depuis le (re)démarrage, attendre gracePeriod avant de refaire confiance aux prix.
        if (block.timestamp - startedAt <= gracePeriod) revert GracePeriodNotOver();
    }

    // ===== AggregatorV3Interface : prix (sequencer-checké) =====

    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _checkSequencer();
        (roundId, answer, startedAt, updatedAt, answeredInRound) = underlyingFeed.latestRoundData();
        if (updatedAt == 0 || answeredInRound < roundId) revert SequencerDown();
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _checkSequencer();
        return underlyingFeed.getRoundData(_roundId);
    }

    // ===== AggregatorV3Interface : métadonnées (délégation transparente, pas de check séquenceur) =====

    function decimals() external view override returns (uint8) {
        return underlyingFeed.decimals();
    }

    function description() external view override returns (string memory) {
        return underlyingFeed.description();
    }

    function version() external view override returns (uint256) {
        return underlyingFeed.version();
    }
}
