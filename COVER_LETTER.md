# Сопроводительное письмо

Здравствуйте.

Направляю проект **PRINT MONEY SYNERGYCHAIN** — исследовательско-инженерную платформу, объединяющую пост-квантовый контур SINERGY L1, двунаправленный messenger/relayer с Base Mainnet и управляемую QE-модель частичного переноса внутреннего ценового градиента во внешний ликвидный рынок.

Цель проекта — проверить архитектуру, в которой собственная L1-система формирует ограниченный QE-импульс, задаёт внутреннее отклонение цены и разрешает лишь заданную долю этого импульса (`gradientTransferBps`) выразить через реальные сделки во внешнем Base-пуле. Внешняя позиция открывается отдельно от закрытия, поэтому система может наблюдать последующее изменение рыночного состояния и выполнять обратную сделку только при достижении заданного порога канонического NAV. После settlement внутренний QE debt закрывается через QT.

В текущей версии реализованы:

- SINERGY L1 G0 с chain id `8453001`;
- публичный PQ admission RPC и приватный EVM backend;
- ML-DSA-87 и SLH-DSA-SHAKE-256s для усиленного режима `hybrid_max`;
- ICrossDomainMessenger-совместимая модель приложений с собственным trusted-relayer corridor Base ↔ SINERGY;
- защита от повторной доставки сообщений и проверка удалённого application sender;
- `SinergyQEController` с QE amplitude, `gradientTransferBps`, QE debt и QT;
- Base-side OPEN/CLOSE executor;
- адаптер к реальному WETH/USDC Uniswap V3 пулу Base;
- двунаправленный relayer;
- Foundry tests и GitHub Actions для Solidity и post-quantum Python stack.

Принципиально важно, что проект не считает внутреннюю эмиссию, QE debt или synthetic executor PnL внешней прибылью. Экономический результат принимается только по реальному консолидированному Base NAV после полного цикла OPEN/CLOSE и учёта комиссий, slippage, gas и других внешних расходов.

Текущая версия является **CODE/CI integration generation**, а не завершённым production mainnet-релизом. Перед live deployment предусмотрены Base-fork тестирование, измерение price impact и forced-unwind risk, ротация всех ключей, отдельный security review, лимиты инвентаря и постепенный controlled pilot.

В дальнейшем архитектура должна перейти от G0 admission gateway к native post-quantum consensus/execution: интеграции `revm/reth`, consensus-critical ML-DSA/SLH-DSA precompiles, детерминированному NEXUS execution/proof surface и доказуемому bridge/light-client verification вместо trusted-relayer trust model.

Репозиторий содержит исходный код, тесты, CI, архитектурное описание, экономическую модель, security model и пошаговый deployment plan.

С уважением,
Евгений Коштенко
SHTENCO / SINERGY
