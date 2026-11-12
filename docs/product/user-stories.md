# User stories

IDs: `US-O2C-nnn` order to cash (v1.8, built), `US-P2P-nnn` procure to pay (v1.8, built), `US-CHN-nnn` channels (v1.9, planned). Feature numbers (F1 to F19) are in `requirements.md`. Personas (P1 to P8) are in `personas.md`. Acceptance criteria are in `acceptance-criteria.md` under the same IDs.

Priority: P0 must pass for the release, P1 should, P2 may slip.

## v1.8 order to cash

| ID | Feature | Persona | Story | Priority |
| --- | --- | --- | --- | --- |
| US-O2C-001 | F1 | P5 | As a sales executive I create a draft sales order for a customer at a location so that I can quote before stock is held. | P0 |
| US-O2C-002 | F1 | P5 | As a sales executive I confirm an order so that every line is reserved in full, or I am told which items are short. | P0 |
| US-O2C-003 | F1 | P1 | As the owner I want two orders for the last unit not to both reserve it so that we never oversell. | P0 |
| US-O2C-004 | F1 | P2 | As an ops manager I allow backorder on a line and reserve again later so that partial stock still ships. | P1 |
| US-O2C-005 | F1 | P5 | As a sales executive I cancel an order, or part of it, so that held stock is released. | P0 |
| US-O2C-006 | F2 | P2 | As an ops manager I make one pick list from several orders so that pickers walk once. | P0 |
| US-O2C-007 | F2 | P3 | As a picker I scan a barcode to confirm each unit so that wrong items are caught. | P0 |
| US-O2C-008 | F2 | P3 | As a picker on a weak connection I resend a scan without double counting so that retries are safe. | P0 |
| US-O2C-009 | F2 | P3 | As a picker I get a clear reason when a scan is wrong, unknown or too many. | P0 |
| US-O2C-010 | F2 | P2 | As an ops manager I complete a pick list with short picks and put the rest on a new list. | P1 |
| US-O2C-011 | F3 | P3 | As a packer I scan items into the parcel so that packed never exceeds picked. | P0 |
| US-O2C-012 | F4 | P2 | As an ops manager I dispatch an order once and get the invoice, stock-out and shipment together. | P0 |
| US-O2C-013 | F4 | P4 | As an accountant I want dispatch refused when picked and packed differ so that invoices match goods. | P0 |
| US-O2C-014 | F4 | P2 | As an ops manager I mark a shipment cash on delivery with an amount so that collection is tracked. | P1 |
| US-O2C-015 | F5 | P2 | As an ops manager I update shipment status with a history so that I can answer customers. | P0 |
| US-O2C-016 | F5, F6 | P2 | As an ops manager I want an RTO to create the return record so that returned parcels are not forgotten. | P0 |
| US-O2C-017 | F6 | P5 | As a sales executive I request a return only up to what was sold so that credit is never over-issued. | P0 |
| US-O2C-018 | F6 | P3 | As a warehouse user I receive returned goods and give each line a disposition: restock, damaged or scrap. | P0 |
| US-O2C-019 | F6 | P4 | As an accountant I close a return and get a credit note, with only restocked units back in stock. | P0 |
| US-O2C-020 | F1 | P4 | As an accountant I want a plain invoice not to take stock that an order has reserved. | P0 |
| US-O2C-021 | F1 to F6 | P1 | As the owner I want each action tied to a permission so that pickers cannot edit orders and sales staff cannot dispatch. | P0 |
| US-O2C-022 | F1 to F6 | P1 | As the owner I want users at one location, and other businesses, not to see my orders. | P0 |

## v1.8 procure to pay

| ID | Feature | Persona | Story | Priority |
| --- | --- | --- | --- | --- |
| US-P2P-001 | F7 | P6 | As a purchase manager I draft, edit, submit and send a purchase order. | P0 |
| US-P2P-002 | F7 | P1 | As the owner I want POs above a set value to wait for approval so that spending is controlled. | P0 |
| US-P2P-003 | F7 | P6 | As a purchase manager I cancel a PO, or its unreceived rest. | P1 |
| US-P2P-004 | F8 | P3 | As a store keeper I receive goods against a PO, in parts, so that stock rises when goods arrive. | P0 |
| US-P2P-005 | F8 | P4 | As an accountant I want over-receipt blocked beyond a set tolerance. | P0 |
| US-P2P-006 | F8 | P3 | As a store keeper I record rejected quantity with a reason so that it never enters stock. | P1 |
| US-P2P-007 | F8 | P4 | As an accountant I cancel a receipt only when stock and billing allow. | P1 |
| US-P2P-008 | F9 | P4 | As an accountant I bill from a receipt so that stock and inventory are not counted twice. | P0 |
| US-P2P-009 | F9 | P4 | As an accountant I want over-billing blocked. | P0 |
| US-P2P-010 | F9 | P4 | As an accountant I want a bill price off the PO blocked, with an override that posts the difference to a variance account. | P0 |
| US-P2P-011 | F9 | P4 | As an accountant I cancel a bill and the receipt becomes billable again. | P1 |
| US-P2P-012 | F10 | P6 | As a purchase manager I see items at or below reorder level and create draft POs by vendor. | P1 |
| US-P2P-013 | F11 | P3 | As a store keeper I count stock by scanning and post the variance. | P1 |
| US-P2P-014 | F11 | P1 | As the owner I want large count variances to need an approver. | P1 |
| US-P2P-015 | F7 to F11 | P1 | As the owner I want purchasing actions behind permissions and isolated per business. | P0 |

## v1.9 Channels (planned)

| ID | Feature | Persona | Story | Priority |
| --- | --- | --- | --- | --- |
| US-CHN-001 | F12 | P2 | As an ops manager I connect a channel and see it as connected only after a successful check. | P0 |
| US-CHN-002 | F12 | P1 | As the owner I want channel credentials stored encrypted and rotatable. | P0 |
| US-CHN-003 | F13 | P2 | As an ops manager I want incoming webhooks verified so that forged events are ignored. | P0 |
| US-CHN-004 | F13 | P2 | As an ops manager I want a replayed webhook to change nothing. | P0 |
| US-CHN-005 | F15 | P2 | As an ops manager I want orders pulled by polling when webhooks fail, without gaps or repeats. | P0 |
| US-CHN-006 | F14 | P5 | As a channel executive I import an orders file using a saved column mapping. | P0 |
| US-CHN-007 | F14 | P5 | As a channel executive I map a channel SKU to an item, or to a bundle of items. | P0 |
| US-CHN-008 | F14 | P2 | As an ops manager I want imported orders to appear as sales orders, once per channel order id. | P0 |
| US-CHN-009 | F16 | P2 | As an ops manager I want available stock pushed to each channel listing. | P1 |
| US-CHN-010 | F17 | P4 | As an accountant I import a settlement file and post it to the ledger exactly once. | P0 |
| US-CHN-011 | F17 | P4 | As an accountant I want an unbalanced settlement refused. | P0 |
| US-CHN-012 | F17 | P4 | As an accountant I want TCS and TDS held as receivables, never as expenses. | P0 |
| US-CHN-013 | F18 | P1 | As the owner I see each channel's status, last success and backlog on one page. | P1 |
| US-CHN-014 | F13 | P2 | As an ops manager I see failed events and replay them after a fix. | P1 |
| US-CHN-015 | F15 | P2 | As an ops manager I want channel cancellations and returns to flow into the existing cancel and return flows. | P1 |
| US-CHN-016 | F19 | P2 | As an ops manager I connect Amazon or Flipkart once the owner has access. | P2 |
