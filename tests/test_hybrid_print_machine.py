from decimal import Decimal

import pytest

from model.hybrid_print_machine import (
    EconomicState,
    HybridPrintMachine,
    ProfitSource,
    RealizedRoute,
    compounding_identity,
)

D = Decimal


def test_mint_and_revaluation_do_not_change_hard_nav() -> None:
    engine = HybridPrintMachine()
    state = EconomicState(external_cash=D("10"))
    state = engine.mint_internal(state, D("1000000000"))
    state = engine.revalue_internal(state, D("1000"))
    assert state.internal_mark_value == D("1000000000000")
    assert state.hard_nav == D("10")
    assert state.realized_external_pnl == D("0")


def test_allocating_cash_to_dex_changes_location_not_wealth() -> None:
    engine = HybridPrintMachine()
    state = EconomicState(external_cash=D("100"))
    after = engine.allocate_external_to_dex(state, D("40"))
    assert after.external_cash == D("60")
    assert after.dex_external_reserve == D("40")
    assert after.hard_nav == state.hard_nav == D("100")


def test_classic_profit_can_capitalize_dex_without_double_counting() -> None:
    engine = HybridPrintMachine()
    state = EconomicState(external_cash=D("100"))
    route = RealizedRoute(
        source=ProfitSource.METAPAY_CLASSIC,
        settlement_asset="USDT",
        principal=D("1000"),
        settled_output=D("1015"),
        external_costs=D("4"),
        flash_premium=D("0"),
    )
    state = engine.realize_route(state, route)
    assert state.hard_nav == D("111")
    assert state.realized_external_pnl == D("11")
    state = engine.allocate_external_to_dex(state, D("10"))
    assert state.hard_nav == D("111")
    assert state.dex_external_reserve == D("10")


def test_dex_profit_retained_in_dex_increases_external_nav_only_by_profit() -> None:
    engine = HybridPrintMachine()
    state = EconomicState(external_cash=D("50"), dex_external_reserve=D("50"))
    route = RealizedRoute(
        source=ProfitSource.DEX_ARBITRAGE,
        settlement_asset="USDT",
        principal=D("100"),
        settled_output=D("107"),
        external_costs=D("1"),
        flash_premium=D("0.1"),
    )
    after = engine.realize_route(state, route, retain_profit_in_dex=True)
    assert route.pnl == D("5.9")
    assert after.dex_external_reserve == D("55.9")
    assert after.hard_nav == D("105.9")
    assert after.realized_external_pnl == D("5.9")


def test_unsettled_or_unrepaid_route_fails_closed() -> None:
    engine = HybridPrintMachine()
    state = EconomicState(external_cash=D("100"))
    with pytest.raises(ValueError, match="external settlement"):
        engine.realize_route(
            state,
            RealizedRoute(
                source=ProfitSource.HYBRID_CLASSIC_DEX,
                settlement_asset="USDT",
                principal=D("100"),
                settled_output=D("120"),
                settlement_realized=False,
            ),
        )
    with pytest.raises(ValueError, match="flash principal"):
        engine.realize_route(
            state,
            RealizedRoute(
                source=ProfitSource.DEX_ARBITRAGE,
                settlement_asset="USDT",
                principal=D("100"),
                settled_output=D("120"),
                flash_principal_repaid=False,
            ),
        )


def test_internal_counterparty_cannot_create_realized_profit() -> None:
    engine = HybridPrintMachine()
    state = EconomicState(external_cash=D("100"))
    with pytest.raises(ValueError, match="independent external counterparty"):
        engine.realize_route(
            state,
            RealizedRoute(
                source=ProfitSource.HYBRID_CLASSIC_DEX,
                settlement_asset="USDT",
                principal=D("100"),
                settled_output=D("1000"),
                independent_external_counterparty=False,
            ),
        )


def test_compounding_identity_uses_only_realized_pnl_inputs() -> None:
    assert compounding_identity(D("100"), D("4"), D("6"), D("2"), D("3")) == D("105")
