// agama-monad: Agama's whole keeper on Monad testnet, as a Chainlink CRE workflow.
//
// Every minute the DON:
//   1. asks AgamaKeeperLens, in one chain read, what each oracle holds and
//      which agent jobs are due: liquidate under HF 1, soft-deleverage under
//      HF 1.15, bring an Earn position back to the LTV its owner picked,
//      compound the vault yield into more stock through Kuru, the vault's
//      daily NAV snapshot;
//   2. fetches the latest Chainlink Data Streams reports of the nine stocks
//      (RWA Advanced v11, one stream per session) and gold (XAU/USD, v3) from
//      the Data Engine REST API, HMAC-signed with credentials from the Vault
//      DON and pinned to the run's agreed time, so every node fetches the same
//      signed bytes. Each node keeps only the reports worth a transaction: in
//      their own session, newer than what the oracle holds, and moved 0.5%,
//      changed session or older than 50 minutes on chain (the rule
//      scripts/keeper.py used). The DON agrees on that short list as is;
//   3. estimates every job from the receiver: one that would revert is
//      dropped before it costs anything, the rest get their own gas;
//   4. writes one report through the Keystone Forwarder to AgamaCREReceiver,
//      which hands the prices to the stock and gold oracles (Chainlink's
//      VerifierProxy checks their signatures on chain) and runs the jobs.
//      Nothing to do, nothing written.
import {
	bytesToHex,
	consensusIdenticalAggregation,
	cre,
	encodeCallMsg,
	getNetwork,
	type HTTPSendRequester,
	LAST_FINALIZED_BLOCK_NUMBER,
	prepareReportRequest,
	type Runtime,
	TxStatus,
} from '@chainlink/cre-sdk'
import { hmac } from '@noble/hashes/hmac'
import { sha256 } from '@noble/hashes/sha256'
import { bytesToHex as nobleHex } from '@noble/hashes/utils'
import {
	type Address,
	decodeAbiParameters,
	decodeFunctionResult,
	encodeAbiParameters,
	encodeFunctionData,
	type Hex,
	hexToString,
	parseAbi,
	parseAbiParameters,
	zeroAddress,
} from 'viem'
import { z } from 'zod'

const market = z.object({
	ticker: z.string(),
	/** Stream ids by session: regular, extended, overnight; gold has `xau`. */
	streams: z.record(z.string()),
})

export const configSchema = z.object({
	schedule: z.string(),
	chainSelectorName: z.string(),
	dataStreamsUrl: z.string(),
	receiver: z.string(),
	lens: z.string(),
	stabilityPool: z.string(),
	/** A report observed longer ago than this (seconds) is not brought. */
	maxReportAge: z.number(),
	/** Bring a price when it moved this much (bps), or the stored one is this old (s). */
	moveBps: z.number(),
	maxStoredAge: z.number(),
	maxReports: z.number(),
	accountsPerRun: z.number(),
	maxJobs: z.number(),
	markets: z.array(market),
})
type Config = z.infer<typeof configSchema>

// ---------------------------------------------------------------------------
// Chainlink Data Streams
// ---------------------------------------------------------------------------

/** Which marketStatus each stream is believed for (mirrors script/Deployer.sol). */
const SESSIONS: Record<string, number[]> = {
	regular: [2, 5],
	extended: [1, 3],
	overnight: [4],
	xau: [2],
}
const OPEN = [1, 2, 3, 4]

const enc = (s: string) => new TextEncoder().encode(s)

/** fullReport = abi(bytes32[3] ctx, bytes blob, ...): the blob is one 32-byte
 *  word per field. v11: word 0 the feed, 2 the observation time, 6 the mid
 *  (18 decimals), 13 the marketStatus. v3 (XAU/USD) has no market status: gold
 *  trades around the clock, so it reads as Regular (2). */
