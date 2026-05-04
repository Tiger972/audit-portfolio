# 🔐 Smart Contract Security Research

> Independent security researcher hunting critical vulnerabilities in DeFi protocols.
> Specialized in Solidity, EVM internals, and AMM mechanics.

---

## ⚡ About

I'm a cybersecurity professional transitioning into smart contract security research.
Background in SOC/CSIRT analysis at BNP Paribas WM, now fully focused on finding bugs that matter.

**Certifications:** AWS Cloud Practitioner · CompTIA Security+  
**Stack:** Solidity · Foundry · Aderyn · Slither · Echidna  
**Focus:** DeFi protocols · AMMs · Lending · Access Control · MEV

---

## 📋 Audit Portfolio

| # | Protocol | Type | Date | Critical | High | Medium | Low | Info | Report |
|---|----------|------|------|:--------:|:----:|:------:|:---:|:----:|--------|
| 01 | **PasswordStore** | Access Control | Apr 2025 | — | 2 | — | 1 | 2 | [📄 View](./2025-04-passwordstore/report.md) |
| 02 | **PuppyRaffle** | NFT Raffle | Apr 2025 | — | 2 | 2 | 2 | 2 | [📄 View](./2025-04-puppyraffle/report.md) |
| 03 | **TSwap** | AMM / DEX | May 2025 | 1 | 4 | 1 | 2 | 5 | [📄 View](./2025-05-tswap/report.md) |

---

## 🎯 Notable Findings

### 🔴 [Critical] TSwap — Broken AMM Invariant via Hidden Swap Incentive
`TSwapPool::_swap` unconditionally transfers 1e18 extra tokens every 10 swaps, permanently breaking the `x * y = k` invariant and draining LP reserves over time.  
→ [Read finding](./2025-05-tswap/report.md#critical-01)

### 🔴 [High] TSwap — Wrong Fee Multiplier (10x Overcharge)
`getInputAmountBasedOnOutput` uses `10000` instead of `1000` as fee basis, causing every `swapExactOutput` call to charge users 10x the intended 0.3% fee.  
→ [Read finding](./2025-05-tswap/report.md#high-04)

### 🔴 [High] PuppyRaffle — Reentrancy Drains Entire Contract
`PuppyRaffle::refund` sends ETH before updating state, allowing a malicious contract to recursively drain the full balance in a single transaction.  
→ [Read finding](./2025-04-puppyraffle/report.md#h-01)

### 🟠 [High] TSwap — Missing Slippage Protection on swapExactOutput
No `maxInputAmount` guard exposes users to unlimited MEV sandwich attacks on every exact-output swap.  
→ [Read finding](./2025-05-tswap/report.md#high-02)

---

## 🛠️ Methodology

```
1. Manual review          — line-by-line code analysis
2. Static analysis        — Aderyn + Slither for automated pattern detection  
3. Attack simulation      — custom Foundry PoC for every finding
4. Invariant testing      — stateful fuzz testing to catch protocol-level bugs
5. Report writing         — structured findings with severity, impact, and mitigation
```

---

## 🧰 Vulnerability Classes

```
✅ Reentrancy (single-function, cross-function, read-only)
✅ Integer Overflow / Underflow
✅ Weak Randomness
✅ Access Control
✅ AMM Invariant Violations
✅ MEV / Sandwich Attacks
✅ Mishandled ETH (selfdestruct, force-feed)
✅ Slippage & Deadline Manipulation
✅ Precision Loss / Division Truncation
⏳ Flash Loan Attacks (in progress)
⏳ Proxy / Upgrade Patterns (in progress)
⏳ Oracle Manipulation (in progress)
```

---

## 📁 Repository Structure

```
audits/
├── 2025-04-passwordstore/
│   ├── report.md           # Full audit report
│   └── test/               # Foundry PoC tests
├── 2025-04-puppyraffle/
│   ├── report.md
│   └── test/
└── 2025-05-tswap/
    ├── report.md
    └── test/
```

---

## 🏆 Competitive Audits

| Platform | Competition | Result | Date |
|----------|-------------|--------|------|
| CodeHawks | Coming soon | — | 2025 |
| Cantina | Coming soon | — | 2025 |

*Actively competing. Results updated as published.*

---

## 📬 Contact

**Andy Piquionne**  
📧 andy.piquionne@icloud.com  
🔗 [LinkedIn](https://www.linkedin.com/in/andy-piquionne/)  
🐙 [GitHub](https://github.com/Tiger972)

---

<div align="center">

*"The best time to find a bug is before it's exploited."*

![Solidity](https://img.shields.io/badge/Solidity-0.8.x-363636?style=flat&logo=solidity)
![Foundry](https://img.shields.io/badge/Foundry-gray?style=flat)
![Security](https://img.shields.io/badge/Focus-Smart%20Contract%20Security-red?style=flat)

</div>
