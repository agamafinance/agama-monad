// agama-monad: Agama's keeper on Monad testnet, as a Chainlink CRE workflow.
//
// Every minute the DON:
//   1. fetches the latest Chainlink Data Streams reports (RWA Advanced v11) of
//      TSLA, NVDA, SPY and AAPL, all three session streams each, from the Data
//      Engine REST API (HMAC-signed, credentials from the Vault DON). The
//      request is pinned to the run's agreed time, floored to the minute, so
//      every node fetches the same signed bytes and they agree on them as is;
//   2. reads the oracle on Monad and keeps, per stock, the report of the stream
//      whose session is live (regular 2 or 5, extended 1 or 3, overnight 4)
//      when it is newer than what the oracle holds;
//   3. reads every Agama account and keeps the positions more than 1% off the
//      LTV their owner picked (the same rule as scripts/keeper.py);
//   4. writes one report through the Keystone Forwarder to AgamaCREReceiver,
//      which hands the Data Streams reports to the oracle (Chainlink's
//      VerifierProxy checks their signatures on chain) and runs `rebalance` on
//      the positions. Nothing to do, nothing written.
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
	decodeFunctionResult,
	encodeAbiParameters,
	encodeFunctionData,
	type Hex,
	parseAbi,
	parseAbiParameters,
	stringToHex,
	zeroAddress,
} from 'viem'
import { z } from 'zod'

const market = z.object({
	ticker: z.string(),
	adapter: z.string(),
	streams: z.object({ regular: z.string(), extended: z.string(), overnight: z.string() }),
})

export const configSchema = z.object({
	schedule: z.string(),
	chainSelectorName: z.string(),
	dataStreamsUrl: z.string(),
	receiver: z.string(),
	oracle: z.string(),
	factory: z.string(),
	pool: z.string(),
	multicall: z.string(),
	/** A report observed longer ago than this (seconds) is not brought. */
	maxReportAge: z.number(),
	maxAccounts: z.number(),
	maxRebalances: z.number(),
	markets: z.array(market),
})
type Config = z.infer<typeof configSchema>

// ---------------------------------------------------------------------------
// Chainlink Data Streams
// ---------------------------------------------------------------------------

/** Which marketStatus each stream is believed for (mirrors script/Deployer.sol). */
const SESSIONS: Record<'regular' | 'extended' | 'overnight', number[]> = {
	regular: [2, 5],
	extended: [1, 3],
	overnight: [4],
}

const enc = (s: string) => new TextEncoder().encode(s)

/** fullReport = abi(bytes32[3] ctx, bytes blob, ...): the blob is one 32-byte
 *  word per v11 field. Word 0 the feed, 2 the observation time, 6 the mid
 *  (18 decimals), 13 the marketStatus. */
function decodeReport(hex: string): { feed: string; at: number; mid: bigint; status: number } {
	const h = hex.replace(/^0x/, '')
	const word = (off: number, i: number) => h.slice((off + i * 32) * 2, (off + i * 32 + 32) * 2)
	const lenOff = Number(BigInt('0x' + word(0, 3)))
	const blob = lenOff + 32
	return {
		feed: '0x' + word(blob, 0),
		at: Number(BigInt('0x' + word(blob, 2))),
		mid: BigInt.asIntN(256, BigInt('0x' + word(blob, 6))),
		status: Number(BigInt('0x' + word(blob, 13))),
	}
}

/** One bulk request at a fixed timestamp, signed with HMAC-SHA256 over method,
 *  path, body hash, key and time. Same inputs on every node, same bytes back. */
const fetchReports = (
	req: HTTPSendRequester,
	url: string,
	ids: string[],
	atS: number,
	key: string,
	secret: string,
	nowMs: number,
): string => {
	const path = `/api/v1/reports/bulk?feedIDs=${ids.join(',')}&timestamp=${atS}`
	const toSign = `GET ${path} ${nobleHex(sha256(new Uint8Array()))} ${key} ${nowMs}`
	const signature = nobleHex(hmac(sha256, enc(secret), enc(toSign)))
	const resp = req
		.sendRequest({
			url: url + path,
			method: 'GET' as const,
			headers: {
				Authorization: key,
				'X-Authorization-Timestamp': String(nowMs),
				'X-Authorization-Signature-SHA256': signature,
			},
		})
		.result()
	if (resp.statusCode !== 200) throw new Error(`Data Streams returned ${resp.statusCode}`)
	const out: Record<string, string> = {}
	for (const r of JSON.parse(new TextDecoder().decode(resp.body)).reports ?? []) {
		out[String(r.feedID).toLowerCase()] = String(r.fullReport)
	}
	// Sorted keys: the agreed value is this exact string.
	return JSON.stringify(Object.fromEntries(Object.entries(out).sort(([a], [b]) => a.localeCompare(b))))
}

