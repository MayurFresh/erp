export type GspCapability = 'einvoice' | 'ewaybill' | 'gstr1_save';

export interface GspCall { gstin: string; credentials: Record<string, string>; timeoutMs: number }

export interface GspAdapter {
  id: string;
  name: string;
  capabilities: ReadonlySet<GspCapability>;
  credentialFields: { key: string; label: string; secret: boolean }[];
  ping(c: GspCall): Promise<{ ok: boolean; message: string }>;
  generateIrn(c: GspCall, payload: object): Promise<{ irn: string; ackNo: string; ackDate: Date; signedQr: string; signedInvoice: string | null }>;
  cancelIrn(c: GspCall, irn: string, reasonCode: '1' | '2' | '3' | '4', remark: string): Promise<{ cancelledAt: Date }>;
  generateEwb(c: GspCall, input: { irn: string; transportMode: string; distanceKm: number; vehicleNo?: string; transporterGstin?: string }): Promise<{ ewbNo: string; ewbDate: Date; validUntil: Date | null }>;
  cancelEwb(c: GspCall, ewbNo: string, reasonCode: '1' | '2' | '3' | '4', remark: string): Promise<{ cancelledAt: Date }>;
  saveGstr1?(c: GspCall, period: string, json: object): Promise<{ reference: string; status: string }>;
}

/** `transient` errors (timeouts, network, HTTP 5xx) are retried; the others are the provider's answer. */
export class GspError extends Error {
  readonly code: string;
  readonly transient: boolean;
  constructor(code: string, message: string, transient: boolean) {
    super(message);
    this.code = code;
    this.transient = transient;
  }
}
