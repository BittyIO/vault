// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.34;

import {IBittyV1Vault} from "../../src/interfaces/IBittyV1Vault.sol";
import {IBittyV1Owner} from "../../src/interfaces/IBittyV1Owner.sol";
import {IBittyV1Manager} from "../../src/interfaces/IBittyV1Manager.sol";
import {IBittyV1Operator} from "../../src/interfaces/IBittyV1Operator.sol";

/**
 * @dev Full vault surface for fork tests that need owner + operator + manager APIs on one typed handle.
 */
interface IVaultFull is IBittyV1Vault, IBittyV1Owner, IBittyV1Operator, IBittyV1Manager {}
