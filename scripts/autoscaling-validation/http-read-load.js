import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Rate } from 'k6/metrics';
import { check } from 'k6';

const rate = Number(__ENV.RATE || '1');
const duration = __ENV.DURATION || '2m';
const baseUrl = (__ENV.BASE_URL || 'https://leechs.shop').replace(/\/$/, '');
const detailIds = (__ENV.DETAIL_IDS || '7,8,9,10,11,12')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);

const errors = new Counter('guard_errors');
const authErrors = new Counter('guard_auth_errors');
const unexpectedNotFound = new Counter('guard_unexpected_404');
const successful = new Rate('guard_successful');

export const options = {
  discardResponseBodies: true,
  noConnectionReuse: false,
  scenarios: {
    public_read: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: Math.min(Math.max(rate, 1), 20),
      maxVUs: 20,
      gracefulStop: '0s',
    },
  },
  thresholds: {
    http_req_duration: [{ threshold: 'p(95)<1000', abortOnFail: true, delayAbortEval: '15s' }],
    guard_errors: [{ threshold: 'count<3', abortOnFail: true, delayAbortEval: '5s' }],
    guard_auth_errors: [{ threshold: 'count<3', abortOnFail: true, delayAbortEval: '1s' }],
    guard_unexpected_404: [{ threshold: 'count<3', abortOnFail: true, delayAbortEval: '1s' }],
    dropped_iterations: [{ threshold: 'count==0', abortOnFail: true, delayAbortEval: '5s' }],
  },
};

let consecutiveFailures = 0;

export default function () {
  const listRequest = Math.random() < 0.3;
  const detailId = detailIds[Math.floor(Math.random() * detailIds.length)];
  const endpoint = listRequest
    ? '/api/v1/time-deals?status=ACTIVE'
    : `/api/v1/time-deals/items/${detailId}`;
  const response = http.get(`${baseUrl}${endpoint}`, {
    redirects: 0,
    timeout: '5s',
    tags: { endpoint: listRequest ? 'list' : 'detail' },
  });

  const ok = check(response, { 'HTTP 200': (res) => res.status === 200 });
  successful.add(ok);
  if (ok) {
    consecutiveFailures = 0;
    return;
  }

  consecutiveFailures += 1;
  errors.add(1);
  if ([401, 403, 429].includes(response.status)) authErrors.add(1);
  if (response.status === 404) unexpectedNotFound.add(1);
  if (consecutiveFailures >= 3) {
    exec.test.abort(`three consecutive failures in VU ${exec.vu.idInTest}`);
  }
}