function decodeReport(hex: string): { feed: string; at: number; mid: bigint; status: number } {
	const h = hex.replace(/^0x/, '')
	const word = (off: number, i: number) => h.slice((off + i * 32) * 2, (off + i * 32 + 32) * 2)
	const lenOff = Number(BigInt('0x' + word(0, 3)))
	const blob = lenOff + 32
	const feed = '0x' + word(blob, 0)
	return {
		feed,
		at: Number(BigInt('0x' + word(blob, 2))),
		mid: BigInt.asIntN(256, BigInt('0x' + word(blob, 6))),
		status: feed.startsWith('0x0003') ? 2 : Number(BigInt('0x' + word(blob, 13))),
	}
}

/** What the oracle holds for one market, as the nodes need it. */
type Stored = { ticker: string; oracle: string; price: string; observedAt: number; open: boolean }
type Pick = { oracle: string; ticker: string; full: string; note: string }

/** One bulk request at a fixed timestamp, signed with HMAC-SHA256 over method,
 *  path, body hash, key and time. Same inputs on every node, same bytes back,
 *  so the same short list of reports worth bringing. */
const fetchReports = (
	req: HTTPSendRequester,
	config: Config,
	stored: Stored[],
	atS: number,
	key: string,
	secret: string,
	nowMs: number,
): string => {
	const ids = config.markets.flatMap((m) => Object.values(m.streams))
	const path = `/api/v1/reports/bulk?feedIDs=${ids.join(',')}&timestamp=${atS}`
	const toSign = `GET ${path} ${nobleHex(sha256(new Uint8Array()))} ${key} ${nowMs}`
	const signature = nobleHex(hmac(sha256, enc(secret), enc(toSign)))
	const resp = req
		.sendRequest({
			url: config.dataStreamsUrl + path,
			method: 'GET' as const,
			headers: {
				Authorization: key,
				'X-Authorization-Timestamp': String(nowMs),
				'X-Authorization-Signature-SHA256': signature,
			},
		})
		.result()
	if (resp.statusCode !== 200) throw new Error(`Data Streams returned ${resp.statusCode}`)
	const byFeed: Record<string, string> = {}
	for (const r of JSON.parse(new TextDecoder().decode(resp.body)).reports ?? []) {
		byFeed[String(r.feedID).toLowerCase()] = String(r.fullReport)
	}

	const nowS = Math.floor(nowMs / 1000)
	const picks: (Pick & { urgency: number })[] = []
	for (const m of config.markets) {
		const s = stored.find((x) => x.ticker === m.ticker)
		if (!s) continue
		// The newest report of a stream that is in its own session.
		let best: { full: string; r: ReturnType<typeof decodeReport>; kind: string } | undefined
		for (const [kind, id] of Object.entries(m.streams)) {
			const full = byFeed[id.toLowerCase()]
			if (!full) continue
			const r = decodeReport(full)
			if (!SESSIONS[kind]?.includes(r.status)) continue
			if (!best || r.at > best.r.at) best = { full, r, kind }
		}
		if (!best) continue
		const { r, full, kind } = best
		if (r.at <= s.observedAt || nowS - r.at > config.maxReportAge || r.mid <= 0n) continue
		const price = BigInt(s.price)
		const diff = r.mid > price ? r.mid - price : price - r.mid
		const moved = price === 0n || diff * 10_000n >= BigInt(config.moveBps) * price
		const sessionChanged = s.open !== OPEN.includes(r.status)
		const old = nowS - s.observedAt >= config.maxStoredAge
		if (!(moved || sessionChanged || old)) continue
		const why = moved ? 'moved' : sessionChanged ? 'session' : 'age'
		picks.push({
			oracle: s.oracle,
			ticker: m.ticker,
			full,
			note: `${m.ticker} ${(Number(r.mid / 10n ** 14n) / 1e4).toFixed(2)} (${kind}, ${why})`,
			// Moves first, then session changes, then the oldest.
			urgency: (moved ? 2e9 : sessionChanged ? 1e9 : 0) + (nowS - s.observedAt),
		})
	}
	picks.sort((a, b) => b.urgency - a.urgency || a.ticker.localeCompare(b.ticker))
	// Kept short: the DON agrees on this string, and an observation is capped.
	return JSON.stringify(picks.slice(0, config.maxReports).map(({ urgency: _, ...p }) => p))
}

