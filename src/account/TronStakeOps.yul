/*
 * TronStakeOps: TRON's Stake 2.0 instructions, behind an ordinary ABI.
 *
 * Solidity has no syntax for TRON's staking opcodes (only TRON's own compiler fork does), and
 * inline assembly cannot emit an unknown opcode. A Yul object can, through `verbatim`, so this file
 * is the one place the build depends on them. It is meant to be DELEGATECALLED: each opcode acts on
 * the account whose code is running (the TVM's context address), so under a delegatecall the
 * caller's account stakes, delegates and withdraws, never this contract's. It keeps no storage and
 * calling it directly only touches its own empty account. It does not refuse call value: under a
 * delegatecall CALLVALUE is the caller's, so a payable caller would be refused for nothing.
 *
 * Opcodes and stack order are java-tron's (actuator/.../vm/Op.java and OperationActions.java): each
 * pops the resource type first, so the type is the FIRST verbatim argument (Yul puts the first
 * argument on top of the stack). Each returns 1/0 (withdrawExpireUnfreeze: the amount released)
 * rather than reverting; the caller decides what a failure means. On a chain without these opcodes
 * (anvil, any EVM) the call reverts on the invalid instruction.
 *
 *   0xda FREEZEBALANCEV2        (amount, resource)          -> ok
 *   0xdb UNFREEZEBALANCEV2      (amount, resource)          -> ok
 *   0xdd WITHDRAWEXPIREUNFREEZE ()                          -> amount released, in sun
 *   0xde DELEGATERESOURCE       (receiver, amount, resource) -> ok
 *   0xdf UNDELEGATERESOURCE     (receiver, amount, resource) -> ok
 *
 * Resource: 0 bandwidth, 1 energy. Amounts are in sun (1 TRX = 1e6).
 */
object "TronStakeOps" {
    code {
        datacopy(0, dataoffset("runtime"), datasize("runtime"))
        return(0, datasize("runtime"))
    }
    object "runtime" {
        code {
            let result := 0
            switch shr(224, calldataload(0))
            // freezeBalanceV2(uint256 amount, uint256 resource)
            case 0x08bee6c4 {
                result := verbatim_2i_1o(hex"da", calldataload(36), calldataload(4))
            }
            // unfreezeBalanceV2(uint256 amount, uint256 resource)
            case 0x2fe36be5 {
                result := verbatim_2i_1o(hex"db", calldataload(36), calldataload(4))
            }
            // withdrawExpireUnfreeze()
            case 0xa465bb19 {
                result := verbatim_0i_1o(hex"dd")
            }
            // delegateResource(address receiver, uint256 amount, uint256 resource)
            case 0xf09cbeba {
                result := verbatim_3i_1o(hex"de", calldataload(68), calldataload(36), receiver())
            }
            // unDelegateResource(address receiver, uint256 amount, uint256 resource)
            case 0x11865b15 {
                result := verbatim_3i_1o(hex"df", calldataload(68), calldataload(36), receiver())
            }
            default { revert(0, 0) }

            mstore(0, result)
            return(0, 32)

            function receiver() -> a {
                a := calldataload(4)
                if shr(160, a) { revert(0, 0) }
            }
        }
    }
}
