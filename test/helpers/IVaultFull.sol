// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1AssetManager} from "../../src/interfaces/IBittyV1AssetManager.sol";
import {IBittyV1PayoutOperator} from "../../src/interfaces/IBittyV1PayoutOperator.sol";

/**
 * @dev Full vault surface for fork tests that need owner + payout operator + asset manager APIs on one typed handle.
 */
interface IVaultFull is IBittyV1Vault, IBittyV1Owner, IBittyV1PayoutOperator, IBittyV1AssetManager {}
