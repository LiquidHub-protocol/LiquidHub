// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title SequencerCheckedAggregator
/// @notice Wrapper Chainlink "sequencer-checké" pour les L2 (Arbitrum). Implémente AggregatorV3Interface et se
///         normalise le prix en 8 decimales et REVERT si le séquenceur L2 est down ou vient de redémarrer.
/// @dev audit V1 (M3-B-fix6, retour Codex) — corrige l'absence de check séquenceur L2 (faille L2 classique :
///      au redémarrage du séquenceur, Chainlink peut servir un prix périmé pendant la fenêtre de grâce).
///
///      POURQUOI UN WRAPPER plutôt que modifier les contrats :
///      - Les prix Chainlink sont lus à PLUSIEURS endroits hors du cache RangeManager : Treasury.collectAndBridge,
///        AaveHedgeManager (_oracleMaxUsdcForWeth, _requireLpNotDeviated). Un fix dans RangeOperations.updatePriceCache
///        n'aurait couvert QUE le cache. Le wrapper couvre TOUS les consommateurs d'un coup.
///      - Les contrats critiques RangeManager/Treasury/HedgeManager continuent d'appeler latestRoundData()
///        sur ce qu'ils croient être un feed Chainlink. Le wrapper garantit aussi un prix USD en 8 décimales,
///        y compris si un futur feed Chainlink n'utilise pas 8 décimales.
///      DÉPLOIEMENT : déployer 1 wrapper par feed distinct (ETH/USD, USDC/USD), puis pointer TOKEN0_ORACLE_ADDRESS /
///      TOKEN1_ORACLE_ADDRESS / NATIVE_ORACLE_ADDRESS sur les wrappers dans le .env (au lieu des feeds bruts).
///
///      STALENESS : NON géré ici (pass-through pur). Les contrats conservent leur propre check updatedAt
///      (MAX_AGE0/1 cote RangeManager ; max age configurable cote Treasury/HedgeManager). Pas de double comptage.
contract SequencerCheckedAggregator is AggregatorV3Interface {
    /// @notice Le vrai feed Chainlink (ex: ETH/USD) auquel on délègue les données de prix.
    AggregatorV3Interface public immutable underlyingFeed;
    /// @notice Le Sequencer Uptime Feed du L2 (Arbitrum : 0xFdB631F5EE196F0ed6FAa767959853A9F217697D).
    AggregatorV3Interface public immutable sequencerUptimeFeed;
    uint8 public immutable underlyingDecimals;
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
        AggregatorV3Interface feed = AggregatorV3Interface(_underlyingFeed);
        uint8 dec = feed.decimals();
        require(dec <= 18, "bad dec");
        underlyingFeed = feed;
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
        underlyingDecimals = dec;
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
        answer = _normalizeAnswer(answer);
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        _checkSequencer();
        (roundId, answer, startedAt, updatedAt, answeredInRound) = underlyingFeed.getRoundData(_roundId);
        answer = _normalizeAnswer(answer);
    }

    function _normalizeAnswer(int256 answer) private view returns (int256) {
        if (answer <= 0) return answer;
        uint256 value = uint256(answer);
        uint8 dec = underlyingDecimals;
        if (dec > 8) value = value / (10 ** (dec - 8));
        else if (dec < 8) value = value * (10 ** (8 - dec));
        return int256(value);
    }

    // ===== AggregatorV3Interface : métadonnées =====

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external view override returns (string memory) {
        return underlyingFeed.description();
    }

    function version() external view override returns (uint256) {
        return underlyingFeed.version();
    }
}
