// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;
import "v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./RangeOperations.sol";
import "./interfaces/ILiquidityRoutes.sol";
import "./interfaces/IRangeStrategyEngine.sol";
import "./AutonomousErrors.sol";
import "./ProtocolSafetyLib.sol";
import "openzeppelin-contracts/contracts/utils/math/Math.sol";
import "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IGovernancePoolIntegration.sol";

/// @dev Shared types only: no storage slots or deployable component.
abstract contract VaultAccountingTypes {
    struct UserInfo {
        uint256 shares;
        uint256 depositedToken0;
        uint256 depositedToken1;
        uint256 depositedValueUSD; // Valeur USD au moment du dépôt (fixe)
        uint256 lastDepositTime;
        uint256 totalFeesEarnedToken0;
        uint256 totalFeesEarnedToken1;
        // AUDIT (nettoyage code mort) : timeWeightedShares + lastTimeUpdate RETIRÉS (jamais écrits, modèle
        // accFeePerShare). ABIs off-chain userInfo() mises à jour en conséquence (décodage positionnel).
        uint256 firstDepositTime; // Timestamp du premier dépôt d'une période de détention. Reset à 0 sur withdraw 100%.
        uint256 lastDepositBlock; // Block du dernier dépôt processé. Bloque deposit+withdraw atomique (anti-flash-loan).
    }

    struct PendingDeposit { address user; uint256 amount0; uint256 amount1; uint256 timestamp; }
    struct PendingQueue {
        PendingDeposit[] items;
        uint256 head;
        mapping(address => uint256) indexPlusOne;
        uint256 total0;
        uint256 total1;
    }
 }
interface IVaultAccountingStrategy { function strategyEngine() external view returns (address); }
interface IVaultAccountingSafe { function safe() external view returns (address); }

/// @notice Pooled share accounting and authenticated governance checkpoints.
/// @dev Explicit storage references, no fixed slots, asset custody or arbitrary execution.
interface IVaultAccountingRange {
    function getOwnerPositions() external view returns(uint256[] memory);
    function emergencyWithdrawForUser(uint256 a,uint256 b,address to) external returns(uint256,uint256);
}
interface IVaultAccountingHedge {
    function emergencySettleForVault(uint256 amount,uint256 proportion,bool full,address recipient) external;
}

interface ICompoundRange {
    function pool() external view returns(IUniswapV3Pool);
    function getOwnerPositions() external view returns(uint256[] memory);
    function refreshPriceCache() external;
    function priceCache() external view returns(RangeOperations.PriceCache memory);
    function config() external view returns(RangeOperations.RangeConfig memory);
    function token0() external view returns(address);
    function token1() external view returns(address);
    function positionManager() external view returns(INonfungiblePositionManager);
    function initMultiSwapTvl() external view returns(uint256);
    function executeSwap(address,address,uint256,uint256) external returns(uint256);
    function addLiquidityToPosition() external;
    function getCurrentBalances() external view returns(uint256,uint256);
}
interface ICompoundVault {function syncFeesForDeposits() external;}
interface ICompoundHedge {function getHedgeData() external view returns(uint256,uint256,uint256,uint256);}
interface ICompoundToken {function balanceOf(address) external view returns(uint256);}

