// IndiaMART Lead Manager pull API (CRM listing v2). Fetch is injectable so tests never reach the real service.
// Documented: GET with glusr_crm_key, start_time, end_time (IST, DD-MM-YYYYHH:MM:SS), at most 7 days apart, at most one hit
// per 5 minutes. Reply is {CODE, STATUS, MESSAGE, TOTAL_RECORDS, RESPONSE: [...]}; CODE 204 means no leads.

export const INDIAMART_URL = 'https://mapi.indiamart.com/wservce/crm/crmListing/v2/';

export type FetchLike = (url: string, init?: { signal?: AbortSignal }) => Promise<{ ok: boolean; status: number; text(): Promise<string> }>;

export interface IndiamartLead {
  uniqueId: string; name: string; phone: string | null; email: string | null; companyName: string | null;
  city: string | null; stateCode: string | null; requirement: string | null; queryTime: string | null;
}

export class IndiamartError extends Error {}

const STATES: Record<string, string> = {
  'jammu and kashmir': '01', 'himachal pradesh': '02', punjab: '03', chandigarh: '04', uttarakhand: '05', haryana: '06', delhi: '07',
  rajasthan: '08', 'uttar pradesh': '09', bihar: '10', sikkim: '11', 'arunachal pradesh': '12', nagaland: '13', manipur: '14',
  mizoram: '15', tripura: '16', meghalaya: '17', assam: '18', 'west bengal': '19', jharkhand: '20', odisha: '21', orissa: '21',
  chhattisgarh: '22', 'madhya pradesh': '23', gujarat: '24', 'dadra and nagar haveli and daman and diu': '26', daman: '26',
  maharashtra: '27', 'andhra pradesh': '37', karnataka: '29', goa: '30', lakshadweep: '31', kerala: '32', 'tamil nadu': '33',
  puducherry: '34', 'andaman and nicobar islands': '35', telangana: '36', ladakh: '38',
};
export const stateCodeOf = (name: string | null | undefined): string | null =>
  name ? (STATES[name.trim().toLowerCase().replace(/&/g, 'and')] ?? null) : null;


/** DD-MM-YYYYHH:MM:SS in Indian time, the timestamp form IndiaMART documents. */
export function istStamp(d: Date): string {
  const p = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
  }).formatToParts(d).reduce<Record<string, string>>((m, x) => { m[x.type] = x.value; return m; }, {});
  return `${p.day}-${p.month}-${p.year}${p.hour}:${p.minute}:${p.second}`;
}

const str = (v: unknown): string | null => (typeof v === 'string' && v.trim() !== '' ? v.trim() : null);

/** Pulls enquiries between two instants. Throws IndiamartError with IndiaMART's own message on failure. */
export async function pullIndiamart(key: string, from: Date, to: Date, fetchFn: FetchLike = fetch as unknown as FetchLike): Promise<IndiamartLead[]> {
  const url = `${INDIAMART_URL}?glusr_crm_key=${encodeURIComponent(key)}&start_time=${encodeURIComponent(istStamp(from))}&end_time=${encodeURIComponent(istStamp(to))}`;
  let res;
  try { res = await fetchFn(url, { signal: AbortSignal.timeout(20_000) }); } catch { throw new IndiamartError('Could not reach IndiaMART. Try again in a few minutes.'); }
  let body: Record<string, unknown>;
  try { body = JSON.parse(await res.text()) as Record<string, unknown>; } catch { throw new IndiamartError('IndiaMART sent a reply that could not be read. Try again later.'); }
  const code = Number(body.CODE ?? res.status);
  if (code === 204) return [];
  if (code !== 200 || !Array.isArray(body.RESPONSE)) {
    throw new IndiamartError(str(body.MESSAGE) ?? `IndiaMART refused the request (code ${code}). Check the key.`);
  }
  const out: IndiamartLead[] = [];
  for (const r of body.RESPONSE as Record<string, unknown>[]) {
    const id = str(r.UNIQUE_QUERY_ID);
    if (!id) continue;
    const product = str(r.QUERY_PRODUCT_NAME);
    const msg = str(r.QUERY_MESSAGE);
    out.push({
      uniqueId: id.slice(0, 100), name: (str(r.SENDER_NAME) ?? 'IndiaMART Buyer').slice(0, 120),
      phone: ((p) => (p && p.length >= 5 ? p.slice(0, 20) : null))(str(r.SENDER_MOBILE)), email: str(r.SENDER_EMAIL)?.slice(0, 200) ?? null,
      companyName: str(r.SENDER_COMPANY)?.slice(0, 200) ?? null, city: str(r.SENDER_CITY)?.slice(0, 80) ?? null,
      stateCode: stateCodeOf(str(r.SENDER_STATE)),
      requirement: [product, msg].filter(Boolean).join(': ').slice(0, 2000) || null, queryTime: str(r.QUERY_TIME),
    });
  }
  return out;
}
