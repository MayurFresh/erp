import { randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, stat, unlink, writeFile } from 'node:fs/promises';
import { join, resolve, sep } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Tx } from '../db/database.ts';
import { badRequest, notFound } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

export const MAX_FILE_BYTES = 10 * 1024 * 1024;

const TYPES = [
  { mime: 'image/jpeg', ext: 'jpg', test: (b: Buffer) => b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff },
  { mime: 'image/png', ext: 'png', test: (b: Buffer) => b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) },
  { mime: 'image/webp', ext: 'webp', test: (b: Buffer) => b.length >= 12 && b.toString('latin1', 0, 4) === 'RIFF' && b.toString('latin1', 8, 12) === 'WEBP' },
  { mime: 'application/pdf', ext: 'pdf', test: (b: Buffer) => b.toString('latin1', 0, 5) === '%PDF-' },
];
export const IMAGE_TYPES = ['image/jpeg', 'image/png', 'image/webp'];

/** The file's real type from its first bytes; the client's claimed type and name are ignored. */
export function sniff(bytes: Buffer) {
  return TYPES.find((t) => t.test(bytes)) ?? null;
}

/** A display name only: never used to build a path. */
function displayName(raw: string | undefined, ext: string): string {
  const base = (raw ?? '').split(/[\\/]/).pop() ?? '';
  // eslint-disable-next-line no-control-regex
  const clean = base.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 200);
  return clean || `upload.${ext}`;
}

export const fileUrl = (id: string) => `/api/v1/files/${id}`;

export function fileRef(f: { id: string; name: string; mime_type: string; size: number }) {
  return { id: f.id, name: f.name, mimeType: f.mime_type, size: f.size, url: fileUrl(f.id) };
}

/** Checks that files exist in this business (row-level security) and, optionally, are images. */
export async function requireFiles(tx: Tx, refs: { id: string; field: string }[], imagesOnly: boolean) {
  const ids = [...new Set(refs.map((r) => r.id))];
  const rows = ids.length ? await tx.selectFrom('files').select(['id', 'mime_type']).where('id', 'in', ids).execute() : [];
  for (const ref of refs) {
    const f = rows.find((r) => r.id === ref.id);
    if (!f) throw badRequest('File not found. Upload it first.', { [ref.field]: 'Not found' });
    if (imagesOnly && !IMAGE_TYPES.includes(f.mime_type)) throw badRequest('This must be a JPEG, PNG or WebP image.', { [ref.field]: 'Not an image' });
  }
}

const contentDisposition = (name: string) => {
  const ascii = name.replace(/[^\x20-\x7e]|["\\]/g, '_');
  return `inline; filename="${ascii}"; filename*=UTF-8''${encodeURIComponent(name)}`;
};

export async function fileRoutes(app: FastifyInstance, uploadDir: string) {
  const root = resolve(uploadDir);

  app.post('/files', async (req, reply) => {
    const ctx = req.ctx;
    if (!req.isMultipart()) throw badRequest('Send the file as multipart/form-data in a field named "file".', { file: 'Required' });
    let part;
    try {
      part = await req.file({ limits: { fileSize: MAX_FILE_BYTES, files: 1 } });
    } catch {
      throw badRequest('Could not read the upload.', { file: 'Unreadable' });
    }
    if (!part || part.fieldname !== 'file') throw badRequest('Send the file in a field named "file".', { file: 'Required' });
    let bytes: Buffer;
    try {
      bytes = await part.toBuffer();
    } catch (err) {
      if ((err as { code?: string }).code === 'FST_REQ_FILE_TOO_LARGE') throw badRequest('The file is larger than 10 MB.', { file: 'Larger than 10 MB' });
      throw badRequest('Could not read the upload.', { file: 'Unreadable' });
    }
    if (!bytes.length) throw badRequest('The file is empty.', { file: 'Empty' });
    const type = sniff(bytes);
    if (!type) throw badRequest('Only JPEG, PNG, WebP or PDF files can be uploaded.', { file: 'Unsupported file type' });

    const id = randomUUID();
    const key = `${ctx.tenantId}/${id}.${type.ext}`;
    const path = join(root, ctx.tenantId, `${id}.${type.ext}`);
    const name = displayName(part.filename, type.ext);
    await mkdir(join(root, ctx.tenantId), { recursive: true });
    await writeFile(path, bytes, { flag: 'wx' });
    try {
      const saved = await ctx.tx(async (tx) => {
        const row = await tx.insertInto('files').values({
          id, tenant_id: ctx.tenantId, company_id: ctx.companyId || null, name, mime_type: type.mime, size: bytes.length,
          storage_key: key, created_by: ctx.userId,
        }).returningAll().executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'file', id, 'upload', null, { name, mimeType: type.mime, size: bytes.length });
        return row;
      });
      return reply.status(201).send(fileRef(saved));
    } catch (err) {
      await unlink(path).catch(() => {});
      throw err;
    }
  });

  app.get<{ Params: { id: string } }>('/files/:id', async (req, reply) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const f = await ctx.tx((tx) => tx.selectFrom('files').selectAll().where('id', '=', id).executeTakeFirst());
    if (!f) throw notFound('File');
    const path = resolve(root, f.storage_key);
    if (!path.startsWith(root + sep)) throw notFound('File');
    const info = await stat(path).catch(() => null);
    if (!info?.isFile()) throw notFound('File');
    return reply
      .type(f.mime_type)
      .header('content-length', info.size)
      .header('content-disposition', contentDisposition(f.name))
      .header('cache-control', 'private, max-age=86400')
      .header('cross-origin-resource-policy', 'cross-origin')
      .send(createReadStream(path));
  });
}
