// k6 부하 테스트 (보정본)
// 로컬 PC에서 공개 도메인을 호출하는 용도입니다.
//
// 사용 예 (smoke):
//   k6 run -e TARGET_URL="https://leechs.shop" -e TARGET_PATH="/api/v1/products" -e PEAK_VUS=1 -e HOT_TIME=30s k6-loadtest.js
//
// 환경변수
//   TARGET_URL     (필수) 예: https://leechs.shop
//   TARGET_PATH    기본 /
//   BASELINE_VUS   기본 2   (PEAK_VUS보다 크면 PEAK_VUS로 맞춤)
//   PEAK_VUS       기본 10
//   BASELINE_TIME  기본 1m  (평소 구간)
//   RAMP_UP_TIME   기본 15s (급증 구간)
//   HOT_TIME       기본 3m  (피크 유지)
//   RAMP_DOWN_TIME 기본 1m  (하강)
//   RECOVER_TIME   기본 2m  (평소 수준 복귀 관찰)
//
// 자동 중단: 실패율 10% 초과 상태가 30초 지속되면 테스트를 중단합니다.

import http from "k6/http";
import { check, sleep } from "k6";

const TARGET_URL = __ENV.TARGET_URL;
if (!TARGET_URL) {
  throw new Error(
    "TARGET_URL is required. e.g. -e TARGET_URL=https://leechs.shop"
  );
}

const TARGET_PATH = __ENV.TARGET_PATH || "/";
const PEAK_VUS = parseInt(__ENV.PEAK_VUS || "10", 10);
const BASELINE_VUS = Math.min(
  parseInt(__ENV.BASELINE_VUS || "2", 10),
  PEAK_VUS
);
const BASELINE_TIME = __ENV.BASELINE_TIME || "1m";
const RAMP_UP_TIME = __ENV.RAMP_UP_TIME || "15s";
const HOT_TIME = __ENV.HOT_TIME || "3m";
const RAMP_DOWN_TIME = __ENV.RAMP_DOWN_TIME || "1m";
const RECOVER_TIME = __ENV.RECOVER_TIME || "2m";

const URL = TARGET_URL.replace(/\/+$/, "") + TARGET_PATH;

export const options = {
  scenarios: {
    flash_sale: {
      executor: "ramping-vus",
      startVUs: BASELINE_VUS,
      gracefulRampDown: "10s",
      stages: [
        { duration: BASELINE_TIME, target: BASELINE_VUS }, // 평소
        { duration: RAMP_UP_TIME, target: PEAK_VUS }, // 급증
        { duration: HOT_TIME, target: PEAK_VUS }, // 유지
        { duration: RAMP_DOWN_TIME, target: BASELINE_VUS }, // 하강
        { duration: RECOVER_TIME, target: BASELINE_VUS }, // 복귀
      ],
    },
  },
  thresholds: {
    http_req_failed: [
      { threshold: "rate<0.10", abortOnFail: true, delayAbortEval: "30s" },
    ],
    http_req_duration: ["p(95)<3000"],
  },
};

export function setup() {
  console.log(`target=${URL} baseline=${BASELINE_VUS} peak=${PEAK_VUS} hot=${HOT_TIME}`);
}

export default function () {
  const res = http.get(URL, {
    headers: { "User-Agent": "k6-loadtest (dev autoscaling test)" },
    timeout: "10s",
  });
  check(res, { "status is 200": (r) => r.status === 200 });
  sleep(1);
}