// ---------------------------------------------------------------------------
// Monad
// ---------------------------------------------------------------------------

const LENS = parseAbi([
	'struct FeedState { bytes32 ticker; address oracle; uint128 price; uint64 observedAt; bool marketOpen; }',
	'struct Job { uint8 kind; address account; address adapter; bytes data; }',
	'function scan(uint256 start, uint256 count, uint256 maxJobs) view returns (FeedState[] feeds, Job[] jobs, uint256 accountCount)',
])
const AGENT = parseAbi([
	'function liquidate(address adapter, address user) returns (uint256)',
	'function softDeleverage(address stockAdapter) returns (uint256)',
	'function rebalance(address stockAdapter) returns (int256)',
	'function compoundIntoStock(address stockAdapter, uint256 usdcIn, address swapTarget, address swapSpender, bytes swapData, uint256 minStockOut) returns (uint256)',
	'function snapshot()',
])
const KINDS = ['liquidate', 'soft-deleverage', 'rebalance', 'compound', 'snapshot']

type Job = { kind: number; account: Address; adapter: Address; data: Hex }

/** The call the receiver makes for a job, so it can be estimated from there. */
function jobCall(config: Config, j: Job): { to: Address; data: Hex } {
	switch (j.kind) {
		case 0:
			return {
				to: config.stabilityPool as Address,
				data: encodeFunctionData({ abi: AGENT, functionName: 'liquidate', args: [j.adapter, j.account] }),
			}
		case 1:
			return { to: j.account, data: encodeFunctionData({ abi: AGENT, functionName: 'softDeleverage', args: [j.adapter] }) }
		case 2:
			return { to: j.account, data: encodeFunctionData({ abi: AGENT, functionName: 'rebalance', args: [j.adapter] }) }
		case 3: {
			const [usdcIn, target, spender, swapData, minOut] = decodeAbiData(j.data)
			return {
				to: j.account,
				data: encodeFunctionData({
					abi: AGENT,
					functionName: 'compoundIntoStock',
					args: [j.adapter, usdcIn, target, spender, swapData, minOut],
				}),
			}
		}
		default:
			return { to: j.adapter, data: encodeFunctionData({ abi: AGENT, functionName: 'snapshot' }) }
	}
}

const decodeAbiData = (data: Hex) =>
	decodeAbiParameters(parseAbiParameters('uint256, address, address, bytes, uint256'), data) as readonly [
		bigint,
		Address,
		Address,
		Hex,
		bigint,
	]

// Monad bills the gas limit, not the gas used, so each part gets close to its
// need: the forwarder and the receiver's loop, a verified Data Streams report
// (about 70k measured, kept at almost twice), and each job at its estimate
// plus 30%. Over the DON's per-transaction cap, the last jobs wait a minute.
const GAS_BASE = 250_000n
const GAS_PER_REPORT = 130_000n
const GAS_PER_JOB = 40_000n
const GAS_CAP = 9_500_000n

// ---------------------------------------------------------------------------
// The run
// ---------------------------------------------------------------------------

