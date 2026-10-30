// Pre-filing check result shared by GST and TDS (API v1.6 §3, §5).

export interface PrefileCheck {
  id: string;
  title: string;
  status: 'pass' | 'warn' | 'fail' | 'skip';
  detail: string;
  count: number | null;
  link: string | null; // client path
}

export const canFile = (checks: PrefileCheck[]) => checks.every((c) => c.status !== 'fail');
