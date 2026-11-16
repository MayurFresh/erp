// Shared CRM helpers used by both the CRM routes and quotations, so deal stage rules live in one place.
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';

export interface Stage { id: string; name: string; probability: number; kind: string; sort: number; is_active: boolean }

const DEFAULT_STAGES = [
  { name: 'New', probability: 10, kind: 'open' },
  { name: 'Contacted', probability: 20, kind: 'open' },
  { name: 'Quotation sent', probability: 50, kind: 'open' },
  { name: 'Negotiation', probability: 70, kind: 'open' },
  { name: 'Won', probability: 100, kind: 'won' },
  { name: 'Lost', probability: 0, kind: 'lost' },
];

/** All stages of the company in order, creating the defaults the first time. Includes inactive ones. */
export async function ensureStages(tx: Tx, ctx: RequestContext): Promise<Stage[]> {
  const load = () => tx.selectFrom('crm_stages').select(['id', 'name', 'probability', 'kind', 'sort', 'is_active'])
    .where('company_id', '=', ctx.companyId).orderBy('sort').execute();
  let rows = await load();
  if (rows.length === 0) {
    await tx.insertInto('crm_stages').values(DEFAULT_STAGES.map((s, i) => ({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, name: s.name, probability: s.probability, kind: s.kind, sort: i + 1,
    }))).onConflict((oc) => oc.columns(['company_id', 'name']).doNothing()).execute();
    rows = await load();
  }
  return rows.map((r) => ({ ...r, probability: Number(r.probability) }));
}

/** Moves a deal to another stage and records the change. */
export async function moveDealStage(tx: Tx, ctx: RequestContext, deal: { id: string; stage_id: string }, toStageId: string,
  extra: Record<string, unknown> = {}): Promise<void> {
  await tx.updateTable('crm_deals').set({ stage_id: toStageId, stage_changed_at: new Date(), ...extra })
    .where('id', '=', deal.id).where('company_id', '=', ctx.companyId).execute();
  await tx.insertInto('crm_deal_stage_history').values({
    tenant_id: ctx.tenantId, deal_id: deal.id, from_stage_id: deal.stage_id, to_stage_id: toStageId, changed_by: ctx.userId,
  }).execute();
}

/** Open (not done) follow-ups go away when a lead or deal closes. */
export async function dropOpenFollowUps(tx: Tx, ctx: RequestContext, ref: { dealId?: string; leadId?: string }): Promise<void> {
  let q = tx.deleteFrom('crm_activities').where('company_id', '=', ctx.companyId).where('done_at', 'is', null);
  if (ref.dealId) q = q.where('deal_id', '=', ref.dealId);
  else if (ref.leadId) q = q.where('lead_id', '=', ref.leadId);
  else return;
  await q.execute();
}

/** Marks an open deal won. Returns false when the deal is missing or already closed. */
export async function markDealWon(tx: Tx, ctx: RequestContext, dealId: string, value?: number): Promise<boolean> {
  const deal = await tx.selectFrom('crm_deals').select(['id', 'stage_id', 'status', 'value'])
    .where('id', '=', dealId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!deal || deal.status !== 'open') return false;
  const won = (await ensureStages(tx, ctx)).find((s) => s.kind === 'won');
  if (!won) return false;
  await moveDealStage(tx, ctx, deal, won.id, { status: 'won', won_at: new Date(), value: value ?? Number(deal.value) });
  await dropOpenFollowUps(tx, ctx, { dealId });
  return true;
}

/** When a quotation is made for an open deal, moves it forward to the first open stage at 50% or more. Never moves back. */
export async function advanceDealForQuotation(tx: Tx, ctx: RequestContext, dealId: string): Promise<void> {
  const deal = await tx.selectFrom('crm_deals').select(['id', 'stage_id', 'status'])
    .where('id', '=', dealId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!deal || deal.status !== 'open') return;
  const stages = await ensureStages(tx, ctx);
  const current = stages.find((s) => s.id === deal.stage_id);
  const target = stages.find((s) => s.kind === 'open' && s.is_active && s.probability >= 50);
  if (current && target && current.sort < target.sort) await moveDealStage(tx, ctx, deal, target.id);
}
