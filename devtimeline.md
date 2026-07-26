# Dev Timeline

## Goal

Deliver alpha-level readiness in 60 days for:

- PaaayIT Terminal
- VTerminal
- Core OS capability (Web, Android, iOS)

Core rule: one shared transaction-processing engine across all editions. Edition differences are feature/UI additions, not processing divergence.

## Session Default Mode

- Active default: VRegister-only changes.
- Do not modify Register UI unless explicitly requested.
- Keep core processing/shared services unchanged unless explicitly requested.
- Override phrase: "Both variants" or "Register-only" when needed.

## Product Strategy

- Use terminal activation + entitlements to determine edition at install/runtime.
- Editions:
  - Terminal
  - VTerminal
  - Retail (expanded later)
- Future verticals should be feature packs/capabilities, not separate processing engines.

## Timeline Overview

### Days 1-21 (Next 3 Weeks)

Focus: surcharge completion + VTerminal initial development.

#### Week 1

- Complete surcharge validation end-to-end.
- Verify processing invariants stay consistent across flows:
  - sale
  - void
  - refund
  - tip adjust
  - batch close
- Freeze/lock transaction processing contracts.

Exit criteria:

- Surcharge toggle behavior validated with processor-authoritative outcomes.
- Fee persistence verified where applicable.
- No regressions in core payment flows.

#### Week 2

- Build VTerminal v1 feature set:
  - richer transaction detail
  - customer management
  - recurring charge primitives
- Implement via capability flags and shared services.

Exit criteria:

- VTerminal feature paths functional behind entitlements/capabilities.
- No changes to core processing rules.

#### Week 3

- Integrate and test VTerminal under realistic transaction volume.
- Validate migrations/data model for recurring and customer flows.
- Produce Alpha-0 internal build.

Exit criteria:

- Alpha-0 build ready for internal test.
- Core transaction engine parity confirmed.

### Days 22-60

Focus: OS hardening for Terminal + VTerminal while keeping Retail scope controlled.

#### Web Hardening

- Browser/session resilience
- hosted payment stability
- error recovery and retry behavior

#### Android Hardening

- app lifecycle (foreground/background)
- network edge cases
- payment/receipt device behavior
- signing/release readiness

#### iOS Hardening

- macOS build/signing pipeline
- entitlement/provisioning stability
- permission handling and fallback paths

#### Shared Reliability

- Unified smoke tests for Terminal and VTerminal on each OS.
- Weekly release train with testable artifacts.
- Core processing changes restricted to high-priority fixes only.

Exit criteria (Day 60 alpha target):

- Terminal + VTerminal alpha-capable on targeted OS paths.
- Activation correctly routes edition/capabilities.
- Payment invariants consistent across editions/platforms.

## Alpha Definition (Day 60)

Must pass:

- Critical payment happy paths and exception paths
- Ledger integrity and reconciliation checks
- Activation and entitlement routing

Allowed in alpha:

- Non-blocking UI polish defects
- Limited secondary workflow gaps with documented follow-up

Not allowed:

- Processing inconsistencies between editions
- Any mismatch in surcharge/totals/posting/batch behavior

## Guardrails

- One transaction state machine for all editions.
- One surcharge/fee policy implementation path.
- One ledger posting/reconciliation model.
- Feature modules may extend UX/data, but cannot alter core posting invariants.

## Nightly Check-In Template

Date:

Work completed tonight:

-
-

In progress:

-

Blocked:

-

Platform status:

- Web:
- Android:
- iOS:

Edition status:

- Terminal:
- VTerminal:
- Retail:

Core engine parity check:

- Status:
- Notes:

Top priorities next session:

1.
2.
3.

Go/No-Go snapshot:

- Overall:
- Risks:
- Owner follow-ups:
