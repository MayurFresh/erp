// Smoke load test: sign in once per virtual user, then read the screens people open most.
//   k6 run -e BASE_URL=http://localhost:8080/api/v1 load/k6-smoke.js
// Defaults to the demo owner. Run against a test database, never against customer data.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080/api/v1';
const EMAIL = __ENV.EMAIL || 'owner@demo.in';
const PASSWORD = __ENV.PASSWORD || 'Demo@1234';

export const options = {
  scenarios: {
    browse: { executor: 'ramping-vus', startVUs: 1, stages: [
      { duration: '20s', target: 10 }, { duration: '40s', target: 10 }, { duration: '10s', target: 0 },
    ] },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500', 'p(99)<1500'],
    'http_req_duration{name:list}': ['p(95)<400'],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  const res = http.post(`${BASE}/auth/login`, JSON.stringify({ email: EMAIL, password: PASSWORD }), { headers: { 'Content-Type': 'application/json' } });
  check(res, { 'sign in ok': (r) => r.status === 200 });
  return { token: res.json('accessToken') };
}

export default function (data) {
  const headers = { Authorization: `Bearer ${data.token}` };
  const get = (path, name) => {
    const r = http.get(`${BASE}${path}`, { headers, tags: { name } });
    check(r, { [`${path} 200`]: (x) => x.status === 200 });
  };
  get('/dashboard', 'dashboard');
  get('/invoices?limit=25', 'list');
  get('/items?limit=25', 'list');
  get('/parties?limit=25', 'list');
  get('/stock?limit=25', 'list');
  sleep(1);
}