export const onCron = (runtime: Runtime<Config>): string => {
	const config = runtime.config
	const network = getNetwork({ chainFamily: 'evm', chainSelectorName: config.chainSelectorName, isTestnet: true })
	if (!network) throw new Error(`unknown chain ${config.chainSelectorName}`)
	const evm = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const nowMs = runtime.now().getTime()
	const nowS = Math.floor(nowMs / 1000)

	// 1. One read: the oracles and the jobs due. Past `accountsPerRun`
	//    accounts, each minute takes the next slice.
	const scan = (start: number) => {
		const data = encodeFunctionData({
			abi: LENS,
			functionName: 'scan',
			args: [BigInt(start), BigInt(config.accountsPerRun), BigInt(config.maxJobs)],
		})
		const out = evm
			.callContract(runtime, {
				call: encodeCallMsg({ from: zeroAddress, to: config.lens as Address, data }),
				blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
			})
			.result()
		return decodeFunctionResult({ abi: LENS, functionName: 'scan', data: bytesToHex(out.data) })
	}
	let [feeds, jobs, count] = scan(0)
	const slices = Math.ceil(Number(count) / config.accountsPerRun)
	if (slices > 1) {
		const slice = Math.floor(nowS / 60) % slices
		if (slice > 0) [feeds, jobs] = scan(slice * config.accountsPerRun)
	}
	const stored: Stored[] = feeds.map((f) => ({
		ticker: hexToString(f.ticker, { size: 32 }).replace(/\0+$/, ''),
		oracle: f.oracle,
		price: f.price.toString(),
		observedAt: Number(f.observedAt),
		open: f.marketOpen,
	}))

	// 2. Data Streams, pinned to the minute: identical on every node.
	const key = runtime.getSecret({ id: 'DATASTREAMS_API_KEY' }).result().value
	const secret = runtime.getSecret({ id: 'DATASTREAMS_API_SECRET' }).result().value
	const atS = Math.floor(nowS / 60) * 60 - 5
	const picks: Pick[] = JSON.parse(
		new cre.capabilities.HTTPClient()
			.sendRequest(runtime, fetchReports, consensusIdenticalAggregation<string>())(
				config,
				stored,
				atS,
				key,
				secret,
				nowMs,
			)
			.result(),
	)

	// 3. Each job estimated from the receiver, as it will run: a revert is
	//    dropped here, before it costs anything.
	let gas = GAS_BASE + GAS_PER_REPORT * BigInt(picks.length)
	const chosen: Job[] = []
	const done: string[] = []
	for (const j of jobs as readonly Job[]) {
		const call = jobCall(config, j)
		const label = `${KINDS[j.kind]} ${j.kind === 4 ? 'vault' : `${j.account.slice(0, 10)} ${j.adapter.slice(0, 10)}`}`
		let est: bigint
		try {
			est = evm
				.estimateGas(runtime, { msg: encodeCallMsg({ from: config.receiver as Address, to: call.to, data: call.data }) })
				.result().gas
		} catch (e) {
			runtime.log(`skipped ${label}: would revert`)
			continue
		}
		const need = (est * 13n) / 10n + GAS_PER_JOB
		if (gas + need > GAS_CAP) break
		gas += need
		chosen.push(j)
		done.push(label)
	}

	runtime.log(`prices to bring: ${picks.map((p) => p.note).join(', ') || 'none'}`)
	runtime.log(`jobs: ${done.join(', ') || 'none'}`)
	if (!picks.length && !chosen.length) return 'nothing to do'

	// 4. One report, through the forwarder: the prices grouped by oracle.
	const oracles = [...new Set(picks.map((p) => p.oracle))].sort()
	const payload = encodeAbiParameters(
		parseAbiParameters(
			'(address oracle, bytes[] reports)[] prices, (uint8 kind, address account, address adapter, bytes data)[] jobs',
		),
		[
			oracles.map((o) => ({
				oracle: o as Address,
				reports: picks.filter((p) => p.oracle === o).map((p) => p.full as Hex),
			})),
			chosen,
		],
	)
	const report = runtime.report(prepareReportRequest(payload)).result()
	const write = evm
		.writeReport(runtime, { receiver: config.receiver, report, gasConfig: { gasLimit: gas.toString() } })
		.result()
	if (write.txStatus !== TxStatus.SUCCESS) throw new Error(`write failed: ${write.errorMessage || write.txStatus}`)
	const tx = bytesToHex(write.txHash || new Uint8Array(32))
	runtime.log(`written: ${tx}`)
	return `${picks.length} prices, ${chosen.length} jobs, gas ${gas}, tx ${tx}`
}

export function initWorkflow(config: Config) {
	const cron = new cre.capabilities.CronCapability()
	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCron)]
}
