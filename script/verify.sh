#!/usr/bin/env bash
#
# Verify every deployed contract, on whichever explorer you name.
#
# Monad testnet has two explorers with two separate verification systems, plus Sourcify, and
# verifying on one does nothing for the others. Doing them by hand is thirteen commands per
# explorer with a source path each, which is thirteen chances to point the wrong path at the wrong
# address and "verify" something that is not what is deployed.
#
#   ./script/verify.sh sourcify              # no key, explorer-independent record
#   ./script/verify.sh monadscan             # testnet.monadscan.com; needs ETHERSCAN_API_KEY
#
# Addresses come from deployments/<chainid>.json, so this cannot drift from what was deployed.
set -euo pipefail

TARGET="${1:-sourcify}"
CHAIN_ID="${CHAIN_ID:-10143}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOK="$HERE/deployments/$CHAIN_ID.json"

[ -f "$BOOK" ] || { echo "no address book at $BOOK"; exit 1; }

# Contract name, source path, and the key it lives under in the address book. `TestUSDC` is here
# too: on a testnet it is ours, and on a real deployment the collateral is somebody else's and this
# line comes out.
CONTRACTS=(
  "TradingBlocklist|src/access/TradingBlocklist.sol|tradingBlocklist"
  "TrustedResolver|src/resolvers/TrustedResolver.sol|trustedResolver"
  "ResolverMultisig|src/resolvers/ResolverMultisig.sol|resolverMultisig"
  "OptimisticResolver|src/resolvers/OptimisticResolver.sol|optimisticResolver"
  "NumeraForwarder|src/relay/NumeraForwarder.sol|numeraForwarder"
  "ResolutionForwarder|src/relay/ResolutionForwarder.sol|resolutionForwarder"
  "LsLmsrMarket|src/markets/LsLmsrMarket.sol|lsLmsrMarket"
  "MarketFactory|src/MarketFactory.sol|marketFactory"
  "TestUSDC|src/testnet/TestUSDC.sol|usdc"
  "WithdrawalVerifier|src/pool/verifiers/WithdrawalVerifier.sol|withdrawalVerifier"
  "CommitmentVerifier|src/pool/verifiers/CommitmentVerifier.sol|ragequitVerifier"
  "PrivacyPoolComplex|src/pool/PrivacyPoolComplex.sol|privacyPool"
  "NumeraPoolEntrypoint|src/pool/NumeraPoolEntrypoint.sol|poolEntrypoint"
)

case "$TARGET" in
  sourcify)
    VERIFIER_ARGS=(--verifier sourcify --verifier-url https://sourcify.dev/server)
    WHERE="Sourcify"
    ;;
  monadscan|etherscan)
    : "${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY — one key covers every chain on Etherscan V2}"
    # Etherscan V2 is one endpoint for every chain, selected by `chainid`. Forge appends it.
    VERIFIER_ARGS=(--verifier etherscan --verifier-url "https://api.etherscan.io/v2/api"
                   --etherscan-api-key "$ETHERSCAN_API_KEY")
    WHERE="MonadScan (Etherscan V2)"
    ;;
  *)
    echo "unknown target '$TARGET' — expected 'sourcify' or 'monadscan'"; exit 1 ;;
esac

echo "Verifying $((${#CONTRACTS[@]})) contracts on $WHERE, chain $CHAIN_ID"
echo

ok=0; skipped=0; failed=0
for entry in "${CONTRACTS[@]}"; do
  IFS='|' read -r name path key <<< "$entry"
  address=$(python3 -c "import json;print(json.load(open('$BOOK')).get('$key',''))")
  if [ -z "$address" ]; then
    printf "  --      %-22s not in the address book\n" "$name"; skipped=$((skipped+1)); continue
  fi

  # No --constructor-args anywhere. Both verifiers recompare the deployed bytecode and derive them,
  # which matters here: OptimisticResolver takes a six-field tuple and ResolverMultisig an address
  # array, and hand-encoding either is the usual way this goes wrong.
  if out=$(forge verify-contract "$address" "$path:$name" \
            --chain-id "$CHAIN_ID" "${VERIFIER_ARGS[@]}" --watch 2>&1); then
    if grep -qiE "successfully verified|already verified|is already" <<< "$out"; then
      printf "  ok      %-22s %s\n" "$name" "$address"; ok=$((ok+1)); continue
    fi
  fi
  printf "  FAILED  %-22s %s\n" "$name" "$(tail -2 <<< "$out" | tr '\n' ' ' | cut -c1-140)"
  failed=$((failed+1))
done

echo
echo "$ok verified, $skipped skipped, $failed failed"
[ "$failed" -eq 0 ]
