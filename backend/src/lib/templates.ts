// Notification templates (v1.7 §6). Every message is plain text; links are client routes or full URLs.

export type TemplateId =
  | 'password_reset' | 'mfa_changed' | 'approval_requested' | 'approval_decided' | 'import_finished'
  | 'compliance_digest' | 'payment_reminder' | 'recurring_invoice' | 'ticket_update' | 'contract_renewal'
  | 'scheduled_report' | 'payment_link';

export interface Rendered { title: string; subject: string; body: string }

export interface TemplateDef {
  label: string;
  inApp: boolean;
  email: boolean;
  /** Offered on WhatsApp; users opt in (null in prefs = not offered). */
  whatsapp: boolean;
  /** Can't be turned off. */
  mandatory: boolean;
  defaultEmail: boolean;
  /** Can go out as an SMS to a customer, when the company has turned SMS on and registered the message (DLT). */
  sms?: boolean;
  render: (d: Record<string, any>) => Rendered;
}

const inr = (n: unknown) => `₹${Number(n ?? 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const DOC: Record<string, string> = {
  purchase: 'Purchase bill', payment: 'Payment', expense: 'Expense', journal: 'Journal', credit_note: 'Credit note',
  purchase_order: 'Purchase order',
};
/** Reader-facing name of a document type; never the raw key. */
const docName = (type: string) => DOC[type] ?? `${type[0]?.toUpperCase() ?? ''}${type.slice(1).replaceAll('_', ' ')}`;
const KIND: Record<string, string> = {
  items: 'Items', parties: 'Parties', opening_stock: 'Opening stock', account_balances: 'Account balances',
};

export const TEMPLATES: Record<TemplateId, TemplateDef> = {
  password_reset: {
    label: 'Password reset', inApp: false, email: true, whatsapp: false, mandatory: true, defaultEmail: true,
    render: (d) => ({
      title: 'Reset your password',
      subject: 'Reset your OneMatrix password',
      body: `Hello ${d.name},\n\nUse this link within 30 minutes to set a new password:\n${d.link}\n\n`
        + 'If you did not ask for this, ignore this email; your password stays the same.',
    }),
  },
  mfa_changed: {
    label: 'Two-factor sign-in changed', inApp: false, email: true, whatsapp: false, mandatory: true, defaultEmail: true,
    render: (d) => ({
      title: d.enabled ? 'Two-factor sign-in turned on' : 'Two-factor sign-in turned off',
      subject: d.enabled ? 'Two-factor sign-in is now on' : 'Two-factor sign-in was turned off',
      body: `Hello ${d.name},\n\nTwo-factor sign-in was turned ${d.enabled ? 'on' : 'off'} for your OneMatrix account`
        + `${d.by ? ` by ${d.by}` : ''}.\n\nIf this wasn't you, contact your administrator now.`,
    }),
  },
  approval_requested: {
    label: 'Approval needed', inApp: true, email: true, whatsapp: false, mandatory: false, defaultEmail: true,
    render: (d) => ({
      title: `Approve ${docName(d.docType)} ${inr(d.amount)}`,
      subject: `Approval needed: ${docName(d.docType)} ${d.number} for ${inr(d.amount)}`,
      body: `${d.requestedBy} sent ${docName(d.docType).toLowerCase()} ${d.number} for ${inr(d.amount)}`
        + `${d.partyName ? ` (${d.partyName})` : ''} for your approval${d.level ? ` at level ${d.level}` : ''}.`
        + `${d.url ? `\n\nOpen it: ${d.url}` : ''}`,
    }),
  },
  approval_decided: {
    label: 'Approval decided', inApp: true, email: true, whatsapp: false, mandatory: false, defaultEmail: true,
    render: (d) => ({
      title: `${d.number} ${d.decision}`,
      subject: `${docName(d.docType)} ${d.number} was ${d.decision}`,
      body: `${d.by} ${d.decision} ${d.number} (${inr(d.amount)}).`
        + `${d.documentNumber ? ` It was saved as ${d.documentNumber}.` : ''}`
        + `${d.comment ? `\n\nComment: ${d.comment}` : ''}`,
    }),
  },
  import_finished: {
    label: 'Import finished', inApp: true, email: false, whatsapp: false, mandatory: false, defaultEmail: false,
    render: (d) => ({
      title: d.status === 'done' ? `${KIND[d.kind] ?? d.kind} import finished` : `${KIND[d.kind] ?? d.kind} import failed`,
      subject: `Import ${d.status === 'done' ? 'finished' : 'failed'}`,
      body: d.status === 'done'
        ? `${d.created ?? 0} created, ${d.updated ?? 0} updated, ${d.skipped ?? 0} skipped.`
        : `Nothing was imported. ${d.error ?? ''}`.trim(),
    }),
  },
  compliance_digest: {
    label: 'Daily compliance digest', inApp: false, email: true, whatsapp: false, mandatory: false, defaultEmail: false,
    render: (d) => {
      const items = (d.items ?? []) as { label: string; dueDate: string; overdue: boolean }[];
      const lines = items.map((i) => `- ${i.overdue ? 'OVERDUE ' : ''}${i.label}: due ${i.dueDate}`).join('\n');
      return {
        title: `${items.length} filing${items.length === 1 ? '' : 's'} due`,
        subject: `${d.companyName}: ${items.filter((i) => i.overdue).length} overdue, ${items.filter((i) => !i.overdue).length} due this week`,
        body: `${d.companyName}\n\n${lines || 'Nothing is due in the next 7 days.'}`,
      };
    },
  },
  payment_reminder: {
    label: 'Payment reminder to a customer', inApp: false, email: true, whatsapp: true, mandatory: false, defaultEmail: true, sms: true,
    render: (d) => ({
      title: `Payment reminder for ${d.partyName}`,
      subject: `Payment reminder from ${d.companyName}`,
      body: `Dear ${d.partyName},\n\n${d.count} invoice${d.count === 1 ? '' : 's'} totalling ${inr(d.amountDue)} `
        + `${d.count === 1 ? 'is' : 'are'} due, the oldest since ${d.oldestDue}.`
        + `${d.upiId ? `\nPay by UPI: ${d.upiId}` : ''}\n\nRegards,\n${d.companyName}`,
    }),
  },
  recurring_invoice: {
    label: 'Recurring invoice to a customer', inApp: false, email: true, whatsapp: true, mandatory: false, defaultEmail: true,
    render: (d) => ({
      title: `Invoice ${d.invoiceNumber} for ${d.partyName}`,
      subject: `Invoice ${d.invoiceNumber} from ${d.companyName}`,
      body: `Dear ${d.partyName},\n\nInvoice ${d.invoiceNumber} dated ${d.invoiceDate} for ${inr(d.total)} is ready`
        + `${d.dueDate ? `, due on ${d.dueDate}` : ''}.${d.upiId ? `\nPay by UPI: ${d.upiId}` : ''}\n\nRegards,\n${d.companyName}`,
    }),
  },
  ticket_update: {
    label: 'Support ticket update to a customer', inApp: false, email: true, whatsapp: true, mandatory: false, defaultEmail: true,
    render: (d) => ({
      title: `Ticket ${d.number} for ${d.partyName}`,
      subject: `${d.companyName}: ticket ${d.number} ${d.headline}`,
      body: `Dear ${d.partyName},\n\nTicket ${d.number} (${d.subject}) ${d.headline}.${d.message ? `\n\n${d.message}` : ''}`
        + `\n\nRegards,\n${d.companyName}`,
    }),
  },
  contract_renewal: {
    label: 'Service contract renewal due', inApp: true, email: true, whatsapp: false, mandatory: false, defaultEmail: true,
    render: (d) => ({
      title: `Contract ${d.number} ends on ${d.endDate}`,
      subject: `Service contract ${d.number} for ${d.partyName} ends on ${d.endDate}`,
      body: `Contract ${d.number} (${d.title}) for ${d.partyName} ends on ${d.endDate}, in ${d.daysLeft} day${d.daysLeft === 1 ? '' : 's'}. Renew it to keep the customer covered.`,
    }),
  },
  scheduled_report: {
    label: 'Scheduled report', inApp: false, email: true, whatsapp: false, mandatory: true, defaultEmail: true,
    render: (d) => ({
      title: String(d.reportName),
      subject: `${d.reportName}: ${d.period}`,
      body: `${d.reportName} for ${d.companyName}, ${d.period}.\n\n${d.text}\n\nThe full table is attached as a CSV file.`,
    }),
  },
  payment_link: {
    label: 'Payment link to a customer', inApp: false, email: true, whatsapp: true, mandatory: false, defaultEmail: true, sms: true,
    render: (d) => ({
      title: `Pay invoice ${d.invoiceNumber}`,
      subject: `Pay invoice ${d.invoiceNumber} to ${d.companyName}`,
      body: `Dear ${d.partyName},\n\nYou can pay ${inr(d.amount)} for invoice ${d.invoiceNumber} online: ${d.url}`
        + `${d.expiresOn ? `\nThe link works until ${d.expiresOn}.` : ''}\n\nRegards,\n${d.companyName}`,
    }),
  },
};

export const TEMPLATE_IDS = Object.keys(TEMPLATES) as TemplateId[];
