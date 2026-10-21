import type { z } from 'zod';
import { badRequest } from './errors.ts';

/** Parses input with a zod schema, turning problems into a 400 with a field → message map. */
export function parse<S extends z.ZodType>(schema: S, input: unknown): z.infer<S> {
  const result = schema.safeParse(input ?? {});
  if (result.success) return result.data;
  const details: Record<string, string> = {};
  for (const issue of result.error.issues) {
    const key = issue.path.join('.') || '_';
    details[key] ??= issue.message;
  }
  const first = Object.entries(details)[0];
  throw badRequest(first ? `${first[0]}: ${first[1]}` : 'Invalid input.', details);
}
