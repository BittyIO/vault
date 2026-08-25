// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

/**
 * @dev The EOA BittyV1Guard hardcodes as its deployer and sole admin.
 *
 *      The guard's constructor reverts NotDeployer() unless tx.origin is this address, and it grants
 *      DEFAULT_ADMIN_ROLE plus every manager role to it — nothing is granted to whoever happens to
 *      deploy. Tests therefore have to deploy AND configure the guard as this address, which needs
 *      the two-argument vm.startPrank(sender, txOrigin): neither the `tx_origin` config key nor
 *      `forge test --tx-origin` reaches the constructor call that deployCodeTo makes.
 *
 *      Roles are still granted onward to tx.origin, so every test that already treats tx.origin as
 *      the guard manager keeps working unchanged.
 */
address constant GUARD_DEPLOYER = 0x12EE2de7BF086388B1D560eb95e7191Edfab9823;
