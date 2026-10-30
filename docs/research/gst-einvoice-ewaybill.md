# GST e-invoice and e-way bill integration — fact sheet

Checked 21–28 Oct 2026. Every fact cites its source; anything not confirmed from a primary or official source is marked **UNVERIFIED**.

**Gaps:**
- CGST Rules 138 and 54 were not opened; the e-way bill rules below come from the NIC e-way bill FAQ.
- GSP pricing is only partly covered.

## 1. Who must e-invoice

**Threshold**
- E-invoicing applies above **₹5 crore** aggregate annual turnover (AATO), from 1 Aug 2023.
- Source: Notification 10/2023-CT ([PDF](https://einvoice6.gst.gov.in/content/wp-content/uploads/2023/05/GST-notification-10-central-tax-english-2023.pdf)), which substituted "five crore rupees" for "ten crore rupees".
- No notification from 2024–2026 changes the threshold. The [GSTN RCM advisory of 16 Oct 2026](https://einv-apisandbox.nic.in/downloads/RCM%20Advisory.pdf) still calls ₹5 crore "the current eligibility threshold for e-Invoicing".

**Principal notification: 13/2020-CT (21 Mar 2020)**
- Applies to "supply of goods or services or both to a registered person".
- Excludes persons under Rule 54(2), (3), (4) and (4A). **UNVERIFIED** (Rule 54 text not opened): these are usually insurers, banks, financial institutions and NBFCs; goods transport agencies (GTAs); passenger transport; and cinema admission.

**Amendments**
- 61/2020: exempts SEZ units.
- 70/2020: the turnover test is "any preceding financial year from 2017-18 onwards"; exports are covered.
- 23/2021: exempts government departments and local authorities.

**Casual taxable persons**
- Allowed to generate e-invoices from Dec 2025 (NIC release note, 16/12/2025).

**Documents and supply types**
- Document types: INV, CRN, DBN.
- Supply types: B2B, SEZWP, SEZWOP, EXPWP, EXPWOP, DEXP.
- **B2C is not covered.**

**B2C dynamic QR**
- Required when AATO is over ₹500 crore, from 1 Dec 2020 (Notification 71/2020-CT).

**New in 2026 (sandbox only, no production date yet)**
- Recipient self-invoices under reverse charge (RCM): supply types RCMDOM and RCMIMP.
- SEZWP is being split into SEZWPA and SEZWPNA. The GSTN advisory is "awaited".

## 2. 30-day reporting limit

- From 1 Apr 2025, a taxpayer with AATO ≥ ₹10 crore cannot report a document to the Invoice Registration Portal (IRP) more than 30 days after its date. This covers invoices, credit notes and debit notes. Source: GSTN advisory of 5 Nov 2024 ([copy](https://www.mahagst.gov.in/public/uploads/gstnadvisory/1760531580_293%20Advisory%20Time%20Limit%20for%20Reporting%20e%20Invoice%20on%20the%20IRP%20Portal%20%20Lowering%20of%20Threshold%20to%20AATO%2010%20Crores%20and%20Above.pdf)).
  - Example from the advisory: an invoice dated 1 Apr 2025 "cannot be reported after 30th April 2025".
  - Below ₹10 crore there is "no such reporting restriction … as of now".
- The limit was first introduced for AATO ≥ ₹100 crore (advisory of 13 Sep 2023).
- No official extension to all taxpayers was found; only blogs claim one.
- The IRP rejects late documents with error 2305.

**ERP implication:** warn when an e-invoice-eligible invoice is more than about 25 days old and its IRN has not been generated.

## 3. Authorised IRPs

There are six (GSTN RCM advisory, 16 Oct 2026):

| IRP | Portal |
| --- | --- |
| NIC IRP-1 | https://einvoice1.gst.gov.in |
| NIC IRP-2 | https://einvoice2.gst.gov.in |
| Cygnet IRP-3 | https://einvoice3.gst.gov.in |
| Clear IRP-4 | https://einvoice4.gst.gov.in |
| EY IRP-5 | https://einvoice5.gst.gov.in |
| IRIS IRP-6 | https://einvoice6.gst.gov.in |

- NIC developer portal: https://einv-apisandbox.nic.in/
- NIC production API bases: `https://api.einvoice1.gst.gov.in` and `https://api.einvoice2.gst.gov.in`.

## 4. API access and authentication

### Direct API access
- **Eligibility:** NIC states "annual turnover of ₹100 crore and above" on its [onboarding page](https://einv-apisandbox.nic.in/onboarding.html). The same page's table says "> 500 Crores", so NIC is inconsistent.
- **Requirements:** TLS 1.2 and up to 4 Indian static IP addresses.
- **Process:**
  1. Submit a Test Summary Report (`EInvoiceAPITestSummary1.03.xlsx`) with an IP whitelisting request. It takes 4–5 days.
  2. Create separate credentials for production.

### Through a GSP or ERP
- **Our case:** taxpayers with turnover between ₹5 crore and ₹500 crore "can contact the GSP / ERPs … On getting the Client-Id from them, they may self-register their GSTINs on the sandbox system."
- **Credentials:** the taxpayer creates their own e-invoice username and password, then uses the GSP's Client Id and Client Secret.
- **Existing e-way bill API users** can reuse the same credentials.

### Sandbox registration
- Form: `einvapiclient/RegistrationForm.aspx`.
- User types: Tax Payer, GSP, e-Com Operator, ERP.
- Fields: GSTIN, trade name, GST-registered mobile and email.
- **UNVERIFIED:** whether test GSTINs are issued.

### Auth API v1.04
Source: [NIC authentication page](https://einv-apisandbox.nic.in/version1.04/authentication.html).

**Request:** `POST <base>/eivital/v1.04/auth`
- Headers: `client_id`, `client_secret`, `Gstin`.
- Body: `{"Data": …}`. The credentials JSON `{UserName, Password, AppKey, ForceRefreshAccessToken}` is Base64-encoded, then encrypted with the e-invoice RSA public key.
- **UNVERIFIED:** the RSA padding scheme, which NIC does not state.
- `AppKey` is a random 32-byte array (44 characters in Base64).

**Response:** `Status`, `ClientId`, `UserName`, `AuthToken`, `Sek`, `TokenExpiry` (format `yyyy-MM-dd HH:mm:ss`).
- `Sek` is a session key encrypted with AppKey using AES-256/ECB/PKCS7. Decrypt it with the AppKey.

**Token life**
- 360 minutes in production, 60 minutes in the sandbox.
- Calls within that window return the same token.
- A new token can be forced in the last 10 minutes before expiry.

**Calls after auth**
- Headers: `client_id`, `client_secret`, `Gstin`, `user_name`, `AuthToken`.
- Optional `sup_gstin`: the e-commerce operator, or the recipient for RCM.
- Body: `{"Data": base64(AES(Sek, invoiceJson))}`. Responses are decrypted with the Sek.
- Interoperability header `irp` = `NIC1` or `NIC2`: one token works on both NIC portals.

### E-way bill API auth v1.03
- **Request:** `POST <base>/auth/`
  - Headers: `client-id`, `client-secret`, `Gstin`.
  - Body: `action: "ACCESSTOKEN"`, `username`, `password`, `app_key` (a 32-character random id).
- **Encryption:** the Sek is encrypted with `app_key` using AES-256 ECB PKCS7.
- **Token life:** 360 minutes.
- **Direct-access prerequisites:**
  - About 10,000 transactions a month per GSTIN.
  - Up to 3 static IP addresses.

## 5. API paths (current version v1.03)

NIC's pages now show placeholders. The versioned paths below are confirmed through the [Vayana GSP docs](https://docs.gsp.vayana.com/E-Invoice/) where noted.

| API | Method | Path |
| --- | --- | --- |
| Auth | POST | `eivital/v1.04/auth` |
| Generate IRN | POST | `eicore/v1.03/Invoice` |
| Get IRN details | GET | `eicore/v1.03/Invoice/irn/{irn}` |
| Get IRN by document | GET | `…/irnbydocdetails?doctype=&docnum=&docdate=` |
| Cancel IRN | POST | `eicore/v1.03/Invoice/Cancel` (**UNVERIFIED** as a raw NIC path) |
| Generate e-way bill by IRN | POST | `eiewb/v1.03/ewaybill` (**UNVERIFIED**) |
| Get e-way bill by IRN | GET | `eiewb/v1.03/ewaybill/irn/{irn}` |
| GSTIN details | GET | `eivital/v1.04/Master/gstin/{gstin}` |

### Cancel IRN
- **Body:** `{Irn, CnlRsn, CnlRem}`.
  - `CnlRsn`: 1 = Duplicate, 2 = Data entry mistake, 3 = Order cancelled, 4 = Others.
  - `CnlRem`: up to 100 characters.
- **Time limit:** within 24 hours of generation.
- **Blocked** while an active e-way bill exists (error 2230).

### E-way bill API
**Request:** `POST <base>/ewayapi/`, with headers `client-id`, `client-secret`, `gstin`, `authtoken`.

| Action | Rule |
| --- | --- |
| `GENEWAYBILL` | Generate |
| `VEHEWB` | Update vehicle (Part B); only while the bill is active and valid |
| `CANEWB` | Cancel within 24 hours of generation |
| `EXTENDVALIDITY` | Between 8 hours before and 8 hours after expiry; never beyond 360 days from generation |
| `REJEWB` | Reject within 72 hours of generation |
| `CLSEWB` | Close; on hold (see §9) |

- **Limits:** at most 250 items per bill.
- **Value check:** Σ `totalValue` must be ≤ `totInvValue` + ₹2.
- **IRN reference:** an e-invoice-enabled supplier's B2B or export e-way bills must be generated from the IRN, through the e-invoice system.

## 6. E-invoice JSON (schema Version "1.1")

### Required sections
`Version`, `TranDtls`, `DocDtls`, `SellerDtls`, `BuyerDtls`, `ItemList`, `ValDtls`. The IRN is never sent in the request.

### TranDtls
- `TaxSch`: `GST`.
- `SupTyp`: as in §1.
- `RegRev`: Y/N. Y is allowed only for B2B and SEZ.
- `EcmGstin`: blank when the supplier generates the invoice.
- `IgstOnIntra`: Y/N.

### DocDtls
- `Typ`: INV/CRN/DBN.
- `Dt`: `dd/mm/yyyy`. Document dates from 01/04/2025 only.
- `No`: at most 16 characters, regex `^([a-zA-Z1-9]{1}[a-zA-Z0-9\/-]{0,15})$`. It cannot start with 0, `/` or `-`, and letters must be **upper case**.
  - **Progen impact:** our `INV/26-27/00001` is 15 characters and passes.

### Seller and buyer
- `Gstin`: 15 characters.
- `LglNm`: 3–100 characters.
- `Addr1`: 1–100 characters.
- `Loc`: 3–50 characters.
- `Pin`: 100000–999999.
- `Stcd` / `Pos`: regex `^(?!0+$)([0-9]{1,2})$`; 96 for places outside India.
- **Exports:** GSTIN `URP`, state code 96, PIN 999999.

### ItemList
- **Items:** 1–1000; `SlNo` must be unique.
- **Description:** `PrdDesc` is 3–300 characters; `IsServc` is Y/N.
- **HSN:** `HsnCd` regex `^(?!0+$)([0-9]{4}|[0-9]{6}|[0-9]{8})$`. Six digits are mandatory when AATO is over ₹5 crore (Notification 78/2020).
- **Quantity and unit:** `Qty` and `Unit` are mandatory for goods. `Unit` must be a UQC code (list below).
- **Assessable amount:** `AssAmt` = total amount − discount.
- **GST rate:** `GstRt` is the **IGST-equivalent rate**; for intra-state supplies, send CGST + SGST. "Tax rate 0.5% is withdrawn."
  - A 40% rate was added to the IRIS IRP rate master on 21 Sep 2025. **UNVERIFIED** on NIC: its master is behind a captcha.
  - NIC's e-way bill rate page still lists only 0, 0.1, 0.25, 0.5, 3, 5, 12, 18 and 28, and looks stale.
- **Item total:** `TotItemVal` = assessable amount + taxes + cess + other charges.

### ValDtls
- Fields: `AssVal`, `CgstVal`, `SgstVal`, `IgstVal`, `CesVal`, `StCesVal`, `Discount`, `OthChrg`, `RndOffAmt`, `TotInvVal`.
- `RndOffAmt` must be between −99.99 and +99.99.
- `TotInvVal` = Σ item totals − invoice discount + other charges + round-off.

### Tolerance
Each amount is accepted between (its rupee part − ₹1) and (rounded up + ₹1). For example, a calculated IGST of 2345.04 is accepted from 2344.00 to 2347.00.

### Other details
- **EwbDtls** (optional transport block):
  - `TransId` (15 characters).
  - `TransMode` 1–4.
  - `Distance` 0–4000.
  - Transport document number and date.
  - `VehNo`.
  - `VehType` R/O.
- **Optional blocks:** `PayDtls`, `RefDtls`, `DispDtls`, `ShipDtls`.
- **Payload limit:** 2 MB.

### UQC codes
BAG, BAL, BDL, BKL, BOU, BOX, BTL, BUN, CAN, CBM, CCM, CMS, CTN, DOZ, DRM, GGK, GMS, GRS, GYD, KGS, KLR, KME, LTR, MLT, MTR, MTS, NOS, OTH, PAC, PCS, PRS, QTL, ROL, SET, SQF, SQM, SQY, TBS, TGM, THD, TON, TUB, UGS, UNT, YDS.

**Progen impact:** items need a UQC mapping for their free-text unit (bag → BAG, kg → KGS, ton → TON, nos → NOS, box → BOX, bucket → OTH or PCS).

## 7. Error codes worth handling

### Invoice errors
| Code | Meaning |
| --- | --- |
| 2150 | Duplicate IRN |
| 2163 | Document date is in the future |
| 2172 | IGST on an intra-state supply |
| 2176 | Invalid HSN code |
| 2182 | Item taxable values don't add up to the total |
| 2189 | Invoice total doesn't match the calculated value |
| 2194 | Item total doesn't match its taxable and tax values |
| 2211 | Supplier and recipient GSTIN are the same |
| 2212 | Recipient GSTIN is URP for a B2B supply |
| 2227 | CGST and SGST amounts differ |
| 2230 | IRN cannot be cancelled because an e-way bill exists |
| 2233 | Duplicate serial numbers in line items |
| 2234 | CGST/SGST amount doesn't match the taxable value and rate |
| 2235 | IGST amount doesn't match the taxable value and rate |
| 2240 | GST rate not as notified |
| 2242 | Recipient place of supply is wrong for this supply type |
| 2258 | Supplier state code doesn't match the GSTIN |
| 2265 | Recipient state code doesn't match the GSTIN |
| 2270 | Cancellation time limit crossed |
| 2278 | IRN was already generated and cancelled for this document number |
| 2283 | IRN details cannot be given because it was generated too long ago |
| 2284 | Document date is earlier than allowed |
| 2295 | IRN already registered by another IRP |
| 2305 | 30-day limit (§2) |
| 3028 | Invalid GSTIN |
| 3029 | GSTIN inactive or cancelled |
| 3039 | PIN code doesn't belong to the state |

Under Notification 20/2025, errors 2194, 2234 and 2235 are suppressed for retail-sale-price-based HSNs from 01/02/2026.

### Authentication errors
| Code | Meaning |
| --- | --- |
| 1005 | Invalid token |
| 1008 | Invalid login credentials |
| 1010 | Invalid client ID or secret |
| 1016 | App key decryption failed |
| 3095, 3096 | Temporarily disabled for erroneous requests |
| 3098 | Invalid IRP code |

### E-way bill errors
| Code | Meaning |
| --- | --- |
| 4043 | Document date too old |
| 4055 | Cancel within 24 hours of the Part B entry |

## 8. IRN and QR code

**IRN**
- The IRN is the SHA-256 hash of supplier GSTIN + financial year (`YYYY-YY`) + document type + document number, giving 64 characters.
- Example input: `01AAAAA9999A19N2019-20INVABC01234`.
- For RCM self-invoices, the hash uses the recipient GSTIN (release note, 16/10/2026).

**Signed QR**
- Format: an RS256 JWT issued by NIC.
- Payload fields: `SellerGstin`, `BuyerGstin`, `DocNo`, `DocTyp`, `DocDt`, `TotInvVal`, `ItemCnt`, `MainHsnCode`, `Irn`, `IrnDt`.
- **Progen impact:** the invoice PDF must print this QR code and the IRN once they are generated.

## 9. E-way bill rules

Source: [NIC e-way bill FAQ](https://ewaybillgst.gov.in/Staticpages/faq.aspx).

### Core rules
- **When required:** goods movement over ₹50,000. Intra-state limits vary by state (**UNVERIFIED** per state).
- **Validity:**
  - One day per 200 km or part; for over-dimensional cargo, one day per 20 km.
  - It expires at midnight of the last day and starts from the first Part B (vehicle) entry.
- **Part B exemption:** within a state, from the consignor to the transporter, when the distance is under 50 km.
- **Distance:**
  - Auto-calculated PIN to PIN; manual entry is capped at +10%.
  - The same PIN allows up to 100 km (300 km for line sales).
  - The maximum is 4000 km.
- **Cancellation:** within 24 hours, and not after an officer has verified the bill.

### 2025 changes
Source: the [advisory](https://docs.ewaybillgst.gov.in/Documents/Advisory_on_Updates_to_EWB-updated.pdf).
- **180-day document age:** from 1 Jan 2025, documents must be dated within 180 days.
- **360-day extension cap:** for example, a bill generated on 1 Jan 2025 can be extended only to 25 Dec 2025.
- **Multi-factor authentication** became mandatory in stages by AATO:
  - over ₹100 crore: 20 Aug 2023
  - over ₹20 crore: 1 Jan 2025
  - over ₹5 crore: 1 Feb 2025
  - everyone else: 1 Apr 2025
  - **UNVERIFIED:** any effect on API calls.

### Later changes
Source: the [release notes](https://docs.ewaybillgst.gov.in/apidocs/release-notes.html).
- 02/12/2025: TDS/TCS GSTINs cannot be the supplier.
- 23/01/2026: retail-sale-price validation relaxed (error 620).
- Aug 2025: cross-portal operations expanded, "intended primarily for emergency or fall back use only".

### On hold
- Mandatory Ship-to GSTIN and voluntary closure (`CLSEWB`) were due 1 Aug 2026. Both are on hold "until further notice".
- Source: the [advisory of 29 Jul 2026](https://docs.ewaybillgst.gov.in/Documents/eWaybill_hold_Advisory.pdf).
- The API is still at v1.03.

## 10. GSPs (GST Suvidha Providers)

Public pricing is mostly unavailable.

| GSP | Notes |
| --- | --- |
| WhiteBooks | Licensed GSP. Plans ₹5,999–₹24,999, quote-based; no per-IRN price. [Pricing](https://www.whitebooks.in/pricing) |
| Masters India (MasterGST) | GSTN-appointed GSP. Pricing not public. |
| ClearTax | E-invoicing GSP API. [Docs](https://docs.cleartax.in/cleartax-docs/e-invoicing-gsp-api/introduction-to-e-invoicing-gsp-api); pricing not public. |
| Vayana GSP | Wraps the NIC paths under `/gus/irp/{irp_provider}/…`. [Docs](https://docs.gsp.vayana.com/E-Invoice/) |
| TaxPro GSP | No official pricing. **UNVERIFIED** listing: "₹5,000 per pack". |

- GSTZen was not checked.
- **UNVERIFIED:** IRN generation is said to be free of charge at the IRPs.

## What Progen needs to build (summary)

1. **Company settings:** e-invoice applicability (AATO band), GSP credentials (stored encrypted on the server) and the IRP choice.
2. **Item master:** a mapping from item unit to UQC code, and validation of six-digit HSN codes when AATO is over ₹5 crore.
3. **Invoices and credit notes:**
   - A "Generate IRN" action. It sends Version 1.1 JSON from our paise-exact totals; `GstRt` is the IGST-equivalent rate.
   - The IRN, acknowledgement number and date, signed invoice and signed QR are stored.
   - The QR and IRN are printed on the PDF.
4. **Cancellation:**
   - Within 24 hours, also cancel the IRN with a reason code.
   - After 24 hours, the only route is a credit note.
   - Block cancellation while an e-way bill is active.
5. **E-way bill:**
   - Generate from the IRN, with transport details, Part B vehicle updates, cancel within 24 hours, and extend validity in the allowed window.
   - Handle the stock transfer case: a transfer between GSTINs needs an e-way bill even without an invoice.
6. **Warnings:** the 30-day limit (AATO ≥ ₹10 crore) and the ₹50,000 e-way bill trigger.
7. **Error mapping:** map the codes in §7 to field-level messages in the invoice form.
