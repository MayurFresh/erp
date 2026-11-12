# Media and creative workflows

Checked 2026-11-03. Master plan: section 6.5. Profile: ../competitor-profiles/adobe-workfront.md. Agencies are also in ../industry-verticals.md section 8.

## Scope
- Agencies, studios, production houses and in-house creative teams.
- Brief to delivery with approvals and versions, usage rights, client billing.
- Out of scope now: building a digital asset manager or video review tool; broadcast scheduling.

## End-to-end workflow
1. Campaign and project created from a client request.
2. Brief and deliverables approved, with budget.
3. Crew, equipment and resources allocated.
4. Assets uploaded, each with a version number.
5. Tasks assigned and tracked.
6. Review: comments and a decision (approve, approve with changes, reject) on a version.
7. Final delivered or published.
8. Usage rights and licence dates recorded (talent, stock, music).
9. Client invoice generated from retainer, milestone or time.
10. Profitability and, where relevant, royalty or revenue-share report.

## Key entities and states
- Deliverable: briefed, in production, in review, approved, delivered.
- Asset version: uploaded, under review, approved, superseded.
- Licence: active, expiring, expired.
- Request: submitted, accepted, converted to project, declined.

## India specifics
- GST on services and TDS on professional fees: ../industry-verticals.md section 8.
- Copyright and music licence rules in India: UNVERIFIED, not researched.
- Influencer and creator payments (TDS) are a pain point: UNVERIFIED.

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Adobe Workfront | Enterprise work management | Adobe India pricing page exists | Proofing, resource management, Fusion, Proof API | n | experienceleague.adobe.com |
| Bynder | Digital asset management | UNVERIFIED | DAM; syncs finished assets from Frame.io | n | support.bynder.com |
| Frame.io | Video review | UNVERIFIED | Review and approval for video; one directory says it is bundled in Creative Cloud (unverified) | UNVERIFIED | capterra.in |
| Monday, Asana, Wrike, ClickUp | Work management | UNVERIFIED | Not researched in this pass | UNVERIFIED | open question |

## Table stakes vs differentiators
- Table stakes: projects, tasks, file links with versions, approval with comments, calendar, client invoice.
- Differentiators: approvals tied to invoice milestones, licence expiry alerts, project profitability in the same ledger, client portal.
- Later: embedded proofing, AI reviewer (Workfront's is gated and on roadmap).

## Edge cases to test
- Approval of a version that was superseded mid-review.
- Two reviewers disagree.
- Licence expires before the campaign ends.
- Client changes scope after approval.
- Asset deleted but still referenced by an invoice milestone.

## What Progen can reuse from its core
- Approvals, files, projects, parties, invoices, custom fields, audit, notifications, cost centres.

## Smallest useful Progen slice
- Project with deliverables, versioned file links, approval states, licence date tracker, invoice on approval. No markup tool.

## Rough effort and priority
- Slice: S to M. Priority: low to medium. The approval engine exists; customer demand in India is UNVERIFIED.

## Open questions
- Do Indian agencies pay for proofing or use free tools?
- Who owns royalty accounting: any evidence of demand?
- Is a DAM integration (link only) enough?

## Sources
- https://experienceleague.adobe.com/en/docs/workfront/using/adobe-workfront-fusion/fusion-apps-and-modules/workfront-proof-modules
- https://support.bynder.com/hc/en-us/articles/36867670322578-How-to-Enable-and-Use-the-Frame-io-Integration
- https://www.capterra.in/software/148214/frame-io
