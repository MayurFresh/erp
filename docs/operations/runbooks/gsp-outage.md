# GSP outage

The GSP adapter handles e-invoice (IRN), e-way bill and GSTR-1 upload. Code: `backend/src/lib/gsp/`, routes in `backend/src/modules/gsp.ts` and `einvoice.ts`. Provider timeouts are enforced per call; errors are mapped to 502 or 503 (`platform.test.ts :: seals provider credentials and maps provider failures to 502 and 503`). Transient errors (timeouts, network, HTTP 5xx) are marked retryable.

## Confirm

1. Test the connection: `POST /api/v1/company/gsp/test` (or the "Test connection" button in company settings).
2. Look at recent submissions: `GET /api/v1/gst/submissions`.
3. Check the provider's own status page.

## While it is down

- Invoices still post. The books do not depend on the GSP.
- Do not switch to manual mode for e-invoice unless the owner and the accountant agree. In manual mode the IRN is entered by hand from the portal. GSTR-1 upload refuses manual mode.
- Record the outage window. IRN reporting has statutory time limits; the accountant decides what to do about late reporting. Statutory figures are unverified until a chartered accountant reviews them.
- Cancelling an IRN is allowed only within 24 hours (`einvoice.test.ts :: records IRN details and enforces the 24 hour cancel window`).

## After it is back

1. Run the connection test again.
2. Retry any failed submissions from the e-invoice screen. Failed background jobs: jobs.md.
3. Compare the count of invoices without an IRN against the portal before filing.

## If credentials are the problem

Credentials are stored sealed. Re-enter them in company settings; the API never returns them. If every GSP and 2FA secret fails to open after a deploy, `DATA_KEY` or `JWT_SECRET` changed (rotate-secrets.md).
