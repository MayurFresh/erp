# Shopify (Shopify Inc.)

Checked 2026-11-03. Confidence: high for pricing and webhooks. Medium for per-plan API limits.

## Snapshot

| Item | Detail |
|---|---|
| URL | https://www.shopify.com/in |
| HQ | Canada |
| Markets | Global, including India |
| Sizes | Solo sellers to enterprise (Plus) |
| Deployment | SaaS |
| Pricing | INR plans below |
| India availability | Yes, INR pricing page |

India plans (INR per month):

| Plan | Monthly billing | Yearly billing | Third-party gateway fee | Staff |
|---|---|---|---|---|
| Basic | 1,994 | 1,499 | 2% | none extra |
| Grow | 7,447 | 5,599 | 1% | 5 |
| Advanced | 30,164 | 22,680 | 0.6% | 15 |
| Plus | from 1,75,000 | n/a | 0.2% | unlimited |

POS Pro add-on is 7,000 per location per month. The page does not mention GST.

## Modules

| Module | Status |
|---|---|
| Online store, checkout | native |
| Orders, fulfilment | native |
| Inventory, locations | native |
| POS | add-on (POS Pro) |
| Marketplace channels | partner |
| GST invoice, e-invoice | partner (UNVERIFIED which apps) |
| Accounting | partner |
| WMS, picking, scanning | partner |
| B2B | native on higher plans (UNVERIFIED) |

## Order-to-settlement workflow

1. Customer pays at checkout. Payment is by Shopify Payments or a third-party gateway.
2. Order is created. Webhook fires.
3. Fulfilment is created per location, with tracking.
4. Refunds and returns are managed in admin.
5. Payout reports show settlement. Matching to a ledger needs an app or Progen.

## APIs, webhooks and integrations

- GraphQL Admin API is the main API.
- HTTPS webhooks carry header X-Shopify-Hmac-SHA256: base64 HMAC-SHA256 of the raw body, keyed with the app client secret.
- X-Shopify-Webhook-Id is unique per delivery. X-Shopify-Event-Id is shared across subscriptions to the same event. Dedupe on Webhook-Id.
- Return 200. Connection timeout is 1s and total is 5s.
- Retries: 8 over 4 hours. After 8 consecutive failures an API-created subscription is deleted.
- Pub/Sub and EventBridge delivery do not use the HMAC header.
- Rate limits: leaky bucket per app and store. Max single query cost 1,000. Backoff 1s. Arrays max 250. Pagination cap 25,000 objects.
- Per-plan points per second (Standard 100, Advanced 200, Plus 1,000, Enterprise 2,000) are from a search summary. Verify.
- New variant cap: 10,000 per day above 500,000 variants (Plus exempt).

## Mobile and scanning

Shopify mobile admin and POS apps exist. Details not verified this round.

## AI

UNVERIFIED this round. Do not rely on any Shopify AI claim until checked on shopify.com.

## Strengths (with evidence)

- Public, versioned API and clear webhook security text.
- Published INR pricing.
- Large app ecosystem for India gaps.

## Gaps (with evidence)

- No GST invoice or e-invoice in core. Apps needed.
- Plan-level API limits are hard to confirm.
- Subscription deleted after 8 failures, so Progen must watch health.

## What Progen should take from it

- Verify HMAC on the raw body before parsing.
- Keep a webhook inbox keyed by Webhook-Id.
- Add a nightly reconcile job because webhooks can fail.
- Respond fast and process later.

## Unknowns needing a demo

- Real GraphQL limits on the merchant plan.
- Which India apps add GST and e-invoice.
- Settlement report fields.

## Sources

- https://shopify.dev/docs/apps/build/webhooks/subscribe/https
- https://shopify.dev/docs/api/usage/rate-limits
- https://www.shopify.com/in/pricing
