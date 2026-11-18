import { z } from 'zod';

// Lower-cased; a password matches when, lower-cased with non-letters/digits removed, it equals one of these.
const COMMON = new Set([
  'password', 'password1', 'password12', 'password123', 'password1234', 'passw0rd', 'p@ssw0rd', 'qwerty123', 'qwerty1',
  'abc12345', 'abcd1234', 'abc123456', 'admin123', 'admin1234', 'administrator1', 'welcome1', 'welcome123', 'welcome@123',
  'letmein1', 'iloveyou1', 'monkey123', 'dragon123', 'sunshine1', 'princess1', 'football1', 'baseball1', 'master123',
  'india123', 'india@123', 'bharat123', 'mumbai123', 'delhi123', 'qwertyuiop1', 'asdfgh123', 'zxcvbnm1', 'test1234',
  'test@123', 'user1234', 'changeme1', 'default1', 'secret123', 'login123', 'pass1234', 'pass@123', 'onematrix123',
  'onematrix@123', 'password@123', 'admin@123', 'qwerty@123', 'company123', 'office123', 'account1', 'temp1234', 'guest123', 'root1234', 'love1234', 'superman1',
  '1q2w3e4r', '1qaz2wsx', 'q1w2e3r4', 'a1b2c3d4', 'zaq12wsx', 'trustno1', 'whatever1', 'computer1', 'internet1',
]);
const normal = (s: string) => s.toLowerCase().replace(/[^a-z0-9@]/g, '');

/** Problems with a new password, or null. `email` lets us refuse passwords built from the address. */
export function passwordProblem(pw: string, email?: string | null): string | null {
  if (pw.length < 8) return 'Use at least 8 characters';
  if (pw.length > 128) return 'Use at most 128 characters';
  if (!/[A-Za-z]/.test(pw) || !/[0-9]/.test(pw)) return 'Use at least one letter and one digit';
  if (COMMON.has(pw.toLowerCase()) || COMMON.has(normal(pw))) {
    return 'This password is too common';
  }
  const local = email?.split('@')[0]?.toLowerCase() ?? '';
  if (local.length >= 4 && pw.toLowerCase().includes(local)) return "Don't use your email address in the password";
  return null;
}

/** zod field for a new password; the email check needs `checkPassword` with the user's email. */
export const newPasswordField = z.string().max(128).superRefine((pw, ctx) => {
  const p = passwordProblem(pw);
  if (p) ctx.addIssue({ code: 'custom', message: p });
});