// ---------------------------------------------------------------------------
// Monad reads, batched through Multicall3
// ---------------------------------------------------------------------------

const MULTICALL = parseAbi([
	'struct Call3 { address target; bool allowFailure; bytes callData; }',
	'struct Result { bool success; bytes returnData; }',
	'function aggregate3(Call3[] calls) payable returns (Result[] returnData)',
])
const ORACLE = parseAbi([
	'struct Feed { uint128 price; uint64 observedAt; bool marketOpen; bool exists; }',
	'function feed(bytes32 ticker) view returns (Feed)',
])
const FACTORY = parseAbi(['function accountCount() view returns (uint256)', 'function accounts(uint256) view returns (address)'])
const ACCOUNT = parseAbi([
	'function targetLtvBps(address adapter) view returns (uint256)',
	'function redeemableUsdc() view returns (uint256)',
])
const ADAPTER = parseAbi(['function getAssetValue(address user, bytes data) view returns (uint256)'])
const POOL = parseAbi(['function getPositionScaledDebt(address adapter, address user, bytes data) view returns (uint256)'])

type Call = { target: Address; callData: Hex }

const multicall = (runtime: Runtime<Config>, evm: InstanceType<typeof cre.capabilities.EVMClient>, calls: Call[]): (Hex | undefined)[] => {
	if (!calls.length) return []
	const data = encodeFunctionData({
		abi: MULTICALL,
		functionName: 'aggregate3',
		args: [calls.map((c) => ({ target: c.target, allowFailure: true, callData: c.callData }))],
	})
	const result = evm
		.callContract(runtime, {
			call: encodeCallMsg({ from: zeroAddress, to: runtime.config.multicall as Address, data }),
			blockNumber: LAST_FINALIZED_BLOCK_NUMBER,
		})
		.result()
	const decoded = decodeFunctionResult({ abi: MULTICALL, functionName: 'aggregate3', data: bytesToHex(result.data) })
	return decoded.map((r) => (r.success ? r.returnData : undefined))
}

