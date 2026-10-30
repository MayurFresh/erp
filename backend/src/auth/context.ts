import { sql } from 'kysely';
import { withTenant, type Db, type Tx } from '../db/database.ts';
import { todayIst } from '../lib/dates.ts';
import { forbidden, sessionRevoked } from '../lib/errors.ts';

export interface Membership {
  companyId: string;
  roles: { id: string; name: string }[];
  permissions: Set<string>;
  /** null = every location of the company. */
  locationIds: string[] | null;
}

/** Everything a request needs to know about who is calling and what they may do. */
export class RequestContext {
  readonly db: Db;
  readonly tenantId: string;
  readonly userId: string;
  readonly userName: string;
  readonly memberships: Membership[];
  readonly company: Membership;

  constructor(db: Db, tenantId: string, userId: string, userName: string, memberships: Membership[], company: Membership) {
    this.db = db;
    this.tenantId = tenantId;
    this.userId = userId;
    this.userName = userName;
    this.memberships = memberships;
    this.company = company;
  }

  get companyId(): string {
    return this.company.companyId;
  }

  can(permission: string): boolean {
    return this.company.permissions.has(permission);
  }

  require(...anyOf: string[]): void {
    if (!anyOf.some((p) => this.can(p))) throw forbidden();
  }

  canAccessLocation(locationId: string): boolean {
    return this.company.locationIds === null || this.company.locationIds.includes(locationId);
  }

  requireLocation(locationId: string): void {
    if (!this.canAccessLocation(locationId)) throw forbidden('This location is outside your access.');
  }

  /** Runs `fn` in a tenant-bound transaction. */
  tx<T>(fn: (tx: Tx) => Promise<T>): Promise<T> {
    return withTenant(this.db, this.tenantId, fn);
  }
}

/** Loads the caller's companies, roles, permissions and location scope. */
export async function loadMemberships(tx: Tx, userId: string): Promise<{ name: string; memberships: Membership[] }> {
  const user = await tx.selectFrom('users').select(['name', 'is_active']).where('id', '=', userId).executeTakeFirst();
  if (!user || !user.is_active) throw sessionRevoked('This account is not active.');

  const today = todayIst();
  const rows = await tx
    .selectFrom('user_roles as ur')
    .innerJoin('roles as r', 'r.id', 'ur.role_id')
    .innerJoin('companies as c', 'c.id', 'ur.company_id')
    .select(['ur.company_id', 'ur.location_ids', 'r.id as role_id', 'r.name as role_name', 'r.permissions', 'c.created_at'])
    .where('ur.user_id', '=', userId)
    .where((eb) => eb.or([eb('ur.valid_from', 'is', null), eb('ur.valid_from', '<=', sql<string>`${today}::date`)]))
    .where((eb) => eb.or([eb('ur.valid_to', 'is', null), eb('ur.valid_to', '>=', sql<string>`${today}::date`)]))
    .orderBy('c.created_at')
    .execute();

  const byCompany = new Map<string, Membership>();
  for (const row of rows) {
    let m = byCompany.get(row.company_id);
    if (!m) {
      m = { companyId: row.company_id, roles: [], permissions: new Set(), locationIds: [] };
      byCompany.set(row.company_id, m);
    }
    m.roles.push({ id: row.role_id, name: row.role_name });
    for (const p of row.permissions) m.permissions.add(p);
    // Any unrestricted assignment makes the whole membership unrestricted.
    if (m.locationIds !== null) {
      m.locationIds = row.location_ids === null ? null : [...new Set([...m.locationIds, ...row.location_ids])];
    }
  }
  return { name: user.name, memberships: [...byCompany.values()] };
}
