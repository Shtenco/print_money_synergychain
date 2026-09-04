# PRINT MONEY SYNERGYCHAIN

**Post-Quantum SINERGY L1 + Base Mainnet Messenger + QE Gradient Economic Engine**

Рабочая ветка: `print_money_synergychain`

## Идея

Проект собирает в одном репозитории минимальный запускаемый контур SINERGY L1 и экономическую машину, которая использует внутренний QE-импульс как управляющий сигнал для ограниченного переноса ценового градиента во внешний ликвидный рынок Base.

Базовый цикл:

```text
POST-QUANTUM SINERGY L1
        ↓
QE / internal price gradient
        ↓
gradientTransferBps
        ↓
SINERGY Messenger
        ↓
Trusted Relayer
        ↓
Base Messenger
        ↓
Base QE External Executor
        ↓
OPEN GRADIENT
        ↓
real Base WETH/USDC liquidity
        ↓
external order flow / market state
        ↓
CLOSE GRADIENT
        ↓
canonical Base NAV settlement
        ↓
SINERGY L1
        ↓
QT / QE debt → 0
```

## Ключевая экономическая оговорка

Внутренний QE сам по себе не создаёт каноническое богатство. Внутренний `qeDebt` и marked-value не считаются прибылью. Экономический PASS фиксируется только по реальному консолидированному Base NAV после полного OPEN/CLOSE цикла и внешних расходов.

Формально:

```text
PASS ⇔ NAV_after ≥ NAV_before + minCanonicalGain
```

Если нормальный CLOSE не достигает порога, транзакция ревертится. После дедлайна governance может выполнить `forceUnwindExpired`, причём убыток остаётся видимым и отправляется обратно в L1 settlement.

## Что реализовано

- SINERGY L1 chain id `8453001`.
- G0 PQ admission RPC: публичный `9545`, приватный EVM backend `9546`.
- ML-DSA-87 и SLH-DSA-SHAKE-256s для `hybrid_max`.
- persistent PQ replay nonce, expiry, chain binding и raw-tx commitment.
- `TrustedRelayerCrossDomainMessenger` с `xDomainMessageSender()` и replay guard.
- `SinergyQEController` с `qePremiumBps`, `gradientTransferBps`, QE debt и QT.
- `BaseQEExternalExecutor` с двухфазным OPEN/CLOSE.
- `BasePinnedPoolGradientAdapter` для реального Base WETH/USDC Uniswap V3 0.30% corridor.
- двунаправленный Base ↔ SINERGY trusted relayer.
- Foundry invariant tests.
- GitHub Actions: Solidity build/tests + PQ Python smoke tests.

## Основные файлы

```text
contracts/bridge/TrustedRelayerCrossDomainMessenger.sol
contracts/economics/SinergyQEController.sol
contracts/economics/BaseQEExternalExecutor.sol
contracts/economics/BasePinnedPoolGradientAdapter.sol
node/pq_rpc_gateway.py
node/generate_pq_relayer_keys.py
node/run-devnet.sh
relayer/base_sinergy_relayer.py
test/SinergyL1BaseQEV1.t.sol
```

## Быстрый локальный запуск G0

Требования: Foundry (`anvil`, `forge`) и Python 3.12+.

```bash
export SYNERGY_DEVNET_MNEMONIC='use-a-new-private-devnet-mnemonic'
bash node/run-devnet.sh
```

Проверка RPC:

```bash
curl -s -H 'content-type: application/json' \
  --data '{"jsonrpc":"2.0","id":1,"method":"synergy_chainProfile","params":[]}' \
  http://127.0.0.1:9545
```

Обычные публичные `eth_sendRawTransaction`/admin-методы блокируются. Запись должна проходить через `synergy_sendPqRawTransaction`.

## PQ ключи relayer

```bash
python -m venv .venv
. .venv/bin/activate
pip install -r node/requirements.txt
python node/generate_pq_relayer_keys.py ~/.synergy-l1/keys
```

Секретные ключи не должны попадать в Git.

## Тесты

```bash
forge build
forge test -vvv
python -m py_compile node/pq_rpc_gateway.py node/generate_pq_relayer_keys.py relayer/base_sinergy_relayer.py
```

## Статус

**CODE/CI integration generation. Mainnet deployment is intentionally not part of this branch.**

G0 является пост-квантово защищённым admission layer поверх приватного EVM backend. Он не заявляется как готовый production multi-validator PQ consensus. Следующее поколение должно переносить PQ verification в native `revm/reth` precompiles/consensus path и заменять trusted-relayer security на доказуемую bridge/light-client модель.

## Безопасность

В репозитории запрещено хранить:

- deployer private keys;
- Base relayer private keys;
- PQ secret keys;
- seed phrases;
- private RPC API keys;
- production `.env`.

Используйте отдельные ключи для deployer, Base relayer, SINERGY backend signer и PQ authorization identity.

## Документация

- `docs/ARCHITECTURE.md` — компоненты и потоки сообщений.
- `docs/ECONOMIC_MODEL.md` — QE/gradient/OPEN/CLOSE/QT модель.
- `docs/DEPLOYMENT.md` — последовательность запуска без mainnet broadcast.
- `docs/SECURITY.md` — threat model и ограничения G0.
- `docs/STATUS.md` — текущая готовность и следующий roadmap.
- `COVER_LETTER.md` — сопроводительное описание проекта.

## Scope

Это исследовательско-инженерная система. Она не обещает гарантированную прибыль и не должна считать внутреннюю эмиссию, synthetic PnL или QE debt внешней стоимостью. Любой экономический результат должен подтверждаться каноническим внешним NAV после комиссий, slippage, MEV, gas и полного settlement.