const ticker32 = (t: string): Hex => stringToHex(t, { size: 32 })

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

	// 1. Data Streams, pinned to the minute: identical on every node.
	const key = runtime.getSecret({ id: 'DATASTREAMS_API_KEY' }).result().value
	const secret = runtime.getSecret({ id: 'DATASTREAMS_API_SECRET' }).result().value
	const ids = config.markets.flatMap((m) => [m.streams.regular, m.streams.extended, m.streams.overnight])
	const atS = Math.floor(nowS / 60) * 60 - 5
	const raw: Record<string, string> = JSON.parse(
		new cre.capabilities.HTTPClient()
			.sendRequest(runtime, fetchReports, consensusIdenticalAggregation<string>())(
				config.dataStreamsUrl,
				ids,
				atS,
				key,
				secret,
				nowMs,
			)
			.result(),
	)

	// 2. What the oracle holds, and how many accounts there are.
	const head = multicall(runtime, evm, [
		...config.markets.map((m) => ({
			target: config.oracle as Address,
			callData: encodeFunctionData({ abi: ORACLE, functionName: 'feed', args: [ticker32(m.ticker)] }),
		})),
		{ target: config.factory as Address, callData: encodeFunctionData({ abi: FACTORY, functionName: 'accountCount' }) },
	])
	const prices: Hex[] = []
	const notes: string[] = []
	config.markets.forEach((m, i) => {
		const stored = head[i]
			? decodeFunctionResult({ abi: ORACLE, functionName: 'feed', data: head[i] as Hex })
			: { observedAt: 0n }
		for (const kind of ['regular', 'extended', 'overnight'] as const) {
			const full = raw[m.streams[kind].toLowerCase()]
			if (!full) continue
			const r = decodeReport(full)
			if (!SESSIONS[kind].includes(r.status)) continue
			if (r.at <= Number(stored.observedAt) || nowS - r.at > config.maxReportAge || r.mid <= 0n) continue
			prices.push(full as Hex)
			notes.push(`${m.ticker} ${(Number(r.mid / 10n ** 14n) / 1e4).toFixed(2)} (${kind})`)
			break
		}
	})

	// 3. The positions off their target.
	const count = head[config.markets.length]
		? Number(decodeFunctionResult({ abi: FACTORY, functionName: 'accountCount', data: head[config.markets.length] as Hex }))
		: 0
	const n = Math.min(count, config.maxAccounts)
	const accounts = multicall(
		runtime,
		evm,
		Array.from({ length: n }, (_, i) => ({
			target: config.factory as Address,
			callData: encodeFunctionData({ abi: FACTORY, functionName: 'accounts', args: [BigInt(i)] }),
		})),
	).flatMap((d) => (d ? [decodeFunctionResult({ abi: FACTORY, functionName: 'accounts', data: d }) as Address] : []))

	const pairs: { account: Address; adapter: Address; ticker: string }[] = []
	if (accounts.length) {
		const calls: Call[] = []
		for (const a of accounts) {
			calls.push({ target: a, callData: encodeFunctionData({ abi: ACCOUNT, functionName: 'redeemableUsdc' }) })
			for (const m of config.markets) {
				const adapter = m.adapter as Address
				calls.push({ target: a, callData: encodeFunctionData({ abi: ACCOUNT, functionName: 'targetLtvBps', args: [adapter] }) })
				calls.push({ target: adapter, callData: encodeFunctionData({ abi: ADAPTER, functionName: 'getAssetValue', args: [a, '0x'] }) })
				calls.push({
					target: config.pool as Address,
					callData: encodeFunctionData({ abi: POOL, functionName: 'getPositionScaledDebt', args: [adapter, a, '0x'] }),
				})
			}
		}
		const out = multicall(runtime, evm, calls)
		const uint = (d: Hex | undefined) => (d ? BigInt(d) : 0n)
		let k = 0
		for (const a of accounts) {
			const buffer = uint(out[k++])
			for (const m of config.markets) {
				const target = uint(out[k++])
				const value = uint(out[k++])
				const debt = uint(out[k++])
				if (target === 0n || value === 0n) continue
				const wanted = (value * target) / 10_000n
				const band = value / 100n
				if (wanted > debt + band || (debt > wanted + band && buffer > 0n)) {
					pairs.push({ account: a, adapter: m.adapter as Address, ticker: m.ticker })
				}
			}
		}
	}
	const chosen = pairs.slice(0, config.maxRebalances)

	runtime.log(`prices to bring: ${notes.join(', ') || 'none'}`)
	runtime.log(`positions to rebalance: ${chosen.map((p) => `${p.account.slice(0, 10)} ${p.ticker}`).join(', ') || 'none'}`)
	if (!prices.length && !chosen.length) return 'nothing to do'

	// 4. One report, through the forwarder.
	const payload = encodeAbiParameters(parseAbiParameters('bytes[] reports, address[] accounts, address[] adapters'), [
		prices,
		chosen.map((p) => p.account),
		chosen.map((p) => p.adapter),
	])
	const report = runtime.report(prepareReportRequest(payload)).result()
	// Monad bills the gas limit: about 90k per verified report, a rebalance
	// borrows or repays and moves vault shares.
	const gasLimit = 250_000 + 150_000 * prices.length + 1_200_000 * chosen.length
	const write = evm
		.writeReport(runtime, { receiver: config.receiver, report, gasConfig: { gasLimit: String(gasLimit) } })
		.result()
	if (write.txStatus !== TxStatus.SUCCESS) throw new Error(`write failed: ${write.errorMessage || write.txStatus}`)
	const tx = bytesToHex(write.txHash || new Uint8Array(32))
	runtime.log(`written: ${tx}`)
	return `${prices.length} prices, ${chosen.length} rebalances, tx ${tx}`
}

export function initWorkflow(config: Config) {
	const cron = new cre.capabilities.CronCapability()
	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCron)]
}
