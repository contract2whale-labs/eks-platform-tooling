// scripts/lab/latency-probe.js — incident-common: commerce-api Pod 안에서 Store API 요청을 일정 간격으로 보내고 요청마다 응답 시간을 TSV 로 찍습니다.
// 앱 Pod 안의 127.0.0.1 로 보내므로 port-forward · SSM 터널의 지연이 섞이지 않고, 같은 요청이 앱의 요청 지표(course_http_request_duration_seconds)에도 기록됩니다.
// 사용: kubectl exec -i <commerce-api Pod> -c commerce-api -- env KEY=<publishable key> node - < scripts/lab/latency-probe.js > latency.tsv
// 환경 변수: KEY (필수, x-publishable-api-key — 브라우저가 들고 다니는 공개 식별자) · URL (기본 http://127.0.0.1:9000/store/products?limit=1&fields=handle)
//            COUNT (기본 200) · INTERVAL_MS (기본 1000, 시작 시각 기준의 고정 간격) · TIMEOUT_MS (기본 5000)
// 표준 출력: 요청마다 "번호<TAB>HTTP 코드<TAB>응답 시간(초)" 한 줄 — 응답 시간은 본문을 다 받은 시각까지, 연결 실패 · 시간 초과는 코드 000
// 표준 오류: 끝에 한 줄 LATENCY_SUMMARY count= answered= non_2xx= failed= p50= p95= max= start= end= (p95 는 응답이 온 요청의 nearest-rank, start · end 는 epoch 초)
// 종료 코드: 0 끝까지 보냄 (판정은 문서가 요약 줄로 함) · 2 입력 오류. Node.js 22 의 내장 모듈만 씁니다(설치 없음, 앱 이미지 node:22-alpine 의 node 로 돎).
'use strict'
const http = require('node:http')
const { performance } = require('node:perf_hooks')

const key = process.env.KEY || ''
const target = new URL(process.env.URL || 'http://127.0.0.1:9000/store/products?limit=1&fields=handle')
const count = Number(process.env.COUNT || 200)
const interval = Number(process.env.INTERVAL_MS || 1000)
const timeout = Number(process.env.TIMEOUT_MS || 5000)

if (!key) {
  console.error('LATENCY_ERROR KEY is empty')
  process.exit(2)
}
if (!Number.isInteger(count) || count < 1 || !(interval >= 0) || !(timeout > 0)) {
  console.error('LATENCY_ERROR COUNT, INTERVAL_MS or TIMEOUT_MS is not valid')
  process.exit(2)
}

function once() {
  return new Promise((resolve) => {
    let done = false
    const finish = (code) => {
      if (done) return
      done = true
      resolve([code, (performance.now() - t0) / 1000])
    }
    const t0 = performance.now()
    const req = http.get(target, { headers: { 'x-publishable-api-key': key }, timeout }, (res) => {
      res.resume()
      res.on('end', () => finish(res.statusCode))
      res.on('error', () => finish(0))
    })
    req.on('timeout', () => req.destroy(new Error('timeout')))
    req.on('error', () => finish(0))
  })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function main() {
  const start = Date.now()
  const answered = []
  let non2xx = 0
  let failed = 0
  for (let i = 1; i <= count; i++) {
    const wait = start + (i - 1) * interval - Date.now()
    if (wait > 0) await sleep(wait)
    const [code, sec] = await once()
    if (code === 0) failed++
    else {
      answered.push(sec)
      if (code < 200 || code > 299) non2xx++
    }
    process.stdout.write(`${i}\t${code === 0 ? '000' : code}\t${sec.toFixed(4)}\n`)
  }
  const sorted = answered.slice().sort((a, b) => a - b)
  const rank = (q) => (sorted.length ? sorted[Math.max(0, Math.ceil(q * sorted.length) - 1)].toFixed(4) : 'none')
  const max = sorted.length ? sorted[sorted.length - 1].toFixed(4) : 'none'
  console.error(
    `LATENCY_SUMMARY count=${count} answered=${answered.length} non_2xx=${non2xx} failed=${failed} ` +
      `p50=${rank(0.5)} p95=${rank(0.95)} max=${max} start=${Math.floor(start / 1000)} end=${Math.ceil(Date.now() / 1000)}`
  )
}

main()
