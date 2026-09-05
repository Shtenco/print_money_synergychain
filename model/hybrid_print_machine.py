from __future__ import annotations

from dataclasses import dataclass, replace
from decimal import Decimal
from enum import StrEnum

D = Decimal


class ProfitSource(StrEnum):
    METAPAY_CLASSIC = "METAPAY_CLASSIC"
    DEX_ARBITRAGE = "DEX_ARBITRAGE"
    HYBRID_CLASSIC_DEX = "HYBRID_CLASSIC_DEX"


@dataclass(frozen=True, slots=True)
class EconomicState:
    """Minimal falsifiable state for the SYNERGY print-machine research loop.

    `external_cash` and `dex_external_reserve` are externally redeemable assets.
    `internal_supply` and `internal_mark` are internal accounting/market variables.
    They cannot increase canonical external NAV by themselves.
    """

    external_cash: Decimal
    dex_external_reserve: Decimal = D("0")
    external_liabilities: Decimal = D("0")
    internal_supply: Decimal = D("0")
    internal_mark: Decimal = D("1")
    realized_external_pnl: Decimal = D("0")
    distributions: Decimal = D("0")

    @property
    def hard_nav(self) -> Decimal:
        return self.external_cash + self.dex_external_reserve - self.external_liabilities

    @property
    def internal_mark_value(self) -> Decimal:
        return self.internal_supply * self.internal_mark


@dataclass(frozen=True, slots=True)
class RealizedRoute:
    source: ProfitSource
    settlement_asset: str
    principal: Decimal
    settled_output: Decimal
    external_costs: Decimal = D("0")
    flash_premium: Decimal = D("0")
    settlement_realized: bool = True
    independent_external_counterparty: bool = True
    flash_principal_repaid: bool = True

    @property
    def pnl(self) -> Decimal:
        return self.settled_output - self.principal - self.external_costs - self.flash_premium


class HybridPrintMachine:
    """Conservative research model coupling MetaPay profits to DEX/QE inventory.

    This model intentionally cannot manufacture canonical external wealth from mint
    or revaluation. The only way `hard_nav` can grow is a positive externally
    realized route or another externally classified inflow outside this model.
    """

    def mint_internal(self, state: EconomicState, amount: Decimal) -> EconomicState:
        amount = D(amount)
        if amount < 0:
            raise ValueError("mint amount must be non-negative")
        return replace(state, internal_supply=state.internal_supply + amount)

    def revalue_internal(self, state: EconomicState, multiplier: Decimal) -> EconomicState:
        multiplier = D(multiplier)
        if multiplier <= 0:
            raise ValueError("multiplier must be positive")
        return replace(state, internal_mark=state.internal_mark * multiplier)

    def allocate_external_to_dex(self, state: EconomicState, amount: Decimal) -> EconomicState:
        """Move owned external capital into DEX inventory; system P&L remains zero."""
        amount = D(amount)
        if amount < 0 or amount > state.external_cash:
            raise ValueError("invalid external allocation")
        before = state.hard_nav
        after = replace(
            state,
            external_cash=state.external_cash - amount,
            dex_external_reserve=state.dex_external_reserve + amount,
        )
        assert after.hard_nav == before
        return after

    def deallocate_external_from_dex(self, state: EconomicState, amount: Decimal) -> EconomicState:
        amount = D(amount)
        if amount < 0 or amount > state.dex_external_reserve:
            raise ValueError("invalid DEX deallocation")
        before = state.hard_nav
        after = replace(
            state,
            external_cash=state.external_cash + amount,
            dex_external_reserve=state.dex_external_reserve - amount,
        )
        assert after.hard_nav == before
        return after

    def realize_route(
        self,
        state: EconomicState,
        route: RealizedRoute,
        *,
        retain_profit_in_dex: bool = False,
    ) -> EconomicState:
        """Book only the positive externally settled delta.

        Principal is working capital and is not profit. Internal mint/mark variables
        are not read here at all. The route must settle, have an independent external
        market/counterparty, and repay flash principal when applicable.
        """
        if route.principal < 0 or route.settled_output < 0:
            raise ValueError("route amounts must be non-negative")
        if route.external_costs < 0 or route.flash_premium < 0:
            raise ValueError("costs must be non-negative")
        if not route.settlement_realized:
            raise ValueError("external settlement not realized")
        if not route.independent_external_counterparty:
            raise ValueError("independent external counterparty evidence required")
        if not route.flash_principal_repaid:
            raise ValueError("flash principal not repaid")
        pnl = route.pnl
        if pnl <= 0:
            raise ValueError("route has no positive realized external P&L")

        if retain_profit_in_dex:
            return replace(
                state,
                dex_external_reserve=state.dex_external_reserve + pnl,
                realized_external_pnl=state.realized_external_pnl + pnl,
            )
        return replace(
            state,
            external_cash=state.external_cash + pnl,
            realized_external_pnl=state.realized_external_pnl + pnl,
        )

    def distribute(self, state: EconomicState, amount: Decimal) -> EconomicState:
        amount = D(amount)
        if amount < 0 or amount > state.external_cash:
            raise ValueError("invalid distribution")
        return replace(
            state,
            external_cash=state.external_cash - amount,
            distributions=state.distributions + amount,
        )


def compounding_identity(
    opening_reserve: Decimal,
    classic_pnl: Decimal,
    dex_pnl: Decimal,
    costs: Decimal,
    distributions: Decimal,
) -> Decimal:
    """R[t+1] = R[t] + P_classic + P_dex - C - distributions."""
    return D(opening_reserve) + D(classic_pnl) + D(dex_pnl) - D(costs) - D(distributions)
