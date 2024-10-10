// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WadRayMath} from "./math/WadRayMath.sol";
import {PercentageMath} from "./math/PercentageMath.sol";
import {Errors} from "./helpers/Errors.sol";
import {IDefaultInterestRateStrategy} from "./IDefaultInterestRateStrategy.sol";
import {IReserveInterestRateStrategy} from "./IReserveInterestRateStrategy.sol";
import {DataTypes} from "./DataTypes.sol";

/**
 * @title DefaultReserveInterestRateStrategy contract
 * @author Aave
 * @notice Implements the calculation of the interest rates depending on the reserve state
 * @dev The model of interest rate is based on 2 slopes, one before the `OPTIMAL_USAGE_RATIO`
 * point of usage and another from that one to 100%.
 * - An instance of this same contract, can't be used across different Aave markets, due to the caching
 *   of the PoolAddressesProvider
 */

contract DefaultReserveInterestRateStrategy is IDefaultInterestRateStrategy {
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    /// @inheritdoc IDefaultInterestRateStrategy
    uint256 public immutable OPTIMAL_USAGE_RATIO;

    /// @inheritdoc IDefaultInterestRateStrategy
    uint256 public immutable MAX_EXCESS_USAGE_RATIO;

    // Base variable borrow rate when usage rate = 0. Expressed in ray
    uint256 internal immutable _baseVariableBorrowRate;

    // Slope of the variable interest curve when usage ratio > 0 and <= OPTIMAL_USAGE_RATIO. Expressed in ray
    uint256 internal immutable _variableRateSlope1;

    // Slope of the variable interest curve when usage ratio > OPTIMAL_USAGE_RATIO. Expressed in ray
    uint256 internal immutable _variableRateSlope2;

    /**
     * @dev Constructor.
     * @param optimalUsageRatio The optimal usage ratio
     * @param baseVariableBorrowRate The base variable borrow rate
     * @param variableRateSlope1 The variable rate slope below optimal usage ratio
     * @param variableRateSlope2 The variable rate slope above optimal usage ratio
     */
    constructor(
        uint256 optimalUsageRatio,
        uint256 baseVariableBorrowRate,
        uint256 variableRateSlope1,
        uint256 variableRateSlope2
    ) {
        require(
            WadRayMath.RAY >= optimalUsageRatio,
            Errors.INVALID_OPTIMAL_USAGE_RATIO
        );
        OPTIMAL_USAGE_RATIO = optimalUsageRatio;
        MAX_EXCESS_USAGE_RATIO = WadRayMath.RAY - optimalUsageRatio;
        _baseVariableBorrowRate = baseVariableBorrowRate;
        _variableRateSlope1 = variableRateSlope1;
        _variableRateSlope2 = variableRateSlope2;
    }

    /// @inheritdoc IDefaultInterestRateStrategy
    function getVariableRateSlope1() external view returns (uint256) {
        return _variableRateSlope1;
    }

    /// @inheritdoc IDefaultInterestRateStrategy
    function getVariableRateSlope2() external view returns (uint256) {
        return _variableRateSlope2;
    }

    /// @inheritdoc IDefaultInterestRateStrategy
    function getBaseVariableBorrowRate()
        external
        view
        override
        returns (uint256)
    {
        return _baseVariableBorrowRate;
    }

    /// @inheritdoc IDefaultInterestRateStrategy
    function getMaxVariableBorrowRate()
        external
        view
        override
        returns (uint256)
    {
        return
            _baseVariableBorrowRate + _variableRateSlope1 + _variableRateSlope2;
    }

    struct CalcInterestRatesLocalVars {
        uint256 availableLiquidity;
        uint256 totalDebt;
        uint256 currentVariableBorrowRate;
        uint256 currentLiquidityRate;
        uint256 borrowUsageRatio;
        uint256 supplyUsageRatio;
        uint256 availableLiquidityPlusDebt;
    }

    /// @inheritdoc IReserveInterestRateStrategy
    function calculateInterestRates(
        DataTypes.CalculateInterestRatesParams memory params
    ) public view returns (uint256, uint256) {
        CalcInterestRatesLocalVars memory vars;

        vars.totalDebt = params.totalVariableDebt;

        vars.currentLiquidityRate = 0;
        vars.currentVariableBorrowRate = _baseVariableBorrowRate;

        if (vars.totalDebt != 0) {
            vars.availableLiquidity =
                params.totalLiquidity +
                params.liquidityAdded -
                params.liquidityTaken;

            vars.availableLiquidityPlusDebt =
                vars.availableLiquidity +
                vars.totalDebt;
            vars.borrowUsageRatio = vars.totalDebt.rayDiv(
                vars.availableLiquidityPlusDebt
            );
            vars.supplyUsageRatio = vars.totalDebt.rayDiv(
                vars.availableLiquidityPlusDebt
            );
        }

        if (vars.borrowUsageRatio > OPTIMAL_USAGE_RATIO) {
            uint256 excessBorrowUsageRatio = (vars.borrowUsageRatio -
                OPTIMAL_USAGE_RATIO).rayDiv(MAX_EXCESS_USAGE_RATIO);

            vars.currentVariableBorrowRate +=
                _variableRateSlope1 +
                _variableRateSlope2.rayMul(excessBorrowUsageRatio);
        } else {
            vars.currentVariableBorrowRate += _variableRateSlope1
                .rayMul(vars.borrowUsageRatio)
                .rayDiv(OPTIMAL_USAGE_RATIO);
        }

        vars.currentLiquidityRate = vars.currentVariableBorrowRate.rayMul(
            vars.supplyUsageRatio
        );

        return (vars.currentLiquidityRate, vars.currentVariableBorrowRate);
    }
}