library VaultAccountingLib {
    function currentRangeBalances() external view returns(uint256,uint256) {
        ICompoundRange rm=ICompoundRange(address(this));
        return RangeOperations.getCurrentBalances(rm.token0(),rm.token1(),address(this),
            rm.getOwnerPositions(),rm.positionManager(),rm.pool());
    }

    error LiquidityRouteInvalid();
    function _requireRouteCode(address target) private view {
        if(target!=address(0) && target.code.length==0)revert LiquidityRouteInvalid();
    }
    function _routeFee(uint24 fee) private pure returns(bool){return fee==100||fee==500||fee==3000||fee==10000;}
    function configureLiquidityRoutes(LiquidityRoutes storage stored, bytes calldata encoded) external {
        LiquidityRoutes memory input=abi.decode(encoded,(LiquidityRoutes));
        _requireRouteCode(input.curve);_requireRouteCode(input.fluid);
        _requireRouteCode(input.augustus);_requireRouteCode(input.executor);
        _requireRouteCode(input.executor2);_requireRouteCode(input.executor3);_requireRouteCode(input.executor4);
        if ((input.augustus == address(0)) != (input.executor == address(0))
            || (input.augustus==address(0)&&(input.executor2!=address(0)||input.executor3!=address(0)||input.executor4!=address(0)))) revert LiquidityRouteInvalid();
        if (input.alternativeFee != 0 && input.alternativeFee != 100 && input.alternativeFee != 500
            && input.alternativeFee != 3000 && input.alternativeFee != 10000) revert LiquidityRouteInvalid();
        if (input.hedgeAlternativeFee != 0 && input.hedgeAlternativeFee != 100 && input.hedgeAlternativeFee != 500
            && input.hedgeAlternativeFee != 3000 && input.hedgeAlternativeFee != 10000) revert LiquidityRouteInvalid();
        if (input.augustus != address(0) && input.minVeloraTvlUsd < 10000) revert LiquidityRouteInvalid();
        ICompoundRange rm = ICompoundRange(address(this));
        if (input.curve != address(0)) {
            (bool a, bytes memory x) = input.curve.staticcall(abi.encodeWithSignature("coins(uint256)", 0));
            (bool b, bytes memory y) = input.curve.staticcall(abi.encodeWithSignature("coins(uint256)", 1));
            if (!a || !b || x.length != 32 || y.length != 32 || abi.decode(x,(address)) != rm.token0()
                || abi.decode(y,(address)) != rm.token1()) revert LiquidityRouteInvalid();
        }
        if (input.fluid != address(0)) {
            (bool ok, bytes memory ret) = input.fluid.staticcall(abi.encodeWithSignature("constantsView()"));
            if (!ok || ret.length < 352) revert LiquidityRouteInvalid();
            address t0; address t1;
            assembly ("memory-safe") { t0 := mload(add(ret,320)) t1 := mload(add(ret,352)) }
            if (!((t0 == rm.token0() && t1 == rm.token1()) || (t1 == rm.token0() && t0 == rm.token1())))
                revert LiquidityRouteInvalid();
            input.fluidToken0 = t0;
        } else input.fluidToken0 = address(0);
        if(input.hedgeBridgeToken!=address(0)) {
            _requireRouteCode(input.hedgeBridgeToken);
            if(input.hedgeBridgeToken==rm.token0()||input.hedgeBridgeToken==rm.token1()
                || !_routeFee(input.hedgeBridgeFee0)||!_routeFee(input.hedgeBridgeFee1))revert LiquidityRouteInvalid();
        } else if(input.hedgeBridgeFee0!=0||input.hedgeBridgeFee1!=0)revert LiquidityRouteInvalid();
        stored.hedgeBridgeToken=input.hedgeBridgeToken;
        stored.hedgeBridgeFee0=input.hedgeBridgeFee0;stored.hedgeBridgeFee1=input.hedgeBridgeFee1;
        stored.curve = input.curve; stored.fluid = input.fluid;
        stored.augustus = input.augustus; stored.executor = input.executor;
        stored.alternativeFee = input.alternativeFee; stored.minVeloraTvlUsd = input.minVeloraTvlUsd;
        if (input.maxExternalSwapUsd > 10000000 || input.maxExternalTvlBps > 5000
            || (input.maxExternalSwapUsd == 0) != (input.maxExternalTvlBps == 0)
            || (input.maxExternalSwapUsd != 0 && input.minVeloraTvlUsd < 10000)) revert LiquidityRouteInvalid();
        stored.fluidToken0 = input.fluidToken0;
        stored.maxExternalSwapUsd = input.maxExternalSwapUsd;
        stored.maxExternalTvlBps = input.maxExternalTvlBps;
        stored.hedgeAlternativeFee = input.hedgeAlternativeFee;
        stored.executor2=input.executor2;stored.executor3=input.executor3;stored.executor4=input.executor4;
    }

    event LiquidityCompounded(uint256 indexed tokenId,uint256 amount0,uint256 amount1,address indexed keeper);
    error ProgressiveMarketGuard();
    error CompoundHedgeChanged();
    function compoundPosition(address rangeManager,address vault,address strategyEngine,address) external returns (uint256) {
        ICompoundRange rm = ICompoundRange(rangeManager);
        uint256[] memory positions = rm.getOwnerPositions();
        if (positions.length != 1) return 0;
        rm.refreshPriceCache();
        RangeOperations.PriceCache memory cache=rm.priceCache();
        require(cache.valid && cache.price0>0 && cache.price1>0,AutonomousCheck(0x040745e3));
        // A STABLE depeg pauses investment, not ordinary checkpoint-stale maintenance.
        if (
            IRangeStrategyEngine(strategyEngine).previewDecision().reason
                == IRangeStrategyEngine.ReasonCode.ORACLE_GUARD
        ) {
            revert ProgressiveMarketGuard();
        }
        (,,,,, int24 lower, int24 upper,,,,,) = rm.positionManager().positions(positions[0]);
        if (cache.poolTick <= lower || cache.poolTick >= upper) return 0;
        ICompoundVault(vault).syncFeesForDeposits();
        RangeOperations.RangeConfig memory cfg = rm.config();
        address t0 = rm.token0();
        address t1 = rm.token1();
        uint256 b0 = ICompoundToken(t0).balanceOf(rangeManager);
        uint256 b1 = ICompoundToken(t1).balanceOf(rangeManager);
        RangeOperations.OptimalSwapParams memory plan =
            RangeOperations.calculateOptimalSwapParams(b0, b1, cache, cfg, lower, upper);
        if (plan.swapNeeded && plan.amountIn > 0) {
            uint256 priceIn = plan.zeroForOne ? cache.price0 : cache.price1;
            uint256 priceOut = plan.zeroForOne ? cache.price1 : cache.price0;
            uint256 scaleIn = 10 ** (plan.zeroForOne ? cfg.token0Decimals : cfg.token1Decimals);
            uint256 scaleOut = 10 ** (plan.zeroForOne ? cfg.token1Decimals : cfg.token0Decimals);
            uint256 cap = Math.mulDiv(rm.initMultiSwapTvl() * 1e8, scaleIn, priceIn);
            uint256 amount = Math.min(plan.amountIn, cap);
            uint256 minOut = Math.mulDiv(amount, priceIn * scaleOut, priceOut * scaleIn);
            minOut = Math.mulDiv(minOut, 10000 - cfg.maxSlippageBps, 10000);
            if (amount > 0 && minOut > 0) {
                rm.executeSwap(plan.zeroForOne ? t0 : t1, plan.zeroForOne ? t1 : t0, amount, minOut);
            }
            b0 = ICompoundToken(t0).balanceOf(rangeManager);
            b1 = ICompoundToken(t1).balanceOf(rangeManager);
        }
        // Skip quantities below oracle precision before calling the position manager.
        if (
            Math.mulDiv(b0, cache.price0, 10 ** cfg.token0Decimals) == 0
                || Math.mulDiv(b1, cache.price1, 10 ** cfg.token1Decimals) == 0
        ) return 0;
        rm.addLiquidityToPosition();
        uint256 added0 = b0 - ICompoundToken(t0).balanceOf(rangeManager);
        uint256 added1 = b1 - ICompoundToken(t1).balanceOf(rangeManager);
        emit LiquidityCompounded(positions[0], added0, added1, msg.sender);
        return Math.mulDiv(added0, cache.price0, 10 ** cfg.token0Decimals)
            + Math.mulDiv(added1, cache.price1, 10 ** cfg.token1Decimals);
    }
    using SafeERC20 for IERC20;
    error OnlyEmergencySafe(); error InvalidRecipient(); error PendingReserveDeficit(); error EmergencyLiquidityShortfall();
    error E03(); error E43(); error E44(); error E46();
    event EmergencyUserRecovered(address indexed user,uint256 amount0,uint256 amount1,uint256 shares);
    struct Recovery {
        address manager; address token0; address token1; address controller; address safe; address hedge; uint256 total;
    }

    error FirstDepositTooSmall();
    error E24();
    uint256 private constant DEAD_SHARES = 1_000_000;
    struct DepositUpdate {
        uint256 credited;
        uint256 previousValue;
        uint256 previousShares;
        uint256 amount0;
        uint256 amount1;
        bool dn;
    }

    function updateFees(VaultAccountingTypes.UserInfo storage user,
        mapping(address => uint256) storage debt0, mapping(address => uint256) storage debt1,
        address wallet, uint256 acc0, uint256 acc1) external {
        _updateFees(user, debt0, debt1, wallet, acc0, acc1);
    }
    function _updateFees(VaultAccountingTypes.UserInfo storage user,
        mapping(address => uint256) storage debt0, mapping(address => uint256) storage debt1,
        address wallet, uint256 acc0, uint256 acc1) private {
        uint256 a=user.shares*acc0; uint256 b=user.shares*acc1;
        if(user.shares!=0) {
            user.totalFeesEarnedToken0+=(a-debt0[wallet])/1e36;
            user.totalFeesEarnedToken1+=(b-debt1[wallet])/1e36;
        }
        debt0[wallet]=a; debt1[wallet]=b;
    }
    function finalizeDeposit(VaultAccountingTypes.UserInfo storage user,
        mapping(address => uint256) storage debt0, mapping(address => uint256) storage debt1,
        address wallet, uint256 acc0, uint256 acc1, DepositUpdate calldata d)
        external returns(uint256 minted,uint256 newTotal) {
        if(d.credited==0) { if(d.dn) revert E24(); revert AutonomousCheck(0xb040a10f); }
        if(d.previousShares<=DEAD_SHARES) {
            minted=(d.credited+d.previousValue)*1e10;
            if(minted<=DEAD_SHARES) { if(d.dn) revert E24(); revert FirstDepositTooSmall(); }
            minted-=DEAD_SHARES;
            newTotal=DEAD_SHARES;
        } else {
            minted=d.credited*d.previousShares/d.previousValue;
            require(minted!=0,AutonomousCheck(0x6dce6290));
            newTotal=d.previousShares;
        }
        _updateFees(user,debt0,debt1,wallet,acc0,acc1);
        if(user.shares==0) user.firstDepositTime=block.timestamp;
        user.shares+=minted;
        user.depositedToken0+=d.amount0; user.depositedToken1+=d.amount1;
        user.depositedValueUSD+=d.credited;
        user.lastDepositTime=block.timestamp; user.lastDepositBlock=block.number;
        debt0[wallet]=user.shares*acc0; debt1[wallet]=user.shares*acc1;
        newTotal+=minted;
    }
    function reduceUser(VaultAccountingTypes.UserInfo storage user,
        mapping(address => uint256) storage debt0, mapping(address => uint256) storage debt1,
        address wallet,uint256 amount,uint256 acc0,uint256 acc1) external {
        uint256 beforeShares=user.shares;
        user.shares=beforeShares-amount;
        if(user.shares==0) {
            user.depositedToken0=0; user.depositedToken1=0; user.depositedValueUSD=0;
            user.totalFeesEarnedToken0=0; user.totalFeesEarnedToken1=0; user.firstDepositTime=0;
        } else {
            // Preserve native rounding: changing it can change qualification generations.
            uint256 remaining=1e18-amount*1e18/beforeShares;
            user.depositedToken0=user.depositedToken0*remaining/1e18;
            user.depositedToken1=user.depositedToken1*remaining/1e18;
            user.depositedValueUSD=user.depositedValueUSD*remaining/1e18;
            user.totalFeesEarnedToken0=user.totalFeesEarnedToken0*remaining/1e18;
            user.totalFeesEarnedToken1=user.totalFeesEarnedToken1*remaining/1e18;
        }
        debt0[wallet]=user.shares*acc0; debt1[wallet]=user.shares*acc1;
    }
    /// @dev Library delegatecalls keep the authenticated Vault as caller of every journal.
    function notifyGovernanceShares(address controller, address wallet, uint256 balance,
        uint256 creditedUsdE8, bool withdrawal, uint256 poolTotal) external { _notifyGovernanceShares(controller,wallet,balance,creditedUsdE8,withdrawal,poolTotal); }
    function _notifyGovernanceShares(address controller, address wallet, uint256 balance,
        uint256 creditedUsdE8, bool withdrawal, uint256 poolTotal) private {
        (address journal, address voting, address rebate) =
            IGovernancePoolController(controller).governanceHooks();
        if (journal == address(0)) return; // Unregistered fixtures only; official installations require all hooks.
        require(voting.code.length != 0 && rebate.code.length != 0, AutonomousCheck(0x2c7e43eb));
        IExposureJournalHook(journal).recordExposure(wallet, balance, creditedUsdE8, withdrawal);
        IDepositorSharesHook(voting).recordShares(wallet, balance);
        IFeeRebateHook escrow = IFeeRebateHook(rebate);
        // Account for native permanently burned shares, without granting them voting/premium rights.
        if (poolTotal >= 1_000_000 && escrow.shares(address(0xdead)) == 0) {
            escrow.setShares(address(0xdead), 1_000_000);
        }
        escrow.setShares(wallet, balance);
    }


    function recordGovernanceFees(address controller, uint256 gross0, uint256 gross1,
        uint256 commission0, uint256 commission1) external {
        address rebate = IGovernancePoolController(controller).feeRebate();
        if (rebate != address(0)) IFeeRebateHook(rebate).recordFees(gross0, gross1, commission0, commission1);
    }

    function validateAdditionalCapital(address controller,uint256 incomingUsdE8) external view {
        IGovernancePoolController(controller).requireAdditionalCapital(incomingUsdE8);
    }

    function installPoolVoting(address manager, address voting, uint32[12] calldata bounds, bool stable) external {
        address engine = IVaultAccountingStrategy(manager).strategyEngine();
        if (stable) IEngineVotingInstallation(engine).installDepositorVoting(voting, bounds);
        else IEngineVotingInstallation(engine).installDepositorVoting(voting);
    }

    function validateFactorySafe(address controller, address expectedSafe, address emergencySafe) external view {
        require(expectedSafe != address(0) && expectedSafe == emergencySafe
            && IVaultAccountingSafe(controller).safe() == expectedSafe,
            AutonomousCheck(0x486e7412));
    }

    function removePending(VaultAccountingTypes.PendingQueue storage queue,
        mapping(address => bool) storage hasPendingDeposit,uint256 index,VaultAccountingTypes.PendingDeposit memory pd) external {
        _removePending(queue,hasPendingDeposit,index,pd);
    }
    function _removePending(VaultAccountingTypes.PendingQueue storage queue,
        mapping(address => bool) storage hasPendingDeposit,uint256 index,VaultAccountingTypes.PendingDeposit memory pd) private {

        hasPendingDeposit[pd.user] = false;
        delete queue.indexPlusOne[pd.user];
        queue.total0 -= pd.amount0;
        queue.total1 -= pd.amount1;

        uint256 head = queue.head;
        uint256 last = queue.items.length - 1;
        if (index == head) {
            delete queue.items[index];
            queue.head = head + 1;
        } else {
            if (index != last) {
                VaultAccountingTypes.PendingDeposit memory moved = queue.items[last];
                queue.items[index] = moved;
                queue.indexPlusOne[moved.user] = index + 1;
            }
            queue.items.pop();
        }

        if (queue.head >= queue.items.length) {
            // Every former slot was cleared by the head branch or pop(). Reset only the length:
            // Solidity's `delete queue.items` would still traverse all historical indices.
            VaultAccountingTypes.PendingDeposit[] storage items=queue.items;
            assembly ("memory-safe") {
                sstore(items.slot, 0)
            }
            queue.head = 0;
        }
        }

    function recoverStandard(mapping(address => VaultAccountingTypes.UserInfo) storage userInfo,
        mapping(address => uint256) storage userFeeDebtToken0,
        mapping(address => uint256) storage userFeeDebtToken1,
        mapping(address => bool) storage hasPendingDeposit,
        VaultAccountingTypes.PendingQueue storage queue,Recovery calldata c,address userAddress)
        external returns(uint256 nextTotal) {
        nextTotal=c.total;

        if (!ProtocolSafetyLib.recoveryAllowed(c.controller, c.safe, userAddress, 1)) {
            revert OnlyEmergencySafe();
        }
        require(userAddress != address(0), "E43");

        VaultAccountingTypes.UserInfo storage user = userInfo[userAddress];
        uint256 userShares = user.shares;
        uint256 totalSharesBefore = nextTotal;

        // Verifier que l'utilisateur a des fonds ou des depots en attente
        require(userShares > 0 || hasPendingDeposit[userAddress], "E44");
        uint256 userAmount0 = 0;
        uint256 userAmount1 = 0;
        uint256 vaultBalance0 = 0;
        uint256 vaultBalance1 = 0;
        uint256 neededFromRange0 = 0;
        uint256 neededFromRange1 = 0;

        // 1. CALCULER LA PART DE L'UTILISATEUR
        if (userShares > 0) {
            require(IVaultAccountingRange(c.manager).getOwnerPositions().length == 0, "E46");
            // SÉCURITÉ (audit V1) : balanceOf(vault) inclut les dépôts EN ATTENTE de TOUS les users
            // (deposit() transfère sur le vault avant traitement). Il faut les EXCLURE du calcul
            // proportionnel, sinon un user récupérerait une part d'un total gonflé par les pending
            // d'autrui (même classe de bug que le sweep balanceOf au withdraw). Les pending du user
            // lui-même sont ajoutés séparément à l'étape 3.
            // Recuperer les balances totales (Vault HORS pending + RangeManager)
            uint256 rawVault0 = IERC20(c.token0).balanceOf(address(this));
            uint256 rawVault1 = IERC20(c.token1).balanceOf(address(this));
            if (rawVault0 < queue.total0 || rawVault1 < queue.total1) revert PendingReserveDeficit();
            vaultBalance0 = rawVault0 - queue.total0;
            vaultBalance1 = rawVault1 - queue.total1;

            uint256 rangeBalance0 = IERC20(c.token0).balanceOf(c.manager);
            uint256 rangeBalance1 = IERC20(c.token1).balanceOf(c.manager);

            // Calculer la part proportionnelle
            uint256 totalBalance0 = vaultBalance0 + rangeBalance0;
            uint256 totalBalance1 = vaultBalance1 + rangeBalance1;

            userAmount0 = (totalBalance0 * userShares) / totalSharesBefore;
            userAmount1 = (totalBalance1 * userShares) / totalSharesBefore;

            // 2. ReCUPeRER LES FONDS DEPUIS RANGEMANAGER SI NeCESSAIRE
            // Calculer combien on doit recuperer depuis RangeManager
            if (userAmount0 > vaultBalance0) {
                neededFromRange0 = userAmount0 - vaultBalance0;
                // S'assurer de ne pas demander plus que ce qui est disponible
                if (neededFromRange0 > rangeBalance0) {
                    neededFromRange0 = rangeBalance0;
                }
            }

            if (userAmount1 > vaultBalance1) {
                neededFromRange1 = userAmount1 - vaultBalance1;
                // S'assurer de ne pas demander plus que ce qui est disponible
                if (neededFromRange1 > rangeBalance1) {
                    neededFromRange1 = rangeBalance1;
                }
            }
        }

        // 3. Recuperer depuis RangeManager AVANT toute suppression d'accounting utilisateur.
        //    Fail-closed : si RangeManager revert, toute la transaction revert et userInfo reste intact.
        if (neededFromRange0 > 0 || neededFromRange1 > 0) {
            (uint256 received0, uint256 received1) = IVaultAccountingRange(c.manager)
                .emergencyWithdrawForUser(neededFromRange0, neededFromRange1, address(this));
            require(received0 == neededFromRange0 && received1 == neededFromRange1, "E47");
        }

        // 4. GeRER LE DePoT EN ATTENTE PAR INDEX (O(1))
        if (hasPendingDeposit[userAddress]) {
            uint256 indexPlusOne = queue.indexPlusOne[userAddress];
            require(indexPlusOne > queue.head && indexPlusOne <= queue.items.length, "E48");
            uint256 index = indexPlusOne - 1;
            VaultAccountingTypes.PendingDeposit memory pd = queue.items[index];
            require(pd.user == userAddress, "E48");
            userAmount0 += pd.amount0;
            userAmount1 += pd.amount1;
            _removePending(queue,hasPendingDeposit,index,pd);
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        // 5. METTRE a JOUR LES STATS APRES RECUPERATION EFFECTIVE DES FONDS
        if (userShares > 0) {
            nextTotal = totalSharesBefore > userShares ? totalSharesBefore - userShares : 0;

            // Reset les infos de l'utilisateur
            delete userInfo[userAddress];
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        // 6. ENVOYER EXACTEMENT LES FONDS DUS A L'UTILISATEUR.
        //    Les reserves pending restantes sont exclues et toute incoherence fait revert avant que les
        //    shares ne puissent etre effacees (la transaction EVM reste atomique).
        uint256 finalBalance0 = IERC20(c.token0).balanceOf(address(this));
        uint256 finalBalance1 = IERC20(c.token1).balanceOf(address(this));
        if (finalBalance0 < queue.total0 || finalBalance1 < queue.total1) revert PendingReserveDeficit();
        uint256 available0 = finalBalance0 - queue.total0;
        uint256 available1 = finalBalance1 - queue.total1;
        if (available0 < userAmount0 || available1 < userAmount1) revert EmergencyLiquidityShortfall();

        if (userAmount0 > 0) {
            IERC20(c.token0).safeTransfer(userAddress, userAmount0);
        }
        if (userAmount1 > 0) {
            IERC20(c.token1).safeTransfer(userAddress, userAmount1);
        }

        if (userShares != 0) _notifyGovernanceShares(c.controller,userAddress,0,0,true,nextTotal);

        emit EmergencyUserRecovered(userAddress, userAmount0, userAmount1, userShares);

    }

    function recoverDn(mapping(address => VaultAccountingTypes.UserInfo) storage userInfo,
        mapping(address => uint256) storage userFeeDebtToken0,
        mapping(address => uint256) storage userFeeDebtToken1,
        mapping(address => bool) storage hasPendingDeposit,
        VaultAccountingTypes.PendingQueue storage queue,Recovery calldata c,address userAddress)
        external returns(uint256 nextTotal) {
        nextTotal=c.total;

        if (!ProtocolSafetyLib.recoveryAllowed(c.controller, c.safe, userAddress, 1)) revert E03();
        if (userAddress == address(0)) revert E43();

        VaultAccountingTypes.UserInfo storage user = userInfo[userAddress];
        uint256 userShares = user.shares;
        uint256 totalSharesBefore = nextTotal;

        if (userShares == 0 && !hasPendingDeposit[userAddress]) revert E44();

        uint256 userAmount0 = 0;
        uint256 userAmount1 = 0;
        uint256 n0 = 0;
        uint256 n1 = 0;

        // 1. Shares actives (cas normal)
        //    EmergencyBurnPositions doit etre appele avant pour ramener les tokens sur vault/RM
        if (userShares > 0) {
            (userAmount0, userAmount1, n0, n1) = ProtocolSafetyLib.emergencyShares(
                c.manager,
                address(IERC20(c.token0)),
                address(IERC20(c.token1)),
                queue.total0,
                queue.total1,
                userShares,
                totalSharesBefore
            );
        }

        // 2. Depot en attente: index direct + swap-and-pop, donc O(1).
        if (hasPendingDeposit[userAddress]) {
            uint256 idx1 = queue.indexPlusOne[userAddress];
            uint256 len = queue.items.length;
            if (idx1 == 0 || idx1 <= queue.head || idx1 > len) revert E44();
            uint256 i = idx1 - 1;
            VaultAccountingTypes.PendingDeposit memory pd = queue.items[i];
            if (pd.user != userAddress) revert E44();
            userAmount0 += pd.amount0;
            userAmount1 += pd.amount1;
            _removePending(queue,hasPendingDeposit,i,pd);
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        // 3. Settle hedge proportionnel pour pools DN
        uint256 proportionX18 =
            totalSharesBefore > 0 ? Math.mulDiv(userShares, 1e18, totalSharesBefore, Math.Rounding.Up) : 0;
        bool isFullWithdraw = totalSharesBefore > userShares ? totalSharesBefore - userShares <= DEAD_SHARES : true;

        // 4. Mettre a jour les stats avant les appels externes.
        if (userShares > 0) {
            nextTotal = totalSharesBefore > userShares ? totalSharesBefore - userShares : 0;
            delete userInfo[userAddress];
            delete userFeeDebtToken0[userAddress];
            delete userFeeDebtToken1[userAddress];
        }

        uint256 bal0BeforeWithdraw = IERC20(c.token0).balanceOf(address(this));
        if (n0 > 0 || n1 > 0) {
            (uint256 received0, uint256 received1) =
                IVaultAccountingRange(c.manager).emergencyWithdrawForUser(n0, n1, address(this));
            if (received0 != n0 || received1 != n1) revert E46();
        }

        // Emergency DN : le settlement AAVE envoie directement la part hedge au user. Cela evite de sous-compter
        // le IERC20(c.token0) eventuellement renvoye par le HedgeManager et garde le Vault plafonne au reliquat LP/pending.
        uint256 wethForRepay = 0;
        if (c.hedge != address(0) && userShares > 0) {
            uint256 bal0AfterWithdraw = IERC20(c.token0).balanceOf(address(this));
            wethForRepay = bal0AfterWithdraw > bal0BeforeWithdraw ? bal0AfterWithdraw - bal0BeforeWithdraw : 0;
            if (wethForRepay > 0) {
                IERC20(c.token0).safeTransfer(c.hedge, wethForRepay);
            }
            IVaultAccountingHedge(c.hedge)
                .emergencySettleForVault(wethForRepay, proportionX18, isFullWithdraw, userAddress);
        }

        // 5. Envoyer les fonds.
        // SÉCURITÉ (audit V1) : ne JAMAIS envoyer balanceOf(vault) entier — il inclut les dépôts EN
        // ATTENTE des AUTRES users. À ce stade, le pending de CE user a déjà été retiré de la queue
        // (étape 2) ; il reste donc sur le vault les pending des autres, à exclure. On borne le solde
        // disponible à (balanceOf − pending des autres) puis on plafonne par le dû du user.
        uint256 rawBal0 = IERC20(c.token0).balanceOf(address(this));
        uint256 rawBal1 = IERC20(c.token1).balanceOf(address(this));
        if (rawBal0 < queue.total0 || rawBal1 < queue.total1) revert E46();
        uint256 bal0 = rawBal0 - queue.total0;
        uint256 bal1 = rawBal1 - queue.total1;
        // La part IERC20(c.token0) envoyee au HedgeManager sert au settlement AAVE de cet utilisateur. Le reliquat LP
        // et la totalite du IERC20(c.token1) doivent rester disponibles avant d'effacer definitivement ses shares.
        // Toute incoherence revert atomiquement au lieu de convertir une recuperation en perte silencieuse.
        if (wethForRepay > userAmount0) revert E46();
        uint256 toSend0 = userAmount0 - wethForRepay;
        uint256 toSend1 = userAmount1;
        if (bal0 < toSend0 || bal1 < toSend1) revert E46();
        if(toSend0!=0) IERC20(c.token0).safeTransfer(userAddress,toSend0);
        if(toSend1!=0) IERC20(c.token1).safeTransfer(userAddress,toSend1);

        if (userShares != 0) _notifyGovernanceShares(c.controller,userAddress,0,0,true,nextTotal);

        emit EmergencyUserRecovered(userAddress, toSend0, toSend1, userShares);

    }
}
